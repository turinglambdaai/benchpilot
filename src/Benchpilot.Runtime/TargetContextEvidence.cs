using System.Globalization;
using System.Runtime.CompilerServices;
using Benchpilot.Core;

namespace Benchpilot.Runtime;

/// <summary>
/// Keeps a very small semantic context ring per target. This is not telemetry:
/// Runtime records only results that callers already requested (power/current),
/// performs no background I/O, and exposes at most a few recent entries when a
/// later flash/reset/boot observation fails.
/// </summary>
internal static class TargetContextEvidence
{
    private const int CapacityPerTarget = 8;
    private const int DefaultSnapshotCount = 3;
    private static readonly TimeSpan MaxContextAge = TimeSpan.FromMinutes(10);

    private static readonly ConditionalWeakTable<BenchRuntime, Store> Stores = new();
    private static readonly AsyncLocal<FailureScopeState?> FailureScope = new();

    public static void RecordPowerOn(BenchRuntime runtime, string targetId, PowerOnResult result) =>
        Put(runtime, targetId, new BenchEvidenceItem(
            "context.power-on",
            result.Ok
                ? "Recent power-on result."
                : "Recent power-on attempt returned a device/safety error.",
            result.Error,
            new Dictionary<string, string>
            {
                ["ok"] = Bool(result.Ok),
                ["voltageV"] = Number(result.Voltage),
                ["currentMa"] = Number(result.CurrentMa),
                ["settled"] = Bool(result.Settled),
            }));

    public static void RecordPowerOff(BenchRuntime runtime, string targetId, PowerOffResult result, bool emergency = false) =>
        Put(runtime, targetId, new BenchEvidenceItem(
            emergency ? "context.power-emergency-off" : "context.power-off",
            result.Ok
                ? emergency
                    ? "Recent emergency power-off completed."
                    : "Recent normal power-off completed."
                : emergency
                    ? "Recent emergency power-off returned a device error."
                    : "Recent normal power-off returned a device error.",
            result.Error,
            new Dictionary<string, string>
            {
                ["ok"] = Bool(result.Ok),
                ["emergency"] = Bool(emergency),
            }));

    public static void RecordCurrentReading(
        BenchRuntime runtime,
        string targetId,
        CurrentReading result) =>
        Put(runtime, targetId, new BenchEvidenceItem(
            "context.current-reading",
            result.Ok
                ? "Recent current measurement."
                : "Recent current measurement returned a device error.",
            result.Error,
            new Dictionary<string, string>
            {
                ["ok"] = Bool(result.Ok),
                ["avgMa"] = Number(result.AvgMa),
                ["peakMa"] = Number(result.PeakMa),
                ["sampleCount"] = result.Samples.Count.ToString(CultureInfo.InvariantCulture),
            }));

    public static void RecordCurrentCheck(
        BenchRuntime runtime,
        string targetId,
        CurrentCheck result,
        double? ltMa,
        double? gtMa)
    {
        var metadata = new Dictionary<string, string>
        {
            ["ok"] = Bool(result.Ok),
            ["passed"] = Bool(result.Passed),
            ["valueMa"] = Number(result.ValueMa),
        };
        if (ltMa is not null) metadata["ltMa"] = Number(ltMa.Value);
        if (gtMa is not null) metadata["gtMa"] = Number(gtMa.Value);

        Put(runtime, targetId, new BenchEvidenceItem(
            "context.current-check",
            result.Ok
                ? result.Passed
                    ? "Recent current assertion passed."
                    : "Recent current assertion failed."
                : "Recent current assertion returned a device error.",
            result.Error,
            metadata));
    }

    public static IReadOnlyList<BenchEvidenceItem> Snapshot(
        BenchRuntime runtime,
        string targetId,
        int maxItems = DefaultSnapshotCount)
    {
        ArgumentNullException.ThrowIfNull(runtime);
        ArgumentException.ThrowIfNullOrWhiteSpace(targetId);
        if (maxItems <= 0) return Array.Empty<BenchEvidenceItem>();

        return GetStore(runtime).Snapshot(targetId, Math.Min(maxItems, DefaultSnapshotCount));
    }

    /// <summary>
    /// Marks a flash/reset call so OperationEvidenceExtractor can append the
    /// same target-local context to device failures and thrown infrastructure
    /// errors without widening RunMutation's generic contract. AsyncLocal is
    /// intentionally scoped to the current async call chain only.
    /// </summary>
    public static IDisposable BeginFailureScope(
        BenchRuntime runtime,
        string targetId,
        string operationKind)
    {
        ArgumentNullException.ThrowIfNull(runtime);
        ArgumentException.ThrowIfNullOrWhiteSpace(targetId);
        ArgumentException.ThrowIfNullOrWhiteSpace(operationKind);

        var previous = FailureScope.Value;
        FailureScope.Value = new FailureScopeState(runtime, targetId, operationKind);
        return new ScopeLease(previous);
    }

    public static IReadOnlyList<BenchEvidenceItem> AppendFailureContext(
        IReadOnlyList<BenchEvidenceItem> primary)
    {
        ArgumentNullException.ThrowIfNull(primary);
        var scope = FailureScope.Value;
        if (scope is null) return primary;

        var context = Snapshot(scope.Runtime, scope.TargetId);
        if (context.Count == 0) return primary;
        return primary.Concat(context).ToArray();
    }

    private static void Put(
        BenchRuntime runtime,
        string targetId,
        BenchEvidenceItem item)
    {
        ArgumentNullException.ThrowIfNull(runtime);
        ArgumentException.ThrowIfNullOrWhiteSpace(targetId);
        GetStore(runtime).Put(targetId, item);
    }

    private static Store GetStore(BenchRuntime runtime) =>
        Stores.GetValue(runtime, static _ => new Store());

    private static string Bool(bool value) => value ? "true" : "false";
    private static string Number(double value) =>
        value.ToString("0.###", CultureInfo.InvariantCulture);

    private sealed record FailureScopeState(
        BenchRuntime Runtime,
        string TargetId,
        string OperationKind);

    private sealed class ScopeLease : IDisposable
    {
        private readonly FailureScopeState? _previous;
        private int _disposed;

        public ScopeLease(FailureScopeState? previous) => _previous = previous;

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
            FailureScope.Value = _previous;
        }
    }

    private sealed class Store
    {
        private readonly object _sync = new();
        private readonly Dictionary<string, Queue<Entry>> _byTarget =
            new(StringComparer.OrdinalIgnoreCase);

        public void Put(string targetId, BenchEvidenceItem item)
        {
            var now = DateTimeOffset.UtcNow;
            lock (_sync)
            {
                if (!_byTarget.TryGetValue(targetId, out var queue))
                {
                    queue = new Queue<Entry>();
                    _byTarget[targetId] = queue;
                }

                queue.Enqueue(new Entry(now, item));
                while (queue.Count > CapacityPerTarget)
                    queue.Dequeue();
            }
        }

        public IReadOnlyList<BenchEvidenceItem> Snapshot(string targetId, int maxItems)
        {
            var now = DateTimeOffset.UtcNow;
            lock (_sync)
            {
                if (!_byTarget.TryGetValue(targetId, out var queue))
                    return Array.Empty<BenchEvidenceItem>();

                while (queue.Count > 0 && now - queue.Peek().CapturedAtUtc > MaxContextAge)
                    queue.Dequeue();

                return queue
                    .Reverse()
                    .Take(maxItems)
                    .Select(entry => WithAge(entry, now))
                    .ToArray();
            }
        }

        private static BenchEvidenceItem WithAge(Entry entry, DateTimeOffset now)
        {
            var metadata = entry.Item.Metadata is null
                ? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                : new Dictionary<string, string>(entry.Item.Metadata, StringComparer.OrdinalIgnoreCase);
            metadata["capturedAtUtc"] = entry.CapturedAtUtc.ToString("O", CultureInfo.InvariantCulture);
            metadata["ageMs"] = Math.Max(0, (long)(now - entry.CapturedAtUtc).TotalMilliseconds)
                .ToString(CultureInfo.InvariantCulture);
            return entry.Item with { Metadata = metadata };
        }

        private sealed record Entry(DateTimeOffset CapturedAtUtc, BenchEvidenceItem Item);
    }
}
