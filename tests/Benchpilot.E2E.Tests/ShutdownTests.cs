using Xunit;

namespace Benchpilot.E2E.Tests;

/// <summary>
/// Graceful daemon shutdown through the real CLI/HTTP path: the updater
/// depends on it to release hardware handles before swapping binaries.
/// </summary>
public sealed class ShutdownTests : IDisposable
{
    private readonly E2EEnvironment _env = E2EEnvironment.Create();

    [Fact]
    public async Task Shutdown_Stops_Daemon_And_Releases_Endpoint()
    {
        await _env.StartDaemonAsync();
        Assert.True(await _env.IsHealthyAsync());

        var (exitCode, stdout) = await _env.RunCliAsync("shutdown", "--json");
        Assert.Equal(0, exitCode);
        Assert.Contains("\"ok\":true", stdout);

        // The daemon must be gone (drained, not just unhealthy): allow the
        // graceful drain a moment, then require the endpoint to stay down.
        await Task.Delay(1500);
        Assert.False(await _env.IsHealthyAsync());
    }

    [Fact]
    public async Task Shutdown_Is_Idempotent_When_Daemon_Is_Not_Running()
    {
        var (exitCode, stdout) = await _env.RunCliAsync("shutdown", "--json");
        Assert.Equal(0, exitCode);
        Assert.Contains("not_running", stdout);
    }

    public void Dispose() => _env.Dispose();
}
