using System.Formats.Tar;
using System.IO.Compression;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Text.Json;

using Benchpilot.Protocol;

namespace Benchpilot.Client;

/// <summary>Result of an update check against the release feed.</summary>
public sealed record UpdateCheckResult(
    bool UpdateAvailable,
    string CurrentVersion,
    string? LatestVersion,
    string? ReleaseUrl,
    string? Error = null);

/// <summary>Outcome of a full update run.</summary>
public sealed record UpdateResult(
    bool Ok,
    string Message,
    string? NewVersion = null,
    bool DaemonWasRunning = false,
    string? Error = null);

/// <summary>
/// Self-update for the shipped single-file shells: checks the release feed,
/// downloads the platform archive, verifies SHA256, stops the resident daemon
/// gracefully and swaps the executables in place. The next CLI command (or the
/// final step of the update itself) restarts the daemon via autostart.
///
/// Feed contract: by default the GitHub releases of BENCHPILOT_UPDATE_REPO
/// (default turinglambdaai/benchpilot) are used. BENCHPILOT_UPDATE_FEED
/// overrides this with a generic feed URL answering
/// {"version": "...", "assets": [{"name": "...", "url": "..."}]} — used by
/// tests and self-hosted mirrors. The platform archive must ship with a
/// SHA256SUMS.txt asset (GitHub) or a sibling "{archive}.sha256" file (feed).
/// </summary>
public static class SelfUpdater
{
    public const string DefaultRepository = "turinglambdaai/benchpilot";

    private static readonly string[] PackagedFiles =
        ["benchpilot", "benchpilotd", "benchpilot-mcp"];

    public static string Repository() =>
        Environment.GetEnvironmentVariable("BENCHPILOT_UPDATE_REPO") ?? DefaultRepository;

    private static string FeedUrl()
    {
        var feed = Environment.GetEnvironmentVariable("BENCHPILOT_UPDATE_FEED");
        return string.IsNullOrWhiteSpace(feed)
            ? $"https://api.github.com/repos/{Repository()}/releases/latest"
            : feed;
    }

    /// <summary>
    /// Maps the running platform to one of the release-packaging RIDs.
    /// </summary>
    public static string PlatformRid()
    {
        if (OperatingSystem.IsWindows())
            return "win-x64";
        if (OperatingSystem.IsMacOS())
            return "osx-arm64";
        if (OperatingSystem.IsLinux())
            return RuntimeInformation.ProcessArchitecture == Architecture.Arm64
                ? "linux-arm64"
                : "linux-x64";
        throw new PlatformNotSupportedException(
            "No BenchPilot package exists for this platform.");
    }

    /// <summary>
    /// Compares dotted numeric versions; returns positive when a is newer,
    /// negative when b is newer, zero when equal. Non-numeric parts compare
    /// lexically after the numeric prefix.
    /// </summary>
    public static int CompareVersions(string a, string b)
    {
        var left = a.Trim().TrimStart('v').Split('.');
        var right = b.Trim().TrimStart('v').Split('.');
        for (var i = 0; i < Math.Max(left.Length, right.Length); i++)
        {
            var l = i < left.Length ? left[i] : "0";
            var r = i < right.Length ? right[i] : "0";
            if (int.TryParse(l, out var li) && int.TryParse(r, out var ri))
            {
                if (li != ri)
                    return li.CompareTo(ri);
            }
            else if (!string.Equals(l, r, StringComparison.OrdinalIgnoreCase))
            {
                return string.Compare(l, r, StringComparison.OrdinalIgnoreCase);
            }
        }

        return 0;
    }

    /// <summary>
    /// Checks the feed for the latest version without touching anything.
    /// </summary>
    public static async Task<UpdateCheckResult> CheckAsync(CancellationToken ct = default)
    {
        var current = BenchpilotRuntimeInfo.Version;
        try
        {
            using var http = CreateHttp();
            var (latest, _, releaseUrl) = await FetchLatestAsync(http, ct).ConfigureAwait(false);
            var available = CompareVersions(latest, current) > 0;
            return new UpdateCheckResult(available, current, latest, releaseUrl);
        }
        catch (Exception ex) when (ex is HttpRequestException or JsonException or InvalidOperationException)
        {
            return new UpdateCheckResult(false, current, null, null, ex.Message);
        }
    }

    /// <summary>
    /// Runs the full update: download, verify, stop daemon, swap, optionally
    /// restart the daemon. Files are only touched after verification passes.
    /// </summary>
    public static async Task<UpdateResult> RunAsync(CancellationToken ct = default)
    {
        var current = BenchpilotRuntimeInfo.Version;
        var workDir = Directory.CreateTempSubdirectory("benchpilot-update-").FullName;
        try
        {
            using var http = CreateHttp();
            var (latest, assets, releaseUrl) = await FetchLatestAsync(http, ct).ConfigureAwait(false);
            if (CompareVersions(latest, current) <= 0)
                return new UpdateResult(true, $"Already up to date ({current}).", current);

            var rid = PlatformRid();
            var extension = rid == "win-x64" ? "zip" : "tar.gz";
            var archiveName = $"benchpilot-{latest}-{rid}.{extension}";
            (string Name, string Url)? archive = assets.FirstOrDefault(x =>
                string.Equals(x.Name, archiveName, StringComparison.OrdinalIgnoreCase));
            if (archive is null)
                throw new InvalidOperationException(
                    $"Release {latest} has no asset '{archiveName}'.");
            (string Name, string Url)? sums = assets.FirstOrDefault(x =>
                x.Name.Equals("SHA256SUMS.txt", StringComparison.OrdinalIgnoreCase));
            if (sums is null)
                throw new InvalidOperationException(
                    $"Release {latest} has no SHA256SUMS.txt asset.");

            var archivePath = Path.Combine(workDir, archiveName);
            await DownloadAsync(http, archive.Value.Url, archivePath, ct).ConfigureAwait(false);
            var sumsPath = Path.Combine(workDir, "SHA256SUMS.txt");
            await DownloadAsync(http, sums.Value.Url, sumsPath, ct).ConfigureAwait(false);

            VerifyChecksum(archivePath, sumsPath, archiveName);

            var extractDir = Path.Combine(workDir, "extract");
            Directory.CreateDirectory(extractDir);
            ExtractArchive(archivePath, extractDir);

            // Refuse to interrupt active hardware work before touching files.
            var endpoint = BenchClient.ResolveEndpoint();
            bool daemonWasRunning;
            (daemonWasRunning, var activeOperations) = await ProbeDaemonAsync(endpoint, ct).ConfigureAwait(false);
            if (activeOperations > 0)
                return new UpdateResult(
                    false,
                    $"The daemon has {activeOperations} active operation(s); update refused. " +
                    "Wait for them to finish or cancel them, then retry.");

            await StopDaemonAsync(endpoint, daemonWasRunning, ct).ConfigureAwait(false);

            var installed = InstallFiles(extractDir);
            if (installed == 0)
                throw new InvalidOperationException(
                    $"Archive '{archiveName}' contained none of the BenchPilot executables.");

            return new UpdateResult(
                true,
                $"Updated to {latest} ({installed} executable(s) swapped). " +
                (daemonWasRunning ? "The daemon restarts automatically on the next command." : string.Empty) +
                "If an agent hosts benchpilot-mcp, restart that MCP server.",
                latest,
                daemonWasRunning);
        }
        catch (Exception ex) when (ex is HttpRequestException or JsonException or InvalidOperationException
            or InvalidDataException or IOException or PlatformNotSupportedException)
        {
            return new UpdateResult(false, $"Update failed: {ex.Message}", Error: ex.Message, NewVersion: current);
        }
        finally
        {
            try
            {
                Directory.Delete(workDir, recursive: true);
            }
            catch (IOException)
            {
                // Temp cleanup is best effort.
            }
        }
    }

    private static HttpClient CreateHttp()
    {
        var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("benchpilot-updater");
        return http;
    }

    private static async Task<(string Version, List<(string Name, string Url)> Assets, string? ReleaseUrl)> FetchLatestAsync(
        HttpClient http,
        CancellationToken ct)
    {
        var feed = FeedUrl();
        using var response = await http.GetAsync(feed, ct).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        using var doc = JsonDocument.Parse(
            await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
        var root = doc.RootElement;

        if (root.TryGetProperty("assets", out var assetsElement))
        {
            // GitHub releases API shape (generic feeds use the same shape).
            var version = root.GetProperty("tag_name").GetString()!.TrimStart('v');
            var releaseUrl = root.TryGetProperty("html_url", out var htmlUrl)
                ? htmlUrl.GetString()
                : feed;
            var assets = new List<(string, string)>();
            foreach (var asset in assetsElement.EnumerateArray())
            {
                var name = asset.GetProperty("name").GetString();
                // browser_download_url is the direct link; the GitHub API
                // "url" field is metadata that only serves bytes to requests
                // with an octet-stream Accept header. Prefer the direct link.
                var url = asset.TryGetProperty("browser_download_url", out var downloadUrl)
                    && downloadUrl.ValueKind == JsonValueKind.String
                    ? downloadUrl.GetString()
                    : asset.GetProperty("url").GetString();
                if (!string.IsNullOrWhiteSpace(name) && !string.IsNullOrWhiteSpace(url))
                    assets.Add((name, url!));
            }

            return (version, assets, releaseUrl);
        }

        throw new JsonException($"Update feed '{feed}' returned an unrecognized shape.");
    }

    private static async Task DownloadAsync(
        HttpClient http,
        string url,
        string destination,
        CancellationToken ct)
    {
        using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct)
            .ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        await using var source = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        await using var target = File.Create(destination);
        await source.CopyToAsync(target, ct).ConfigureAwait(false);
    }

    public static void VerifyChecksum(string archivePath, string sumsPath, string archiveName)
    {
        string? expected = null;
        foreach (var line in File.ReadAllLines(sumsPath))
        {
            // Format: "<hex>  <name>" (sha256sum output, two spaces).
            var parts = line.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 2 &&
                parts[1].Trim().Equals(archiveName, StringComparison.OrdinalIgnoreCase))
            {
                expected = parts[0].Trim().ToLowerInvariant();
                break;
            }
        }

        if (expected is null)
            throw new InvalidOperationException(
                $"SHA256SUMS.txt has no entry for '{archiveName}'.");

        using var stream = File.OpenRead(archivePath);
        var actual = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
        if (actual != expected)
            throw new InvalidOperationException(
                "Checksum mismatch: the downloaded archive does not match SHA256SUMS.txt " +
                $"(expected {expected}, got {actual}).");
    }

    private static void ExtractArchive(string archivePath, string destination)
    {
        if (archivePath.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
        {
            ZipFile.ExtractToDirectory(archivePath, destination, overwriteFiles: true);
        }
        else
        {
            using var stream = File.OpenRead(archivePath);
            TarFile.ExtractToDirectory(stream, destination, overwriteFiles: true);
        }

        // Archives wrap files in one directory; flatten it.
        var entries = Directory.GetFileSystemEntries(destination);
        if (entries.Length == 1 && Directory.Exists(entries[0]))
        {
            var inner = entries[0];
            foreach (var file in Directory.GetFiles(inner))
                File.Move(file, Path.Combine(destination, Path.GetFileName(file)), overwrite: true);
        }
    }

    private static async Task<(bool WasRunning, int ActiveOperations)> ProbeDaemonAsync(
        Uri endpoint,
        CancellationToken ct)
    {
        try
        {
            using var client = new BenchClient(endpoint);
            var operations = await client.Operations(ct).ConfigureAwait(false);
            return (true, operations.Operations.Count);
        }
        catch (Exception ex) when (ex is HttpRequestException or BenchClientException or TaskCanceledException)
        {
            return (false, 0);
        }
    }

    private static async Task StopDaemonAsync(Uri endpoint, bool wasRunning, CancellationToken ct)
    {
        if (wasRunning)
        {
            try
            {
                using var client = new BenchClient(endpoint);
                await client.Shutdown(ct).ConfigureAwait(false);
            }
            catch (HttpRequestException)
            {
                // Daemon disappeared between probe and shutdown.
            }

            // Wait for the graceful drain to finish (bounded; the daemon
            // releases hardware resources before exiting).
            for (var i = 0; i < 50; i++)
            {
                await Task.Delay(200, ct).ConfigureAwait(false);
                using var probe = new HttpClient { Timeout = TimeSpan.FromSeconds(1) };
                try
                {
                    using var response = await probe.GetAsync(new Uri(endpoint, "healthz"), ct)
                        .ConfigureAwait(false);
                }
                catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or InvalidOperationException)
                {
                    return;
                }
            }
        }

        // Hard fallback: anything still holding the daemon binary is killed so
        // the file swap cannot fail on Windows file locks.
        foreach (var process in System.Diagnostics.Process.GetProcessesByName("benchpilotd"))
        {
            try
            {
                process.Kill(entireProcessTree: true);
                await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
            }
            catch (System.ComponentModel.Win32Exception)
            {
            }
            catch (InvalidOperationException)
            {
            }
            finally
            {
                process.Dispose();
            }
        }
    }

    private static int InstallFiles(string extractDir)
    {
        var installDir = AppContext.BaseDirectory;
        var suffix = OperatingSystem.IsWindows() ? ".exe" : string.Empty;
        var swapped = 0;

        foreach (var baseName in PackagedFiles)
        {
            var source = Path.Combine(extractDir, baseName + suffix);
            if (!File.Exists(source))
                continue;

            var target = Path.Combine(installDir, baseName + suffix);
            var backup = target + ".old";
            if (File.Exists(backup))
            {
                try
                {
                    File.Delete(backup);
                }
                catch (IOException)
                {
                }
            }

            // Renaming a running executable is allowed on Windows (the image
            // section stays with the old name), so even benchpilot.exe
            // replacing itself mid-run works; deleting does not.
            if (File.Exists(target))
                File.Move(target, backup, overwrite: true);
            File.Move(source, target);
            swapped++;
        }

        return swapped;
    }
}
