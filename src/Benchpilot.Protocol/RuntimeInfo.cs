using System.Reflection;

namespace Benchpilot.Protocol;

/// <summary>
/// Product version reported by every shell (benchpilotd, benchpilot,
/// benchpilot-mcp). All projects share one VersionPrefix, so the entry
/// assembly version is the product version for whichever process asks.
/// </summary>
public static class BenchpilotRuntimeInfo
{
    public static string Version { get; } =
        Assembly.GetEntryAssembly()?.GetName().Version?.ToString(3) ?? "0.0.0";
}
