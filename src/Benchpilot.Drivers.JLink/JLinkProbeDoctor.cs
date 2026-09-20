using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using Benchpilot.Core;

namespace Benchpilot.Drivers.JLink;

internal static class JLinkProbeDoctor
{
    public static async Task<ResourceHealthResult> Check(
        JLinkSettings settings,
        string executable,
        IReadOnlyDictionary<string, string> baseDetails,
        CancellationToken ct)
    {
        var commandFile = Path.Combine(
            Path.GetTempPath(),
            $"benchpilot-jlink-probes-{Guid.NewGuid():N}.jlink");

        try
        {
            // ShowEmuList only enumerates host-visible probes. Deliberately do
            // not pass -AutoConnect/-Device/-If/-Speed/-USB here: preflight
            // must not connect to, reset or otherwise touch the target MCU.
            await File.WriteAllLinesAsync(
                commandFile,
                ["ShowEmuList USB", "exit"],
                Encoding.UTF8,
                ct);

            var start = new ProcessStartInfo
            {
                FileName = executable,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };
            Add(start, "-ExitOnError", "1");
            Add(start, "-NoGui", "1");
            Add(start, "-CommandFile", commandFile);

            using var process = new Process { StartInfo = start };
            try
            {
                if (!process.Start())
                    return Failure(baseDetails, "Failed to start J-Link Commander for probe enumeration.");
            }
            catch (Win32Exception ex)
            {
                return Failure(baseDetails, $"Could not start '{executable}'. {ex.Message}");
            }

            var stdoutTask = process.StandardOutput.ReadToEndAsync();
            var stderrTask = process.StandardError.ReadToEndAsync();

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(Math.Min(settings.TimeoutMs, 15_000));

            try
            {
                await process.WaitForExitAsync(timeout.Token);
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                TryKill(process);
                await Drain(stdoutTask, stderrTask);
                return Failure(baseDetails, "J-Link USB probe enumeration timed out after 15000 ms.");
            }
            catch (OperationCanceledException)
            {
                TryKill(process);
                await Drain(stdoutTask, stderrTask);
                throw;
            }

            var stdout = await stdoutTask;
            var stderr = await stderrTask;
            if (process.ExitCode != 0)
            {
                return Failure(
                    baseDetails,
                    $"J-Link Commander probe enumeration exited with code {process.ExitCode}. {Tail(stdout, stderr)}");
            }

            var probes = JLinkProbeDiscovery.Parse(string.Join(Environment.NewLine, stdout, stderr));
            return JLinkProbeDiscovery.Evaluate(probes, settings.SerialNumber, baseDetails);
        }
        catch (IOException ex)
        {
            return Failure(baseDetails, ex.Message);
        }
        finally
        {
            try { File.Delete(commandFile); } catch (IOException) { }
        }
    }

    private static ResourceHealthResult Failure(
        IReadOnlyDictionary<string, string> baseDetails,
        string error)
    {
        var details = new Dictionary<string, string>(baseDetails, StringComparer.OrdinalIgnoreCase)
        {
            ["probeEnumerationChecked"] = "true",
            ["targetConnectivityChecked"] = "false",
        };
        return new ResourceHealthResult(
            false,
            "J-Link USB probe enumeration failed.",
            details,
            error);
    }

    private static void Add(ProcessStartInfo start, string name, string value)
    {
        start.ArgumentList.Add(name);
        start.ArgumentList.Add(value);
    }

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
}
