using System.Globalization;
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Benchpilot.Client;
using Benchpilot.Protocol;

return await BenchpilotCli.Run(args);

internal static class BenchpilotCli
{
    public static async Task<int> Run(string[] args)
    {
        CliArguments parsed;
        try
        {
            parsed = CliArguments.Parse(args);
        }
        catch (ArgumentException ex)
        {
            Print(new ApiError(false, "validation", ex.Message),
                args.Any(x => string.Equals(x, "--json", StringComparison.OrdinalIgnoreCase)));
            return 2;
        }

        if (parsed.HasFlag("version") ||
            (parsed.Positionals.Count == 1 &&
             string.Equals(parsed.Positionals[0], "version", StringComparison.OrdinalIgnoreCase)))
        {
            Console.Out.WriteLine(BenchpilotRuntimeInfo.Version);
            return 0;
        }

        if (parsed.HasFlag("help") || parsed.Positionals.Count == 0)
        {
            PrintUsage();
            return 0;
        }

        using var cts = new CancellationTokenSource();
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            cts.Cancel();
        };

        var endpoint = BenchClient.ResolveEndpoint(parsed.Get("endpoint"));

        // One retry budget: if the resident daemon is not running, start it
        // and re-issue the command. This is what makes `benchpilot <cmd>` a
        // single-command experience for agents and CI instead of requiring a
        // separate terminal for benchpilotd.
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                return await RunClientSessionAsync(parsed, endpoint, cts.Token);
            }
            catch (BenchClientException ex)
            {
                Print(new ApiError(
                    false,
                    ex.Code,
                    ex.Message,
                    ex.OperationId,
                    ex.BusyScope,
                    ex.BusyId,
                    ex.DeadlineMs,
                    ex.DeadlineAtUtc), parsed.Json);
                return ex.Code switch
                {
                    "busy" => 5,
                    "deadline_exceeded" => 6,
                    "cancelled" => 1,
                    "runtime_state" => 4,
                    "unauthorized" => 4,
                    _ => ex.StatusCode switch
                    {
                        HttpStatusCode.BadRequest => 2,
                        HttpStatusCode.NotFound => 3,
                        _ => 1,
                    },
                };
            }
            catch (HttpRequestException ex) when (attempt == 0)
            {
                var started = await RuntimeAutoStart.EnsureRunningAsync(endpoint, cts.Token);
                if (!started)
                {
                    Print(UnavailableError(ex, endpoint, parsed), parsed.Json);
                    return 4;
                }
            }
            catch (HttpRequestException ex)
            {
                Print(UnavailableError(ex, endpoint, parsed), parsed.Json);
                return 4;
            }
            catch (OperationCanceledException)
            {
                Print(new ApiError(false, "cancelled", "Request cancelled."), parsed.Json);
                return 1;
            }
            catch (ArgumentException ex)
            {
                Print(new ApiError(false, "validation", ex.Message), parsed.Json);
                return 2;
            }
            catch (FormatException ex)
            {
                Print(new ApiError(false, "validation", ex.Message), parsed.Json);
                return 2;
            }
        }
    }

    private static async Task<int> RunClientSessionAsync(
        CliArguments parsed,
        Uri endpoint,
        CancellationToken ct)
    {
        using var client = new BenchClient(endpoint);
        var target = parsed.Get("target");
        var deadlineMs = parsed.GetNullableInt("deadline-ms");
        var command = parsed.Positionals[0].ToLowerInvariant();
        var subcommand = parsed.Positionals.Count > 1
            ? parsed.Positionals[1].ToLowerInvariant()
            : string.Empty;

        switch ((command, subcommand))
        {
            case ("status", _):
            {
                var result = await client.Status(ct);
                Print(result, parsed.Json);
                return result.Ok ? 0 : 1;
            }

            case ("doctor", _):
            {
                var result = await DoctorAsync(client, endpoint, ct);
                Print(result, parsed.Json);
                return result.Ok ? 0 : 4;
            }

            case ("operations", _):
            {
                var result = await client.Operations(ct);
                Print(result, parsed.Json);
                return result.Ok ? 0 : 1;
            }

            case ("history", _):
            {
                var limit = parsed.GetInt("limit", 50);
                var result = await client.OperationHistory(limit, ct);
                Print(result, parsed.Json);
                return result.Ok ? 0 : 1;
            }

            case ("evidence", _):
            {
                var operationId = RequirePositional(parsed, 1, "operation id");
                var result = await client.OperationEvidence(operationId, ct);
                Print(result, parsed.Json);
                return result.Ok ? 0 : 1;
            }

            case ("cancel", _):
            {
                var operationId = RequirePositional(parsed, 1, "operation id");
                var result = await client.CancelOperation(operationId, ct);
                Print(result, parsed.Json);
                return result.Ok && result.CancelRequested ? 0 : 1;
            }

            case ("observe", "list"):
            {
                var result = await client.Observations(ct);
                Print(result, parsed.Json);
                return result.Ok ? 0 : 1;
            }

            case ("observe", "history"):
            {
                var limit = parsed.GetInt("limit", 50);
                var result = await client.ObservationHistory(limit, ct);
                Print(result, parsed.Json);
                return result.Ok ? 0 : 1;
            }

            case ("observe", "evidence"):
            {
                var observationId = RequirePositional(parsed, 2, "observation id");
                var result = await client.ObservationEvidence(observationId, ct);
                Print(result, parsed.Json);
                return result.Ok ? 0 : 1;
            }

            case ("observe", "cancel"):
            {
                var observationId = RequirePositional(parsed, 2, "observation id");
                var result = await client.CancelObservation(observationId, ct);
                Print(result, parsed.Json);
                return result.Ok && result.CancelRequested ? 0 : 1;
            }

            case ("preflight", _):
            {
                var result = await client.Preflight(target, ct);
                Print(result, parsed.Json);
                return result.Ok ? 0 : 4;
            }

            case ("bench", "validate"):
            {
                var result = await client.ValidateTargetReadiness(target, ct);
                Print(result, parsed.Json);
                if (!result.Ok) return 4;
                return result.ReadyForRealEcuLoop ? 0 : 1;
            }

            case ("power", "on"):
            {
                var voltage = parsed.GetDouble("voltage", 12);
                var settleMs = parsed.GetInt("settle-ms", 2000);
                var result = await client.PowerOn(voltage, settleMs, target, deadlineMs, ct);
                Print(result, parsed.Json);
                return result.Ok ? 0 : 4;
            }

            case ("power", "off"):
            {
                var result = await client.PowerOff(target, deadlineMs, ct);
                Print(result, parsed.Json);
                return result.Ok ? 0 : 4;
            }

            case ("power", "emergency-off"):
            {
                var result = await client.EmergencyPowerOff(target, ct);
                Print(result, parsed.Json);
                return result.Ok ? 0 : 4;
            }

            case ("power", "current"):
            {
                var windowMs = parsed.GetInt("window-ms", 500);
                var result = await client.ReadCurrent(windowMs, target, ct);
                Print(result, parsed.Json);
                return result.Ok ? 0 : 4;
            }

            case ("power", "check"):
            {
                var lt = parsed.GetNullableDouble("lt-ma");
                var gt = parsed.GetNullableDouble("gt-ma");
                var result = await client.CheckCurrent(lt, gt, target, ct);
                Print(result, parsed.Json);
                if (!result.Ok) return 4;
                return result.Passed ? 0 : 1;
            }

            case ("flash", "write"):
            {
                var firmware = RequirePositional(parsed, 2, "firmware path");
                var confirmTarget = parsed.Get("confirm-target");
                var result = await client.Flash(
                    firmware,
                    target,
                    confirmTarget,
                    deadlineMs,
                    ct);
                Print(result, parsed.Json);
                return result.Ok ? 0 : 4;
            }

            case ("flash", "reset"):
            {
                var confirmTarget = parsed.Get("confirm-target");
                var result = await client.Reset(target, confirmTarget, deadlineMs, ct);
                Print(result, parsed.Json);
                return result.Ok ? 0 : 4;
            }

            case ("serial", "open"):
            {
                var port = parsed.Get("port");
                var baud = parsed.GetNullableInt("baud");
                var result = await client.SerialOpen(port, baud, target, deadlineMs, ct);
                Print(result, parsed.Json);
                return result.Ok ? 0 : 4;
            }

            case ("serial", "wait"):
            {
                var pattern = RequirePositional(parsed, 2, "pattern");
                var timeoutMs = parsed.GetInt("timeout-ms", 10000);
                var result = await client.SerialWaitFor(
                    pattern,
                    timeoutMs,
                    target,
                    deadlineMs,
                    ct);
                Print(result, parsed.Json);
                if (!result.Ok) return 4;
                return result.Matched ? 0 : 1;
            }

            case ("serial", "window"):
            {
                var lines = parsed.GetInt("lines", 50);
                var filter = parsed.Get("filter");
                var result = await client.SerialReadWindow(
                    lines,
                    filter,
                    target,
                    deadlineMs,
                    ct);
                Print(result, parsed.Json);
                return result.Ok ? 0 : 4;
            }

            case ("serial", "send"):
            {
                var data = RequirePositional(parsed, 2, "data");
                var result = await client.SerialSend(data, target, deadlineMs, ct);
                Print(result, parsed.Json);
                return result.Ok ? 0 : 4;
            }

            default:
                throw new ArgumentException(
                    $"Unknown command: {string.Join(" ", parsed.Positionals)}");
        }
    }

    private static async Task<DoctorReport> DoctorAsync(
        BenchClient client,
        Uri endpoint,
        CancellationToken ct)
    {
        var daemonPath = RuntimeAutoStart.ResolveDaemonPath();
        var token = LocalAuth.ReadToken();
        string? runtimeVersion = null;
        string? statusError = null;
        string? profileName = null;
        int targetCount = 0;
        var reachable = false;

        try
        {
            var health = await client.Status(ct);
            reachable = health.Ok;
            runtimeVersion = health.RuntimeVersion;
            profileName = health.Name;
            targetCount = health.Targets.Count;
        }
        catch (BenchClientException ex)
        {
            statusError = $"{ex.Code}: {ex.Message}";
            reachable = ex.StatusCode == HttpStatusCode.Unauthorized;
        }
        catch (HttpRequestException ex)
        {
            statusError = ex.Message;
        }

        var versionMatch = runtimeVersion is null || runtimeVersion == BenchpilotRuntimeInfo.Version;

        return new DoctorReport(
            reachable,
            endpoint.ToString(),
            BenchpilotRuntimeInfo.Version,
            reachable,
            runtimeVersion,
            BenchpilotApi.Version,
            statusError,
            token is not null,
            LocalAuth.TokenFilePath,
            daemonPath is not null,
            daemonPath,
            profileName,
            targetCount,
            versionMatch,
            reachable ? null :
                (RuntimeAutoStart.IsDisabled()
                    ? "The daemon is not reachable and BENCHPILOT_AUTOSTART=0 disables automatic start. Run benchpilotd manually."
                    : (daemonPath is null
                        ? "The daemon is not reachable and no benchpilotd executable was found next to the CLI or on PATH."
                        : "The daemon will start automatically on the next benchpilot command.")));
    }

    private static ApiError UnavailableError(HttpRequestException ex, Uri endpoint, CliArguments parsed)
    {
        var hint = RuntimeAutoStart.IsDisabled()
            ? "Start the resident runtime with: benchpilotd"
            : RuntimeAutoStart.ResolveDaemonPath() is null
                ? "No benchpilotd executable was found next to the CLI or on PATH. Install BenchPilot or start the runtime manually."
                : "Automatic daemon start failed. Start the resident runtime with: benchpilotd";
        return new ApiError(
            false,
            "runtime_unavailable",
            $"BenchPilot runtime at {endpoint} is not reachable: {ex.Message}. {hint}");
    }

    private static string RequirePositional(CliArguments parsed, int index, string label)
    {
        if (parsed.Positionals.Count <= index || string.IsNullOrWhiteSpace(parsed.Positionals[index]))
            throw new ArgumentException($"Missing required {label}.");
        return parsed.Positionals[index];
    }

    private static void Print(object value, bool compact)
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web)
        {
            WriteIndented = !compact,
        };
        Console.Out.WriteLine(JsonSerializer.Serialize(value, options));
    }

    private static void PrintUsage()
    {
        Console.WriteLine($"""
BenchPilot CLI - client for the resident ECU bench runtime ({BenchpilotRuntimeInfo.Version})

Usage:
  benchpilot status                  [--json] [--endpoint URL]
  benchpilot doctor                  [--json] [--endpoint URL]
  benchpilot operations              [--json] [--endpoint URL]
  benchpilot history                 [--limit N] [--json] [--endpoint URL]
  benchpilot evidence <operation-id> [--json] [--endpoint URL]
  benchpilot cancel <operation-id>   [--json] [--endpoint URL]

  benchpilot observe list                      [--json] [--endpoint URL]
  benchpilot observe history                   [--limit N] [--json] [--endpoint URL]
  benchpilot observe evidence <observation-id> [--json] [--endpoint URL]
  benchpilot observe cancel <observation-id>   [--json] [--endpoint URL]

  benchpilot preflight              [--target ID] [--json]
  benchpilot bench validate         [--target ID] [--json]

  benchpilot power on            [--target ID] [--voltage V] [--settle-ms N] [--deadline-ms N] [--json]
  benchpilot power off           [--target ID] [--deadline-ms N] [--json]
  benchpilot power emergency-off [--target ID] [--json]
  benchpilot power current       [--target ID] [--window-ms N] [--json]
  benchpilot power check         [--target ID] [--lt-ma N] [--gt-ma N] [--json]

  benchpilot flash write <firmware> [--target ID] [--confirm-target ID] [--deadline-ms N] [--json]
  benchpilot flash reset            [--target ID] [--confirm-target ID] [--deadline-ms N] [--json]

  benchpilot serial open            [--target ID] [--port NAME] [--baud N] [--deadline-ms N] [--json]
  benchpilot serial wait <pattern>  [--target ID] [--timeout-ms N] [--deadline-ms N] [--json]
  benchpilot serial window          [--target ID] [--lines N] [--filter TEXT] [--deadline-ms N] [--json]
  benchpilot serial send <data>     [--target ID] [--deadline-ms N] [--json]

  benchpilot version | --version

Resident runtime:
  The first benchpilot command starts benchpilotd automatically (autostart)
  and every later command reuses that resident process and its hardware
  state. State is deliberately NOT reset between commands. Set
  BENCHPILOT_AUTOSTART=0 to require a manually started daemon. Daemon logs
  from autostart live in {LocalAuth.LogDirectoryPath}.

`doctor` is a non-mutating installation check: runtime reachability, versions,
token presence and daemon discovery. It never starts the daemon.

Authentication:
  benchpilotd binds to loopback only and additionally requires a per-user
  token stored at {LocalAuth.TokenFilePath}.
  Clients attach it automatically; BENCHPILOT_TOKEN overrides the file.

Mutating operations and observations are intentionally separate. `operations`
uses target/resource gates for state-changing work. `observe ...` reports
non-mutating serial observations that may run concurrently with flash/power.

`history` returns the Runtime's bounded mutation audit. `evidence` returns one
compact mutation evidence bundle. `observe history/evidence` provide the same
bounded correlation for serial observations without converting them into locks.
A failed/unmatched serial wait captures only a small tail of the Runtime-owned
serial line buffer, never the unbounded raw stream.

`--deadline-ms` is a Runtime execution budget for supported mutation/observation
operations. It is different from `serial wait --timeout-ms`: the latter is a
semantic wait window and a normal unmatched assertion returns exit code 1;
exceeding the Runtime deadline is an execution failure with code
`deadline_exceeded` and exit code 6. Emergency power-off deliberately ignores
Runtime deadlines so an accepted safety action cannot be abandoned by a shell.

`preflight` is non-destructive. It checks configured resource readiness without
power-cycling, resetting or flashing the target.

`bench validate` is also non-destructive. It combines required capability,
hardware-vs-simulator, safety-policy, placeholder and resource-preflight checks
into one machine-readable real-ECU readiness report with remediation guidance.
Exit code 0 means ready; exit code 1 means the validation ran successfully but
one or more readiness assertions failed.

Normal `power off` participates in the target mutation gate and will return busy
rather than interrupting an active flash/reset. `power emergency-off` is the
explicit safety escape hatch and is allowed to bypass that gate.

`serial open` normally uses port/baud from the target resource profile. --port and
--baud are optional expert/debug overrides. Serial results include observationId
for later `observe evidence` lookup.

When safety.requireDestructiveConfirmation is enabled, flash/reset require
--confirm-target to exactly match the resolved semantic target id.

Environment:
  BENCHPILOT_ENDPOINT    Runtime endpoint (default http://127.0.0.1:5640/)
  BENCHPILOT_TOKEN       Local API token (default: token file)
  BENCHPILOT_AUTOSTART   Set to 0 to disable automatic daemon start

Exit codes:
  0 success / readiness passed
  1 operation/assertion/readiness failure or cancellation
  2 validation error
  3 target/resource/operation/observation/evidence not found
  4 runtime/device unavailable, unauthorized, or device/preflight error
  5 target/resource busy (another mutating operation is active)
  6 Runtime deadline exceeded
""");
    }
}

internal sealed record DoctorReport(
    bool Ok,
    string Endpoint,
    string CliVersion,
    bool RuntimeReachable,
    string? RuntimeVersion,
    int ApiVersion,
    string? StatusError,
    bool TokenFound,
    string TokenPath,
    bool DaemonFound,
    string? DaemonPath,
    string? ProfileName,
    int TargetCount,
    bool VersionMatch,
    string? Remediation);

internal sealed class CliArguments
{
    private static readonly HashSet<string> Flags =
        new(StringComparer.OrdinalIgnoreCase) { "json", "help", "version" };

    private readonly Dictionary<string, string?> _options =
        new(StringComparer.OrdinalIgnoreCase);

    public List<string> Positionals { get; } = [];
    public bool Json => HasFlag("json");

    public static CliArguments Parse(string[] args)
    {
        var result = new CliArguments();

        for (var i = 0; i < args.Length; i++)
        {
            var token = args[i];
            if (!token.StartsWith("--", StringComparison.Ordinal))
            {
                result.Positionals.Add(token);
                continue;
            }

            var option = token[2..];
            var equals = option.IndexOf('=');
            if (equals >= 0)
            {
                result._options[option[..equals]] = option[(equals + 1)..];
                continue;
            }

            if (Flags.Contains(option))
            {
                result._options[option] = null;
                continue;
            }

            if (i + 1 >= args.Length || args[i + 1].StartsWith("--", StringComparison.Ordinal))
                throw new ArgumentException($"Option --{option} requires a value.");

            result._options[option] = args[++i];
        }

        return result;
    }

    public bool HasFlag(string name) => _options.ContainsKey(name);

    public string? Get(string name) =>
        _options.TryGetValue(name, out var value) ? value : null;

    public int GetInt(string name, int defaultValue)
    {
        var value = Get(name);
        if (value is null) return defaultValue;
        return int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed)
            ? parsed
            : throw new FormatException($"Option --{name} must be an integer.");
    }

    public int? GetNullableInt(string name)
    {
        var value = Get(name);
        if (value is null) return null;
        return int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed)
            ? parsed
            : throw new FormatException($"Option --{name} must be an integer.");
    }

    public double GetDouble(string name, double defaultValue)
    {
        var value = Get(name);
        if (value is null) return defaultValue;
        return double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed)
            ? parsed
            : throw new FormatException($"Option --{name} must be a number.");
    }

    public double? GetNullableDouble(string name)
    {
        var value = Get(name);
        if (value is null) return null;
        return double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed)
            ? parsed
            : throw new FormatException($"Option --{name} must be a number.");
    }
}
