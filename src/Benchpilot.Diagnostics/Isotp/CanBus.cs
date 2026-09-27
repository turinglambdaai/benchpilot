namespace Benchpilot.Diagnostics.Isotp;

/// <summary>
/// One CAN frame as the ISO-TP layer needs it. Data is at most 8 bytes for
/// classic CAN; CAN FD up to 64 is accepted by the codec where legal.
/// </summary>
public readonly record struct CanFrame(
    uint Id,
    bool ExtendedId,
    ReadOnlyMemory<byte> Data);

/// <summary>
/// A CAN bus in the eyes of the diagnostic stack: frames go out, frames come
/// in. Implementations: SocketCAN, PCAN, and the in-process simulated bus.
/// The diagnostic layer never talks to vendor SDKs directly.
/// </summary>
public interface ICanBus : IDisposable
{
    string Name { get; }

    Task OpenAsync(CancellationToken ct = default);

    Task SendAsync(CanFrame frame, CancellationToken ct = default);

    /// <summary>Raised for every frame received on the bus, on a background thread.</summary>
    event Action<CanFrame>? FrameReceived;
}
