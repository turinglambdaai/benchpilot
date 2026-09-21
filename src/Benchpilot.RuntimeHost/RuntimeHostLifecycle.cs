using Benchpilot.Runtime;

namespace Benchpilot.RuntimeHost;

internal sealed class RuntimeHostLifecycle
{
    private int _stopping;

    public bool IsStopping => Volatile.Read(ref _stopping) != 0;

    public void BeginStopping() => Interlocked.Exchange(ref _stopping, 1);
}

internal sealed class RuntimeShutdownService : IHostedService
{
    private static readonly TimeSpan DrainTimeout = TimeSpan.FromSeconds(5);

    private readonly BenchRuntime _runtime;
    private readonly RuntimeHostLifecycle _lifecycle;
    private readonly ILogger<RuntimeShutdownService> _logger;

    public RuntimeShutdownService(
        BenchRuntime runtime,
        RuntimeHostLifecycle lifecycle,
        ILogger<RuntimeShutdownService> logger)
    {
        _runtime = runtime;
        _lifecycle = lifecycle;
        _logger = logger;
    }

    public Task StartAsync(CancellationToken cancellationToken) => Task.CompletedTask;

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        _lifecycle.BeginStopping();

        var activeOperations = _runtime.ActiveOperations.Count;
        var activeObservations = _runtime.ActiveObservations.Count;
        if (activeOperations > 0 || activeObservations > 0)
        {
            _logger.LogInformation(
                "BenchPilot Runtime shutdown: requesting cancellation of {Operations} operations and {Observations} observations.",
                activeOperations,
                activeObservations);
        }

        var drained = await _runtime.DrainAsync(DrainTimeout, cancellationToken);
        if (drained.Drained)
        {
            _runtime.Dispose();
            _logger.LogInformation("BenchPilot Runtime shutdown: active work drained and hardware resources released.");
            return;
        }

        // Do not call Dispose while driver calls are still active. Doing so can
        // invalidate serial/J-Link/SCPI handles underneath cooperative cleanup.
        // The process is already stopping, so OS process teardown is the safer
        // fallback for an uncooperative driver after the bounded drain timeout.
        _logger.LogError(
            "BenchPilot Runtime shutdown timed out. Remaining operations: {Operations}; observations: {Observations}. " +
            "Resources were intentionally not disposed underneath active drivers and will be reclaimed by process teardown.",
            string.Join(",", drained.RemainingOperationIds),
            string.Join(",", drained.RemainingObservationIds));
    }
}
