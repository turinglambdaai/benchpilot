using System.ComponentModel;
using Benchpilot.Core;
using ModelContextProtocol.Server;

namespace Benchpilot.Mcp.Tools;

// Power channel (PRD §6.1). The bench supply is the loop's pacemaker:
// power_on -> flash -> observe -> power_off. Method names map to snake_case
// tool names automatically (PowerOn -> power_on).
internal sealed class PowerTools
{
    private readonly BenchKernel _kernel;
    public PowerTools(BenchKernel kernel) => _kernel = kernel;

    [McpServerTool]
    [Description("Power on the bench supply at the given voltage, then wait for it to settle. Returns the settled current draw in mA. Idempotent: a no-op if already on.")]
    public async Task<PowerOnResult> PowerOn(
        [Description("Supply voltage in volts, e.g. 12")] double voltage = 12,
        [Description("Settle window in milliseconds before reporting current")] int settleMs = 2000)
        => await _kernel.Power.PowerOn(voltage, settleMs, CancellationToken.None);

    [McpServerTool]
    [Description("Switch off the bench supply.")]
    public async Task<PowerOffResult> PowerOff()
        => await _kernel.Power.PowerOff(CancellationToken.None);

    [McpServerTool]
    [Description("Sample current draw over a window and return avg / peak / raw samples in mA.")]
    public async Task<CurrentReading> ReadCurrent(
        [Description("Sampling window in milliseconds")] int windowMs = 500)
        => await _kernel.Power.ReadCurrent(windowMs, CancellationToken.None);

    [McpServerTool]
    [Description("Check current draw against a threshold. Pass lt (less-than) or gt (greater-than) in mA; returns whether it passed. Use this to verify low-power / sleep current targets.")]
    public async Task<CurrentCheck> CheckCurrent(
        [Description("Pass if current (mA) is below this, e.g. 100 for an idle check")] double? lt = null,
        [Description("Pass if current (mA) is above this")] double? gt = null)
        => await _kernel.Power.CheckCurrent(lt, gt, CancellationToken.None);
}
