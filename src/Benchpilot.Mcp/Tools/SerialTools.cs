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
        [Description("Semantic target id. Omit to use defaultTarget when allowed.")] string? target = null,
        [Description("Optional Runtime execution deadline in milliseconds.")] int? deadlineMs = null)
        => await _client.SerialOpen(port, baud, target, deadlineMs, CancellationToken.None);

    [McpServerTool]
    [Description("Wait until a line containing the pattern appears on a target console, or until timeout. Returns only the matched event instead of an unbounded byte stream. timeoutMs is the semantic wait window; deadlineMs is a separate Runtime execution budget.")]
    public async Task<SerialWaitResult> SerialWaitFor(
        [Description("Substring to wait for (case-insensitive), e.g. 'Ready'")] string pattern,
        [Description("Semantic wait timeout in milliseconds. Expiry returns a normal unmatched result.")] int timeoutMs = 10000,
        [Description("Semantic target id. Omit to use defaultTarget when allowed.")] string? target = null,
        [Description("Optional Runtime execution deadline in milliseconds. Expiry is reported as deadline_exceeded, not as an unmatched serial assertion.")] int? deadlineMs = null)
        => await _client.SerialWaitFor(pattern, timeoutMs, target, deadlineMs, CancellationToken.None);

    [McpServerTool]
    [Description("Read a bounded trailing window from a target console, optionally filtered by a substring.")]
    public async Task<SerialWindowResult> SerialReadWindow(
        [Description("Number of trailing lines to return")] int lines = 50,
        [Description("Optional substring filter (case-insensitive)")] string? filter = null,
        [Description("Semantic target id. Omit to use defaultTarget when allowed.")] string? target = null,
        [Description("Optional Runtime execution deadline in milliseconds.")] int? deadlineMs = null)
        => await _client.SerialReadWindow(lines, filter, target, deadlineMs, CancellationToken.None);

    [McpServerTool]
    [Description("Send a line of text to a target serial console.")]
    public async Task<SerialSendResult> SerialSend(
        [Description("Text to send")] string data,
        [Description("Semantic target id. Omit to use defaultTarget when allowed.")] string? target = null,
        [Description("Optional Runtime execution deadline in milliseconds.")] int? deadlineMs = null)
        => await _client.SerialSend(data, target, deadlineMs, CancellationToken.None);
}