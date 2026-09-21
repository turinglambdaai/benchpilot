using System.Collections.Concurrent;
using Benchpilot.Core;

namespace Benchpilot.Runtime;

/// <summary>
/// Stateful runtime facade shared by CLI, MCP and Studio. It maps target-level
/// semantic capabilities onto long-lived resource instances and owns the
/// validation/safety boundary. Shells must not call hardware drivers directly.
/// </summary>
public sealed class BenchRuntime : IDisposable
{
    private const int OperationHistoryCapacity = 128;
    private const int ObservationHistoryCapacity = 128;
    private const int MaxHistoryErrorLength = 1000;

    private readonly ConcurrentDictionary<string, SemaphoreSlim> _mutationGates =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, ActiveMutation> _activeOperations =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, ActiveObservation> _activeObservations =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly object _historySync = new();
    private readonly Queue<BenchOperationRecord> _operationHistory = new();
    private readonly object _observationHistorySync = new();
    private readonly Queue<BenchObservationRecord> _observationHistory = new();
    private readonly OperationEvidenceStore _evidence = new();
    private readonly ObservationEvidenceStore _observationEvidence = new();
    private bool _disposed;

    public BenchProfile Profile { get; }
    public BenchResourceRegistry Resources { get; }

    public BenchRuntime(BenchProfile profile, BenchResourceRegistry resources)
    {
        Profile = profile ?? throw new ArgumentNullException(nameof(profile));
        Resources = resources ?? throw new ArgumentNullException(nameof(resources));
        ProfileLoader.Validate(profile);
    }

    public IReadOnlyList<BenchOperationInfo> ActiveOperations
    {
        get
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            return _activeOperations.Values
                .Select(x => x.Snapshot())
                .OrderBy(x => x.StartedAtUtc)
                .ThenBy(x => x.Id, StringComparer.OrdinalIgnoreCase)
                .ToArray();
        }
    }

    public IReadOnlyList<BenchObservationInfo> ActiveObservations
    {
        get
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            return _activeObservations.Values
                .Select(x => x.Snapshot())
                .OrderBy(x => x.StartedAtUtc)
                .ThenBy(x => x.Id, StringComparer.OrdinalIgnoreCase)
                .ToArray();
        }
    }

    public IReadOnlyList<BenchOperationRecord> RecentOperations(int limit = 50)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (limit is < 1 or > OperationHistoryCapacity)
            throw new BenchValidationException(
                $"Operation history limit must be between 1 and {OperationHistoryCapacity}.");

        lock (_historySync)
        {
            return _operationHistory
                .Reverse()
                .Take(limit)
                .ToArray();
        }
    }

    public IReadOnlyList<BenchObservationRecord> RecentObservations(int limit = 50)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (limit is < 1 or > ObservationHistoryCapacity)
            throw new BenchValidationException(
                $"Observation history limit must be between 1 and {ObservationHistoryCapacity}.");

        lock (_observationHistorySync)
        {
            return _observationHistory
                .Reverse()
                .Take(limit)
                .ToArray();
        }
    }

    public BenchOperationEvidence? GetOperationEvidence(string operationId)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentException.ThrowIfNullOrWhiteSpace(operationId);
        return _evidence.Get(operationId);
    }

    public BenchObservationEvidence? GetObservationEvidence(string observationId)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentException.ThrowIfNullOrWhiteSpace(observationId);
        return _observationEvidence.Get(observationId);
    }

    public bool CancelOperation(string operationId)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentException.ThrowIfNullOrWhiteSpace(operationId);
        return _activeOperations.TryGetValue(operationId, out var active)
            && active.RequestCancel();
    }

    public bool CancelObservation(string observationId)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentException.ThrowIfNullOrWhiteSpace(observationId);
        return _activeObservations.TryGetValue(observationId, out var active)
            && active.RequestCancel();
    }

    public BenchTarget Target(string? targetName = null)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (Profile.Safety.RequireExplicitTarget && string.IsNullOrWhiteSpace(targetName))
            throw new BenchValidationException(
                "This bench requires an explicit target for every operation.");

        var resolvedName = string.IsNullOrWhiteSpace(targetName)
            ? Profile.DefaultTarget
            : targetName;

        if (string.IsNullOrWhiteSpace(resolvedName))
            throw new BenchValidationException(
                "No target was specified and the bench profile has no default target.");

        try
        {
            var target = ProfileLoader.ResolveTarget(Profile, resolvedName);
            return new BenchTarget(this, resolvedName, target);
        }
        catch (KeyNotFoundException ex)
        {
            throw new BenchTargetNotFoundException(ex.Message);
        }
    }

    internal async Task<T> RunMutation<T>(
        string targetId,
        string operation,
        IReadOnlyCollection<string> resourceIds,
        Func<CancellationToken, Task<T>> action,
        CancellationToken requestCancellation,
        int? deadlineMs = null)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentException.ThrowIfNullOrWhiteSpace(targetId);
        ArgumentException.ThrowIfNullOrWhiteSpace(operation);
        ArgumentNullException.ThrowIfNull(resourceIds);
        ArgumentNullException.ThrowIfNull(action);
        ValidateDeadline(deadlineMs);
        requestCancellation.ThrowIfCancellationRequested();

        var normalizedResources = resourceIds
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(x => x, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        // Target ownership is the primary semantic boundary, so acquire it
        // first. Resource gates follow in deterministic order. Acquisition is
        // non-blocking; if any later gate is busy we immediately release what
        // we already acquired, so there is no wait-cycle/deadlock risk.
        var requests = new List<MutationGateRequest>
        {
            new($"target:{targetId}", "target", targetId),
        };
        requests.AddRange(normalizedResources.Select(resourceId => new MutationGateRequest(
            $"resource:{resourceId}",
            "resource",
            resourceId)));

        var acquired = new List<SemaphoreSlim>(requests.Count);
        ActiveMutation? active = null;
        try
        {
            foreach (var request in requests)
            {
                requestCancellation.ThrowIfCancellationRequested();
                var gate = _mutationGates.GetOrAdd(
                    request.Key,
                    static _ => new SemaphoreSlim(1, 1));

                if (!await gate.WaitAsync(0, requestCancellation))
                {
                    var owner = FindOwner(request.Scope, request.Id);
                    throw new BenchBusyException(
                        targetId,
                        operation,
                        request.Scope,
                        request.Id,
                        owner?.Id,
                        owner?.Kind);
                }

                acquired.Add(gate);
            }

            var operationId = Guid.NewGuid().ToString("N");
            active = new ActiveMutation(
                operationId,
                targetId,
                operation,
                normalizedResources,
                DateTimeOffset.UtcNow,
                requestCancellation,
                deadlineMs);

            if (!_activeOperations.TryAdd(operationId, active))
                throw new InvalidOperationException($"Could not register active operation '{operationId}'.");

            try
            {
                var result = await action(active.Token);
                // Preserve the existing compatibility contract for a driver that
                // ignores caller/drain cancellation and eventually returns. A
                // Runtime deadline is different: once its wall-clock budget has
                // expired, a late success is never accepted.
                if (active.DeadlineExceeded)
                    throw new OperationCanceledException(active.Token);
                RecordEvidence(active, OperationEvidenceExtractor.FromResult(result));
                RecordOperation(active, "completed", null);
                return result;
            }
            catch (OperationCanceledException) when (active.DeadlineExceeded)
            {
                var deadline = active.CreateDeadlineException();
                RecordEvidence(
                    active,
                    OperationEvidenceExtractor.FromDeadline(
                        deadline.DeadlineMs,
                        deadline.DeadlineAtUtc));
                RecordOperation(active, "deadline_exceeded", deadline.Message);
                throw deadline;
            }
            catch (OperationCanceledException)
            {
                RecordEvidence(active, OperationEvidenceExtractor.FromCancellation());
                RecordOperation(active, "cancelled", "Operation cancelled.");
                throw;
            }
            catch (Exception ex)
            {
                RecordEvidence(active, OperationEvidenceExtractor.FromException(ex));
                RecordOperation(active, "faulted", BoundHistoryError(ex.Message));
                throw;
            }
        }
        finally
        {
            if (active is not null)
            {
                _activeOperations.TryRemove(active.Id, out _);
                active.Dispose();
            }

            for (var i = acquired.Count - 1; i >= 0; i--)
                acquired[i].Release();
        }
    }

    /// <summary>
    /// Runs a non-mutating observation without taking target/resource mutation
    /// gates. Observations can therefore run alongside flash/power operations,
    /// while still receiving identity, cancellation, deadline, history and
    /// bounded evidence owned by the resident Runtime.
    /// </summary>
    internal async Task<T> RunObservation<T>(
        string targetId,
        string observation,
        IReadOnlyCollection<string> resourceIds,
        Func<string, CancellationToken, Task<ObservationExecution<T>>> action,
        CancellationToken requestCancellation,
        int? deadlineMs = null)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentException.ThrowIfNullOrWhiteSpace(targetId);
        ArgumentException.ThrowIfNullOrWhiteSpace(observation);
        ArgumentNullException.ThrowIfNull(resourceIds);
        ArgumentNullException.ThrowIfNull(action);
        ValidateDeadline(deadlineMs);
        requestCancellation.ThrowIfCancellationRequested();

        var normalizedResources = resourceIds
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(x => x, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var observationId = Guid.NewGuid().ToString("N");
        var active = new ActiveObservation(
            observationId,
            targetId,
            observation,
            normalizedResources,
            DateTimeOffset.UtcNow,
            requestCancellation,
            deadlineMs);

        if (!_activeObservations.TryAdd(observationId, active))
        {
            active.Dispose();
            throw new InvalidOperationException($"Could not register active observation '{observationId}'.");
        }

        try
        {
            var execution = await action(observationId, active.Token);
            if (active.DeadlineExceeded)
                throw new OperationCanceledException(active.Token);
            RecordObservationEvidence(active, execution.Evidence);
            RecordObservation(active, "completed", null);
            return execution.Result;
        }
        catch (OperationCanceledException) when (active.DeadlineExceeded)
        {
            var deadline = active.CreateDeadlineException();
            RecordObservationEvidence(
                active,
                SerialObservationEvidenceExtractor.FromDeadline(
                    deadline.DeadlineMs,
                    deadline.DeadlineAtUtc));
            RecordObservation(active, "deadline_exceeded", deadline.Message);
            throw deadline;
        }
        catch (OperationCanceledException)
        {
            RecordObservationEvidence(active, SerialObservationEvidenceExtractor.FromCancellation());
            RecordObservation(active, "cancelled", "Observation cancelled.");
            throw;
        }
        catch (Exception ex)
        {
            RecordObservationEvidence(active, SerialObservationEvidenceExtractor.FromException(ex));
            RecordObservation(active, "faulted", BoundHistoryError(ex.Message));
            throw;
        }
        finally
        {
            _activeObservations.TryRemove(observationId, out _);
            active.Dispose();
        }
    }

    /// <summary>
    /// Runs a safety action without taking target/resource mutation gates. The
    /// action is intentionally not cancellable once accepted, but it is still
    /// assigned an operation id and written to bounded audit/evidence stores.
    /// Emergency safety actions deliberately do not accept Runtime deadlines.
    /// </summary>
    internal async Task<T> RunUngatedSafetyOperation<T>(
        string targetId,
        string operation,
        IReadOnlyCollection<string> resourceIds,
        Func<Task<T>> action)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentException.ThrowIfNullOrWhiteSpace(targetId);
        ArgumentException.ThrowIfNullOrWhiteSpace(operation);
        ArgumentNullException.ThrowIfNull(resourceIds);
        ArgumentNullException.ThrowIfNull(action);

        var normalizedResources = resourceIds
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(x => x, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var operationId = Guid.NewGuid().ToString("N");
        var startedAt = DateTimeOffset.UtcNow;

        try
        {
            var result = await action();
            RecordEvidence(
                operationId,
                targetId,
                operation,
                normalizedResources,
                OperationEvidenceExtractor.FromResult(result));
            RecordOperation(
                operationId,
                targetId,
                operation,
                normalizedResources,
                startedAt,
                null,
                "completed",
                null);
            return result;
        }
        catch (Exception ex)
        {
            RecordEvidence(
                operationId,
                targetId,
                operation,
                normalizedResources,
                OperationEvidenceExtractor.FromException(ex));
            RecordOperation(
                operationId,
                targetId,
                operation,
                normalizedResources,
                startedAt,
                null,
                "faulted",
                BoundHistoryError(ex.Message));
            throw;
        }
    }

    private BenchOperationInfo? FindOwner(string scope, string id)
    {
        foreach (var active in _activeOperations.Values)
        {
            var snapshot = active.Snapshot();
            if (string.Equals(scope, "target", StringComparison.OrdinalIgnoreCase)
                && string.Equals(snapshot.TargetId, id, StringComparison.OrdinalIgnoreCase))
            {
                return snapshot;
            }

            if (string.Equals(scope, "resource", StringComparison.OrdinalIgnoreCase)
                && snapshot.ResourceIds.Contains(id, StringComparer.OrdinalIgnoreCase))
            {
                return snapshot;
            }
        }

        return null;
    }

    private void RecordEvidence(
        ActiveMutation active,
        IReadOnlyList<BenchEvidenceItem> items) =>
        RecordEvidence(
            active.Id,
            active.TargetId,
            active.Kind,
            active.ResourceIds,
            items);

    private void RecordEvidence(
        string operationId,
        string targetId,
        string operation,
        IReadOnlyList<string> resourceIds,
        IReadOnlyList<BenchEvidenceItem> items) =>
        _evidence.Put(operationId, targetId, operation, resourceIds, items);

    private void RecordObservationEvidence(
        ActiveObservation active,
        IReadOnlyList<BenchEvidenceItem> items) =>
        _observationEvidence.Put(
            active.Id,
            active.TargetId,
            active.Kind,
            active.ResourceIds,
            items);

    private void RecordOperation(ActiveMutation active, string state, string? error) =>
        RecordOperation(
            active.Id,
            active.TargetId,
            active.Kind,
            active.ResourceIds,
            active.StartedAtUtc,
            active.DeadlineAtUtc,
            state,
            error);

    private void RecordOperation(
        string operationId,
        string targetId,
        string kind,
        IReadOnlyList<string> resourceIds,
        DateTimeOffset startedAt,
        DateTimeOffset? deadlineAtUtc,
        string state,
        string? error)
    {
        var completedAt = DateTimeOffset.UtcNow;
        var durationMs = DurationMs(startedAt, completedAt);
        var record = new BenchOperationRecord(
            operationId,
            targetId,
            kind,
            resourceIds,
            startedAt,
            completedAt,
            durationMs,
            deadlineAtUtc,
            state,
            error);

        lock (_historySync)
        {
            _operationHistory.Enqueue(record);
            while (_operationHistory.Count > OperationHistoryCapacity)
                _operationHistory.Dequeue();
        }
    }

    private void RecordObservation(ActiveObservation active, string state, string? error)
    {
        var completedAt = DateTimeOffset.UtcNow;
        var record = new BenchObservationRecord(
            active.Id,
            active.TargetId,
            active.Kind,
            active.ResourceIds,
            active.StartedAtUtc,
            completedAt,
            DurationMs(active.StartedAtUtc, completedAt),
            active.DeadlineAtUtc,
            state,
            error);

        lock (_observationHistorySync)
        {
            _observationHistory.Enqueue(record);
            while (_observationHistory.Count > ObservationHistoryCapacity)
                _observationHistory.Dequeue();
        }
    }

    private static void ValidateDeadline(int? deadlineMs)
    {
        if (deadlineMs is <= 0)
            throw new BenchValidationException("Runtime deadlineMs must be greater than zero.");
    }

    private static int DurationMs(DateTimeOffset startedAt, DateTimeOffset completedAt) =>
        (int)Math.Min(
            int.MaxValue,
            Math.Max(0, (completedAt - startedAt).TotalMilliseconds));

    private static string? BoundHistoryError(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return value;
        return value.Length <= MaxHistoryErrorLength
            ? value
            : value[..MaxHistoryErrorLength];
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        foreach (var active in _activeOperations.Values)
            active.RequestCancel();
        foreach (var active in _activeObservations.Values)
            active.RequestCancel();

        Resources.Dispose();

        foreach (var active in _activeOperations.Values)
            active.Dispose();
        _activeOperations.Clear();
        foreach (var active in _activeObservations.Values)
            active.Dispose();
        _activeObservations.Clear();

        foreach (var gate in _mutationGates.Values)
            gate.Dispose();
        _mutationGates.Clear();
    }

    private sealed record MutationGateRequest(string Key, string Scope, string Id);

    private sealed class ActiveMutation : IDisposable
    {
        private readonly RuntimeExecutionCancellation _cancellation;

        public ActiveMutation(
            string id,
            string targetId,
            string kind,
            IReadOnlyList<string> resourceIds,
            DateTimeOffset startedAtUtc,
            CancellationToken requestCancellation,
            int? deadlineMs)
        {
            Id = id;
            TargetId = targetId;
            Kind = kind;
            ResourceIds = resourceIds;
            StartedAtUtc = startedAtUtc;
            _cancellation = new RuntimeExecutionCancellation(
                requestCancellation,
                deadlineMs,
                startedAtUtc);
        }

        public string Id { get; }
        public string TargetId { get; }
        public string Kind { get; }
        public IReadOnlyList<string> ResourceIds { get; }
        public DateTimeOffset StartedAtUtc { get; }
        public int? DeadlineMs => _cancellation.DeadlineMs;
        public DateTimeOffset? DeadlineAtUtc => _cancellation.DeadlineAtUtc;
        public bool DeadlineExceeded => _cancellation.DeadlineExceeded;
        public CancellationToken Token => _cancellation.Token;

        public BenchOperationInfo Snapshot() =>
            new(
                Id,
                TargetId,
                Kind,
                ResourceIds,
                StartedAtUtc,
                DeadlineAtUtc,
                _cancellation.CancellationRequested,
                DeadlineExceeded);

        public bool RequestCancel() => _cancellation.RequestCancel();

        public BenchDeadlineExceededException CreateDeadlineException() =>
            new(
                TargetId,
                Kind,
                DeadlineMs ?? throw new InvalidOperationException("Deadline metadata is unavailable."),
                DeadlineAtUtc ?? throw new InvalidOperationException("Deadline metadata is unavailable."));

        public void Dispose() => _cancellation.Dispose();
    }

    private sealed class ActiveObservation : IDisposable
    {
        private readonly RuntimeExecutionCancellation _cancellation;

        public ActiveObservation(
            string id,
            string targetId,
            string kind,
            IReadOnlyList<string> resourceIds,
            DateTimeOffset startedAtUtc,
            CancellationToken requestCancellation,
            int? deadlineMs)
        {
            Id = id;
            TargetId = targetId;
            Kind = kind;
            ResourceIds = resourceIds;
            StartedAtUtc = startedAtUtc;
            _cancellation = new RuntimeExecutionCancellation(
                requestCancellation,
                deadlineMs,
                startedAtUtc);
        }

        public string Id { get; }
        public string TargetId { get; }
        public string Kind { get; }
        public IReadOnlyList<string> ResourceIds { get; }
        public DateTimeOffset StartedAtUtc { get; }
        public int? DeadlineMs => _cancellation.DeadlineMs;
        public DateTimeOffset? DeadlineAtUtc => _cancellation.DeadlineAtUtc;
        public bool DeadlineExceeded => _cancellation.DeadlineExceeded;
        public CancellationToken Token => _cancellation.Token;

        public BenchObservationInfo Snapshot() =>
            new(
                Id,
                TargetId,
                Kind,
                ResourceIds,
                StartedAtUtc,
                DeadlineAtUtc,
                _cancellation.CancellationRequested,
                DeadlineExceeded);

        public bool RequestCancel() => _cancellation.RequestCancel();

        public BenchDeadlineExceededException CreateDeadlineException() =>
            new(
                TargetId,
                Kind,
                DeadlineMs ?? throw new InvalidOperationException("Deadline metadata is unavailable."),
                DeadlineAtUtc ?? throw new InvalidOperationException("Deadline metadata is unavailable."));

        public void Dispose() => _cancellation.Dispose();
    }
}