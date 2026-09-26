using System.Diagnostics;
using Benchpilot.Protocol;

namespace Benchpilot.Client;

/// <summary>
/// Starts the resident benchpilotd process on demand so a single CLI/MCP
/// invocation works without a separate terminal. The daemon outlives the
/// caller: logs go to ~/.benchpilot/logs and state stays resident for the
/// next command, which is what makes CLI invocations a session rather than
/// one-shot requests.
/// </summary>
public static class RuntimeAutoStart
{
    private static readonly TimeSpan ReadyTimeout = TimeSpan.FromSeconds(15);

    public static bool IsDisabled() =>
        string.Equals(
            Environment.GetEnvironmentVariable("BENCHPILOT_AUTOSTART"),
            "0",
            StringComparison.Ordinal);

    /// <summary>
    /// Ensures a healthy daemon serves the endpoint. Returns true when the
    /// daemon is reachable afterwards, false when autostart is impossible
    /// (for example benchpilotd is not installed next to the CLI).
    /// </summary>
    public static async Task<bool> EnsureRunningAsync(Uri endpoint, CancellationToken ct = default)
    {
        if (IsDisabled())
            return false;
        if (await IsHealthyAsync(endpoint, ct).ConfigureAwait(false))
            return true;

        var daemonPath = ResolveDaemonPath();
        if (daemonPath is null)
            return false;

        StartDaemon(daemonPath, endpoint);

        var deadline = DateTimeOffset.UtcNow + ReadyTimeout;
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (await IsHealthyAsync(endpoint, ct).ConfigureAwait(false))
                return true;
            await Task.Delay(200, ct).ConfigureAwait(false);
        }

        return false;
    }

    /// <summary>
    /// Locates the daemon executable that belongs to this installation:
    /// next to the current shell binary first, then on PATH.
    /// </summary>
    public static string? ResolveDaemonPath()
    {
        var exeName = OperatingSystem.IsWindows() ? "benchpilotd.exe" : "benchpilotd";

        var candidate = Path.Combine(AppContext.BaseDirectory, exeName);
        if (File.Exists(candidate))
            return candidate;

        var pathEnv = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrWhiteSpace(pathEnv))
            return null;

        foreach (var dir in pathEnv.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                candidate = Path.Combine(dir.Trim(), exeName);
                if (File.Exists(candidate))
                    return candidate;
            }
            catch (ArgumentException)
            {
                // PATH entries can contain garbage; skip them.
            }
        }

        return null;
    }

    private static void StartDaemon(string daemonPath, Uri endpoint)
    {
        Directory.CreateDirectory(LocalAuth.LogDirectoryPath);
        var logPath = Path.Combine(
            LocalAuth.LogDirectoryPath,
            $"runtime-{DateTimeOffset.UtcNow:yyyyMMdd-HHmmss}-{Guid.NewGuid().ToString("N")[..8]}.log");

        var psi = new ProcessStartInfo
        {
            FileName = daemonPath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = false,
        };
        psi.Environment["BENCHPILOT_ENDPOINT"] = endpoint.GetLeftPart(UriPartial.Authority);
        // The spawning shell is short-lived: once it exits nobody drains the
        // pipe, and a daemon that keeps writing to stdout would eventually
        // block on a full pipe buffer. The daemon therefore logs to its own
        // file and stays silent on stdout/stderr in autostart mode.
        psi.Environment["BENCHPILOT_QUIET"] = "1";
        psi.Environment["BENCHPILOT_LOG_FILE"] = logPath;

        // On POSIX a Ctrl+C in the shared terminal process group would kill
        // the daemon together with the short-lived shell that spawned it.
        // setsid detaches the daemon into its own session; Windows needs no
        // equivalent because CreateNoWindow already isolates it from the
        // console Ctrl+C signal.
        if (!OperatingSystem.IsWindows())
        {
            var setsid = ResolveSetsidPath();
            if (setsid is not null)
            {
                psi.ArgumentList.Add(daemonPath);
                psi.FileName = setsid;
            }
        }

        var process = Process.Start(psi);
        if (process is null)
            return;

        _ = PumpToLog(process.StandardOutput, logPath);
        _ = PumpToLog(process.StandardError, logPath);
    }

    private static string? ResolveSetsidPath()
    {
        foreach (var dir in new[] { "/usr/bin", "/bin", "/usr/local/bin" })
        {
            var candidate = Path.Combine(dir, "setsid");
            if (File.Exists(candidate))
                return candidate;
        }

        return null;
    }

    private static async Task PumpToLog(StreamReader reader, string logPath)
    {
        try
        {
            while (await reader.ReadLineAsync().ConfigureAwait(false) is { } line)
            {
                await File.AppendAllTextAsync(logPath, line + Environment.NewLine)
                    .ConfigureAwait(false);
            }
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException)
        {
            // The daemon outliving this process is expected; the pipe then
            // breaks. Durable daemon logs live in BENCHPILOT_LOG_FILE.
        }
    }

    private static async Task<bool> IsHealthyAsync(Uri endpoint, CancellationToken ct)
    {
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
            var baseUri = endpoint.AbsoluteUri.EndsWith("/", StringComparison.Ordinal)
                ? endpoint
                : new Uri(endpoint.AbsoluteUri + "/");
            using var response = await http.GetAsync(new Uri(baseUri, "healthz"), ct).ConfigureAwait(false);
            return response.IsSuccessStatusCode;
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or InvalidOperationException)
        {
            return false;
        }
    }
}
