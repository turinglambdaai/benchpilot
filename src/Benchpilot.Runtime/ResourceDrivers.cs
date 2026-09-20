using Benchpilot.Core;

namespace Benchpilot.Runtime;

/// <summary>
/// Creates one live bench resource from its vendor-neutral profile entry.
/// Driver projects implement this interface; Runtime remains unaware of vendor
/// SDK types and RuntimeHost only composes factories.
/// </summary>
public interface IBenchResourceFactory
{
    string DriverName { get; }
    object Create(string resourceId, BenchResourceConfig config);
}

/// <summary>
/// Resolves profile driver names to factories and constructs one Runtime from
/// a declarative bench profile. Duplicate driver names are rejected so startup
/// behavior stays deterministic.
/// </summary>
public sealed class BenchDriverRegistry
{
    private readonly Dictionary<string, IBenchResourceFactory> _factories =
        new(StringComparer.OrdinalIgnoreCase);

    public BenchDriverRegistry(IEnumerable<IBenchResourceFactory> factories)
    {
        ArgumentNullException.ThrowIfNull(factories);
        foreach (var factory in factories)
            Register(factory);
    }

    public IReadOnlyCollection<string> DriverNames => _factories.Keys.ToArray();

    public void Register(IBenchResourceFactory factory)
    {
        ArgumentNullException.ThrowIfNull(factory);
        if (string.IsNullOrWhiteSpace(factory.DriverName))
            throw new ArgumentException("Resource factory DriverName cannot be empty.", nameof(factory));

        if (!_factories.TryAdd(factory.DriverName, factory))
            throw new InvalidOperationException(
                $"A resource factory for driver '{factory.DriverName}' is already registered.");
    }

    public object Create(string resourceId, BenchResourceConfig config)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(resourceId);
        ArgumentNullException.ThrowIfNull(config);

        if (!_factories.TryGetValue(config.Driver, out var factory))
        {
            var available = _factories.Count == 0
                ? "none"
                : string.Join(", ", _factories.Keys.Order(StringComparer.OrdinalIgnoreCase));
            throw new InvalidOperationException(
                $"Resource '{resourceId}' uses unsupported driver '{config.Driver}'. " +
                $"Available drivers: {available}.");
        }

        return factory.Create(resourceId, config)
            ?? throw new InvalidOperationException(
                $"Driver '{config.Driver}' returned null for resource '{resourceId}'.");
    }

    public BenchRuntime CreateRuntime(BenchProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        ProfileLoader.Validate(profile);

        var resources = new BenchResourceRegistry(profile);
        try
        {
            foreach (var (resourceId, config) in profile.Resources)
                resources.Register(resourceId, Create(resourceId, config));

            return new BenchRuntime(profile, resources);
        }
        catch
        {
            resources.Dispose();
            throw;
        }
    }
}
