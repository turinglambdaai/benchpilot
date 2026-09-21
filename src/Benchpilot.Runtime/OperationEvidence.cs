using System.Globalization;
using Benchpilot.Core;

namespace Benchpilot.Runtime;

public sealed record BenchEvidenceItem(
    string Kind,
    string Summary,
    string? Text = null,
    IReadOnlyDictionary<string, string>? Metadata = null);

public sealed record BenchOperationEvidence(
    string OperationId,
    string TargetId,
    string OperationKind,
    IReadOnlyList<string> ResourceIds,
    DateTimeOffset CreatedAtUtc,
    IReadOnlyList<BenchEvidenceItem> Items);

/// <summary>
/// Converts already-bounded semantic driver results into Agent-friendly
/// evidence. This layer deliberately does not know about vendor SDK/process
/// types. Drivers remain responsible for bounding raw diagnostics before they
/// place them in their public Core result Error field.
/// </summary>
internal static class OperationEvidenceExtractor
{
    public static IReadOnlyList<BenchEvidenceItem> FromResult(object? result)
    {
        IReadOnlyList<BenchEvidenceItem> primary = result switch
        {
            PowerOnResult value =>
            [
                Item(
                    "power.result",
                    value.Ok ? "Power-on completed." : "Power-on returned a device error.",
                    value.Error,
                    new Dictionary<string, string>
                    {
                        ["ok"] = Bool(value.Ok),
                        ["voltageV"] = Number(value.Voltage),
                        ["currentMa"] = Number(value.CurrentMa),
                        ["settled"] = Bool(value.Settled),
                    })
            ],
            PowerOffResult value =>
            [
                Item(
                    "power.result",
                    value.Ok ? "Power-off completed." : "Power-off returned a device error.",
                    value.Error,
                    new Dictionary<string, string>
                    {
                        ["ok"] = Bool(value.Ok),
                    })
            ],
            FlashResult value =>
            [
                Item(
                    "flash.result",
                    value.Ok ? "Flash completed." : "Flash returned a device error.",
                    value.Error,
                    new Dictionary<string, string>
                    {
                        ["ok"] = Bool(value.Ok),
                        ["bytes"] = value.Bytes.ToString(CultureInfo.InvariantCulture),
                        ["durationMs"] = value.DurationMs.ToString(CultureInfo.InvariantCulture),
                    })
            ],
            ResetResult value =>
            [
                Item(
                    "reset.result",
                    value.Ok ? "Reset completed." : "Reset returned a device error.",
                    value.Error,
                    new Dictionary<string, string>
                    {
                        ["ok"] = Bool(value.Ok),
                    })
            ],
            _ =>
            [
                Item(
                    "operation.result",
                    result is null
                        ? "Operation returned no result payload."
                        : $"Operation returned {result.GetType().Name}.")
            ],
        };

        return result switch
        {
            FlashResult { Ok: false } => TargetContextEvidence.AppendFailureContext(primary),
            ResetResult { Ok: false } => TargetContextEvidence.AppendFailureContext(primary),
            _ => primary,
        };
    }

    public static IReadOnlyList<BenchEvidenceItem> FromCancellation() =>
        TargetContextEvidence.AppendFailureContext(
        [
            Item(
                "runtime.cancelled",
                "Operation was cancelled before normal completion.",
                "Operation cancelled.")
        ]);

    public static IReadOnlyList<BenchEvidenceItem> FromException(Exception exception)
    {
        ArgumentNullException.ThrowIfNull(exception);
        return TargetContextEvidence.AppendFailureContext(
        [
            Item(
                "runtime.exception",
                "Operation terminated with an infrastructure exception.",
                exception.Message,
                new Dictionary<string, string>
                {
                    ["exceptionType"] = exception.GetType().Name,
                })
        ]);
    }

    private static BenchEvidenceItem Item(
        string kind,
        string summary,
        string? text = null,
        IReadOnlyDictionary<string, string>? metadata = null) =>
        new(kind, summary, text, metadata);

    private static string Bool(bool value) => value ? "true" : "false";

    private static string Number(double value) =>
        value.ToString("0.###", CultureInfo.InvariantCulture);
}

/// <summary>
/// In-memory bounded evidence store. The Runtime keeps at most one compact
/// evidence bundle for each of the newest operations, independently of the
/// active-operation registry. It is intentionally not persistent storage.
/// </summary>
internal sealed class OperationEvidenceStore
{
    public const int Capacity = 128;
    public const int MaxItemsPerOperation = 8;
    public const int MaxTextLength = 4000;
    public const int MaxSummaryLength = 512;
    public const int MaxMetadataItems = 16;
    public const int MaxMetadataValueLength = 512;

    private readonly object _sync = new();
    private readonly Dictionary<string, BenchOperationEvidence> _byOperationId =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly Queue<string> _order = new();

    public void Put(
        string operationId,
        string targetId,
        string operationKind,
        IReadOnlyList<string> resourceIds,
        IReadOnlyList<BenchEvidenceItem> items)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(operationId);
        ArgumentException.ThrowIfNullOrWhiteSpace(targetId);
        ArgumentException.ThrowIfNullOrWhiteSpace(operationKind);
        ArgumentNullException.ThrowIfNull(resourceIds);
        ArgumentNullException.ThrowIfNull(items);

        var boundedItems = items
            .Take(MaxItemsPerOperation)
            .Select(BoundItem)
            .ToArray();
        var evidence = new BenchOperationEvidence(
            operationId,
            targetId,
            operationKind,
            resourceIds.ToArray(),
            DateTimeOffset.UtcNow,
            boundedItems);

        lock (_sync)
        {
            if (_byOperationId.ContainsKey(operationId))
            {
                _byOperationId[operationId] = evidence;
                return;
            }

            _byOperationId[operationId] = evidence;
            _order.Enqueue(operationId);
            while (_order.Count > Capacity)
            {
                var evicted = _order.Dequeue();
                _byOperationId.Remove(evicted);
            }
        }
    }

    public BenchOperationEvidence? Get(string operationId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(operationId);
        lock (_sync)
        {
            return _byOperationId.TryGetValue(operationId, out var evidence)
                ? evidence
                : null;
        }
    }

    private static BenchEvidenceItem BoundItem(BenchEvidenceItem item)
    {
        var metadata = item.Metadata?
            .Take(MaxMetadataItems)
            .ToDictionary(
                x => Bound(x.Key, 128) ?? string.Empty,
                x => Bound(x.Value, MaxMetadataValueLength) ?? string.Empty,
                StringComparer.OrdinalIgnoreCase);

        return item with
        {
            Kind = Bound(item.Kind, 128) ?? "evidence",
            Summary = Bound(item.Summary, MaxSummaryLength) ?? string.Empty,
            Text = Bound(item.Text, MaxTextLength),
            Metadata = metadata,
        };
    }

    private static string? Bound(string? value, int maxLength)
    {
        if (string.IsNullOrEmpty(value)) return value;
        return value.Length <= maxLength ? value : value[..maxLength];
    }
}
