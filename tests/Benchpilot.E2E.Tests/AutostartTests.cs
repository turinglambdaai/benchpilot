using System.Diagnostics;
using Xunit;

namespace Benchpilot.E2E.Tests;

/// <summary>
/// Autostart runs in its own environment precisely because no daemon is
/// running when the first command arrives.
/// </summary>
public sealed class AutostartTests : IDisposable
{
    private readonly E2EEnvironment _env = E2EEnvironment.Create();
    private readonly HashSet<int> _preExistingDaemonIds = [.. GetDaemonProcessIds()];

    private E2EEnvironment Env => _env;

    [Fact]
    public async Task First_Command_Starts_Daemon_And_Succeeds()
    {
        var (exitCode, stdout) = await Env.RunCliAsync("status", "--json");

        Assert.Equal(0, exitCode);
        Assert.Contains("\"ok\":true", stdout);

        // The daemon must outlive the short-lived CLI command: that resident
        // state is the product premise, not an implementation detail.
        Assert.True(
            await Env.IsHealthyAsync(),
            "autostarted daemon must stay healthy after the CLI exits");
    }

    [Fact]
    public async Task Doctor_Does_Not_Start_Daemon()
    {
        var (exitCode, stdout) = await Env.RunCliAsync("doctor", "--json");

        Assert.Equal(4, exitCode);
        Assert.Contains("\"runtimeReachable\":false", stdout);
        Assert.Contains("remediation", stdout);
        Assert.False(
            await Env.IsHealthyAsync(),
            "doctor must be non-mutating and not start the daemon");
    }

    public void Dispose()
    {
        foreach (var pid in GetDaemonProcessIds())
        {
            if (_preExistingDaemonIds.Contains(pid))
                continue;
            try
            {
                using var daemon = Process.GetProcessById(pid);
                daemon.Kill(entireProcessTree: true);
                daemon.WaitForExit(10_000);
            }
            catch (Exception ex) when (ex is ArgumentException or InvalidOperationException)
            {
                // Process already exited.
            }
        }

        _env.Dispose();
    }

    private static IEnumerable<int> GetDaemonProcessIds() =>
        Process.GetProcessesByName(E2EEnvironment.ExeName("benchpilotd"))
            .Select(x => x.Id);
}
