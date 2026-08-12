namespace Benchpilot.Core;

// Programming channel (PRD §6.2). A real probe backend (probe-rs / OpenOCD /
// J-Link) implements this; the DEMO simulator stands in for it. This is the
// seam where a future DAP-backed hardware driver plugs in.
public interface IFlashTarget
{
    Task<FlashResult> Flash(string firmwarePath, CancellationToken ct = default);
    Task<ResetResult> Reset(CancellationToken ct = default);
}
