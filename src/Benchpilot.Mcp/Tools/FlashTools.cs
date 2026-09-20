using System.ComponentModel;
using Benchpilot.Core;
using Benchpilot.Runtime;
using ModelContextProtocol.Server;

namespace Benchpilot.Mcp.Tools;

// Low-level programming tools remain available for the P0 loop. Professional
// UDS flashing will sit above this capability as a validated transaction/plan.
internal sealed class FlashTools
{
    private readonly BenchRuntime _runtime;
    public FlashTools(BenchRuntime runtime) => _runtime = runtime;

    [McpServerTool]
    [Description("Flash firmware to a target using its configured flash capability. Uses defaultTarget when target is omitted unless policy requires an explicit target.")]
    public async Task<FlashResult> Flash(
        [Description("Path to the firmware image, e.g. build/app.elf")] string firmware = "build/app.elf",
        [Description("Semantic target id. Omit to use defaultTarget when allowed.")] string? target = null)
        => await _runtime.Target(target).Flash(firmware, CancellationToken.None);

    [McpServerTool]
    [Description("Reset the target through its configured flash/debug capability.")]
    public async Task<ResetResult> Reset(
        [Description("Semantic target id. Omit to use defaultTarget when allowed.")] string? target = null)
        => await _runtime.Target(target).Reset(CancellationToken.None);
}
