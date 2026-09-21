namespace Benchpilot.Runtime;

public sealed record BenchObservationInfo(
    string Id,
    string TargetId,
    string Kind,
    IReadOnlyList<string> ResourceIds,
    DateTimeOffset StartedAtUtc,
    bool CancellationRequested);

public sealed record BenchObservationRecord(
    string Id,
    string TargetId,
    string Kind,
    IReadOnlyList<string> ResourceIds,
    DateTimeOffset StartedAtUtc,
    DateTimeOffset CompletedAtUtc,
    int DurationMs,
    string State,
    string? Error = null);

internal sealed record ObservationExecution<T>(
    T Result,
    IReadOnlyList<BenchEvidenceItem> Evidence);
