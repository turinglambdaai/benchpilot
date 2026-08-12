namespace Benchpilot.Core;

// Auxiliary channel (PRD §6.3). WaitFor is the thin end of the context-
// compression strategy (PRD §6.7): the driver buffers the raw stream
// locally and only surfaces the matched event, not the full byte flood.
public interface ISerialChannel
{
    Task<SerialOpenResult> Open(string port, int baud, CancellationToken ct = default);
    Task<SerialWaitResult> WaitFor(string pattern, int timeoutMs, CancellationToken ct = default);
    Task<SerialWindowResult> ReadWindow(int lines, string? filter, CancellationToken ct = default);
    Task<SerialSendResult> Send(string data, CancellationToken ct = default);

    bool IsOpen { get; }
}
