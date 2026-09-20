using System.Diagnostics;
using System.Globalization;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Benchpilot.Core;
using Benchpilot.Runtime;

namespace Benchpilot.Drivers.ScpiPower;

public sealed class ScpiPowerResourceFactory : IBenchResourceFactory
{
    public string DriverName => "scpi-power";

    public object Create(string resourceId, BenchResourceConfig config)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(resourceId);
        ArgumentNullException.ThrowIfNull(config);

        if (!config.Capabilities.Contains("power", StringComparer.OrdinalIgnoreCase))
            throw new InvalidOperationException(
                $"Resource '{resourceId}' uses scpi-power but does not declare the 'power' capability.");

        var host = RequireString(config, "host", resourceId);
        var port = GetInt(config, "port") ?? 5025;
        var connectTimeoutMs = GetInt(config, "connectTimeoutMs") ?? 3000;
        var ioTimeoutMs = GetInt(config, "ioTimeoutMs") ?? 3000;
        var currentLimitA = GetDouble(config, "currentLimitA");
        var channel = GetString(config, "channel");

        var commands = new ScpiPowerCommands(
            GetString(config, "setVoltage") ?? "VOLT {voltage}",
            GetString(config, "setCurrentLimit") ?? "CURR {current}",
            GetString(config, "outputOn") ?? "OUTP ON",
            GetString(config, "outputOff") ?? "OUTP OFF",
            GetString(config, "measureVoltage") ?? "MEAS:VOLT?",
            GetString(config, "measureCurrent") ?? "MEAS:CURR?",
            GetString(config, "identify") ?? "*IDN?");

        if (port is <= 0 or > 65535)
            throw new InvalidOperationException($"Resource '{resourceId}' has invalid TCP port {port}.");
        if (connectTimeoutMs is < 100 or > 120_000)
            throw new InvalidOperationException(
                $"Resource '{resourceId}' connectTimeoutMs must be between 100 and 120000.");
        if (ioTimeoutMs is < 100 or > 120_000)
            throw new InvalidOperationException(
                $"Resource '{resourceId}' ioTimeoutMs must be between 100 and 120000.");
        if (currentLimitA is <= 0)
            throw new InvalidOperationException(
                $"Resource '{resourceId}' currentLimitA must be greater than zero when configured.");

        ValidateCommands(resourceId, commands);

        return new ScpiPowerSupply(new ScpiPowerSettings(
            host,
            port,
            connectTimeoutMs,
            ioTimeoutMs,
            currentLimitA,
            channel,
            commands));
    }

    private static void ValidateCommands(string resourceId, ScpiPowerCommands commands)
    {
        foreach (var command in new[]
        {
            commands.SetVoltage,
            commands.SetCurrentLimit,
            commands.OutputOn,
            commands.OutputOff,
            commands.MeasureVoltage,
            commands.MeasureCurrent,
            commands.Identify,
        })
        {
            if (string.IsNullOrWhiteSpace(command))
                throw new InvalidOperationException(
                    $"Resource '{resourceId}' contains an empty SCPI command template.");
            if (command.IndexOfAny(['\r', '\n']) >= 0)
                throw new InvalidOperationException(
                    $"Resource '{resourceId}' SCPI command templates must be single-line.");
        }
    }

    private static string RequireString(BenchResourceConfig config, string key, string resourceId) =>
        GetString(config, key) is { Length: > 0 } value
            ? value
            : throw new InvalidOperationException(
                $"Resource '{resourceId}' requires scpi-power setting '{key}'.");

    private static string? GetString(BenchResourceConfig config, string key)
    {
        if (!config.Settings.TryGetValue(key, out var value)) return null;
        if (value.ValueKind != JsonValueKind.String)
            throw new InvalidOperationException($"SCPI power setting '{key}' must be a string.");
        return value.GetString();
    }

    private static int? GetInt(BenchResourceConfig config, string key)
    {
        if (!config.Settings.TryGetValue(key, out var value)) return null;
        if (!value.TryGetInt32(out var result))
            throw new InvalidOperationException($"SCPI power setting '{key}' must be an integer.");
        return result;
    }

    private static double? GetDouble(BenchResourceConfig config, string key)
    {
        if (!config.Settings.TryGetValue(key, out var value)) return null;
        if (!value.TryGetDouble(out var result))
            throw new InvalidOperationException($"SCPI power setting '{key}' must be a number.");
        return result;
    }
}

public sealed record ScpiPowerCommands(
    string SetVoltage,
    string SetCurrentLimit,
    string OutputOn,
    string OutputOff,
    string MeasureVoltage,
    string MeasureCurrent,
    string Identify);

public sealed record ScpiPowerSettings(
    string Host,
    int Port,
    int ConnectTimeoutMs,
    int IoTimeoutMs,
    double? CurrentLimitA,
    string? Channel,
    ScpiPowerCommands Commands);

/// <summary>
/// Generic raw-TCP SCPI power supply. Vendor differences are expressed as
/// profile command templates; the Runtime sees only IPowerSupply.
/// </summary>
public sealed class ScpiPowerSupply : IPowerSupply, IDisposable
{
    private readonly ScpiPowerSettings _settings;
    private readonly SemaphoreSlim _ioGate = new(1, 1);

    private TcpClient? _client;
    private StreamReader? _reader;
    private StreamWriter? _writer;
    private volatile bool _isOn;
    private bool _disposed;

    public ScpiPowerSupply(ScpiPowerSettings settings) =>
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));

    public bool IsOn => !_disposed && _isOn;

    public async Task<PowerOnResult> PowerOn(
        double voltage,
        int settleMs,
        CancellationToken ct = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await _ioGate.WaitAsync(ct);
        try
        {
            await EnsureConnectedCore(ct);
            await SendCore(Format(_settings.Commands.SetVoltage, voltage, _settings.CurrentLimitA), ct);

            if (_settings.CurrentLimitA is { } currentLimit)
                await SendCore(Format(_settings.Commands.SetCurrentLimit, voltage, currentLimit), ct);

            await SendCore(Format(_settings.Commands.OutputOn, voltage, _settings.CurrentLimitA), ct);
            _isOn = true;

            if (settleMs > 0)
                await Task.Delay(settleMs, ct);

            var measuredVoltage = await QueryDoubleCore(
                Format(_settings.Commands.MeasureVoltage, voltage, _settings.CurrentLimitA), ct);
            var currentA = await QueryDoubleCore(
                Format(_settings.Commands.MeasureCurrent, voltage, _settings.CurrentLimitA), ct);

            return new PowerOnResult(true, measuredVoltage, currentA * 1000.0, true);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex) when (IsTransportOrProtocolError(ex))
        {
            CloseConnectionCore();
            _isOn = false;
            return new PowerOnResult(false, voltage, 0, false, ex.Message);
        }
        finally
        {
            _ioGate.Release();
        }
    }

    public async Task<PowerOffResult> PowerOff(CancellationToken ct = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await _ioGate.WaitAsync(ct);
        try
        {
            await EnsureConnectedCore(ct);
            await SendCore(Format(_settings.Commands.OutputOff, null, _settings.CurrentLimitA), ct);
            _isOn = false;
            return new PowerOffResult(true);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex) when (IsTransportOrProtocolError(ex))
        {
            CloseConnectionCore();
            _isOn = false;
            return new PowerOffResult(false, ex.Message);
        }
        finally
        {
            _ioGate.Release();
        }
    }

    public async Task<CurrentReading> ReadCurrent(int windowMs, CancellationToken ct = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!_isOn)
            return new CurrentReading(false, 0, 0, Array.Empty<double>(), "Power output is off.");

        var samples = new List<double>();
        var sw = Stopwatch.StartNew();

        try
        {
            do
            {
                samples.Add(await MeasureCurrentMa(ct));
                if (sw.ElapsedMilliseconds >= windowMs) break;
                await Task.Delay(Math.Min(100, Math.Max(20, windowMs / 10)), ct);
            }
            while (sw.ElapsedMilliseconds < windowMs);

            return new CurrentReading(
                true,
                samples.Average(),
                samples.Max(),
                samples);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex) when (IsTransportOrProtocolError(ex))
        {
            return new CurrentReading(false, 0, 0, samples, ex.Message);
        }
    }

    public async Task<CurrentCheck> CheckCurrent(
        double? ltMa = null,
        double? gtMa = null,
        CancellationToken ct = default)
    {
        if (!_isOn)
            return new CurrentCheck(false, 0, false, "Power output is off.");
        if (ltMa is null && gtMa is null)
            return new CurrentCheck(false, 0, false, "Provide lt or gt threshold (mA).");

        var reading = await ReadCurrent(300, ct);
        if (!reading.Ok)
            return new CurrentCheck(false, reading.AvgMa, false, reading.Error);

        var passed = (!ltMa.HasValue || reading.AvgMa < ltMa.Value)
            && (!gtMa.HasValue || reading.AvgMa > gtMa.Value);
        return new CurrentCheck(true, reading.AvgMa, passed);
    }

    public async Task<string> Identify(CancellationToken ct = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await _ioGate.WaitAsync(ct);
        try
        {
            await EnsureConnectedCore(ct);
            return await QueryCore(Format(_settings.Commands.Identify, null, _settings.CurrentLimitA), ct);
        }
        finally
        {
            _ioGate.Release();
        }
    }

    private async Task<double> MeasureCurrentMa(CancellationToken ct)
    {
        await _ioGate.WaitAsync(ct);
        try
        {
            await EnsureConnectedCore(ct);
            var currentA = await QueryDoubleCore(
                Format(_settings.Commands.MeasureCurrent, null, _settings.CurrentLimitA), ct);
            return currentA * 1000.0;
        }
        finally
        {
            _ioGate.Release();
        }
    }

    private async Task EnsureConnectedCore(CancellationToken ct)
    {
        if (_client?.Connected == true && _reader is not null && _writer is not null)
            return;

        CloseConnectionCore();
        var client = new TcpClient { NoDelay = true };
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(_settings.ConnectTimeoutMs);

        try
        {
            await client.ConnectAsync(_settings.Host, _settings.Port, timeout.Token);
        }
        catch
        {
            client.Dispose();
            throw;
        }

        var stream = client.GetStream();
        _client = client;
        _reader = new StreamReader(stream, Encoding.ASCII, false, 1024, leaveOpen: true);
        _writer = new StreamWriter(stream, Encoding.ASCII, 1024, leaveOpen: true)
        {
            AutoFlush = true,
            NewLine = "\n",
        };
    }

    private async Task SendCore(string command, CancellationToken ct)
    {
        var writer = _writer ?? throw new IOException("SCPI connection is not open.");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(_settings.IoTimeoutMs);
        await writer.WriteLineAsync(command.AsMemory(), timeout.Token);
        await writer.FlushAsync(timeout.Token);
    }

    private async Task<string> QueryCore(string command, CancellationToken ct)
    {
        await SendCore(command, ct);
        var reader = _reader ?? throw new IOException("SCPI connection is not open.");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(_settings.IoTimeoutMs);
        var line = await reader.ReadLineAsync(timeout.Token);
        return line ?? throw new IOException("SCPI instrument closed the connection while waiting for a response.");
    }

    private async Task<double> QueryDoubleCore(string command, CancellationToken ct)
    {
        var response = (await QueryCore(command, ct)).Trim();
        if (!double.TryParse(response, NumberStyles.Float, CultureInfo.InvariantCulture, out var value))
            throw new InvalidDataException($"SCPI response is not numeric: '{response}'.");
        return value;
    }

    private string Format(string template, double? voltage, double? current)
    {
        var command = template
            .Replace("{voltage}", voltage?.ToString("0.########", CultureInfo.InvariantCulture) ?? string.Empty,
                StringComparison.OrdinalIgnoreCase)
            .Replace("{current}", current?.ToString("0.########", CultureInfo.InvariantCulture) ?? string.Empty,
                StringComparison.OrdinalIgnoreCase)
            .Replace("{channel}", _settings.Channel ?? string.Empty,
                StringComparison.OrdinalIgnoreCase);

        if (command.IndexOfAny(['\r', '\n']) >= 0)
            throw new InvalidDataException("Formatted SCPI command must remain single-line.");
        return command;
    }

    private static bool IsTransportOrProtocolError(Exception ex) =>
        ex is IOException
            or SocketException
            or InvalidDataException
            or TimeoutException;

    private void CloseConnectionCore()
    {
        try { _writer?.Dispose(); } catch (IOException) { }
        try { _reader?.Dispose(); } catch (IOException) { }
        try { _client?.Dispose(); } catch (SocketException) { }
        _writer = null;
        _reader = null;
        _client = null;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _isOn = false;
        CloseConnectionCore();
        _ioGate.Dispose();
    }
}
