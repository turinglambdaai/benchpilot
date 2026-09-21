namespace Benchpilot.Runtime;

public sealed record BenchObservationInfo(
    string Id,
    string TargetId,
    string Kind,
    IReadOnlyList<string> ResourceIds,
    DateTimeOffset StartedAtUtc,
    DateTimeOffset? DeadlineAtUtc,
    bool CancellationRequested,
    bool DeadlineExceeded);

public sealed record BenchObservationRecord(
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

internal sealed record ObservationExecution<T>(
    T Result,
    IReadOnlyList<BenchEvidenceItem> Evidence);