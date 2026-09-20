namespace Benchpilot.Core;

/// <summary>
/// Optional non-destructive readiness check for a live bench resource.
/// Implementations must not power-cycle, reset, flash or otherwise mutate the
/// target. Preflight is intended to diagnose bench wiring/tool availability
/// before an Agent starts the real ECU loop.
/// </summary>
public interface IResourceHealthCheck
{
    Task<ResourceHealthResult> CheckHealth(CancellationToken ct = default);
}
