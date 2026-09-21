using Benchpilot.Core;
using Benchpilot.Runtime;

namespace Benchpilot.Core.Tests;

public class TargetContextEvidenceTests
{
    [Fact]
    public async Task Failed_flash_includes_recent_power_and_current_context()
    {
        var device = new ContextDevice { FlashOk = false };
        using var runtime = CreateRuntime(device);
        var target = runtime.Target("ecu");

        await target.PowerOn(12.4, 0);
        await target.ReadCurrent(100);
        var check = await target.CheckCurrent(ltMa: 500);
        Assert.True(check.Passed);

        var flash = await target.Flash("app.hex");
        Assert.False(flash.Ok);

        var operation = Assert.Single(runtime.RecentOperations(10), x => x.Kind == "flash.write");
        var evidence = Assert.IsType<BenchOperationEvidence>(runtime.GetOperationEvidence(operation.Id));
        Assert.Contains(evidence.Items, x => x.Kind == "flash.result");
        Assert.Contains(evidence.Items, x => x.Kind == "context.current-check");
        Assert.Contains(evidence.Items, x => x.Kind == "context.current-reading");
        Assert.Contains(evidence.Items, x => x.Kind == "context.power-on");

        var power = Assert.Single(evidence.Items, x => x.Kind == "context.power-on");
        Assert.Equal("12.4", power.Metadata!["voltageV"]);
        Assert.Equal("184", power.Metadata["currentMa"]);
        Assert.True(power.Metadata.ContainsKey("capturedAtUtc"));
        Assert.True(power.Metadata.ContainsKey("ageMs"));
    }

    [Fact]
    public async Task Unmatched_serial_wait_includes_uart_window_and_recent_target_context()
    {
        var device = new ContextDevice();
        using var runtime = CreateRuntime(device);
        var target = runtime.Target("ecu");

        await target.PowerOn(12, 0);
        await target.CheckCurrent(ltMa: 500);
        var wait = await target.SerialWaitFor("READY", 50);

        Assert.True(wait.Ok);
        Assert.False(wait.Matched);
        Assert.False(string.IsNullOrWhiteSpace(wait.ObservationId));

        var evidence = Assert.IsType<BenchObservationEvidence>(
            runtime.GetObservationEvidence(wait.ObservationId!));
        Assert.Contains(evidence.Items, x => x.Kind == "serial.wait");
        Assert.Contains(evidence.Items, x => x.Kind == "serial.failure-window");
        Assert.Contains(evidence.Items, x => x.Kind == "context.current-check");
        Assert.Contains(evidence.Items, x => x.Kind == "context.power-on");
    }

    [Fact]
    public async Task Successful_flash_does_not_bloat_evidence_with_target_context()
    {
        var device = new ContextDevice { FlashOk = true };
        using var runtime = CreateRuntime(device);
        var target = runtime.Target("ecu");

        await target.PowerOn(12, 0);
        await target.ReadCurrent(100);
        var flash = await target.Flash("app.hex");
        Assert.True(flash.Ok);

        var operation = Assert.Single(runtime.RecentOperations(10), x => x.Kind == "flash.write");
        var evidence = Assert.IsType<BenchOperationEvidence>(runtime.GetOperationEvidence(operation.Id));
        Assert.Single(evidence.Items);
        Assert.Equal("flash.result", evidence.Items[0].Kind);
    }

    [Fact]
    public async Task Failure_context_is_bounded_to_three_newest_entries()
    {
        var device = new ContextDevice { FlashOk = false };
        using var runtime = CreateRuntime(device);
        var target = runtime.Target("ecu");

        await target.PowerOn(12, 0);
        for (var i = 0; i < 6; i++)
        {
            device.NextCurrentMa = 100 + i;
            await target.ReadCurrent(10);
        }

        await target.Flash("app.hex");
        var operation = Assert.Single(runtime.RecentOperations(10), x => x.Kind == "flash.write");
        var evidence = Assert.IsType<BenchOperationEvidence>(runtime.GetOperationEvidence(operation.Id));
        var context = evidence.Items.Where(x => x.Kind.StartsWith("context.", StringComparison.Ordinal)).ToArray();

        Assert.Equal(3, context.Length);
        Assert.All(context, item => Assert.Equal("context.current-reading", item.Kind));
        Assert.Equal("105", context[0].Metadata!["avgMa"]);
        Assert.Equal("104", context[1].Metadata!["avgMa"]);
        Assert.Equal("103", context[2].Metadata!["avgMa"]);
    }

    [Fact]
    public async Task Recent_power_off_is_visible_in_later_failure_context()
    {
        var device = new ContextDevice { FlashOk = false };
        using var runtime = CreateRuntime(device);
        var target = runtime.Target("ecu");

        await target.PowerOn(12, 0);
        await target.PowerOff();
        await target.Flash("app.hex");

        var operation = Assert.Single(runtime.RecentOperations(10), x => x.Kind == "flash.write");
        var evidence = Assert.IsType<BenchOperationEvidence>(runtime.GetOperationEvidence(operation.Id));
        var context = evidence.Items.Where(x => x.Kind.StartsWith("context.", StringComparison.Ordinal)).ToArray();

        Assert.NotEmpty(context);
        Assert.Equal("context.power-off", context[0].Kind);
        Assert.Contains(context, x => x.Kind == "context.power-on");
    }

    private static BenchRuntime CreateRuntime(ContextDevice device)
    {
        var profile = new BenchProfile
        {
            Name = "Context evidence bench",
            DefaultTarget = "ecu",
            Resources = new Dictionary<string, BenchResourceConfig>(StringComparer.OrdinalIgnoreCase)
            {
                ["device.ecu"] = new()
                {
                    Driver = "context-test",
                    Capabilities = new[] { "power", "serial", "flash" },
                },
            },
            Targets = new Dictionary<string, BenchTargetConfig>(StringComparer.OrdinalIgnoreCase)
            {
                ["ecu"] = new()
                {
                    Name = "Context ECU",
                    Bindings = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                    {
                        ["power"] = "device.ecu",
                        ["serial"] = "device.ecu",
                        ["flash"] = "device.ecu",
                    },
                },
            },
        };
        var registry = new BenchResourceRegistry(profile);
        registry.Register("device.ecu", device);
        return new BenchRuntime(profile, registry);
    }

    private sealed class ContextDevice : IPowerSupply, ISerialChannel, IFlashTarget
    {
        public bool FlashOk { get; set; } = true;
        public double NextCurrentMa { get; set; } = 184;
        public bool IsOn { get; private set; }
        public bool IsOpen { get; private set; }

        public Task<PowerOnResult> PowerOn(double voltage, int settleMs, CancellationToken ct = default)
        {
            IsOn = true;
            return Task.FromResult(new PowerOnResult(true, voltage, 184, true));
        }

        public Task<PowerOffResult> PowerOff(CancellationToken ct = default)
        {
            IsOn = false;
            return Task.FromResult(new PowerOffResult(true));
        }

        public Task<CurrentReading> ReadCurrent(int windowMs, CancellationToken ct = default) =>
            Task.FromResult(new CurrentReading(
                true,
                NextCurrentMa,
                NextCurrentMa + 1,
                new[] { NextCurrentMa }));

        public Task<CurrentCheck> CheckCurrent(
            double? ltMa = null,
            double? gtMa = null,
            CancellationToken ct = default)
        {
            var passed = (ltMa is null || NextCurrentMa < ltMa)
                && (gtMa is null || NextCurrentMa > gtMa);
            return Task.FromResult(new CurrentCheck(true, NextCurrentMa, passed));
        }

        public Task<FlashResult> Flash(string firmwarePath, CancellationToken ct = default) =>
            Task.FromResult(FlashOk
                ? new FlashResult(true, 4096, 25)
                : new FlashResult(false, 0, 25, "Injected flash failure."));

        public Task<ResetResult> Reset(CancellationToken ct = default) =>
            Task.FromResult(new ResetResult(true));

        public Task<SerialOpenResult> Open(
            string? port = null,
            int? baud = null,
            CancellationToken ct = default)
        {
            IsOpen = true;
            return Task.FromResult(new SerialOpenResult(true, port ?? "CTX", baud ?? 115200));
        }

        public Task<SerialWaitResult> WaitFor(
            string pattern,
            int timeoutMs,
            CancellationToken ct = default) =>
            Task.FromResult(new SerialWaitResult(true, false, null, timeoutMs));

        public Task<SerialWindowResult> ReadWindow(
            int lines,
            string? filter,
            CancellationToken ct = default) =>
            Task.FromResult(new SerialWindowResult(
                true,
                new[] { "Booting...", "Still waiting..." }));

        public Task<SerialSendResult> Send(string data, CancellationToken ct = default) =>
            Task.FromResult(new SerialSendResult(true));
    }
}