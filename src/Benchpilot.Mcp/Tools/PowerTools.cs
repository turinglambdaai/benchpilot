using System.ComponentModel;
using Benchpilot.Client;
using Benchpilot.Core;
using ModelContextProtocol.Server;

namespace Benchpilot.Mcp.Tools;

// Agent-facing power tools are thin IPC calls into benchpilotd. The daemon owns
// device handles, validation and safety policy so MCP cannot bypass Runtime.
internal sealed class PowerTools
{
    private readonly BenchClient _client;
    public PowerTools(BenchClient client) => _client = client;

    [McpServerTool]
    [Description("Power on a target at the given voltage, then wait for the supply to settle. Uses the profile default target when target is omitted unless policy requires an explicit target.")]
    public async Task<PowerOnResult> PowerOn(
        [Description("Supply voltage in volts, e.g. 12")] double voltage = 12,
        [Description("Settle window in milliseconds before reporting current")] int settleMs = 2000,
        [Description("Semantic target id, e.g. 'radar'. Omit to use defaultTarget when allowed.")] string? target = null)
        => await _client.PowerOn(voltage, settleMs, target, CancellationToken.None);

    [McpServerTool]
    [Description("Switch off the target's bench supply.")]
    public async Task<PowerOffResult> PowerOff(
        [Description("Semantic target id. Omit to use defaultTarget when allowed.")] string? target = null)
        => await _client.PowerOff(target, CancellationToken.None);

    [McpServerTool]
    [Description("Sample target current draw over a bounded window and return avg / peak / raw samples in mA.")]
    public async Task<CurrentReading> ReadCurrent(
        [Description("Sampling window in milliseconds")] int windowMs = 500,
        [Description("Semantic target id. Omit to use defaultTarget when allowed.")] string? target = null)
        => await _client.ReadCurrent(windowMs, target, CancellationToken.None);

    [McpServerTool]
    [Description("Check target current draw against a threshold. Pass lt or gt in mA and receive a bounded assertion result.")]
    public async Task<CurrentCheck> CheckCurrent(
        [Description("Pass if current (mA) is below this, e.g. 100 for an idle check")] double? lt = null,
        [Description("Pass if current (mA) is above this")] double? gt = null,
        [Description("Semantic target id. Omit to use defaultTarget when allowed.")] string? target = null)
        => await _client.CheckCurrent(lt, gt, target, CancellationToken.None);
}
