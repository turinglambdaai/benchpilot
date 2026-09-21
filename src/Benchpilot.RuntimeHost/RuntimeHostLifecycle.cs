using Benchpilot.Runtime;

namespace Benchpilot.RuntimeHost;

internal sealed class RuntimeHostLifecycle
{
    private int _stopping;
    private int _inFlightRequests;

    public bool IsStopping => Volatile.Read(ref _stopping) != 0;
    public int InFlightRequests => Math.Max(0, Volatile.Read(ref _inFlightRequests));

    public void BeginStopping() => Interlocked.Exchange(ref _stopping, 1);

    /// <summary>
    /// Atomically admits one non-health API request while the host is running.
    /// The second stopping check closes the race where shutdown begins between
    /// the initial check and increment. Requests admitted just before shutdown
    /// remain counted until they leave middleware, so resource disposal can
    /// wait for even those calls that have not yet registered Runtime work.
    /// </summary>
    public bool TryEnterRequest(out IDisposable? lease)
    {
        lease = null;
        if (IsStopping)
            return false;

        Interlocked.Increment(ref _inFlightRequests);
        if (IsStopping)
        {
            Interlocked.Decrement(ref _inFlightRequests);
            return false;
        }

        lease = new RequestLease(this);
        return true;
    }

    private void ExitRequest() => Interlocked.Decrement(ref _inFlightRequests);

    private sealed class RequestLease : IDisposable
    {
        private RuntimeHostLifecycle? _owner;

        public RequestLease(RuntimeHostLifecycle owner) => _owner = owner;

        public void Dispose()
        {
            var owner = Interlocked.Exchange(ref _owner, null);
            owner?.ExitRequest();
        }
    }
}

internal sealed class RuntimeShutdownService : IHostedService
{
    private static readonly TimeSpan DrainTimeout = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan RequestPollInterval = TimeSpan.FromMilliseconds(25);

    private readonly BenchRuntime _runtime;
    private readonly RuntimeHostLifecycle _lifecycle;
    private readonly IHostApplicationLifetime _applicationLifetime;
    private readonly ILogger<RuntimeShutdownService> _logger;
    private CancellationTokenRegistration _stoppingRegistration;

    public RuntimeShutdownService(
        BenchRuntime runtime,
        RuntimeHostLifecycle lifecycle,
        IHostApplicationLifetime applicationLifetime,
        ILogger<RuntimeShutdownService> logger)
    {
        _runtime = runtime;
        _lifecycle = lifecycle;
        _applicationLifetime = applicationLifetime;
        _logger = logger;
    }

    public Task StartAsync(CancellationToken cancellationToken)
    {
        // ApplicationStopping fires before the host invokes hosted-service
        // StopAsync. Cancel Runtime-owned long requests here so the web server
        // does not wait on an HTTP serial/flash request that itself needs
        // StopAsync to be cancelled — a shutdown dependency cycle.
        _stoppingRegistration = _applicationLifetime.ApplicationStopping.Register(() =>
        {
            _lifecycle.BeginStopping();

            foreach (var operation in _runtime.ActiveOperations)
                _runtime.CancelOperation(operation.Id);
            foreach (var observation in _runtime.ActiveObservations)
                _runtime.CancelObservation(observation.Id);
        });
        return Task.CompletedTask;
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        _lifecycle.BeginStopping();

        var activeOperations = _runtime.ActiveOperations.Count;
        var activeObservations = _runtime.ActiveObservations.Count;
        var inFlightRequests = _lifecycle.InFlightRequests;
        if (activeOperations > 0 || activeObservations > 0 || inFlightRequests > 0)
        {
            _logger.LogInformation(
                "BenchPilot Runtime shutdown: draining {Requests} admitted requests, {Operations} operations and {Observations} observations.",
                inFlightRequests,
                activeOperations,
                activeObservations);
        }

        var deadline = DateTimeOffset.UtcNow + DrainTimeout;
        BenchRuntimeDrainResult? lastDrain = null;

        while (DateTimeOffset.UtcNow < deadline && !cancellationToken.IsCancellationRequested)
        {
            var remaining = deadline - DateTimeOffset.UtcNow;
            lastDrain = await _runtime.DrainAsync(remaining, cancellationToken);

            if (lastDrain.Drained && _lifecycle.InFlightRequests == 0)
            {
                _runtime.Dispose();
                _stoppingRegistration.Dispose();
                _logger.LogInformation("BenchPilot Runtime shutdown: active work drained and hardware resources released.");
                return;
            }

            // DrainAsync may return immediately when Runtime registries are
            // empty while a request admitted just before ApplicationStopping is
            // still executing preflight/current-read code or has not registered
            // its operation yet. Keep the host alive until middleware reports
            // all admitted requests have left, then re-scan Runtime state.
            if (lastDrain.Drained)
            {
                try
                {
                    await Task.Delay(RequestPollInterval, cancellationToken);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                continue;
            }

            // A non-drained result means the bounded deadline was consumed by
            // an uncooperative active driver.
            break;
        }

        _stoppingRegistration.Dispose();
        var remainingOperations = _runtime.ActiveOperations.Select(x => x.Id).ToArray();
        var remainingObservations = _runtime.ActiveObservations.Select(x => x.Id).ToArray();

        // Do not call Dispose while driver calls or admitted API requests are
        // still active. Doing so can invalidate serial/J-Link/SCPI handles
        // underneath cooperative cleanup. Process teardown is the safer final
        // fallback after the bounded drain window.
        _logger.LogError(
            "BenchPilot Runtime shutdown timed out. In-flight requests: {Requests}; remaining operations: {Operations}; observations: {Observations}. " +
            "Resources were intentionally not disposed underneath active work and will be reclaimed by process teardown.",
            _lifecycle.InFlightRequests,
            string.Join(",", remainingOperations),
            string.Join(",", remainingObservations));
    }
}
