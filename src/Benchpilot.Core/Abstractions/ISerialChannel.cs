namespace Benchpilot.Core;

// Auxiliary channel. WaitFor is the thin end of the context-compression
// strategy: the driver buffers the raw stream locally and only surfaces the
// matched event, not the full byte flood. Port/baud are nullable overrides;
// real drivers should normally take their defaults from the resource profile.
public interface ISerialChannel
{
    Task<SerialOpenResult> Open(string? port = null, int? baud = null, CancellationToken ct = default);
    Task<SerialWaitResult> WaitFor(string pattern, int timeoutMs, CancellationToken ct = default);
    Task<SerialWindowResult> ReadWindow(int lines, string? filter, CancellationToken ct = default);
    Task<SerialSendResult> Send(string data, CancellationToken ct = default);

    bool IsOpen { get; }
}
