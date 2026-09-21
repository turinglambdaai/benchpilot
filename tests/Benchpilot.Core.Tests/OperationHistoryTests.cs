using Benchpilot.Core;
using Benchpilot.Runtime;
using Benchpilot.Simulator;

namespace Benchpilot.Core.Tests;

public sealed class OperationHistoryTests
{
    private static (BenchRuntime Runtime, SimulatedBench Bench) NewSimulatorRuntime()
    {
        var profile = ProfileLoader.DefaultSimulator();
        var bench = new SimulatedBench();
        var registry = new BenchResourceRegistry(profile);
        registry.Register("sim.demo", bench);
        return (new BenchRuntime(profile, registry), bench);
    }

    [Fact]
    public async Task Completed_mutation_is_recorded_with_duration_and_resources()
    {
        var (runtime, _) = NewSimulatorRuntime();

        var result = await runtime.Target().PowerOn(12, 0);
        Assert.True(result.Ok);

        var record = Assert.Single(runtime.RecentOperations());
        Assert.True(Guid.TryParseExact(record.Id, "N", out _));
        Assert.Equal("demo", record.TargetId);
        Assert.Equal("power.on", record.Kind);
        Assert.Equal(new[] { "sim.demo" }, record.ResourceIds);
        Assert.Equal("completed", record.State);
        Assert.True(record.CompletedAtUtc >= record.StartedAtUtc);
        Assert.True(record.DurationMs >= 0);
        Assert.Null(record.Error);
    }

    [Fact]
    public async Task Cancelled_mutation_is_recorded_after_driver_exits()
    {
        var (runtime, _) = NewSimulatorRuntime();
        var target = runtime.Target();
        Assert.True((await target.PowerOn(12, 0)).Ok);

        var flash = target.Flash("build/cancellable.elf");
        var active = Assert.Single(runtime.ActiveOperations);
        Assert.True(runtime.CancelOperation(active.Id));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () => await flash);
        Assert.Empty(runtime.ActiveOperations);

        var record = runtime.RecentOperations(1).Single();
        Assert.Equal(active.Id, record.Id);
        Assert.Equal("flash.write", record.Kind);
        Assert.Equal("cancelled", record.State);
        Assert.Equal("Operation cancelled.", record.Error);
    }

    [Fact]
    public async Task Faulted_mutation_records_bounded_infrastructure_error()
    {
        var profile = new BenchProfile
        {
            SchemaVersion = 1,
            Name = "Fault history bench",
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
        registry.Register("flash.test", new ThrowingFlashTarget());
        var runtime = new BenchRuntime(profile, registry);

        var ex = await Assert.ThrowsAsync<InvalidOperationException>(
            () => runtime.Target("ecu").Flash("build/app.elf"));
        Assert.Contains("synthetic flash failure", ex.Message);

        var record = Assert.Single(runtime.RecentOperations());
        Assert.Equal("faulted", record.State);
        Assert.Equal("flash.write", record.Kind);
        Assert.Contains("synthetic flash failure", record.Error);
    }

    [Fact]
    public async Task History_is_bounded_and_newest_first()
    {
        var (runtime, _) = NewSimulatorRuntime();
        var target = runtime.Target();
        Assert.True((await target.PowerOn(12, 0)).Ok);

        for (var i = 0; i < 140; i++)
            Assert.True((await target.Reset()).Ok);

        var records = runtime.RecentOperations(128);
        Assert.Equal(128, records.Count);
        Assert.All(records, x => Assert.Equal("flash.reset", x.Kind));
        Assert.True(records[0].CompletedAtUtc >= records[^1].CompletedAtUtc);
        Assert.Single(runtime.RecentOperations(1));
    }

    [Fact]
    public void History_limit_is_validated()
    {
        var (runtime, _) = NewSimulatorRuntime();

        Assert.Throws<BenchValidationException>(() => runtime.RecentOperations(0));
        Assert.Throws<BenchValidationException>(() => runtime.RecentOperations(129));
    }

    private sealed class ThrowingFlashTarget : IFlashTarget
    {
        public Task<FlashResult> Flash(string firmwarePath, CancellationToken ct = default)
        {
            ct.ThrowIfCancellationRequested();
            return Task.FromException<FlashResult>(
                new InvalidOperationException("synthetic flash failure"));
        }

        public Task<ResetResult> Reset(CancellationToken ct = default)
        {
            ct.ThrowIfCancellationRequested();
            return Task.FromResult(new ResetResult(true));
        }
    }
}
