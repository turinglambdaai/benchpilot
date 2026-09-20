using System.ComponentModel;
using Benchpilot.Core;
using Benchpilot.Runtime;
using ModelContextProtocol.Server;

namespace Benchpilot.Mcp.Tools;

// Agent-facing power tools operate on semantic targets. Runtime resolves the
// target's "power" capability to the live resource instance.
internal sealed class PowerTools
{
    private readonly BenchRuntime _runtime;
    public PowerTools(BenchRuntime runtime) => _runtime = runtime;

    private IPowerSupply Power(string? target) =>
        _runtime.Target(target).Capability<IPowerSupply>("power");

    [McpServerTool]
    [Description("Power on a target at the given voltage, then wait for the supply to settle. Uses the profile default target when target is omitted.")]
    public async Task<PowerOnResult> PowerOn(
        [Description("Supply voltage in volts, e.g. 12")] double voltage = 12,
        [Description("Settle window in milliseconds before reporting current")] int settleMs = 2000,
        [Description("Semantic target id, e.g. 'radar'. Omit to use defaultTarget.")] string? target = null)
        => await Power(target).PowerOn(voltage, settleMs, CancellationToken.None);

    [McpServerTool]
    [Description("Switch off the target's bench supply.")]
    public async Task<PowerOffResult> PowerOff(
        [Description("Semantic target id. Omit to use defaultTarget.")] string? target = null)
        => await Power(target).PowerOff(CancellationToken.None);

    [McpServerTool]
    [Description("Sample target current draw over a bounded window and return avg / peak / raw samples in mA.")]
    public async Task<CurrentReading> ReadCurrent(
        [Description("Sampling window in milliseconds")] int windowMs = 500,
        [Description("Semantic target id. Omit to use defaultTarget.")] string? target = null)
        => await Power(target).ReadCurrent(windowMs, CancellationToken.None);

    [McpServerTool]
    [Description("Check target current draw against a threshold. Pass lt or gt in mA and receive a bounded assertion result.")]
    public async Task<CurrentCheck> CheckCurrent(
        [Description("Pass if current (mA) is below this, e.g. 100 for an idle check")] double? lt = null,
        [Description("Pass if current (mA) is above this")] double? gt = null,
        [Description("Semantic target id. Omit to use defaultTarget.")] string? target = null)
        => await Power(target).CheckCurrent(lt, gt, CancellationToken.None);
}
