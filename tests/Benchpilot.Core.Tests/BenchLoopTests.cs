using Benchpilot.Core;
using Benchpilot.Simulator;

namespace Benchpilot.Core.Tests;

// Verifies the simulated bench behaves like a real board through the exact
// P0 loop an agent runs: power_on -> flash -> wait_for("Ready") ->
// check_current -> power_off. These run against the kernel directly (no MCP
// on the wire); a separate smoke test exercises the MCP transport.
public class BenchLoopTests
{
    // One SimulatedBench backs all three channels, exactly as the DI in
    // Program.cs wires it, so power/serial/flash share state.
    private static BenchKernel NewKernel()
    {
        var bench = new SimulatedBench();
        return new BenchKernel(ProfileLoader.DefaultSimulator(), bench, bench, bench);
    }

    [Fact]
    public async Task PowerOn_sets_isOn_and_reports_current()
    {
        var k = NewKernel();
        var r = await k.Power.PowerOn(12, 200);
        Assert.True(r.Ok);
        Assert.True(k.Power.IsOn);
        Assert.Equal(12, r.Voltage);
        Assert.True(r.CurrentMa > 0);
    }

    [Fact]
    public async Task PowerOn_is_idempotent_when_already_on()
    {
        var k = NewKernel();
        await k.Power.PowerOn(12, 100);
        var second = await k.Power.PowerOn(12, 100);
        Assert.True(second.Ok);
        Assert.True(second.Settled);
    }

    [Fact]
    public async Task Flash_reboots_and_console_reaches_Ready()
    {
        var k = NewKernel();
        await k.Power.PowerOn(12, 100);
        var flash = await k.Flash.Flash("build/app.elf");
        Assert.True(flash.Ok);
        Assert.True(flash.Bytes > 0);
        Assert.True(flash.DurationMs > 0);

        var wait = await k.Serial.WaitFor("Ready", 5000);
        Assert.True(wait.Matched, "Console never reached 'Ready' after flash.");
    }

    [Fact]
    public async Task Full_smoke_loop_passes()
    {
        var k = NewKernel();
        // The exact P0 acceptance sequence (PRD §9.1).
        Assert.True((await k.Power.PowerOn(12, 200)).Ok);
        Assert.True((await k.Flash.Flash("build/app.elf")).Ok);

        var ready = await k.Serial.WaitFor("Ready", 5000);
        Assert.True(ready.Matched);

        var current = await k.Power.CheckCurrent(ltMa: 100);
        Assert.True(current.Passed);   // settled idle (~45mA) is under 100mA

        Assert.True((await k.Power.PowerOff()).Ok);
        Assert.False(k.Power.IsOn);
    }

    [Fact]
    public async Task CheckCurrent_fails_during_inrush()
    {
        var k = NewKernel();
        await k.Power.PowerOn(12, 0);        // no settle -> still in inrush
        var current = await k.Power.CheckCurrent(ltMa: 100);
        Assert.False(current.Passed);        // inrush (~600-900mA) exceeds 100mA
    }

    [Fact]
    public async Task PowerOff_clears_state()
    {
        var k = NewKernel();
        await k.Power.PowerOn(12, 100);
        Assert.True(k.Power.IsOn);
        await k.Power.PowerOff();
        Assert.False(k.Power.IsOn);
        var window = await k.Serial.ReadWindow(10, null);
        Assert.Empty(window.Lines);
    }

    [Fact]
    public async Task Reset_reboots_firmware()
    {
        var k = NewKernel();
        await k.Power.PowerOn(12, 100);
        await k.Flash.Flash("build/app.elf");
        await k.Serial.WaitFor("Ready", 5000);
        // Reset should produce a fresh boot log.
        Assert.True((await k.Flash.Reset()).Ok);
        var wait = await k.Serial.WaitFor("Ready", 5000);
        Assert.True(wait.Matched);
    }

    [Fact]
    public async Task SerialWaitFor_times_out_on_missing_pattern()
    {
        var k = NewKernel();
        await k.Power.PowerOn(12, 100);
        var wait = await k.Serial.WaitFor("NONEXISTENT_PATTERN_xyz", 300);
        Assert.False(wait.Matched);
    }
}
