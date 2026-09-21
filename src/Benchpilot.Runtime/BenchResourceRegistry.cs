using Benchpilot.Core;

namespace Benchpilot.Runtime;

/// <summary>
/// Owns live resource instances for one bench process. Device handles are
/// registered once and reused so all shells observe the same state. The
/// registry also owns resource lifetime and disposes driver instances when the
/// resident Runtime stops.
/// </summary>
public sealed class BenchResourceRegistry : IDisposable
{
    private readonly BenchProfile _profile;
    private readonly Dictionary<string, object> _instances =
        new(StringComparer.OrdinalIgnoreCase);
    private bool _disposed;

    public BenchResourceRegistry(BenchProfile profile)
    {
        _profile = profile ?? throw new ArgumentNullException(nameof(profile));
        ProfileLoader.Validate(profile);
    }

    public void Register(string resourceId, object instance)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentException.ThrowIfNullOrWhiteSpace(resourceId);
        ArgumentNullException.ThrowIfNull(instance);

        if (!_profile.Resources.ContainsKey(resourceId))
            throw new KeyNotFoundException(
                $"Cannot register resource '{resourceId}' because it is not declared in the bench profile.");

        if (!_instances.TryAdd(resourceId, instance))
            throw new InvalidOperationException(
                $"Resource '{resourceId}' is already registered in this runtime.");
    }

    public bool IsRegistered(string resourceId)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return _instances.ContainsKey(resourceId);
    }

    public IReadOnlyCollection<string> RegisteredResourceIds
    {
        get
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            return _instances.Keys.ToArray();
        }
    }

    public T Get<T>(string resourceId) where T : class
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (!_instances.TryGetValue(resourceId, out var instance))
            throw new InvalidOperationException(
                $"Resource '{resourceId}' is declared but has no live driver instance.");

        if (instance is not T typed)
            throw new InvalidOperationException(
                $"Resource '{resourceId}' does not implement {typeof(T).Name}. " +
                $"Actual type: {instance.GetType().Name}.");

        return typed;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        var disposed = new HashSet<object>(ReferenceEqualityComparer.Instance);
        foreach (var instance in _instances.Values.Reverse())
        {
            if (!disposed.Add(instance)) continue;
            if (instance is IDisposable disposable)
                disposable.Dispose();
        }

        _instances.Clear();
    }
}
