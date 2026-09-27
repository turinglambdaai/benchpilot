using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json;
using Benchpilot.Core;
using Benchpilot.Diagnostics.Can;
using Benchpilot.Diagnostics.Channels;
using Benchpilot.Diagnostics.Doip;
using Benchpilot.Diagnostics.Isotp;

namespace Benchpilot.Runtime;

/// <summary>
/// Creates UDS diagnostic channels from profile resources. All three
/// transports (simulated CAN, real CAN, DoIP) expose the same
/// IDiagChannel capability to the Runtime, so targets and agents never
/// switch tooling when the bench switches transport.
/// </summary>
public static class DiagSettings
{
    public static string? GetString(BenchResourceConfig config, string name) =>
        TryGet(config, name) is { } value && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    public static int? GetInt(BenchResourceConfig config, string name) =>
        TryGet(config, name) is { } value
            ? value.ValueKind == JsonValueKind.Number
                ? value.GetInt32()
                : value.ValueKind == JsonValueKind.String &&
                  value.GetString() is { } text &&
                  text.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
                    ? int.Parse(text[2..], NumberStyles.HexNumber, CultureInfo.InvariantCulture)
                    : int.TryParse(value.ToString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed)
                        ? parsed
                        : null
            : null;

    public static long? GetLong(BenchResourceConfig config, string name) =>
        TryGet(config, name) is { } value
            ? value.ValueKind == JsonValueKind.Number
                ? value.GetInt64()
                : value.ValueKind == JsonValueKind.String &&
                  value.GetString() is { } text &&
                  text.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
                    ? long.Parse(text[2..], NumberStyles.HexNumber, CultureInfo.InvariantCulture)
                    : null
            : null;

    public static bool? GetBool(BenchResourceConfig config, string name)
    {
        if (TryGet(config, name) is not { } value)
            return null;
        return value.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? value.GetBoolean()
            : null;
    }

    private static JsonElement? TryGet(BenchResourceConfig config, string name) =>
        config.Settings.TryGetValue(name, out var value) ? value : null;
}

public sealed class SimDiagnosticsResourceFactory : IBenchResourceFactory
{
    public string DriverName => SimUdsChannel.DriverName;

    public object Create(string resourceId, BenchResourceConfig config)
    {
        var requestId = DiagSettings.GetLong(config, "requestId") ?? 0x7E0;
        var responseId = DiagSettings.GetLong(config, "responseId") ?? 0x7E8;
        return new SimUdsChannel(
            (uint)requestId,
            (uint)responseId,
            (byte?)DiagSettings.GetInt(config, "securityLevel") ?? 0x01,
            DiagSettings.GetString(config, "keyDeriver") ?? "xor0x5a",
            DiagSettings.GetInt(config, "maxBlockPayload") ?? 1024);
    }
}

public sealed class CanUdsResourceFactory : IBenchResourceFactory
{
    public string DriverName => "can-iso-tp";

    public object Create(string resourceId, BenchResourceConfig config)
    {
        var txId = (uint)(DiagSettings.GetLong(config, "requestId")
            ?? throw new InvalidOperationException(
                $"Resource '{resourceId}' (can-iso-tp) requires 'requestId' (for example 0x7E0)."));
        var rxId = (uint)(DiagSettings.GetLong(config, "responseId")
            ?? throw new InvalidOperationException(
                $"Resource '{resourceId}' (can-iso-tp) requires 'responseId' (for example 0x7E8)."));

        var securityLevel = DiagSettings.GetInt(config, "securityLevel");
        var extended = DiagSettings.GetBool(config, "extended") ?? txId > 0x7FF;
        var options = new IsotpOptions
        {
            StMinMs = DiagSettings.GetInt(config, "stMinMs") ?? 0,
        };

        ICanBus bus;
        if (OperatingSystem.IsLinux() && DiagSettings.GetString(config, "interface") is { } iface)
        {
            bus = new SocketCanBus(iface);
        }
        else if (OperatingSystem.IsWindows() && DiagSettings.GetInt(config, "pcanChannel") is { } channel)
        {
            bus = new PcanBus(
                (ushort)channel,
                DiagSettings.GetInt(config, "bitrate") ?? 500000,
                extended);
        }
        else
        {
            throw new InvalidOperationException(
                $"Resource '{resourceId}' (can-iso-tp) needs 'interface' (Linux/SocketCAN) or " +
                "'pcanChannel' (Windows/PCAN-Basic) in its settings.");
        }

        return new CanUdsChannel(
            bus,
            txId,
            rxId,
            (byte?)securityLevel,
            DiagSettings.GetString(config, "keyDeriver") ?? "xor0x5a",
            DiagSettings.GetInt(config, "maxBlockPayload") ?? 1024,
            options);
    }
}

public sealed class DoipUdsResourceFactory : IBenchResourceFactory
{
    public string DriverName => "doip";

    public object Create(string resourceId, BenchResourceConfig config)
    {
        var host = DiagSettings.GetString(config, "host")
            ?? throw new InvalidOperationException(
                $"Resource '{resourceId}' (doip) requires 'host' (the DoIP entity's IP, reachable " +
                "directly over RJ45 through a 100BASE-T1 media converter, or a gateway).");
        var ecuAddress = DiagSettings.GetInt(config, "ecuAddress")
            ?? throw new InvalidOperationException(
                $"Resource '{resourceId}' (doip) requires 'ecuAddress' (target logical address).");
        var testerAddress = DiagSettings.GetInt(config, "testerAddress") ?? 0x0E00;

        return new DoipUdsChannel(
            host,
            DiagSettings.GetInt(config, "port") ?? DoipClient.DoipPort,
            (ushort)testerAddress,
            (ushort)ecuAddress,
            (byte?)DiagSettings.GetInt(config, "securityLevel"),
            DiagSettings.GetString(config, "keyDeriver") ?? "xor0x5a",
            DiagSettings.GetInt(config, "maxBlockPayload") ?? 4096);
    }
}
