using System.Globalization;
using System.Net;
using System.Text.Json;
using Benchpilot.Client;
using Benchpilot.Core;
using Benchpilot.Protocol;

return await BenchpilotCli.Run(args);

internal static class BenchpilotCli
{
    public static async Task<int> Run(string[] args)
    {
        var parsed = CliArguments.Parse(args);
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

        try
        {
            using var client = new BenchClient(BenchClient.ResolveEndpoint(parsed.Get("endpoint")));
            var target = parsed.Get("target");
            var command = parsed.Positionals[0].ToLowerInvariant();
            var subcommand = parsed.Positionals.Count > 1
                ? parsed.Positionals[1].ToLowerInvariant()
                : string.Empty;

            switch ((command, subcommand))
            {
                case ("status", _):
                {
                    var result = await client.Status(cts.Token);
                    Print(result, parsed.Json);
                    return result.Ok ? 0 : 1;
                }

                case ("power", "on"):
                {
                    var voltage = parsed.GetDouble("voltage", 12);
                    var settleMs = parsed.GetInt("settle-ms", 2000);
                    var result = await client.PowerOn(voltage, settleMs, target, cts.Token);
                    Print(result, parsed.Json);
                    return result.Ok ? 0 : 4;
                }

                case ("power", "off"):
                {
                    var result = await client.PowerOff(target, cts.Token);
                    Print(result, parsed.Json);
                    return result.Ok ? 0 : 4;
                }

                case ("power", "current"):
                {
                    var windowMs = parsed.GetInt("window-ms", 500);
                    var result = await client.ReadCurrent(windowMs, target, cts.Token);
                    Print(result, parsed.Json);
                    return result.Ok ? 0 : 4;
                }

                case ("power", "check"):
                {
                    var lt = parsed.GetNullableDouble("lt-ma");
                    var gt = parsed.GetNullableDouble("gt-ma");
                    var result = await client.CheckCurrent(lt, gt, target, cts.Token);
                    Print(result, parsed.Json);
                    if (!result.Ok) return 4;
                    return result.Passed ? 0 : 1;
                }

                case ("flash", "write"):
                {
                    var firmware = RequirePositional(parsed, 2, "firmware path");
                    var result = await client.Flash(firmware, target, cts.Token);
                    Print(result, parsed.Json);
                    return result.Ok ? 0 : 4;
                }

                case ("flash", "reset"):
                {
                    var result = await client.Reset(target, cts.Token);
                    Print(result, parsed.Json);
                    return result.Ok ? 0 : 4;
                }

                case ("serial", "open"):
                {
                    var port = parsed.Get("port") ?? "SIM0";
                    var baud = parsed.GetInt("baud", 115200);
                    var result = await client.SerialOpen(port, baud, target, cts.Token);
                    Print(result, parsed.Json);
                    return result.Ok ? 0 : 4;
                }

                case ("serial", "wait"):
                {
                    var pattern = RequirePositional(parsed, 2, "pattern");
                    var timeoutMs = parsed.GetInt("timeout-ms", 10000);
                    var result = await client.SerialWaitFor(pattern, timeoutMs, target, cts.Token);
                    Print(result, parsed.Json);
                    if (!result.Ok) return 4;
                    return result.Matched ? 0 : 1;
                }

                case ("serial", "window"):
                {
                    var lines = parsed.GetInt("lines", 50);
                    var filter = parsed.Get("filter");
                    var result = await client.SerialReadWindow(lines, filter, target, cts.Token);
                    Print(result, parsed.Json);
                    return result.Ok ? 0 : 4;
                }

                case ("serial", "send"):
                {
                    var data = RequirePositional(parsed, 2, "data");
                    var result = await client.SerialSend(data, target, cts.Token);
                    Print(result, parsed.Json);
                    return result.Ok ? 0 : 4;
                }

                default:
                    throw new ArgumentException(
                        $"Unknown command: {string.Join(' ', parsed.Positionals)}");
            }
        }
        catch (BenchClientException ex)
        {
            Print(new ApiError(false, ex.Code, ex.Message), parsed.Json);
            return ex.StatusCode switch
            {
                HttpStatusCode.BadRequest => 2,
                HttpStatusCode.NotFound => 3,
                _ => 1,
            };
        }
        catch (HttpRequestException ex)
        {
            Print(new ApiError(false, "runtime_unavailable", ex.Message), parsed.Json);
            return 4;
        }
        catch (OperationCanceledException)
        {
            Print(new ApiError(false, "cancelled", "Operation cancelled."), parsed.Json);
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
        Console.WriteLine("""
BenchPilot CLI - client for the resident ECU bench runtime

Usage:
  benchpilot status [--json] [--endpoint URL]

  benchpilot power on      [--target ID] [--voltage V] [--settle-ms N] [--json]
  benchpilot power off     [--target ID] [--json]
  benchpilot power current [--target ID] [--window-ms N] [--json]
  benchpilot power check   [--target ID] [--lt-ma N] [--gt-ma N] [--json]

  benchpilot flash write <firmware> [--target ID] [--json]
  benchpilot flash reset            [--target ID] [--json]

  benchpilot serial open            [--target ID] [--port NAME] [--baud N] [--json]
  benchpilot serial wait <pattern>  [--target ID] [--timeout-ms N] [--json]
  benchpilot serial window          [--target ID] [--lines N] [--filter TEXT] [--json]
  benchpilot serial send <data>     [--target ID] [--json]

Environment:
  BENCHPILOT_ENDPOINT   Runtime endpoint (default http://127.0.0.1:5640/)

Exit codes:
  0 success
  1 operation/assertion failure
  2 validation error
  3 target/resource not found
  4 runtime/device unavailable or device error
""");
    }
}

internal sealed class CliArguments
{
    private static readonly HashSet<string> Flags =
        new(StringComparer.OrdinalIgnoreCase) { "json", "help" };

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
