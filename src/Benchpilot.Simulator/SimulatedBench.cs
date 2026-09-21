using System.Collections.Concurrent;
using System.Diagnostics;
using Benchpilot.Core;

namespace Benchpilot.Simulator;

// A self-contained virtual bench for the DEMO. One class implements all three
// channels so power / serial / flash share state and behave like a real board:
// flashing while powered reboots the simulated firmware, which then streams its
// boot log over the serial console.
public sealed class SimulatedBench : IPowerSupply, ISerialChannel, IFlashTarget, IResourceHealthCheck
{
    private readonly object _gate = new();
    private bool _powered;
    private long _powerOnTicks;
    private string _firmware = "factory-bootloader";

    private readonly ConcurrentQueue<ConsoleLine> _console = new();
    private readonly Random _rng = new(0xC0FFEE);

    private double SecondsSincePowerOn()
    {
        if (!_powered) return -1;
        return (Stopwatch.GetTimestamp() - _powerOnTicks) / (double)Stopwatch.Frequency;
    }

    private double CurrentMaNow()
    {
        if (!_powered) return 0;
        var t = SecondsSincePowerOn();
        var steady = _firmware == "factory-bootloader" ? 22.0 : 45.0;
        if (t < 0.4) return 600 + _rng.NextDouble() * 300;
        if (t < 1.5) return 200 - (t - 0.4) * 90 + _rng.NextDouble() * 20;
        return steady + _rng.NextDouble() * 5;
    }

    public bool IsOn => _powered;

    public Task<PowerOnResult> PowerOn(double voltage, int settleMs, CancellationToken ct = default)
    {
        bool alreadyOn;
        lock (_gate)
        {
            alreadyOn = _powered;
            if (!alreadyOn)
            {
                _powered = true;
                _powerOnTicks = Stopwatch.GetTimestamp();
            }
        }
        if (alreadyOn)
            return Task.FromResult(new PowerOnResult(true, voltage, CurrentMaNow(), true));

        var wait = Math.Clamp(settleMs, 0, 5000);
        return Task.Run(async () =>
        {
            try
            {
                await Task.Delay(wait, ct);
                ct.ThrowIfCancellationRequested();
                BootFirmware();
                return new PowerOnResult(true, voltage, CurrentMaNow(), true);
            }
            catch (OperationCanceledException)
            {
                lock (_gate)
                {
                    _powered = false;
                    _console.Clear();
                }
                throw;
            }
        }, ct);
    }

    public Task<PowerOffResult> PowerOff(CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        lock (_gate)
        {
            _powered = false;
            _console.Clear();
        }
        return Task.FromResult(new PowerOffResult(true));
    }

    public async Task<CurrentReading> ReadCurrent(int windowMs, CancellationToken ct = default)
    {
        if (!_powered)
            return new CurrentReading(false, 0, 0, Array.Empty<double>(), "Power is off.");
        var samples = new List<double>();
        var sw = Stopwatch.StartNew();
        var stepMs = Math.Clamp(windowMs / 20, 20, 200);
        while (sw.ElapsedMilliseconds < windowMs)
        {
            samples.Add(CurrentMaNow());
            try { await Task.Delay(stepMs, ct); } catch (OperationCanceledException) { break; }
        }
        return new CurrentReading(true, samples.Average(), samples.Max(), samples);
    }

    public async Task<CurrentCheck> CheckCurrent(double? ltMa = null, double? gtMa = null, CancellationToken ct = default)
    {
        if (!_powered)
            return new CurrentCheck(false, 0, false, "Power is off.");
        if (ltMa is null && gtMa is null)
            return new CurrentCheck(false, 0, false, "Provide lt or gt threshold (mA).");
        var reading = await ReadCurrent(300, ct);
        var v = reading.AvgMa;
        var passed = (!ltMa.HasValue || v < ltMa.Value) && (!gtMa.HasValue || v > gtMa.Value);
        return new CurrentCheck(true, v, passed);
    }

    public async Task<FlashResult> Flash(string firmwarePath, CancellationToken ct = default)
    {
        if (!_powered)
            return new FlashResult(false, 0, 0, "Power is off; cannot flash.");
        var bytes = 256 * 1024 + _rng.Next(0, 4096);
        var durationMs = 400 + _rng.Next(0, 250);
        await Task.Delay(durationMs, ct);
        ct.ThrowIfCancellationRequested();
        _firmware = string.IsNullOrWhiteSpace(firmwarePath) ? "app.elf" : Path.GetFileName(firmwarePath);
        BootFirmware();
        return new FlashResult(true, bytes, durationMs);
    }

    public Task<ResetResult> Reset(CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        if (!_powered)
            return Task.FromResult(new ResetResult(false, "Power is off; cannot reset."));
        BootFirmware();
        return Task.FromResult(new ResetResult(true));
    }

    public bool IsOpen => !_console.IsEmpty;

    public Task<SerialOpenResult> Open(string? port = null, int? baud = null, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var resolvedPort = string.IsNullOrWhiteSpace(port) ? "SIM0" : port;
        var resolvedBaud = baud ?? 115200;
        return Task.FromResult(new SerialOpenResult(true, resolvedPort, resolvedBaud));
    }

    public async Task<SerialWaitResult> WaitFor(string pattern, int timeoutMs, CancellationToken ct = default)
    {
        if (!_powered)
            return new SerialWaitResult(false, false, null, 0, "Power is off.");
        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < timeoutMs)
        {
            foreach (var line in _console)
                if (line.Text.Contains(pattern, StringComparison.OrdinalIgnoreCase))
                    return new SerialWaitResult(true, true, line.Text, (int)sw.ElapsedMilliseconds);
            await Task.Delay(50, ct);
        }
        return new SerialWaitResult(true, false, null, (int)sw.ElapsedMilliseconds);
    }

    public Task<SerialWindowResult> ReadWindow(int lines, string? filter, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        IEnumerable<ConsoleLine> q = _console.ToArray();
        if (!string.IsNullOrEmpty(filter))
            q = q.Where(l => l.Text.Contains(filter, StringComparison.OrdinalIgnoreCase));
        var result = q.TakeLast(Math.Clamp(lines, 1, 1024)).Select(l => l.Text).ToList();
        return Task.FromResult(new SerialWindowResult(true, result));
    }

    public Task<SerialSendResult> Send(string data, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        return Task.FromResult(new SerialSendResult(true));
    }

    public Task<ResourceHealthResult> CheckHealth(CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        IReadOnlyDictionary<string, string> details = new Dictionary<string, string>
        {
            ["kind"] = "simulator",
            ["powered"] = IsOn.ToString(),
            ["firmware"] = _firmware,
        };
        return Task.FromResult(new ResourceHealthResult(
            true,
            "Simulator resource is ready.",
            details));
    }

    private void BootFirmware()
    {
        _console.Clear();
        var boot = DateTime.UtcNow;
        var fw = _firmware;
        _ = Task.Run(async () =>
        {
            await EmitAsync(boot, 0,    $"[reset] {fw} starting...");
            await EmitAsync(boot, 180,  "Clock: 160MHz, Flash: OK");
            await EmitAsync(boot, 260,  "Initializing peripherals...");
            await EmitAsync(boot, 200,  "CAN1: up @ 500kbps");
            await EmitAsync(boot, 160,  "GPIO: configured (8 pins)");
            await EmitAsync(boot, 180,  "Watchdog: enabled");
            await EmitAsync(boot, 220,  "System Ready");
        });
    }

    private async Task EmitAsync(DateTime boot, int delayMs, string text)
    {
        try { await Task.Delay(delayMs); } catch (OperationCanceledException) { return; }
        var ms = (int)(DateTime.UtcNow - boot).TotalMilliseconds;
        _console.Enqueue(new ConsoleLine($"[{ms,4}ms] {text}"));
        while (_console.Count > 256 && _console.TryDequeue(out _)) { }
    }

    private sealed record ConsoleLine(string Text);
}
