using System.ComponentModel;
using Benchpilot.Client;
using Benchpilot.Core;
using Benchpilot.Protocol;
using ModelContextProtocol.Server;

namespace Benchpilot.Mcp.Tools;

internal sealed class BenchTools
{
    private readonly BenchClient _client;
    public BenchTools(BenchClient client) => _client = client;

    [McpServerTool]
    [Description("Return the resident BenchPilot runtime status, semantic targets, capabilities and registered resources. Use this before operating an unfamiliar bench.")]
    public async Task<RuntimeStatusResult> BenchStatus() =>
        await _client.Status(CancellationToken.None);

    [McpServerTool]
    [Description("Run non-destructive readiness checks for all physical resources bound to a semantic target. Does not power-cycle, reset or flash the ECU.")]
    public async Task<TargetPreflightResult> BenchPreflight(
        [Description("Semantic target id. Omit to use defaultTarget when policy allows it.")] string? target = null) =>
        await _client.Preflight(target, CancellationToken.None);

    [McpServerTool]
    [Description("Validate whether a semantic target is ready for BenchPilot's minimum real-ECU loop. Checks power/serial/flash bindings, hardware-vs-simulator mode, safety policy, placeholders and non-destructive resource preflight. Returns actionable remediation and never powers, resets or flashes the ECU.")]
    public async Task<TargetReadinessResult> BenchValidate(
        [Description("Semantic target id. Real bench safety policy normally requires this explicitly.")] string? target = null) =>
        await _client.ValidateTargetReadiness(target, CancellationToken.None);
}
