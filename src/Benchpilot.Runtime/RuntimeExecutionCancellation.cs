namespace Benchpilot.Runtime;

/// <summary>
/// Owns the three cancellation causes for one Runtime execution: caller/request
/// cancellation, explicit Runtime cancellation, and an optional operation
/// deadline. The first observed cause wins so history/API classification does
/// not depend on callback or thread scheduling order.
/// </summary>
internal sealed class RuntimeExecutionCancellation : IDisposable
{
    private const int CauseNone = 0;
    private const int CauseCaller = 1;
    private const int CauseExplicit = 2;
    private const int CauseDeadline = 3;

    private readonly CancellationTokenSource _explicitCancellation = new();
    private readonly CancellationTokenSource? _deadlineCancellation;
    private readonly CancellationTokenSource _linkedCancellation;
    private readonly CancellationTokenRegistration _requestRegistration;
    private readonly CancellationTokenRegistration _deadlineRegistration;
    private int _cause;
    private int _disposed;

    public RuntimeExecutionCancellation(
        CancellationToken requestCancellation,
        int? deadlineMs,
        DateTimeOffset startedAtUtc)
    {
        DeadlineMs = deadlineMs;
        DeadlineAtUtc = deadlineMs is { } value
            ? startedAtUtc.AddMilliseconds(value)
            : null;

        if (requestCancellation.IsCancellationRequested)
            Interlocked.CompareExchange(ref _cause, CauseCaller, CauseNone);

        _requestRegistration = requestCancellation.Register(
            static state => ((RuntimeExecutionCancellation)state!).MarkCause(CauseCaller),
            this);

        if (deadlineMs is { } timeoutMs)
        {
            _deadlineCancellation = new CancellationTokenSource(timeoutMs);
            _deadlineRegistration = _deadlineCancellation.Token.Register(
                static state => ((RuntimeExecutionCancellation)state!).MarkCause(CauseDeadline),
                this);
            _linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                requestCancellation,
                _explicitCancellation.Token,
                _deadlineCancellation.Token);
        }
        else
        {
            _linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                requestCancellation,
                _explicitCancellation.Token);
        }
    }

    public int? DeadlineMs { get; }
    public DateTimeOffset? DeadlineAtUtc { get; }
    public CancellationToken Token => _linkedCancellation.Token;

    public bool DeadlineExceeded
    {
        get
        {
            // Timer callbacks can be scheduled a little after their nominal due
            // time. If a driver ignores cancellation and returns after the wall
            // clock deadline, claim the deadline cause here before accepting the
            // result. A caller/explicit cancellation that already won remains the
            // cause because MarkCause is compare-exchange based.
            if (DeadlineAtUtc is { } deadlineAtUtc && DateTimeOffset.UtcNow >= deadlineAtUtc)
                MarkCause(CauseDeadline);
            return Volatile.Read(ref _cause) == CauseDeadline;
        }
    }

    public bool CancellationRequested => Volatile.Read(ref _cause) != CauseNone || Token.IsCancellationRequested;

    public bool RequestCancel()
    {
        if (Volatile.Read(ref _disposed) != 0)
            return false;

        MarkCause(CauseExplicit);
        try
        {
            _explicitCancellation.Cancel();
            return true;
        }
        catch (ObjectDisposedException)
        {
            return false;
        }
    }

    private void MarkCause(int cause) =>
        Interlocked.CompareExchange(ref _cause, cause, CauseNone);

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
            return;

        _requestRegistration.Dispose();
        _deadlineRegistration.Dispose();
        _linkedCancellation.Dispose();
        _deadlineCancellation?.Dispose();
        _explicitCancellation.Dispose();
    }
}