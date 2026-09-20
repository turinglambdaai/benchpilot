using System.ComponentModel;
using Benchpilot.Client;
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
}
