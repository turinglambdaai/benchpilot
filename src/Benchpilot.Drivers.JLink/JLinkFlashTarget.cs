using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using Benchpilot.Core;
using Benchpilot.Runtime;

namespace Benchpilot.Drivers.JLink;

public sealed class JLinkResourceFactory : IBenchResourceFactory
{
    public string DriverName => "jlink";

    public object Create(string resourceId, BenchResourceConfig config)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(resourceId);
        ArgumentNullException.ThrowIfNull(config);

        if (!config.Capabilities.Contains("flash", StringComparer.OrdinalIgnoreCase))
            throw new InvalidOperationException(
                $"Resource '{resourceId}' uses jlink but does not declare the 'flash' capability.");

        var device = RequireString(config, "device", resourceId);
        var targetInterface = GetString(config, "interface") ?? "SWD";
        var speedKhz = GetInt(config, "speedKhz") ?? 4000;
        var serialNumber = GetString(config, "serialNumber");
        var executable = GetString(config, "executable") ?? DefaultExecutable();
        var timeoutMs = GetInt(config, "timeoutMs") ?? 120_000;
        var binAddress = GetAddress(config, "binAddress");

        if (speedKhz <= 0)
            throw new InvalidOperationException($"Resource '{resourceId}' speedKhz must be greater than zero.");
        if (timeoutMs is < 1000 or > 30 * 60 * 1000)
            throw new InvalidOperationException(
                $"Resource '{resourceId}' timeoutMs must be between 1000 and 1800000.");

        return new JLinkFlashTarget(new JLinkSettings(
            executable,
            device,
            targetInterface,
            speedKhz,
            serialNumber,
            timeoutMs,
            binAddress));
    }

    private static string DefaultExecutable() =>
        OperatingSystem.IsWindows() ? "JLink.exe" : "JLinkExe";

    private static string RequireString(BenchResourceConfig config, string key, string resourceId) =>
        GetString(config, key) is { Length: > 0 } value
            ? value
            : throw new InvalidOperationException(
                $"Resource '{resourceId}' requires jlink setting '{key}'.");

    private static string? GetString(BenchResourceConfig config, string key)
    {
        if (!config.Settings.TryGetValue(key, out var value)) return null;
        if (value.ValueKind != JsonValueKind.String)
            throw new InvalidOperationException($"J-Link setting '{key}' must be a string.");
        return value.GetString();
    }

    private static int? GetInt(BenchResourceConfig config, string key)
    {
        if (!config.Settings.TryGetValue(key, out var value)) return null;
        if (!value.TryGetInt32(out var result))
            throw new InvalidOperationException($"J-Link setting '{key}' must be an integer.");
        return result;
    }

    private static ulong? GetAddress(BenchResourceConfig config, string key)
    {
        if (!config.Settings.TryGetValue(key, out var value)) return null;

        if (value.ValueKind == JsonValueKind.Number && value.TryGetUInt64(out var numeric))
            return numeric;

        if (value.ValueKind == JsonValueKind.String)
        {
            var text = value.GetString();
            if (string.IsNullOrWhiteSpace(text)) return null;
            if (text.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
                text = text[2..];
            if (ulong.TryParse(text, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var hex))
                return hex;
        }

        throw new InvalidOperationException(
            $"J-Link setting '{key}' must be an integer or hexadecimal string such as '0x80000000'.");
    }
}

public sealed record JLinkSettings(
    string Executable,
    string Device,
    string Interface,
    int SpeedKhz,
    string? SerialNumber,
    int TimeoutMs,
    ulong? BinAddress);

/// <summary>
/// J-Link programming backend built on SEGGER's installed J-Link Commander
/// (JLink.exe on Windows, JLinkExe elsewhere). BenchPilot does not redistribute
/// SEGGER binaries. Process arguments use ArgumentList and generated command
/// files are treated as trusted Runtime artifacts, not shell commands.
/// </summary>
public sealed class JLinkFlashTarget : IFlashTarget, IResourceHealthCheck
{
    private readonly JLinkSettings _settings;

    public JLinkFlashTarget(JLinkSettings settings) =>
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));

    public Task<ResourceHealthResult> CheckHealth(CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var executable = ResolveCommanderExecutable(_settings.Executable);
        IReadOnlyDictionary<string, string> details = new Dictionary<string, string>
        {
            ["configuredExecutable"] = _settings.Executable,
            ["device"] = _settings.Device,
            ["interface"] = _settings.Interface,
            ["speedKhz"] = _settings.SpeedKhz.ToString(CultureInfo.InvariantCulture),
            ["serialNumber"] = _settings.SerialNumber ?? string.Empty,
            ["probeConnectivityChecked"] = "false",
        };

        if (executable is null)
        {
            return Task.FromResult(new ResourceHealthResult(
                false,
                "SEGGER J-Link Commander was not found.",
                details,
                $"Could not resolve '{_settings.Executable}'. Install the SEGGER J-Link Software and Documentation Pack or configure settings.executable."));
        }

        var enriched = new Dictionary<string, string>(details)
        {
            ["resolvedExecutable"] = executable,
        };
        return Task.FromResult(new ResourceHealthResult(
            true,
            "SEGGER J-Link Commander is available. Preflight does not connect to or reset the probe/target.",
            enriched));
    }

    public async Task<FlashResult> Flash(string firmwarePath, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(firmwarePath))
            return new FlashResult(false, 0, 0, "Firmware path is empty.");

        string fullPath;
        try
        {
            fullPath = Path.GetFullPath(firmwarePath);
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return new FlashResult(false, 0, 0, ex.Message);
        }

        if (!File.Exists(fullPath))
            return new FlashResult(false, 0, 0, $"Firmware file not found: {fullPath}");

        if (ContainsCommandFileMetacharacter(fullPath))
            return new FlashResult(false, 0, 0, "Firmware path contains characters unsupported by the J-Link command-file backend.");

        var extension = Path.GetExtension(fullPath);
        var isBinary = extension.Equals(".bin", StringComparison.OrdinalIgnoreCase);
        if (isBinary && _settings.BinAddress is null)
        {
            return new FlashResult(
                false,
                0,
                0,
                "Flashing a .bin file requires resources.<id>.settings.binAddress so BenchPilot never guesses a target address.");
        }

        var loadFile = new StringBuilder()
            .Append("loadfile \"")
            .Append(fullPath)
            .Append('"');
        if (isBinary)
            loadFile.Append(" 0x").Append(_settings.BinAddress!.Value.ToString("X", CultureInfo.InvariantCulture));

        var commands = new[]
        {
            "r",
            "h",
            loadFile.ToString(),
            "r",
            "g",
            "exit",
        };

        var sw = Stopwatch.StartNew();
        var run = await RunCommander(commands, ct);
        sw.Stop();

        if (!run.Ok)
            return new FlashResult(false, 0, (int)Math.Min(int.MaxValue, sw.ElapsedMilliseconds), run.Error);

        var length = new FileInfo(fullPath).Length;
        return new FlashResult(
            true,
            (int)Math.Min(int.MaxValue, length),
            (int)Math.Min(int.MaxValue, sw.ElapsedMilliseconds));
    }

    public async Task<ResetResult> Reset(CancellationToken ct = default)
    {
        var run = await RunCommander(new[] { "r", "g", "exit" }, ct);
        return run.Ok ? new ResetResult(true) : new ResetResult(false, run.Error);
    }

    private async Task<CommanderRunResult> RunCommander(
        IReadOnlyList<string> commands,
        CancellationToken ct)
    {
        var executable = ResolveCommanderExecutable(_settings.Executable);
        if (executable is null)
        {
            return new CommanderRunResult(
                false,
                $"Could not resolve '{_settings.Executable}'. Install the SEGGER J-Link Software and Documentation Pack or configure settings.executable.");
        }

        var commandFile = Path.Combine(
            Path.GetTempPath(),
            $"benchpilot-jlink-{Guid.NewGuid():N}.jlink");

        try
        {
            await File.WriteAllLinesAsync(commandFile, commands, Encoding.UTF8, ct);

            var start = new ProcessStartInfo
            {
                FileName = executable,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };

            Add(start, "-Device", _settings.Device);
            Add(start, "-If", _settings.Interface);
            Add(start, "-Speed", _settings.SpeedKhz.ToString(CultureInfo.InvariantCulture));
            Add(start, "-AutoConnect", "1");
            Add(start, "-ExitOnError", "1");
            Add(start, "-NoGui", "1");
            if (!string.IsNullOrWhiteSpace(_settings.SerialNumber))
                Add(start, "-USB", _settings.SerialNumber!);
            Add(start, "-CommandFile", commandFile);

            using var process = new Process { StartInfo = start };
            try
            {
                if (!process.Start())
                    return new CommanderRunResult(false, "Failed to start J-Link Commander.");
            }
            catch (Win32Exception ex)
            {
                return new CommanderRunResult(
                    false,
                    $"Could not start '{executable}'. {ex.Message}");
            }

            var stdoutTask = process.StandardOutput.ReadToEndAsync();
            var stderrTask = process.StandardError.ReadToEndAsync();

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(_settings.TimeoutMs);

            try
            {
                await process.WaitForExitAsync(timeout.Token);
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                TryKill(process);
                await Drain(stdoutTask, stderrTask);
                return new CommanderRunResult(
                    false,
                    $"J-Link Commander timed out after {_settings.TimeoutMs} ms.");
            }
            catch (OperationCanceledException)
            {
                TryKill(process);
                await Drain(stdoutTask, stderrTask);
                throw;
            }

            var stdout = await stdoutTask;
            var stderr = await stderrTask;
            if (process.ExitCode == 0)
                return new CommanderRunResult(true, null);

            return new CommanderRunResult(
                false,
                $"J-Link Commander exited with code {process.ExitCode}. {Tail(stdout, stderr)}");
        }
        catch (IOException ex)
        {
            return new CommanderRunResult(false, ex.Message);
        }
        finally
        {
            try { File.Delete(commandFile); } catch (IOException) { }
        }
    }

    private static string? ResolveCommanderExecutable(string configured)
    {
        if (string.IsNullOrWhiteSpace(configured)) return null;

        if (Path.IsPathRooted(configured)
            || configured.Contains(Path.DirectorySeparatorChar)
            || configured.Contains(Path.AltDirectorySeparatorChar))
        {
            try
            {
                var full = Path.GetFullPath(configured);
                return File.Exists(full) ? full : null;
            }
            catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
            {
                return null;
            }
        }

        var path = Environment.GetEnvironmentVariable("PATH");
        if (!string.IsNullOrWhiteSpace(path))
        {
            foreach (var directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            {
                try
                {
                    var candidate = Path.Combine(directory.Trim(), configured);
                    if (File.Exists(candidate)) return Path.GetFullPath(candidate);
                }
                catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
                {
                }
            }
        }

        foreach (var candidate in CommonInstallCandidates(configured))
        {
            try
            {
                if (File.Exists(candidate)) return Path.GetFullPath(candidate);
            }
            catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
            {
            }
        }

        return null;
    }

    private static IEnumerable<string> CommonInstallCandidates(string executable)
    {
        if (OperatingSystem.IsWindows())
        {
            foreach (var root in new[]
            {
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            }.Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase))
            {
                var segger = Path.Combine(root, "SEGGER");
                if (!Directory.Exists(segger)) continue;
                IEnumerable<string> directories;
                try { directories = Directory.EnumerateDirectories(segger, "JLink*"); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { continue; }
                foreach (var directory in directories.OrderDescending())
                    yield return Path.Combine(directory, executable);
            }
            yield break;
        }

        yield return Path.Combine("/usr/bin", executable);
        yield return Path.Combine("/usr/local/bin", executable);
        yield return Path.Combine("/opt/SEGGER/JLink", executable);

        const string optSegger = "/opt/SEGGER";
        if (Directory.Exists(optSegger))
        {
            IEnumerable<string> directories;
            try { directories = Directory.EnumerateDirectories(optSegger, "JLink*"); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { yield break; }
            foreach (var directory in directories.OrderDescending())
                yield return Path.Combine(directory, executable);
        }
    }

    private static void Add(ProcessStartInfo start, string name, string value)
    {
        start.ArgumentList.Add(name);
        start.ArgumentList.Add(value);
    }

    private static bool ContainsCommandFileMetacharacter(string path) =>
        path.IndexOfAny(new[] { '\r', '\n', '"' }) >= 0;

    private static async Task Drain(Task<string> stdout, Task<string> stderr)
    {
        try { await Task.WhenAll(stdout, stderr); } catch { }
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
                process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException) { }
    }

    private static string Tail(string stdout, string stderr)
    {
        var combined = string.Join(Environment.NewLine,
            new[] { stdout.Trim(), stderr.Trim() }.Where(x => x.Length > 0));
        if (combined.Length == 0) return "No output was produced.";
        const int max = 3000;
        return combined.Length <= max ? combined : combined[^max..];
    }

    private sealed record CommanderRunResult(bool Ok, string? Error);
}
