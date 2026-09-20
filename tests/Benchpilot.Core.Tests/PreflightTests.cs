using Benchpilot.Core;
using Benchpilot.Drivers.JLink;
using Benchpilot.Drivers.Serial;
using Benchpilot.Runtime;
using Benchpilot.Simulator;

namespace Benchpilot.Core.Tests;

public class PreflightTests
{
    [Fact]
    public async Task Simulator_preflight_checks_composite_resource_once()
    {
        var profile = ProfileLoader.DefaultSimulator();
        var registry = new BenchResourceRegistry(profile);
        registry.Register("sim.demo", new SimulatedBench());
        using var runtime = new BenchRuntime(profile, registry);

        var result = await runtime.Preflight();

        Assert.True(result.Ok, result.Error);
        Assert.Equal("demo", result.TargetId);
        var resource = Assert.Single(result.Resources);
        Assert.Equal("sim.demo", resource.ResourceId);
        Assert.Equal("simulator", resource.Driver);
        Assert.True(resource.Ok, resource.Error);
    }

    [Fact]
    public async Task Serial_preflight_reports_missing_configured_port_without_opening_it()
    {
        using var serial = new SystemSerialChannel(
            $"BENCHPILOT_MISSING_{Guid.NewGuid():N}",
            115200);

        var result = await serial.CheckHealth();

        Assert.False(result.Ok);
        Assert.Contains("not found", result.Summary, StringComparison.OrdinalIgnoreCase);
        Assert.False(serial.IsOpen);
    }

    [Fact]
    public async Task JLink_preflight_reports_missing_commander_without_touching_target()
    {
        var missing = Path.Combine(
            Path.GetTempPath(),
            $"benchpilot-missing-jlink-{Guid.NewGuid():N}",
            OperatingSystem.IsWindows() ? "JLink.exe" : "JLinkExe");

        var target = new JLinkFlashTarget(new JLinkSettings(
            missing,
            "TEST_DEVICE",
            "SWD",
            4000,
            null,
            5000,
            null));

        var result = await target.CheckHealth();

        Assert.False(result.Ok);
        Assert.Contains("not found", result.Summary, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("settings.executable", result.Error, StringComparison.OrdinalIgnoreCase);
    }
}
