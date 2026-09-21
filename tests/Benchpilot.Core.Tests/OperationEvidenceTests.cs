using Benchpilot.Core;
using Benchpilot.Runtime;
using Benchpilot.Simulator;

namespace Benchpilot.Core.Tests;

public sealed class OperationEvidenceTests
{
    private static (BenchRuntime Runtime, SimulatedBench Bench) NewSimulatorRuntime()
    {
        var profile = ProfileLoader.DefaultSimulator();
        var bench = new SimulatedBench();
        var registry = new BenchResourceRegistry(profile);
        registry.Register("sim.demo", bench);
        return (new BenchRuntime(profile, registry), bench);
    }

    private static BenchRuntime NewFlashRuntime(IFlashTarget flashTarget)
    {
        var profile = new BenchProfile
        {
            SchemaVersion = 1,
            Name = "Evidence test bench",
            DefaultTarget = "ecu",
            Resources = new Dictionary<string, BenchResourceConfig>(StringComparer.OrdinalIgnoreCase)
            {
                ["flash.test"] = new()
                {
                    Driver = "test",
                    Capabilities = ["flash"],
                },
            },
            Targets = new Dictionary<string, BenchTargetConfig>(StringComparer.OrdinalIgnoreCase)
            {
                ["ecu"] = new()
                {
                    Bindings = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                    {
                        ["flash"] = "flash.test",
                    },
                },
            },
        };

        var registry = new BenchResourceRegistry(profile);
        registry.Register("flash.test", flashTarget);
        return new BenchRuntime(profile, registry);
    }

    [Fact]
    public async Task Completed_flash_records_compact_semantic_evidence()
    {
        var runtime = NewFlashRuntime(new ResultFlashTarget(
            new FlashResult(true, 2048, 123)));

        var result = await runtime.Target().Flash("build/app.elf");
        Assert.True(result.Ok);

        var history = Assert.Single(runtime.RecentOperations());
        var evidence = Assert.IsType<BenchOperationEvidence>(
            runtime.GetOperationEvidence(history.Id));
        var item = Assert.Single(evidence.Items);

        Assert.Equal(history.Id, evidence.OperationId);
        Assert.Equal("ecu", evidence.TargetId);
        Assert.Equal("flash.write", evidence.OperationKind);
        Assert.Equal(["flash.test"], evidence.ResourceIds);
        Assert.Equal("flash.result", item.Kind);
        Assert.Equal("Flash completed.", item.Summary);
        Assert.Null(item.Text);
        Assert.Equal("true", item.Metadata!["ok"]);
        Assert.Equal("2048", item.Metadata["bytes"]);
        Assert.Equal("123", item.Metadata["durationMs"]);
    }

    [Fact]
    public async Task Device_error_remains_completed_history_but_is_visible_in_evidence()
    {
        const string diagnostic = "J-Link Commander exited with code 1. bounded-tail";
        var runtime = NewFlashRuntime(new ResultFlashTarget(
            new FlashResult(false, 0, 321, diagnostic)));

        var result = await runtime.Target().Flash("build/app.elf");
        Assert.False(result.Ok);

        var history = Assert.Single(runtime.RecentOperations());
        Assert.Equal("completed", history.State);
        Assert.Null(history.Error);

        var evidence = Assert.IsType<BenchOperationEvidence>(
            runtime.GetOperationEvidence(history.Id));
        var item = Assert.Single(evidence.Items);
        Assert.Equal("flash.result", item.Kind);
        Assert.Equal("Flash returned a device error.", item.Summary);
        Assert.Equal(diagnostic, item.Text);
        Assert.Equal("false", item.Metadata!["ok"]);
        Assert.Equal("321", item.Metadata["durationMs"]);
    }

    [Fact]
    public async Task Cancelled_operation_records_cancellation_evidence()
    {
        var (runtime, _) = NewSimulatorRuntime();
        var target = runtime.Target();
        Assert.True((await target.PowerOn(12, 0)).Ok);

        var flash = target.Flash("build/cancellable.elf");
        var active = Assert.Single(runtime.ActiveOperations);
        Assert.True(runtime.CancelOperation(active.Id));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () => await flash);

        var evidence = Assert.IsType<BenchOperationEvidence>(
            runtime.GetOperationEvidence(active.Id));
        var item = Assert.Single(evidence.Items);
        Assert.Equal("runtime.cancelled", item.Kind);
        Assert.Equal("Operation cancelled.", item.Text);
    }

    [Fact]
    public async Task Fault_evidence_text_is_bounded()
    {
        var longMessage = new string('x', 6000);
        var runtime = NewFlashRuntime(new ThrowingFlashTarget(longMessage));

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => runtime.Target().Flash("build/app.elf"));

        var history = Assert.Single(runtime.RecentOperations());
        Assert.Equal("faulted", history.State);
        var evidence = Assert.IsType<BenchOperationEvidence>(
            runtime.GetOperationEvidence(history.Id));
        var item = Assert.Single(evidence.Items);

        Assert.Equal("runtime.exception", item.Kind);
        Assert.Equal(4000, item.Text!.Length);
        Assert.Equal("InvalidOperationException", item.Metadata!["exceptionType"]);
    }

    [Fact]
    public async Task Evidence_store_is_bounded_to_newest_128_operations()
    {
        var (runtime, _) = NewSimulatorRuntime();
        var target = runtime.Target();
        Assert.True((await target.PowerOn(12, 0)).Ok);
        var firstId = runtime.RecentOperations(1).Single().Id;
        Assert.NotNull(runtime.GetOperationEvidence(firstId));

        for (var i = 0; i < 128; i++)
            Assert.True((await target.Reset()).Ok);

        Assert.Null(runtime.GetOperationEvidence(firstId));
        var newestId = runtime.RecentOperations(1).Single().Id;
        Assert.NotNull(runtime.GetOperationEvidence(newestId));
    }

    private sealed class ResultFlashTarget : IFlashTarget
    {
        private readonly FlashResult _result;
        public ResultFlashTarget(FlashResult result) => _result = result;

        public Task<FlashResult> Flash(string firmwarePath, CancellationToken ct = default)
        {
            ct.ThrowIfCancellationRequested();
            return Task.FromResult(_result);
        }

        public Task<ResetResult> Reset(CancellationToken ct = default)
        {
            ct.ThrowIfCancellationRequested();
            return Task.FromResult(new ResetResult(true));
        }
    }

    private sealed class ThrowingFlashTarget : IFlashTarget
    {
        private readonly string _message;
        public ThrowingFlashTarget(string message) => _message = message;

        public Task<FlashResult> Flash(string firmwarePath, CancellationToken ct = default)
        {
            ct.ThrowIfCancellationRequested();
            return Task.FromException<FlashResult>(new InvalidOperationException(_message));
        }

        public Task<ResetResult> Reset(CancellationToken ct = default)
        {
            ct.ThrowIfCancellationRequested();
            return Task.FromResult(new ResetResult(true));
        }
    }
}
