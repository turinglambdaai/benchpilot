using System.ComponentModel;
using Benchpilot.Core;
using ModelContextProtocol.Server;

namespace Benchpilot.Mcp.Tools;

// Serial console channel (PRD §6.3). `serial_wait_for` is the thin end of the
// context-compression strategy (PRD §6.7): the driver buffers the raw stream
// locally and only surfaces the matched event, not the full byte flood.
internal sealed class SerialTools
{
    private readonly BenchKernel _kernel;
    public SerialTools(BenchKernel kernel) => _kernel = kernel;

    [McpServerTool]
    [Description("Open the serial console. The board must be powered on to receive any output.")]
    public async Task<SerialOpenResult> SerialOpen(
        [Description("Serial port identifier")] string port = "SIM0",
        [Description("Baud rate")] int baud = 115200)
        => await _kernel.Serial.Open(port, baud, CancellationToken.None);

    [McpServerTool]
    [Description("Block until a line containing the pattern appears on the serial console, or until timeout. Returns the matched line and elapsed time. This is how you observe firmware boot events like 'Ready'.")]
    public async Task<SerialWaitResult> SerialWaitFor(
        [Description("Substring to wait for (case-insensitive), e.g. 'Ready'")] string pattern,
        [Description("Timeout in milliseconds")] int timeoutMs = 10000)
        => await _kernel.Serial.WaitFor(pattern, timeoutMs, CancellationToken.None);

    [McpServerTool]
    [Description("Read the last N lines from the serial console, optionally filtered by a substring.")]
    public async Task<SerialWindowResult> SerialReadWindow(
        [Description("Number of trailing lines to return")] int lines = 50,
        [Description("Optional substring filter (case-insensitive)")] string? filter = null)
        => await _kernel.Serial.ReadWindow(lines, filter, CancellationToken.None);

    [McpServerTool]
    [Description("Send a line of text to the serial console.")]
    public async Task<SerialSendResult> SerialSend(
        [Description("Text to send")] string data)
        => await _kernel.Serial.Send(data, CancellationToken.None);
}
