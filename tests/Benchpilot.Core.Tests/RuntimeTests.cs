using Benchpilot.Core;
using Benchpilot.Runtime;
using Benchpilot.Simulator;

namespace Benchpilot.Core.Tests;

public class RuntimeTests
{
    [Fact]
    public void Target_resolves_multiple_capabilities_to_same_live_resource()
    {
        var profile = ProfileLoader.DefaultSimulator();
        var bench = new SimulatedBench();
        var registry = new BenchResourceRegistry(profile);
        registry.Register("sim.demo", bench);
        var runtime = new BenchRuntime(profile, registry);

        var target = runtime.Target();

        Assert.Equal("demo", target.Id);
        Assert.Same(bench, target.Capability<IPowerSupply>("power"));
        Assert.Same(bench, target.Capability<ISerialChannel>("serial"));
        Assert.Same(bench, target.Capability<IFlashTarget>("flash"));
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
