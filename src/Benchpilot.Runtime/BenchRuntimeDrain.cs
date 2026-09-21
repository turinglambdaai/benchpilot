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
    /// Requests cooperative cancellation of all Runtime-owned mutations and
    /// observations, then waits up to <paramref name="timeout"/> for drivers to
    /// unwind and release their Runtime registrations. This method does not
    /// dispose hardware resources; the host should dispose only after a
    /// successful drain so handles are never pulled out from under live driver
    /// calls.
    /// </summary>
    public static async Task<BenchRuntimeDrainResult> DrainAsync(
        this BenchRuntime runtime,
        TimeSpan timeout,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(runtime);
        if (timeout < TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(timeout), "Drain timeout cannot be negative.");

        var initialOperations = runtime.ActiveOperations;
        var initialObservations = runtime.ActiveObservations;
        var cancelledOperations = 0;
        var cancelledObservations = 0;

        foreach (var operation in initialOperations)
        {
            if (runtime.CancelOperation(operation.Id))
                cancelledOperations++;
        }

        foreach (var observation in initialObservations)
        {
            if (runtime.CancelObservation(observation.Id))
                cancelledObservations++;
        }

        var deadline = DateTimeOffset.UtcNow + timeout;
        while (true)
        {
            var operations = runtime.ActiveOperations;
            var observations = runtime.ActiveObservations;
            if (operations.Count == 0 && observations.Count == 0)
            {
                return new BenchRuntimeDrainResult(
                    true,
                    cancelledOperations,
                    cancelledObservations,
                    Array.Empty<string>(),
                    Array.Empty<string>());
            }

            if (DateTimeOffset.UtcNow >= deadline || ct.IsCancellationRequested)
            {
                return new BenchRuntimeDrainResult(
                    false,
                    cancelledOperations,
                    cancelledObservations,
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
                    cancelledOperations,
                    cancelledObservations,
                    operationsAfterCancel.Select(x => x.Id).ToArray(),
                    observationsAfterCancel.Select(x => x.Id).ToArray());
            }
        }
    }
}
