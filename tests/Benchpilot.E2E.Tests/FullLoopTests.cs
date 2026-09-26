using System.Text.Json;
using Xunit;

namespace Benchpilot.E2E.Tests;

/// <summary>
/// The complete simulator ECU loop through the real CLI process boundary:
/// exactly the command sequence from the README quick start.
/// </summary>
[Collection("shared-daemon")]
public sealed class FullLoopTests(SharedDaemonFixture fixture)
{
    private E2EEnvironment Env => fixture.Environment;

    [Fact]
    public async Task Simulator_Ecu_Loop_Succeeds_Through_Cli()
    {
        await Env.RunCliJsonAsync("status", "--json");
        await Env.RunCliJsonAsync("power", "on", "--voltage", "12", "--settle-ms", "200", "--json");
        await Env.RunCliJsonAsync("serial", "open", "--json");
        await Env.RunCliJsonAsync("flash", "write", "build/app.elf", "--json");

        using (var wait = await Env.RunCliJsonAsync("serial", "wait", "Ready", "--timeout-ms", "5000", "--json"))
        {
            Assert.True(wait.RootElement.GetProperty("matched").GetBoolean());
        }

        using (var check = await Env.RunCliJsonAsync("power", "check", "--lt-ma", "100", "--json"))
        {
            Assert.True(check.RootElement.GetProperty("passed").GetBoolean());
        }

        await Env.RunCliJsonAsync("power", "off", "--json");
    }

    [Fact]
    public async Task Unmatched_Serial_Wait_Returns_Exit_Code_1_With_Failure_Evidence()
    {
        // The simulator only drives its serial line while power is on.
        await Env.RunCliJsonAsync("power", "on", "--voltage", "12", "--settle-ms", "100", "--json");
        await Env.RunCliJsonAsync("serial", "open", "--json");

        var (exitCode, stdout) = await Env.RunCliAsync(
            "serial", "wait", "__E2E_NEVER_MATCH__", "--timeout-ms", "50", "--json");
        // Assertion-style failure: the observation itself executed fine
        // (ok=true) but nothing matched, so the CLI maps it to exit code 1.
        Assert.Equal(1, exitCode);

        using var result = JsonDocument.Parse(stdout);
        Assert.True(result.RootElement.GetProperty("ok").GetBoolean());
        Assert.False(result.RootElement.GetProperty("matched").GetBoolean());
        var observationId = result.RootElement.GetProperty("observationId").GetString();
        Assert.False(string.IsNullOrWhiteSpace(observationId));

        // The failed observation must produce bounded evidence through the
        // same CLI path, including correlated power context.
        using (var evidence = await Env.RunCliJsonAsync("observe", "evidence", observationId!, "--json"))
        {
            var kinds = evidence.RootElement.GetProperty("items")
                .EnumerateArray()
                .Select(x => x.GetProperty("kind").GetString())
                .ToHashSet();
            Assert.Contains("serial.wait", kinds);
            Assert.Contains("serial.failure-window", kinds);
            Assert.Contains("context.power-on", kinds);
        }
    }

    [Fact]
    public async Task Runtime_Deadline_Exceeds_Semantic_Wait_And_Returns_Exit_Code_6()
    {
        // The simulator only drives its serial line while power is on.
        await Env.RunCliJsonAsync("power", "on", "--voltage", "12", "--settle-ms", "100", "--json");
        await Env.RunCliJsonAsync("serial", "open", "--json");

        var (exitCode, stdout) = await Env.RunCliAsync(
            "serial", "wait", "__E2E_DEADLINE__", "--timeout-ms", "5000", "--deadline-ms", "100", "--json");
        Assert.Equal(6, exitCode);

        using var result = JsonDocument.Parse(stdout);
        Assert.Equal("deadline_exceeded", result.RootElement.GetProperty("code").GetString());
        Assert.Equal(100, result.RootElement.GetProperty("deadlineMs").GetInt32());
    }

    [Fact]
    public async Task Simulator_Bench_Validate_Is_Not_Ready_For_Real_Ecu()
    {
        var (exitCode, stdout) = await Env.RunCliAsync("bench", "validate", "--target", "demo", "--json");
        Assert.Equal(1, exitCode);

        using var report = JsonDocument.Parse(stdout);
        Assert.True(report.RootElement.GetProperty("ok").GetBoolean());
        Assert.False(report.RootElement.GetProperty("readyForRealEcuLoop").GetBoolean());
        Assert.Equal("simulator", report.RootElement.GetProperty("mode").GetString());
        var realHardwareCheck = report.RootElement.GetProperty("checks")
            .EnumerateArray()
            .First(x => x.GetProperty("code").GetString() == "target.real-hardware");
        Assert.False(realHardwareCheck.GetProperty("passed").GetBoolean());
        Assert.False(string.IsNullOrWhiteSpace(
            realHardwareCheck.GetProperty("remediation").GetString()));
    }
}
