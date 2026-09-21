namespace Benchpilot.Runtime;

public sealed record BenchRuntimeDrainResult(
    bool Drained,
    int CancelRequestedOperations,
    int CancelRequestedObservations,
    IReadOnlyList<string> RemainingOperationIds,
    IReadOnlyList<string> RemainingObservationIds);

public static class BenchRuntimeDrain
{
    /// <summary>
    /// Requests cooperative cancellation of Runtime-owned mutations and
    /// observations, then waits up to <paramref name="timeout"/> for drivers to
    /// unwind and release their Runtime registrations. New active work observed
    /// while the host is entering shutdown is cancelled too. This method does
    /// not dispose hardware resources; the host should dispose only after a
    /// successful drain so handles are never pulled out from under live calls.
    /// </summary>
    public static async Task<BenchRuntimeDrainResult> DrainAsync(
        this BenchRuntime runtime,
        TimeSpan timeout,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(runtime);
        if (timeout < TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(timeout), "Drain timeout cannot be negative.");

        var cancelledOperationIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var cancelledObservationIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var deadline = DateTimeOffset.UtcNow + timeout;

        while (true)
        {
            var operations = runtime.ActiveOperations;
            var observations = runtime.ActiveObservations;

            foreach (var operation in operations)
            {
                if (cancelledOperationIds.Add(operation.Id))
                    runtime.CancelOperation(operation.Id);
            }

            foreach (var observation in observations)
            {
                if (cancelledObservationIds.Add(observation.Id))
                    runtime.CancelObservation(observation.Id);
            }

            // Re-read after issuing cancellation because cooperative drivers may
            // unregister synchronously/very quickly.
            operations = runtime.ActiveOperations;
            observations = runtime.ActiveObservations;
            if (operations.Count == 0 && observations.Count == 0)
            {
                return new BenchRuntimeDrainResult(
                    true,
                    cancelledOperationIds.Count,
                    cancelledObservationIds.Count,
                    Array.Empty<string>(),
                    Array.Empty<string>());
            }

            if (DateTimeOffset.UtcNow >= deadline || ct.IsCancellationRequested)
            {
                return new BenchRuntimeDrainResult(
                    false,
                    cancelledOperationIds.Count,
                    cancelledObservationIds.Count,
                    operations.Select(x => x.Id).ToArray(),
                    observations.Select(x => x.Id).ToArray());
            }

            var remaining = deadline - DateTimeOffset.UtcNow;
            var delay = remaining < TimeSpan.FromMilliseconds(25)
                ? remaining
                : TimeSpan.FromMilliseconds(25);
            if (delay <= TimeSpan.Zero)
                continue;

            try
            {
                await Task.Delay(delay, ct);
            }
            catch (OperationCanceledException)
            {
                var operationsAfterCancel = runtime.ActiveOperations;
                var observationsAfterCancel = runtime.ActiveObservations;
                return new BenchRuntimeDrainResult(
                    operationsAfterCancel.Count == 0 && observationsAfterCancel.Count == 0,
                    cancelledOperationIds.Count,
                    cancelledObservationIds.Count,
                    operationsAfterCancel.Select(x => x.Id).ToArray(),
                    observationsAfterCancel.Select(x => x.Id).ToArray());
            }
        }
    }
}
