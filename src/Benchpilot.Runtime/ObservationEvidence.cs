using System.Globalization;
using Benchpilot.Core;

namespace Benchpilot.Runtime;

public sealed record BenchObservationEvidence(
    string ObservationId,
    string TargetId,
    string ObservationKind,
    IReadOnlyList<string> ResourceIds,
    DateTimeOffset CreatedAtUtc,
    IReadOnlyList<BenchEvidenceItem> Items);

internal static class SerialObservationEvidenceExtractor
{
    public static IReadOnlyList<BenchEvidenceItem> FromOpen(SerialOpenResult result) =>
    [
        Item(
            "serial.open",
            result.Ok ? "Serial channel opened." : "Serial open returned a device error.",
            result.Error,
            new Dictionary<string, string>
            {
                ["ok"] = Bool(result.Ok),
                ["port"] = result.Port,
                ["baud"] = result.Baud.ToString(CultureInfo.InvariantCulture),
            })
    ];

    public static IReadOnlyList<BenchEvidenceItem> FromWait(
        string pattern,
        int timeoutMs,
        SerialWaitResult result,
        SerialWindowResult? failureWindow)
    {
        var items = new List<BenchEvidenceItem>
        {
            Item(
                "serial.wait",
                result.Matched
                    ? "Serial pattern matched."
                    : result.Ok
                        ? "Serial wait completed without a match."
                        : "Serial wait returned a device error.",
                result.Error ?? result.MatchedLine,
                new Dictionary<string, string>
                {
                    ["ok"] = Bool(result.Ok),
                    ["matched"] = Bool(result.Matched),
                    ["pattern"] = pattern,
                    ["timeoutMs"] = timeoutMs.ToString(CultureInfo.InvariantCulture),
                    ["elapsedMs"] = result.ElapsedMs.ToString(CultureInfo.InvariantCulture),
                })
        };

        if (failureWindow is { Ok: true } window && window.Lines.Count > 0)
        {
            items.Add(Item(
                "serial.failure-window",
                $"Recent serial context captured around an unmatched/failed wait ({window.Lines.Count} lines).",
                string.Join("\n", window.Lines),
                new Dictionary<string, string>
                {
                    ["lineCount"] = window.Lines.Count.ToString(CultureInfo.InvariantCulture),
                }));
        }
        else if (failureWindow is { Ok: false } unavailable)
        {
            items.Add(Item(
                "serial.failure-window",
                "Recent serial context could not be read.",
                unavailable.Error));
        }

        return items;
    }

    public static IReadOnlyList<BenchEvidenceItem> FromWindow(SerialWindowResult result) =>
    [
        Item(
            "serial.window",
            result.Ok
                ? $"Serial window returned {result.Lines.Count} lines."
                : "Serial window returned a device error.",
            result.Ok ? string.Join("\n", result.Lines) : result.Error,
            new Dictionary<string, string>
            {
                ["ok"] = Bool(result.Ok),
                ["lineCount"] = result.Lines.Count.ToString(CultureInfo.InvariantCulture),
            })
    ];

    public static IReadOnlyList<BenchEvidenceItem> FromSend(SerialSendResult result, int charCount) =>
    [
        Item(
            "serial.send",
            result.Ok ? "Serial send completed." : "Serial send returned a device error.",
            result.Error,
            new Dictionary<string, string>
            {
                ["ok"] = Bool(result.Ok),
                ["charCount"] = charCount.ToString(CultureInfo.InvariantCulture),
            })
    ];

    public static IReadOnlyList<BenchEvidenceItem> FromCancellation() =>
    [
        Item(
            "runtime.cancelled",
            "Observation was cancelled before normal completion.",
            "Observation cancelled.")
    ];

    public static IReadOnlyList<BenchEvidenceItem> FromException(Exception exception)
    {
        ArgumentNullException.ThrowIfNull(exception);
        return
        [
            Item(
                "runtime.exception",
                "Observation terminated with an infrastructure exception.",
                exception.Message,
                new Dictionary<string, string>
                {
                    ["exceptionType"] = exception.GetType().Name,
                })
        ];
    }

    private static BenchEvidenceItem Item(
        string kind,
        string summary,
        string? text = null,
        IReadOnlyDictionary<string, string>? metadata = null) =>
        new(kind, summary, text, metadata);

    private static string Bool(bool value) => value ? "true" : "false";
}

internal sealed class ObservationEvidenceStore
{
    public const int Capacity = 128;
    public const int MaxItemsPerObservation = 8;
    public const int MaxTextLength = 4000;
    public const int MaxSummaryLength = 512;
    public const int MaxMetadataItems = 16;
    public const int MaxMetadataValueLength = 512;

    private readonly object _sync = new();
    private readonly Dictionary<string, BenchObservationEvidence> _byObservationId =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly Queue<string> _order = new();

    public void Put(
        string observationId,
        string targetId,
        string observationKind,
        IReadOnlyList<string> resourceIds,
        IReadOnlyList<BenchEvidenceItem> items)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(observationId);
        ArgumentException.ThrowIfNullOrWhiteSpace(targetId);
        ArgumentException.ThrowIfNullOrWhiteSpace(observationKind);
        ArgumentNullException.ThrowIfNull(resourceIds);
        ArgumentNullException.ThrowIfNull(items);

        var boundedItems = items
            .Take(MaxItemsPerObservation)
            .Select(BoundItem)
            .ToArray();
        var evidence = new BenchObservationEvidence(
            observationId,
            targetId,
            observationKind,
            resourceIds.ToArray(),
            DateTimeOffset.UtcNow,
            boundedItems);

        lock (_sync)
        {
            if (_byObservationId.ContainsKey(observationId))
            {
                _byObservationId[observationId] = evidence;
                return;
            }

            _byObservationId[observationId] = evidence;
            _order.Enqueue(observationId);
            while (_order.Count > Capacity)
            {
                var evicted = _order.Dequeue();
                _byObservationId.Remove(evicted);
            }
        }
    }

    public BenchObservationEvidence? Get(string observationId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(observationId);
        lock (_sync)
        {
            return _byObservationId.TryGetValue(observationId, out var evidence)
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
