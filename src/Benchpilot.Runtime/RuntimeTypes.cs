namespace Benchpilot.Runtime;

public class BenchRuntimeException : Exception
{
    public BenchRuntimeException(string message) : base(message) { }
}

public sealed class BenchValidationException : BenchRuntimeException
{
    public BenchValidationException(string message) : base(message) { }
}

public sealed class BenchTargetNotFoundException : BenchRuntimeException
{
    public BenchTargetNotFoundException(string message) : base(message) { }
}

public sealed class BenchBusyException : BenchRuntimeException
{
    public BenchBusyException(
        string targetId,
        string operation,
        string busyScope = "target",
        string? busyId = null,
        string? ownerOperationId = null,
        string? ownerOperation = null)
        : base(CreateMessage(
            targetId,
            operation,
            busyScope,
            busyId,
            ownerOperationId,
            ownerOperation))
    {
        TargetId = targetId;
        Operation = operation;
        BusyScope = busyScope;
        BusyId = busyId ?? targetId;
        OwnerOperationId = ownerOperationId;
        OwnerOperation = ownerOperation;
    }

    public string TargetId { get; }
    public string Operation { get; }
    public string BusyScope { get; }
    public string BusyId { get; }
    public string? OwnerOperationId { get; }
    public string? OwnerOperation { get; }
    public string? ResourceId =>
        string.Equals(BusyScope, "resource", StringComparison.OrdinalIgnoreCase)
            ? BusyId
            : null;

    private static string CreateMessage(
        string targetId,
        string operation,
        string busyScope,
        string? busyId,
        string? ownerOperationId,
        string? ownerOperation)
    {
        var owner = string.IsNullOrWhiteSpace(ownerOperationId)
            ? string.Empty
            : $" Active operation: {ownerOperation ?? "mutation"} ({ownerOperationId}).";

        if (string.Equals(busyScope, "resource", StringComparison.OrdinalIgnoreCase))
        {
            var resourceId = busyId ?? "unknown";
            return $"Resource '{resourceId}' is busy with another mutating operation; " +
                $"target '{targetId}' operation '{operation}' was not started.{owner}";
        }

        return $"Target '{targetId}' is busy with another mutating operation; " +
            $"'{operation}' was not started.{owner}";
    }
}

public sealed record BenchOperationInfo(
    string Id,
    string TargetId,
    string Kind,
    IReadOnlyList<string> ResourceIds,
    DateTimeOffset StartedAtUtc,
    bool CancellationRequested);

public sealed record BenchOperationRecord(
    string Id,
    string TargetId,
    string Kind,
    IReadOnlyList<string> ResourceIds,
    DateTimeOffset StartedAtUtc,
    DateTimeOffset CompletedAtUtc,
    int DurationMs,
    string State,
    string? Error = null);
