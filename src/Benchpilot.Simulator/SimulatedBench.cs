using System.Collections.Concurrent;
using System.Diagnostics;
using Benchpilot.Core;

namespace Benchpilot.Simulator;

// A self-contained virtual bench for the DEMO. One class implements all three
// channels so power / serial / flash share state and behave like a real board:
// flashing while powered reboots the simulated firmware, which then streams its
// boot log over the serial console. Swap this out for a real SCPI supply +
// System.IO.Ports console + probe backend by registering different
// IPowerSupply / ISerialChannel / IFlashTarget — the kernel and MCP tools stay
// untouched (PRD §2.1 "the kernel is valuable, the shells are replaceable").
public sealed class SimulatedBench : IPowerSupply, ISerialChannel, IFlashTarget
{
    private readonly object _gate = new();
    private bool _powered;
    private long _powerOnTicks;          // Stopwatch ticks when last powered on
    private string _firmware = "factory-bootloader";

    // Serial console buffer: timestamped lines the simulated firmware emits.
    private readonly ConcurrentQueue<ConsoleLine> _console = new();
    private readonly Random _rng = new(0xC0FFEE);

    // --- shared model ---

    private double SecondsSincePowerOn()
    {
        if (!_powered) return -1;
        return (Stopwatch.GetTimestamp() - _powerOnTicks) / (double)Stopwatch.Frequency;
    }

    // Current-draw model (mA) vs. time since power-on: inrush spike, ramp down,
    // steady idle. A flashed app idles slightly higher than the bare bootloader,
    // which is what a real ECU looks like.
    private double CurrentMaNow()
    {
        if (!_powered) return 0;
        var t = SecondsSincePowerOn();
        var steady = _firmware == "factory-bootloader" ? 22.0 : 45.0;
        if (t < 0.4) return 600 + _rng.NextDouble() * 300;        // inrush 600-900mA
        if (t < 1.5) return 200 - (t - 0.4) * 90 + _rng.NextDouble() * 20; // ramp down
        return steady + _rng.NextDouble() * 5;                    // steady idle
    }

    // --- IPowerSupply ---

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

        // Idempotent (PRD §6.8): already-on is a no-op. Otherwise simulate the
        // settle window, then boot whatever firmware is present.
        var wait = Math.Clamp(settleMs, 0, 5000);
        return Task.Run(async () =>
        {
            try { await Task.Delay(wait, ct); } catch (OperationCanceledException) { }
            BootFirmware();
            return new PowerOnResult(true, voltage, CurrentMaNow(), true);
        }, ct);
    }

    public Task<PowerOffResult> PowerOff(CancellationToken ct = default)
    {
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

    // --- IFlashTarget ---

    public async Task<FlashResult> Flash(string firmwarePath, CancellationToken ct = default)
    {
        if (!_powered)
            return new FlashResult(false, 0, 0, "Power is off; cannot flash.");
        // Simulate programming a ~256KB image at a believable rate.
        var bytes = 256 * 1024 + _rng.Next(0, 4096);
        var durationMs = 400 + _rng.Next(0, 250);
        try { await Task.Delay(durationMs, ct); } catch (OperationCanceledException) { }
        _firmware = string.IsNullOrWhiteSpace(firmwarePath) ? "app.elf" : Path.GetFileName(firmwarePath);
        // Flashing reboots into the new firmware, which streams its boot log.
        BootFirmware();
        return new FlashResult(true, bytes, durationMs);
    }

    public Task<ResetResult> Reset(CancellationToken ct = default)
    {
        if (!_powered)
            return Task.FromResult(new ResetResult(false, "Power is off; cannot reset."));
        BootFirmware();
        return Task.FromResult(new ResetResult(true));
    }

    // --- ISerialChannel ---

    public bool IsOpen => !_console.IsEmpty;

    public Task<SerialOpenResult> Open(string port, int baud, CancellationToken ct = default)
    {
        // The console mirrors the firmware boot log produced at power-on / flash
        // time. "Opening" marks intent; the buffer may already hold boot lines.
        return Task.FromResult(new SerialOpenResult(true, port, baud));
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
            try { await Task.Delay(50, ct); } catch (OperationCanceledException) { break; }
        }
        return new SerialWaitResult(true, false, null, (int)sw.ElapsedMilliseconds);
    }

    public Task<SerialWindowResult> ReadWindow(int lines, string? filter, CancellationToken ct = default)
    {
        IEnumerable<ConsoleLine> q = _console.ToArray();
        if (!string.IsNullOrEmpty(filter))
            q = q.Where(l => l.Text.Contains(filter, StringComparison.OrdinalIgnoreCase));
        var result = q.TakeLast(Math.Clamp(lines, 1, 1024)).Select(l => l.Text).ToList();
        return Task.FromResult(new SerialWindowResult(true, result));
    }

    public Task<SerialSendResult> Send(string data, CancellationToken ct = default)
    {
        // A real console would echo or the firmware would react; the simulator
        // acknowledges the write silently.
        return Task.FromResult(new SerialSendResult(true));
    }

    // --- simulated firmware boot sequence ---

    // Emits the boot log asynchronously so WaitFor can observe lines arriving
    // over time, exactly like a real MCU streaming its console. Clears the
    // buffer first so each boot is a fresh console session.
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
