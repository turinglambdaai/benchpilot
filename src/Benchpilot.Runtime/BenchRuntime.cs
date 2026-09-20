using Benchpilot.Core;

namespace Benchpilot.Runtime;

/// <summary>
/// Owns live resource instances for one bench process. Device handles are
/// registered once and reused so all shells observe the same state.
/// </summary>
public sealed class BenchResourceRegistry
{
    private readonly BenchProfile _profile;
    private readonly Dictionary<string, object> _instances =
        new(StringComparer.OrdinalIgnoreCase);

    public BenchResourceRegistry(BenchProfile profile)
    {
        _profile = profile ?? throw new ArgumentNullException(nameof(profile));
        ProfileLoader.Validate(profile);
    }

    public void Register(string resourceId, object instance)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(resourceId);
        ArgumentNullException.ThrowIfNull(instance);

        if (!_profile.Resources.ContainsKey(resourceId))
            throw new KeyNotFoundException(
                $"Cannot register resource '{resourceId}' because it is not declared in the bench profile.");

        if (!_instances.TryAdd(resourceId, instance))
            throw new InvalidOperationException(
                $"Resource '{resourceId}' is already registered in this runtime.");
    }

    public bool IsRegistered(string resourceId) => _instances.ContainsKey(resourceId);

    public T Get<T>(string resourceId) where T : class
    {
        if (!_instances.TryGetValue(resourceId, out var instance))
            throw new InvalidOperationException(
                $"Resource '{resourceId}' is declared but has no live driver instance.");

        if (instance is not T typed)
            throw new InvalidOperationException(
                $"Resource '{resourceId}' does not implement {typeof(T).Name}. " +
                $"Actual type: {instance.GetType().Name}.");

        return typed;
    }
}

/// <summary>
/// Stateful runtime facade shared by CLI, MCP and the future Studio. It maps
/// target-level semantic capabilities onto long-lived resource instances.
/// </summary>
public sealed class BenchRuntime
{
    public BenchProfile Profile { get; }
    public BenchResourceRegistry Resources { get; }

    public BenchRuntime(BenchProfile profile, BenchResourceRegistry resources)
    {
        Profile = profile ?? throw new ArgumentNullException(nameof(profile));
        Resources = resources ?? throw new ArgumentNullException(nameof(resources));
        ProfileLoader.Validate(profile);
    }

    public BenchTarget Target(string? targetName = null)
    {
        var resolvedName = string.IsNullOrWhiteSpace(targetName)
            ? Profile.DefaultTarget
            : targetName;

        if (string.IsNullOrWhiteSpace(resolvedName))
            throw new InvalidOperationException(
                "No target was specified and the bench profile has no default target.");

        var target = ProfileLoader.ResolveTarget(Profile, resolvedName);
        return new BenchTarget(this, resolvedName, target);
    }
}

/// <summary>
/// A target-oriented view over Runtime. Callers request a semantic capability
/// and never need to know which OS device/vendor adapter provides it.
/// </summary>
public sealed class BenchTarget
{
    private readonly BenchRuntime _runtime;
    private readonly BenchTargetConfig _config;

    internal BenchTarget(BenchRuntime runtime, string id, BenchTargetConfig config)
    {
        _runtime = runtime;
        Id = id;
        _config = config;
    }

    public string Id { get; }
    public string Name => string.IsNullOrWhiteSpace(_config.Name) ? Id : _config.Name;
    public string? Mcu => _config.Mcu;

    public bool HasCapability(string capability) =>
        _config.Bindings.ContainsKey(capability);

    public T Capability<T>(string capability) where T : class
    {
        var binding = ProfileLoader.ResolveResource(_runtime.Profile, capability, Id);
        return _runtime.Resources.Get<T>(binding.ResourceId);
    }
}
