using System.ComponentModel;
using Benchpilot.Client;
using Benchpilot.Core;
using Benchpilot.Protocol;
using ModelContextProtocol.Server;

namespace Benchpilot.Mcp.Tools;

// Diagnostics tools: raw UDS escape, DID reads and the destructive UDS flash
// workflow. MCP never touches CAN or Ethernet itself; benchpilotd owns the
// resident diagnostic channel (ISO-TP/CAN or DoIP).
internal sealed class DiagTools
{
    private readonly BenchClient _client;
    public DiagTools(BenchClient client) => _client = client;

    [McpServerTool]
    [Description("Send one raw UDS request to a target's diagnostic channel and return the decoded outcome (positive response hex or negative response code). Expert escape hatch: prefer semantic tools when they exist. Example hex: '10 03' enters extended session, '22 F1 95' reads a version DID.")]
    public async Task<UdsRequestResult> UdsRequest(
        [Description("Request bytes as hex, for example '10 03'")] string requestHex,
        [Description("P2 timeout in milliseconds for the first response.")] int? p2TimeoutMs = null,
        [Description("P2* timeout in milliseconds while NRC 0x78 keeps arriving.")] int? p2StarTimeoutMs = null,
        [Description("Semantic target id. Omit to use defaultTarget when allowed.")] string? target = null)
        => await _client.UdsRequest(requestHex, p2TimeoutMs, p2StarTimeoutMs, target, CancellationToken.None);

    [McpServerTool]
    [Description("Read one UDS data identifier (DID) from a target. Returns the raw response bytes; decode with the ECU's DID table.")]
    public async Task<UdsRequestResult> UdsReadDid(
        [Description("DID as a number or hex, for example '0xF195'")] string did,
        [Description("Semantic target id. Omit to use defaultTarget when allowed.")] string? target = null)
        => await _client.UdsRequest($"22{(int.Parse(did.Replace("0x", ""), System.Globalization.NumberStyles.HexNumber)):X4}".ToLowerInvariant(), null, null, target, CancellationToken.None);

    [McpServerTool]
    [Description("DESTRUCTIVE: execute the UDS flash workflow (session, security access, erase routine, download, verify routine, ECU reset) over the target's diagnostic channel (ISO-TP over CAN, or DoIP). Requires confirmTarget to match the target id when the profile enables destructive confirmation. The firmware must be a raw binary image; use planPath for multi-segment layouts.")]
    public async Task<UdsFlashResult> UdsFlash(
        [Description("Path to the firmware image (raw binary)")] string firmware,
        [Description("Flash start address, for example '0x08000000'. Required unless planPath is given.")] string? address = null,
        [Description("Path to a JSON flash plan for multi-segment images.")] string? planPath = null,
        [Description("Semantic target id. Omit to use defaultTarget when allowed.")] string? target = null,
        [Description("Must match the resolved target id when destructive confirmation is enabled.")] string? confirmTarget = null,
        [Description("Optional Runtime execution deadline in milliseconds.")] int? deadlineMs = null)
    {
        long? addressValue = null;
        if (!string.IsNullOrWhiteSpace(address))
        {
            var text = address.Trim();
            if (text.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
                addressValue = long.Parse(text[2..], System.Globalization.NumberStyles.HexNumber);
            else
                addressValue = long.Parse(text);
        }

        return await _client.UdsFlash(
            firmware,
            planPath,
            addressValue,
            null,
            confirmTarget,
            target,
            deadlineMs,
            CancellationToken.None);
    }

    [McpServerTool]
    [Description("Discover DoIP entities (vehicles) on the local network via UDP broadcast. Returns VIN, logical address and IP. Use the IP in a doip resource profile.")]
    public async Task<DoipDiscoveryResult> DoipDiscover(
        [Description("Discovery window in milliseconds")] int windowMs = 800)
        => await _client.DoipDiscover(windowMs, CancellationToken.None);
}
