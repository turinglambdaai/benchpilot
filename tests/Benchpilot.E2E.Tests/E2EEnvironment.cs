using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;

namespace Benchpilot.E2E.Tests;

/// <summary>
/// Locates the built executables, stages them into one directory (the same
/// layout as a release package: benchpilotd and benchpilot side by side) and
/// owns daemon process lifecycle for a test collection.
/// </summary>
public sealed class E2EEnvironment : IDisposable
{
    public string StageDirectory { get; }
    public string DaemonPath => Path.Combine(StageDirectory, ExeName("benchpilotd"));
    public string CliPath => Path.Combine(StageDirectory, ExeName("benchpilot"));
    public Uri Endpoint { get; }
    public string DaemonLogFile { get; }
    private Process? _daemon;

    private E2EEnvironment(string stageDirectory, Uri endpoint, string daemonLogFile)
    {
        StageDirectory = stageDirectory;
        Endpoint = endpoint;
        DaemonLogFile = daemonLogFile;
    }

    public static string ExeName(string baseName) =>
        OperatingSystem.IsWindows() ? $"{baseName}.exe" : baseName;

    /// <summary>
    /// Stages benchpilotd + benchpilot into a fresh directory. Does not start
    /// anything: the daemon-down state is exactly what autostart tests need.
    /// </summary>
    public static E2EEnvironment Create()
    {
        var repoRoot = FindRepoRoot();
        var config = GetBuildConfiguration();

        var stage = Directory.CreateTempSubdirectory("benchpilot-e2e-").FullName;
        CopyBuildOutput(repoRoot, config, "Benchpilot.RuntimeHost", stage);
        CopyBuildOutput(repoRoot, config, "Benchpilot.Cli", stage);

        var port = GetFreeLoopbackPort();
        var endpoint = new Uri($"http://127.0.0.1:{port}/");
        return new E2EEnvironment(
            stage,
            endpoint,
            Path.Combine(stage, "benchpilotd-e2e.log"));
    }

    /// <summary>
    /// Starts benchpilotd against the staged endpoint and waits until it is
    /// healthy. The daemon shares the user token file with any other daemon,
    /// which is fine: tests talk to one endpoint at a time.
    /// </summary>
    public void StartDaemon()
    {
        if (_daemon is not null && !_daemon.HasExited)
            return;

        var psi = new ProcessStartInfo
        {
            FileName = DaemonPath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        psi.Environment["BENCHPILOT_ENDPOINT"] = Endpoint.ToString();
        psi.Environment["BENCHPILOT_QUIET"] = "1";
        psi.Environment["BENCHPILOT_LOG_FILE"] = DaemonLogFile;

        _daemon = Process.Start(psi) ?? throw new InvalidOperationException("Failed to start benchpilotd.");
        // Drain pipes so a chatty daemon can never block on a full buffer.
        _ = _daemon.StandardOutput.ReadToEndAsync();
        _ = _daemon.StandardError.ReadToEndAsync();

        WaitHealthy();
    }

    public void WaitHealthy(int timeoutSeconds = 60)
    {
        var deadline = DateTimeOffset.UtcNow.AddSeconds(timeoutSeconds);
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (IsHealthy())
                return;
            Thread.Sleep(200);
        }

        throw new TimeoutException(
            $"benchpilotd did not become healthy within {timeoutSeconds}s. Log: {LogTail()}");
    }

    public bool IsHealthy()
    {
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
            using var response = http.GetAsync(new Uri(Endpoint, "healthz")).GetAwaiter().GetResult();
            return response.IsSuccessStatusCode;
        }
        catch (Exception ex) when (ex is HttpRequestException or InvalidOperationException or TaskCanceledException)
        {
            return false;
        }
    }

    /// <summary>
    /// Runs the staged CLI as a real process and returns its observable
    /// contract: exit code plus stdout (JSON text or plain output).
    /// </summary>
    public (int ExitCode, string Stdout) RunCli(params string[] args)
    {
        var psi = new ProcessStartInfo
        {
            FileName = CliPath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var arg in args)
            psi.ArgumentList.Add(arg);
        psi.Environment["BENCHPILOT_ENDPOINT"] = Endpoint.ToString();

        using var process = Process.Start(psi)
            ?? throw new InvalidOperationException("Failed to start benchpilot CLI.");
        var wait = TimeSpan.FromMinutes(3);
        var stdout = process.StandardOutput.ReadToEndAsync().WaitAsync(wait).GetAwaiter().GetResult();
        _ = process.StandardError.ReadToEndAsync().WaitAsync(wait).GetAwaiter().GetResult();
        if (!process.WaitForExit((int)wait.TotalMilliseconds))
        {
            process.Kill(entireProcessTree: true);
            throw new TimeoutException($"CLI did not exit: benchpilot {string.Join(' ', args)}");
        }

        return (process.ExitCode, stdout);
    }

    public JsonDocument RunCliJson(params string[] args)
    {
        var (exitCode, stdout) = RunCli(args);
        Assert.Equal(0, exitCode);
        return JsonDocument.Parse(stdout);
    }

    public string LogTail()
    {
        try
        {
            return File.Exists(DaemonLogFile) ? File.ReadAllText(DaemonLogFile) : "(no daemon log)";
        }
        catch (IOException)
        {
            return "(daemon log unreadable)";
        }
    }

    private static void CopyBuildOutput(
        string repoRoot,
        string config,
        string project,
        string stage)
    {
        var sourceDir = Path.Combine(repoRoot, "src", project, "bin", config, "net10.0");
        var apphost = Path.Combine(sourceDir, ExeName(project == "Benchpilot.RuntimeHost" ? "benchpilotd" : "benchpilot"));
        Assert.True(
            File.Exists(apphost),
            $"Built executable not found: {apphost}. Run 'dotnet build -c {config}' first.");

        // Framework-dependent apphosts need their whole build output next to
        // them, and staging both shells into one directory mirrors the
        // release package layout (benchpilotd next to benchpilot).
        foreach (var file in Directory.GetFiles(sourceDir))
            File.Copy(file, Path.Combine(stage, Path.GetFileName(file)), overwrite: true);
    }

    private static string FindRepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Benchpilot.slnx")))
            dir = dir.Parent;
        Assert.NotNull(dir);
        return dir!.FullName;
    }

    private static string GetBuildConfiguration()
    {
#if DEBUG
        return "Debug";
#else
        return "Release";
#endif
    }

    private static int GetFreeLoopbackPort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        try
        {
            return ((IPEndPoint)listener.LocalEndpoint).Port;
        }
        finally
        {
            listener.Stop();
        }
    }

    public void Dispose()
    {
        if (_daemon is not null && !_daemon.HasExited)
        {
            try
            {
                _daemon.Kill(entireProcessTree: true);
                _daemon.WaitForExit(10_000);
            }
            catch (InvalidOperationException)
            {
                // Already gone.
            }
        }

        _daemon?.Dispose();
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                Directory.Delete(StageDirectory, recursive: true);
                return;
            }
            catch (Exception) when (attempt >= 5)
            {
                return;
            }
            catch (Exception ex) when (attempt < 5 &&
                ex is IOException or UnauthorizedAccessException)
            {
                // On Windows a just-killed daemon's file locks (or a
                // transient antivirus scan of freshly written binaries) can
                // hold the stage directory for a while. Retry, then give up:
                // a leftover temp directory must never fail a test run.
                Thread.Sleep(200 * (attempt + 1));
            }
        }
    }
}
