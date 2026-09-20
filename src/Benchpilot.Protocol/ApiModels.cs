namespace Benchpilot.Protocol;

public static class BenchpilotApi
{
    public const int Version = 1;
    public const string Prefix = "/api/v1";
}

public record ApiError(bool Ok, string Code, string Error);

public record TargetSummary(
    string Id,
    string Name,
    string? Mcu,
    IReadOnlyList<string> Capabilities);

public record ResourceSummary(
    string Id,
    string Driver,
    IReadOnlyList<string> Capabilities,
    bool Registered);

public record RuntimeStatusResult(
    bool Ok,
    string Name,
    int SchemaVersion,
    string? DefaultTarget,
    IReadOnlyList<TargetSummary> Targets,
    IReadOnlyList<ResourceSummary> Resources,
    string? Error = null);

public record PowerOnRequest(double Voltage = 12, int SettleMs = 2000);
public record CurrentReadRequest(int WindowMs = 500);
public record CurrentCheckRequest(double? LtMa = null, double? GtMa = null);
public record FlashRequest(string Firmware);
public record SerialOpenRequest(string Port = "SIM0", int Baud = 115200);
public record SerialWaitRequest(string Pattern, int TimeoutMs = 10000);
public record SerialWindowRequest(int Lines = 50, string? Filter = null);
public record SerialSendRequest(string Data);
