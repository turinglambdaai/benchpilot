using Benchpilot.Core;
using Benchpilot.Runtime;
using Benchpilot.Simulator;

namespace Benchpilot.Core.Tests;

public class RuntimeTests
{
    private static (BenchRuntime Runtime, SimulatedBench Bench) NewRuntime(BenchProfile? profile = null)
    {
        profile ??= ProfileLoader.DefaultSimulator();
        var bench = new SimulatedBench();
        var registry = new BenchResourceRegistry(profile);
        registry.Register("sim.demo", bench);
        return (new BenchRuntime(profile, registry), bench);
    }

    [Fact]
    public void Target_resolves_multiple_capabilities_to_same_live_resource()
    {
        var (runtime, bench) = NewRuntime();
        var target = runtime.Target();

        Assert.Equal("demo", target.Id);
        Assert.Same(bench, target.Capability<IPowerSupply>("power"));
        Assert.Same(bench, target.Capability<ISerialChannel>("serial"));
        Assert.Same(bench, target.Capability<IFlashTarget>("flash"));
    }

    [Fact]
    public async Task Target_operations_share_the_same_stateful_resource()
    {
        var (runtime, _) = NewRuntime();
        var target = runtime.Target();

        Assert.True((await target.PowerOn(12, 50)).Ok);
        Assert.True((await target.Flash("build/app.elf")).Ok);

        var ready = await target.SerialWaitFor("Ready", 5000);
        Assert.True(ready.Ok);
        Assert.True(ready.Matched);
    }

    [Fact]
    public async Task Safety_policy_blocks_overvoltage_before_driver_call()
    {
        var profile = ProfileLoader.DefaultSimulator() with
        {
            Safety = new BenchSafetyPolicy { MaxVoltage = 13.5 },
        };
        var (runtime, bench) = NewRuntime(profile);

        var ex = await Assert.ThrowsAsync<BenchValidationException>(
            () => runtime.Target().PowerOn(14.0, 0));

        Assert.Contains("exceeds bench safety limit", ex.Message);
        Assert.False(bench.IsOn);
    }

    [Fact]
    public async Task Safety_policy_cuts_power_when_measured_current_exceeds_limit()
    {
        var profile = ProfileLoader.DefaultSimulator() with
        {
            Safety = new BenchSafetyPolicy { MaxCurrentMa = 10 },
        };
        var (runtime, bench) = NewRuntime(profile);

        var result = await runtime.Target().PowerOn(12, 2000);

        Assert.False(result.Ok);
        Assert.Contains("exceeds bench safety limit", result.Error);
        Assert.False(bench.IsOn);
    }

    [Fact]
    public async Task Destructive_confirmation_must_match_resolved_target_when_required()
    {
        var profile = ProfileLoader.DefaultSimulator() with
        {
            Safety = new BenchSafetyPolicy { RequireDestructiveConfirmation = true },
        };
        var (runtime, _) = NewRuntime(profile);
        var target = runtime.Target();
        Assert.True((await target.PowerOn(12, 0)).Ok);

        var missing = await Assert.ThrowsAsync<BenchValidationException>(
            () => target.Flash("build/app.elf"));
        Assert.Contains("confirmTarget", missing.Message);
        Assert.Contains("demo", missing.Message);

        await Assert.ThrowsAsync<BenchValidationException>(
            () => target.Reset("wrong-target"));

        Assert.True((await target.Flash("build/app.elf", "demo")).Ok);
        Assert.True((await target.Reset("demo")).Ok);
    }

    [Fact]
    public async Task Concurrent_mutating_operations_are_rejected_instead_of_queued()
    {
        var (runtime, _) = NewRuntime();
        var target = runtime.Target();
        Assert.True((await target.PowerOn(12, 0)).Ok);

        var flash = target.Flash("build/app.elf");
        var busy = await Assert.ThrowsAsync<BenchBusyException>(() => target.Reset());

        Assert.Equal("demo", busy.TargetId);
        Assert.Equal("flash.reset", busy.Operation);
        Assert.Contains("busy", busy.Message, StringComparison.OrdinalIgnoreCase);
        Assert.True((await flash).Ok);
    }

    [Fact]
    public async Task Power_off_remains_available_during_an_active_mutation()
    {
        var (runtime, bench) = NewRuntime();
        var target = runtime.Target();
        Assert.True((await target.PowerOn(12, 0)).Ok);

        var flash = target.Flash("build/app.elf");
        var off = await target.PowerOff();

        Assert.True(off.Ok);
        Assert.False(bench.IsOn);
        await flash;
        Assert.False(bench.IsOn);
    }

    [Fact]
    public void Explicit_target_policy_is_enforced_by_runtime()
    {
        var profile = ProfileLoader.DefaultSimulator() with
        {
            Safety = new BenchSafetyPolicy { RequireExplicitTarget = true },
        };
        var (runtime, _) = NewRuntime(profile);

        Assert.Throws<BenchValidationException>(() => runtime.Target());
        Assert.Equal("demo", runtime.Target("demo").Id);
    }

    [Fact]
    public void Unknown_target_has_a_specific_runtime_error()
    {
        var (runtime, _) = NewRuntime();

        var ex = Assert.Throws<BenchTargetNotFoundException>(
            () => runtime.Target("missing-ecu"));

        Assert.Contains("missing-ecu", ex.Message);
    }

    [Fact]
    public void Missing_live_resource_fails_before_a_driver_call()
    {
        var profile = ProfileLoader.DefaultSimulator();
        var runtime = new BenchRuntime(profile, new BenchResourceRegistry(profile));

        var ex = Assert.Throws<InvalidOperationException>(
            () => runtime.Target().Capability<IPowerSupply>("power"));

        Assert.Contains("no live driver instance", ex.Message);
    }

    [Fact]
    public void Registry_rejects_resource_not_declared_by_profile()
    {
        var profile = ProfileLoader.DefaultSimulator();
        var registry = new BenchResourceRegistry(profile);

        var ex = Assert.Throws<KeyNotFoundException>(
            () => registry.Register("unknown.device", new SimulatedBench()));

        Assert.Contains("not declared", ex.Message);
    }
}
