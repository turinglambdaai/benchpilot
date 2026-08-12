using System.ComponentModel;
using Benchpilot.Core;
using ModelContextProtocol.Server;

namespace Benchpilot.Mcp.Tools;

// Programming channel (PRD §6.2). In the DEMO these are backed by the
// simulator; a future DAP-backed hardware driver (probe-rs / OpenOCD / J-Link)
// implements the same IFlashTarget behind the kernel.
internal sealed class FlashTools
{
    private readonly BenchKernel _kernel;
    public FlashTools(BenchKernel kernel) => _kernel = kernel;

    [McpServerTool]
    [Description("Flash firmware to the target. The target must be powered on first. Flashing reboots the device into the new firmware, which then streams its boot log over the serial console. Returns bytes written and duration.")]
    public async Task<FlashResult> Flash(
        [Description("Path to the firmware image, e.g. build/app.elf")] string firmware = "build/app.elf")
        => await _kernel.Flash.Flash(firmware, CancellationToken.None);

    [McpServerTool]
    [Description("Software-reset the target. Re-runs the boot sequence of the current firmware.")]
    public async Task<ResetResult> Reset()
        => await _kernel.Flash.Reset(CancellationToken.None);
}
