using Benchpilot.Core;

namespace Benchpilot.Runtime;

public static class BenchPreflight
{
    /// <summary>
    /// Runs non-destructive readiness checks once per physical resource bound to
    /// a semantic target. Composite resources are checked only once even when
    /// they provide multiple capabilities.
    /// </summary>
    public static async Task<TargetPreflightResult> Preflight(
        this BenchRuntime runtime,
        string? targetName = null,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(runtime);
        var target = runtime.Target(targetName);

        var resources = new Dictionary<string, BenchResourceConfig>(StringComparer.OrdinalIgnoreCase);
        foreach (var capability in target.Capabilities)
        {
            var binding = ProfileLoader.ResolveResource(runtime.Profile, capability, target.Id);
            resources.TryAdd(binding.ResourceId, binding.Resource);
        }

        var checks = new List<ResourcePreflightResult>(resources.Count);
        foreach (var (resourceId, config) in resources.OrderBy(x => x.Key, StringComparer.OrdinalIgnoreCase))
        {
            ct.ThrowIfCancellationRequested();
            var instance = runtime.Resources.Get<object>(resourceId);

            if (instance is not IResourceHealthCheck health)
            {
                checks.Add(new ResourcePreflightResult(
                    resourceId,
                    config.Driver,
                    config.Capabilities,
                    false,
                    "Driver does not implement a non-destructive health check.",
                    Error: $"Resource '{resourceId}' cannot be preflighted by driver '{config.Driver}'."));
                continue;
            }

            try
            {
                var result = await health.CheckHealth(ct);
                checks.Add(new ResourcePreflightResult(
                    resourceId,
                    config.Driver,
                    config.Capabilities,
                    result.Ok,
                    result.Summary,
                    result.Details,
                    result.Error));
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                checks.Add(new ResourcePreflightResult(
                    resourceId,
                    config.Driver,
                    config.Capabilities,
                    false,
                    "Health check failed with an unexpected driver error.",
                    Error: ex.Message));
            }
        }

        var ok = checks.Count > 0 && checks.All(x => x.Ok);
        return new TargetPreflightResult(
            ok,
            target.Id,
            target.Name,
            checks,
            ok ? null : "One or more target resources are not ready.");
    }
}
