using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO.Ports;
using System.Text;
using Benchpilot.Core;
using Benchpilot.Runtime;

namespace Benchpilot.Drivers.Serial;

public sealed class SystemSerialResourceFactory : IBenchResourceFactory
{
    public string DriverName => "system-serial";

    public object Create(string resourceId, BenchResourceConfig config)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(resourceId);
        ArgumentNullException.ThrowIfNull(config);

        if (!config.Capabilities.Contains("serial", StringComparer.OrdinalIgnoreCase))
            throw new InvalidOperationException(
                $"Resource '{resourceId}' uses system-serial but does not declare the 'serial' capability.");

        var port = GetString(config, "port");
        var baud = GetInt(config, "baud") ?? 115200;
        var newLine = GetString(config, "newLine") ?? "\n";
        var maxBufferedLines = GetInt(config, "maxBufferedLines") ?? 4096;

        if (baud <= 0)
            throw new InvalidOperationException($"Resource '{resourceId}' has invalid serial baud {baud}.");
        if (string.IsNullOrEmpty(newLine))
            throw new InvalidOperationException($"Resource '{resourceId}' newLine cannot be empty.");
        if (maxBufferedLines is < 64 or > 100_000)
            throw new InvalidOperationException(
                $"Resource '{resourceId}' maxBufferedLines must be between 64 and 100000.");

        return new SystemSerialChannel(port, baud, newLine, maxBufferedLines);
    }

    private static string? GetString(BenchResourceConfig config, string key)
    {
        if (!config.Settings.TryGetValue(key, out var value)) return null;
        if (value.ValueKind != System.Text.Json.JsonValueKind.String)
            throw new InvalidOperationException($"Serial setting '{key}' must be a string.");
        return value.GetString();
    }

    private static int? GetInt(BenchResourceConfig config, string key)
    {
        if (!config.Settings.TryGetValue(key, out var value)) return null;
        if (!value.TryGetInt32(out var result))
            throw new InvalidOperationException($"Serial setting '{key}' must be an integer.");
        return result;
    }
}

/// <summary>
/// Stateful serial console backed by System.IO.Ports. The resource owns one OS
/// handle, keeps a bounded line buffer locally and exposes semantic WaitFor /
/// ReadWindow operations so Agents do not consume an unbounded raw stream.
/// </summary>
public sealed class SystemSerialChannel : ISerialChannel, IResourceHealthCheck, IDisposable
{
    private readonly object _portGate = new();
    private readonly object _lineGate = new();
    private readonly ConcurrentQueue<SerialLine> _lines = new();
    private readonly StringBuilder _partialLine = new();
    private readonly string? _defaultPort;
    private readonly int _defaultBaud;
    private readonly string _newLine;
    private readonly int _maxBufferedLines;

    private SerialPort? _port;
    private bool _disposed;

    public SystemSerialChannel(
        string? defaultPort,
        int defaultBaud = 115200,
        string newLine = "\n",
        int maxBufferedLines = 4096)
    {
        _defaultPort = string.IsNullOrWhiteSpace(defaultPort) ? null : defaultPort;
        _defaultBaud = defaultBaud;
        _newLine = newLine;
        _maxBufferedLines = maxBufferedLines;
    }

    public bool IsOpen
    {
        get
        {
            lock (_portGate)
                return !_disposed && _port?.IsOpen == true;
        }
    }

    public Task<SerialOpenResult> Open(
        string? port = null,
        int? baud = null,
        CancellationToken ct = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ct.ThrowIfCancellationRequested();

        var resolvedPort = string.IsNullOrWhiteSpace(port) ? _defaultPort : port;
        var resolvedBaud = baud ?? _defaultBaud;

        if (string.IsNullOrWhiteSpace(resolvedPort))
        {
            return Task.FromResult(new SerialOpenResult(
                false,
                string.Empty,
                resolvedBaud,
                "No serial port was configured. Set resources.<id>.settings.port or pass an explicit override."));
        }

        if (resolvedBaud <= 0)
            return Task.FromResult(new SerialOpenResult(false, resolvedPort, resolvedBaud, "Baud must be greater than zero."));

        lock (_portGate)
        {
            try
            {
                if (_port?.IsOpen == true &&
                    string.Equals(_port.PortName, resolvedPort, StringComparison.OrdinalIgnoreCase) &&
                    _port.BaudRate == resolvedBaud)
                {
                    return Task.FromResult(new SerialOpenResult(true, resolvedPort, resolvedBaud));
                }

                ClosePortLocked();
                ClearBuffer();

                _port = new SerialPort(resolvedPort, resolvedBaud)
                {
                    NewLine = _newLine,
                    ReadTimeout = 500,
                    WriteTimeout = 2000,
                    DtrEnable = false,
                    RtsEnable = false,
                };

                _port.DataReceived += OnDataReceived;
                _port.Open();
                return Task.FromResult(new SerialOpenResult(true, resolvedPort, resolvedBaud));
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException)
            {
                ClosePortLocked();
                return Task.FromResult(new SerialOpenResult(false, resolvedPort, resolvedBaud, ex.Message));
            }
        }
    }

    public async Task<SerialWaitResult> WaitFor(
        string pattern,
        int timeoutMs,
        CancellationToken ct = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!IsOpen)
            return new SerialWaitResult(false, false, null, 0, "Serial channel is not open.");

        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds <= timeoutMs)
        {
            foreach (var line in _lines)
            {
                if (line.Text.Contains(pattern, StringComparison.OrdinalIgnoreCase))
                    return new SerialWaitResult(true, true, line.Text, (int)sw.ElapsedMilliseconds);
            }

            if (sw.ElapsedMilliseconds >= timeoutMs) break;
            await Task.Delay(25, ct);
        }

        return new SerialWaitResult(true, false, null, (int)sw.ElapsedMilliseconds);
    }

    public Task<SerialWindowResult> ReadWindow(
        int lines,
        string? filter,
        CancellationToken ct = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ct.ThrowIfCancellationRequested();

        if (!IsOpen)
            return Task.FromResult(new SerialWindowResult(false, Array.Empty<string>(), "Serial channel is not open."));

        IEnumerable<SerialLine> snapshot = _lines.ToArray();
        if (!string.IsNullOrWhiteSpace(filter))
            snapshot = snapshot.Where(x => x.Text.Contains(filter, StringComparison.OrdinalIgnoreCase));

        var result = snapshot
            .TakeLast(Math.Clamp(lines, 1, _maxBufferedLines))
            .Select(x => x.Text)
            .ToArray();

        return Task.FromResult(new SerialWindowResult(true, result));
    }

    public Task<SerialSendResult> Send(string data, CancellationToken ct = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ct.ThrowIfCancellationRequested();

        lock (_portGate)
        {
            if (_port?.IsOpen != true)
                return Task.FromResult(new SerialSendResult(false, "Serial channel is not open."));

            try
            {
                _port.WriteLine(data);
                return Task.FromResult(new SerialSendResult(true));
            }
            catch (Exception ex) when (ex is IOException or InvalidOperationException or TimeoutException)
            {
                return Task.FromResult(new SerialSendResult(false, ex.Message));
            }
        }
    }

    public Task<ResourceHealthResult> CheckHealth(CancellationToken ct = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ct.ThrowIfCancellationRequested();

        if (IsOpen)
        {
            IReadOnlyDictionary<string, string> openDetails = new Dictionary<string, string>
            {
                ["port"] = _port?.PortName ?? _defaultPort ?? string.Empty,
                ["baud"] = (_port?.BaudRate ?? _defaultBaud).ToString(),
                ["open"] = "true",
            };
            return Task.FromResult(new ResourceHealthResult(
                true,
                "Serial channel is already open.",
                openDetails));
        }

        if (string.IsNullOrWhiteSpace(_defaultPort))
        {
            return Task.FromResult(new ResourceHealthResult(
                false,
                "No serial port is configured.",
                Error: "Set resources.<id>.settings.port before running preflight."));
        }

        try
        {
            var discovered = SerialPort.GetPortNames();
            var present = discovered.Contains(_defaultPort, StringComparer.OrdinalIgnoreCase)
                || File.Exists(_defaultPort);
            IReadOnlyDictionary<string, string> details = new Dictionary<string, string>
            {
                ["port"] = _defaultPort,
                ["baud"] = _defaultBaud.ToString(),
                ["open"] = "false",
                ["discoveredPorts"] = string.Join(",", discovered.Order(StringComparer.OrdinalIgnoreCase).Take(32)),
            };

            return Task.FromResult(new ResourceHealthResult(
                present,
                present
                    ? $"Configured serial port '{_defaultPort}' is present."
                    : $"Configured serial port '{_defaultPort}' was not found.",
                details,
                present ? null : $"Serial port '{_defaultPort}' is not currently visible to the OS."));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            return Task.FromResult(new ResourceHealthResult(
                false,
                "Could not enumerate serial ports.",
                Error: ex.Message));
        }
    }

    private void OnDataReceived(object? sender, SerialDataReceivedEventArgs args)
    {
        try
        {
            string chunk;
            lock (_portGate)
            {
                if (_disposed || _port?.IsOpen != true) return;
                chunk = _port.ReadExisting();
            }

            if (chunk.Length > 0)
                ConsumeChunk(chunk);
        }
        catch (Exception ex) when (ex is IOException or InvalidOperationException)
        {
            // A disconnect can race disposal or OS device removal. The next
            // explicit operation reports the closed/error state to the caller.
        }
    }

    private void ConsumeChunk(string chunk)
    {
        lock (_lineGate)
        {
            foreach (var ch in chunk)
            {
                if (ch is '\r' or '\n')
                {
                    if (_partialLine.Length == 0) continue;
                    EnqueueLine(_partialLine.ToString());
                    _partialLine.Clear();
                }
                else
                {
                    _partialLine.Append(ch);
                }
            }
        }
    }

    private void EnqueueLine(string text)
    {
        _lines.Enqueue(new SerialLine(DateTimeOffset.UtcNow, text));
        while (_lines.Count > _maxBufferedLines && _lines.TryDequeue(out _)) { }
    }

    private void ClearBuffer()
    {
        while (_lines.TryDequeue(out _)) { }
        lock (_lineGate)
            _partialLine.Clear();
    }

    private void ClosePortLocked()
    {
        if (_port is null) return;
        try
        {
            _port.DataReceived -= OnDataReceived;
            if (_port.IsOpen) _port.Close();
        }
        finally
        {
            _port.Dispose();
            _port = null;
        }
    }

    public void Dispose()
    {
        lock (_portGate)
        {
            if (_disposed) return;
            _disposed = true;
            ClosePortLocked();
        }
        ClearBuffer();
    }

    private sealed record SerialLine(DateTimeOffset Timestamp, string Text);
}
