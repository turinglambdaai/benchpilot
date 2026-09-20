using System.ComponentModel;
using Benchpilot.Core;
using Benchpilot.Runtime;
using ModelContextProtocol.Server;

namespace Benchpilot.Mcp.Tools;

// Serial remains the first context-compressed observation channel. Runtime
// resolves the target's serial capability so callers never depend on COM/tty
// identifiers once the bench profile is configured.
internal sealed class SerialTools
{
    private readonly BenchRuntime _runtime;
    public SerialTools(BenchRuntime runtime) => _runtime = runtime;

    private ISerialChannel Serial(string? target) =>
        _runtime.Target(target).Capability<ISerialChannel>("serial");

    [McpServerTool]
    [Description("Open a target's serial console. Uses the profile default target when target is omitted.")]
    public async Task<SerialOpenResult> SerialOpen(
        [Description("Serial port identifier. Driver defaults may be used by future Runtime backends.")] string port = "SIM0",
        [Description("Baud rate")] int baud = 115200,
        [Description("Semantic target id. Omit to use defaultTarget.")] string? target = null)
        => await Serial(target).Open(port, baud, CancellationToken.None);

    [McpServerTool]
    [Description("Wait until a line containing the pattern appears on a target console, or until timeout. Returns only the matched event instead of an unbounded byte stream.")]
    public async Task<SerialWaitResult> SerialWaitFor(
        [Description("Substring to wait for (case-insensitive), e.g. 'Ready'")] string pattern,
        [Description("Timeout in milliseconds")] int timeoutMs = 10000,
        [Description("Semantic target id. Omit to use defaultTarget.")] string? target = null)
        => await Serial(target).WaitFor(pattern, timeoutMs, CancellationToken.None);

    [McpServerTool]
    [Description("Read a bounded trailing window from a target console, optionally filtered by a substring.")]
    public async Task<SerialWindowResult> SerialReadWindow(
        [Description("Number of trailing lines to return")] int lines = 50,
        [Description("Optional substring filter (case-insensitive)")] string? filter = null,
        [Description("Semantic target id. Omit to use defaultTarget.")] string? target = null)
        => await Serial(target).ReadWindow(lines, filter, CancellationToken.None);

    [McpServerTool]
    [Description("Send a line of text to a target serial console.")]
    public async Task<SerialSendResult> SerialSend(
        [Description("Text to send")] string data,
        [Description("Semantic target id. Omit to use defaultTarget.")] string? target = null)
        => await Serial(target).Send(data, CancellationToken.None);
}
