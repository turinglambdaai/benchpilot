using System.ComponentModel;
using Benchpilot.Client;
using Benchpilot.Core;
using ModelContextProtocol.Server;

namespace Benchpilot.Mcp.Tools;

// Low-level programming tools remain available for the P0 loop. Professional
// UDS flashing will sit above this capability as a validated transaction/plan.
internal sealed class FlashTools
{
    private readonly BenchClient _client;
    public FlashTools(BenchClient client) => _client = client;

    [McpServerTool]
    [Description("Flash firmware to a target using its configured flash capability. Uses defaultTarget when target is omitted unless policy requires an explicit target.")]
    public async Task<FlashResult> Flash(
        [Description("Path to the firmware image, e.g. build/app.elf")] string firmware = "build/app.elf",
        [Description("Semantic target id. Omit to use defaultTarget when allowed.")] string? target = null)
        => await _client.Flash(firmware, target, CancellationToken.None);

    [McpServerTool]
    [Description("Reset the target through its configured flash/debug capability.")]
    public async Task<ResetResult> Reset(
        [Description("Semantic target id. Omit to use defaultTarget when allowed.")] string? target = null)
        => await _client.Reset(target, CancellationToken.None);
}
