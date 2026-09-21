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

    private static (
        BenchRuntime Runtime,
        SimulatedBench SharedBench,
        SimulatedBench IndependentBench) NewMultiTargetRuntime()
    {
        var profile = new BenchProfile
        {
            SchemaVersion = 1,
            Name = "Multi-target locking bench",
            DefaultTarget = "ecu-a",
            Resources = new Dictionary<string, BenchResourceConfig>(StringComparer.OrdinalIgnoreCase)
            {
                ["sim.shared"] = new()
                {
                    Driver = "simulator",
                    Capabilities = ["power", "serial", "flash"],
                },
                ["sim.independent"] = new()
                {
                    Driver = "simulator",
                    Capabilities = ["power", "serial", "flash"],
                },
            },
            Targets = new Dictionary<string, BenchTargetConfig>(StringComparer.OrdinalIgnoreCase)
            {
                ["ecu-a"] = new()
                {
                    Name = "ECU A",
                    Bindings = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                    {
                        ["power"] = "sim.shared",
                        ["serial"] = "sim.shared",
                        ["flash"] = "sim.shared",
                    },
                },
                ["ecu-b"] = new()
                {
                    Name = "ECU B",
                    Bindings = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                    {
                        ["power"] = "sim.shared",
                        ["serial"] = "sim.shared",
                        ["flash"] = "sim.shared",
                    },
                },
                ["ecu-c"] = new()
                {
                    Name = "ECU C",
                    Bindings = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                    {
                        ["power"] = "sim.independent",
                        ["serial"] = "sim.independent",
                        ["flash"] = "sim.independent",
                    },
                },
            },
        };

        var sharedBench = new SimulatedBench();
        var independentBench = new SimulatedBench();
        var registry = new BenchResourceRegistry(profile);
        registry.Register("sim.shared", sharedBench);
        registry.Register("sim.independent", independentBench);
        return (new BenchRuntime(profile, registry), sharedBench, independentBench);
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
    public async Task Active_mutation_has_identity_and_can_be_cancelled()
    {
        var (runtime, bench) = NewRuntime();
        var target = runtime.Target();
        Assert.True((await target.PowerOn(12, 0)).Ok);
        Assert.True(bench.IsOn);

        var flash = target.Flash("build/cancellable.elf");
        var active = Assert.Single(runtime.ActiveOperations);

        Assert.True(Guid.TryParseExact(active.Id, "N", out _));
        Assert.Equal("demo", active.TargetId);
        Assert.Equal("flash.write", active.Kind);
        Assert.Equal(["sim.demo"], active.ResourceIds);
        Assert.False(active.CancellationRequested);
        Assert.True(runtime.CancelOperation(active.Id));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () => await flash);
        Assert.Empty(runtime.ActiveOperations);
        Assert.True(bench.IsOn);

        // Cancellation must release both target and resource gates.
        Assert.True((await target.Reset()).Ok);
        Assert.False(runtime.CancelOperation(active.Id));
    }

    [Fact]
    public async Task Cancelling_power_on_rolls_back_simulated_power_state()
    {
        var (runtime, bench) = NewRuntime();
        var target = runtime.Target();

        var powerOn = target.PowerOn(12, 5000);
        var active = Assert.Single(runtime.ActiveOperations);
        Assert.Equal("power.on", active.Kind);
        Assert.True(bench.IsOn);

        Assert.True(runtime.CancelOperation(active.Id));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () => await powerOn);

        Assert.Empty(runtime.ActiveOperations);
        Assert.False(bench.IsOn);
    }

    [Fact]
    public async Task Concurrent_mutating_operations_report_active_owner()
    {
        var (runtime, _) = NewRuntime();
        var target = runtime.Target();
        Assert.True((await target.PowerOn(12, 0)).Ok);

        var flash = target.Flash("build/app.elf");
        var active = Assert.Single(runtime.ActiveOperations);
        var busy = await Assert.ThrowsAsync<BenchBusyException>(() => target.Reset());

        Assert.Equal("demo", busy.TargetId);
        Assert.Equal("flash.reset", busy.Operation);
        Assert.Equal("target", busy.BusyScope);
        Assert.Equal("demo", busy.BusyId);
        Assert.Null(busy.ResourceId);
        Assert.Equal(active.Id, busy.OwnerOperationId);
        Assert.Equal("flash.write", busy.OwnerOperation);
        Assert.Contains(active.Id, busy.Message);
        Assert.True((await flash).Ok);
    }

    [Fact]
    public async Task Shared_physical_resource_blocks_mutations_across_different_targets()
    {
        var (runtime, sharedBench, _) = NewMultiTargetRuntime();
        var ecuA = runtime.Target("ecu-a");
        var ecuB = runtime.Target("ecu-b");
        Assert.True((await ecuA.PowerOn(12, 0)).Ok);
        Assert.True(sharedBench.IsOn);

        var flash = ecuA.Flash("build/ecu-a.elf");
        var active = Assert.Single(runtime.ActiveOperations);
        var busy = await Assert.ThrowsAsync<BenchBusyException>(() => ecuB.Reset());

        Assert.Equal("ecu-b", busy.TargetId);
        Assert.Equal("flash.reset", busy.Operation);
        Assert.Equal("resource", busy.BusyScope);
        Assert.Equal("sim.shared", busy.BusyId);
        Assert.Equal("sim.shared", busy.ResourceId);
        Assert.Equal(active.Id, busy.OwnerOperationId);
        Assert.Contains("sim.shared", busy.Message);
        Assert.True((await flash).Ok);
    }

    [Fact]
    public async Task Independent_physical_resources_can_mutate_in_parallel()
    {
        var (runtime, _, independentBench) = NewMultiTargetRuntime();
        var ecuA = runtime.Target("ecu-a");
        var ecuC = runtime.Target("ecu-c");
        Assert.True((await ecuA.PowerOn(12, 0)).Ok);
        Assert.True((await ecuC.PowerOn(12, 0)).Ok);
        Assert.True(independentBench.IsOn);

        var flashA = ecuA.Flash("build/ecu-a.elf");
        var resetC = await ecuC.Reset();

        Assert.True(resetC.Ok);
        Assert.True((await flashA).Ok);
    }

    [Fact]
    public async Task Normal_power_off_does_not_interrupt_an_active_mutation()
    {
        var (runtime, bench) = NewRuntime();
        var target = runtime.Target();
        Assert.True((await target.PowerOn(12, 0)).Ok);

        var flash = target.Flash("build/app.elf");
        var busy = await Assert.ThrowsAsync<BenchBusyException>(() => target.PowerOff());

        Assert.Equal("demo", busy.TargetId);
        Assert.Equal("power.off", busy.Operation);
        Assert.True(bench.IsOn);
        Assert.True((await flash).Ok);
        Assert.True(bench.IsOn);
    }

    [Fact]
    public async Task Emergency_power_off_remains_available_during_an_active_mutation_and_is_audited()
    {
        var (runtime, bench) = NewRuntime();
        var target = runtime.Target();
        Assert.True((await target.PowerOn(12, 0)).Ok);

        var flash = target.Flash("build/app.elf");
        var off = await target.EmergencyPowerOff();

        Assert.True(off.Ok);
        Assert.False(bench.IsOn);

        var emergency = runtime.RecentOperations()
            .First(x => x.Kind == "power.emergency-off");
        Assert.True(Guid.TryParseExact(emergency.Id, "N", out _));
        Assert.Equal("demo", emergency.TargetId);
        Assert.Equal(["sim.demo"], emergency.ResourceIds);
        Assert.Equal("completed", emergency.State);

        await flash;
        Assert.False(bench.IsOn);
    }

    [Fact]
    public async Task Accepted_emergency_power_off_ignores_caller_cancellation()
    {
        var (runtime, bench) = NewRuntime();
        var target = runtime.Target();
        Assert.True((await target.PowerOn(12, 0)).Ok);
        Assert.True(bench.IsOn);

        using var cts = new CancellationTokenSource();
        cts.Cancel();

        var off = await target.EmergencyPowerOff(cts.Token);

        Assert.True(off.Ok);
        Assert.False(bench.IsOn);
        var emergency = runtime.RecentOperations(1).Single();
        Assert.Equal("power.emergency-off", emergency.Kind);
        Assert.Equal("completed", emergency.State);
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
