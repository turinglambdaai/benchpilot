namespace Benchpilot.Protocol;

public static class BenchpilotApi
{
    public const int Version = 1;
    public const string Prefix = "/api/v1";
}

public record ApiError(
    bool Ok,
    string Code,
    string Error,
    string? OperationId = null,
    string? BusyScope = null,
    string? BusyId = null,
    int? DeadlineMs = null,
    DateTimeOffset? DeadlineAtUtc = null);

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
    string? Error = null,
    string? RuntimeVersion = null);

public record OperationSummary(
    string Id,
    string TargetId,
    string Kind,
    IReadOnlyList<string> ResourceIds,
    DateTimeOffset StartedAtUtc,
    DateTimeOffset? DeadlineAtUtc,
    bool CancellationRequested,
    bool DeadlineExceeded);

public record OperationListResult(
    bool Ok,
    IReadOnlyList<OperationSummary> Operations,
    string? Error = null);

public record OperationCancelResult(
    bool Ok,
    string OperationId,
    bool CancelRequested,
    string? Error = null);

public record OperationHistorySummary(
    string Id,
    string TargetId,
    string Kind,
    IReadOnlyList<string> ResourceIds,
    DateTimeOffset StartedAtUtc,
    DateTimeOffset CompletedAtUtc,
    int DurationMs,
    DateTimeOffset? DeadlineAtUtc,
    string State,
    string? Error = null);

public record OperationHistoryResult(
    bool Ok,
    IReadOnlyList<OperationHistorySummary> Operations,
    string? Error = null);

public record ObservationSummary(
    string Id,
    string TargetId,
    string Kind,
    IReadOnlyList<string> ResourceIds,
    DateTimeOffset StartedAtUtc,
    DateTimeOffset? DeadlineAtUtc,
    bool CancellationRequested,
    bool DeadlineExceeded);

public record ObservationListResult(
    bool Ok,
    IReadOnlyList<ObservationSummary> Observations,
    string? Error = null);

public record ObservationCancelResult(
    bool Ok,
    string ObservationId,
    bool CancelRequested,
    string? Error = null);

public record ObservationHistorySummary(
    string Id,
    string TargetId,
    string Kind,
    IReadOnlyList<string> ResourceIds,
    DateTimeOffset StartedAtUtc,
    DateTimeOffset CompletedAtUtc,
    int DurationMs,
    DateTimeOffset? DeadlineAtUtc,
    string State,
    string? Error = null);

public record ObservationHistoryResult(
    bool Ok,
    IReadOnlyList<ObservationHistorySummary> Observations,
    string? Error = null);

public record EvidenceItemSummary(
    string Kind,
    string Summary,
    string? Text = null,
    IReadOnlyDictionary<string, string>? Metadata = null);

public record OperationEvidenceResult(
    bool Ok,
    string OperationId,
    string TargetId,
    string OperationKind,
    IReadOnlyList<string> ResourceIds,
    DateTimeOffset CreatedAtUtc,
    IReadOnlyList<EvidenceItemSummary> Items,
    string? Error = null);

public record ObservationEvidenceResult(
    bool Ok,
    string ObservationId,
    string TargetId,
    string ObservationKind,
    IReadOnlyList<string> ResourceIds,
    DateTimeOffset CreatedAtUtc,
    IReadOnlyList<EvidenceItemSummary> Items,
    string? Error = null);

public record PowerOnRequest(double Voltage = 12, int SettleMs = 2000);
public record CurrentReadRequest(int WindowMs = 500);
public record CurrentCheckRequest(double? LtMa = null, double? GtMa = null);
public record FlashRequest(string Firmware, string? ConfirmTarget = null);
public record ResetRequest(string? ConfirmTarget = null);
// Null values mean "use the resource profile defaults". Device-centric values
// are expert overrides, not required Agent inputs.
public record SerialOpenRequest(string? Port = null, int? Baud = null);
public record SerialWaitRequest(string Pattern, int TimeoutMs = 10000);
public record SerialWindowRequest(int Lines = 50, string? Filter = null);
public record SerialSendRequest(string Data);