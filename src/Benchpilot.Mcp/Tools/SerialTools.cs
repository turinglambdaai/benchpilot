using System.ComponentModel;
using Benchpilot.Client;
using Benchpilot.Core;
using ModelContextProtocol.Server;

namespace Benchpilot.Mcp.Tools;

// Serial remains the first context-compressed observation channel. MCP never
// opens a COM/tty handle itself; benchpilotd owns the live serial resource.
internal sealed class SerialTools
{
    private readonly BenchClient _client;
    public SerialTools(BenchClient client) => _client = client;

    [McpServerTool]
    [Description("Open a target's serial console using the resource profile. Port/baud overrides are optional expert controls; Agents normally only specify the semantic target.")]
    public async Task<SerialOpenResult> SerialOpen(
        [Description("Optional OS serial-port override. Omit to use the target resource profile.")] string? port = null,
        [Description("Optional baud-rate override. Omit to use the target resource profile.")] int? baud = null,
        [Description("Semantic target id. Omit to use defaultTarget when allowed.")] string? target = null)
        => await _client.SerialOpen(port, baud, target, CancellationToken.None);

    [McpServerTool]
    [Description("Wait until a line containing the pattern appears on a target console, or until timeout. Returns only the matched event instead of an unbounded byte stream.")]
    public async Task<SerialWaitResult> SerialWaitFor(
        [Description("Substring to wait for (case-insensitive), e.g. 'Ready'")] string pattern,
        [Description("Timeout in milliseconds")] int timeoutMs = 10000,
        [Description("Semantic target id. Omit to use defaultTarget when allowed.")] string? target = null)
        => await _client.SerialWaitFor(pattern, timeoutMs, target, CancellationToken.None);

    [McpServerTool]
    [Description("Read a bounded trailing window from a target console, optionally filtered by a substring.")]
    public async Task<SerialWindowResult> SerialReadWindow(
        [Description("Number of trailing lines to return")] int lines = 50,
        [Description("Optional substring filter (case-insensitive)")] string? filter = null,
        [Description("Semantic target id. Omit to use defaultTarget when allowed.")] string? target = null)
        => await _client.SerialReadWindow(lines, filter, target, CancellationToken.None);

    [McpServerTool]
    [Description("Send a line of text to a target serial console.")]
    public async Task<SerialSendResult> SerialSend(
        [Description("Text to send")] string data,
        [Description("Semantic target id. Omit to use defaultTarget when allowed.")] string? target = null)
        => await _client.SerialSend(data, target, CancellationToken.None);
}
