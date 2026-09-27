using System.Collections.Concurrent;
using System.Diagnostics;

namespace Benchpilot.Diagnostics.Isotp;

/// <summary>
/// ISO 15765-2 network-layer endpoint over a CAN bus: turns CAN frames into
/// complete payloads and back. One endpoint owns one (txId, rxId) pair.
/// Diagnostic traffic is half-duplex, so one pending transmission at a time
/// is the correct contract; receiving stays concurrent with sending.
/// </summary>
public sealed class IsotpEndpoint : IDisposable
{
    private readonly ICanBus _bus;
    private readonly uint _txId;
    private readonly uint _rxId;
    private readonly IsotpOptions _options;
    private readonly ConcurrentQueue<byte[]> _received = new();
    private readonly object _sendGate = new();

    // Receive-side state.
    private readonly object _rxGate = new();
    private byte[]? _rxBuffer;
    private int _rxLength;
    private int _rxOffset;
    private int _rxExpectedSequence;
    private bool _rxFlowControlSent;

    public IsotpEndpoint(ICanBus bus, uint txId, uint rxId, IsotpOptions? options = null)
    {
        _bus = bus;
        _txId = txId;
        _rxId = rxId;
        _options = options ?? new IsotpOptions();
        _bus.FrameReceived += OnFrameReceived;
    }

    public async Task SendAsync(ReadOnlyMemory<byte> payload, CancellationToken ct = default)
    {
        if (payload.Length == 0)
            throw new ArgumentException("ISO-TP payload cannot be empty.", nameof(payload));

        lock (_sendGate)
        {
            if (_sending)
                throw new InvalidOperationException(
                    "Another ISO-TP transmission is in progress; diagnostic traffic is half-duplex.");
            _sending = true;
        }

        try
        {
            await SendLockedAsync(payload, ct).ConfigureAwait(false);
        }
        finally
        {
            lock (_sendGate)
                _sending = false;
        }
    }

    private async Task SendLockedAsync(ReadOnlyMemory<byte> payload, CancellationToken ct)
    {
        if (payload.Length <= 7)
        {
            await SendCanAsync(IsotpCodec.EncodeSingle(payload.Span), ct).ConfigureAwait(false);
            return;
        }

        // First frame, then wait for a flow control (N_Bs timeout).
        await SendCanAsync(IsotpCodec.EncodeFirstPrefix(payload.Span), ct).ConfigureAwait(false);
        var fc = await ReceiveFlowControlAsync(ct).ConfigureAwait(false);
        switch (fc.FlowStatus)
        {
            case FlowControlStatus.ContinueToSend:
                break;
            case FlowControlStatus.Wait:
                fc = await ReceiveFlowControlAsync(ct).ConfigureAwait(false);
                if (fc.FlowStatus != FlowControlStatus.ContinueToSend)
                    throw new IsotpException($"Flow control did not clear (status {fc.FlowStatus}).");
                break;
            case FlowControlStatus.Overflow:
                throw new IsotpException("Receiver signaled buffer overflow (FC.OVFLW).");
            default:
                throw new IsotpException($"Unexpected flow status {fc.FlowStatus}.");
        }

        var stMin = TimeSpan.FromMilliseconds(Math.Max(0, fc.StMinMs));
        var blockSize = fc.BlockSize;
        var offset = FirstFramePayloadLength(payload.Length);
        var sequence = 1;
        var blockCount = 0;

        while (offset < payload.Length)
        {
            var chunk = Math.Min(payload.Length - offset, IsotpCodec.ClassicDataLength - 1);
            await SendCanAsync(
                IsotpCodec.EncodeConsecutive(sequence, payload.Span.Slice(offset, chunk)),
                ct).ConfigureAwait(false);
            offset += chunk;
            sequence = (sequence + 1) & 0x0F;

            blockCount++;
            if (blockSize > 0 && blockCount >= blockSize && offset < payload.Length)
            {
                blockCount = 0;
                fc = await ReceiveFlowControlAsync(ct).ConfigureAwait(false);
                if (fc.FlowStatus != FlowControlStatus.ContinueToSend)
                    throw new IsotpException($"Flow control interrupted a block (status {fc.FlowStatus}).");
            }

            if (stMin > TimeSpan.Zero && offset < payload.Length)
                await Task.Delay(stMin, ct).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Receives the next complete payload addressed to this endpoint.
    /// </summary>
    public async Task<byte[]> ReceiveAsync(CancellationToken ct = default)
    {
        while (true)
        {
            if (_received.TryDequeue(out var payload))
                return payload;

            await Task.Delay(_options.PollInterval, ct).ConfigureAwait(false);
        }
    }

    private async Task EmitFlowControlAsync(byte[] fcFrame)
    {
        try
        {
            await SendCanAsync(fcFrame, CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is InvalidOperationException or IOException)
        {
            // The bus died mid-handshake; the sender's N_Bs timeout surfaces
            // the failure with its own message.
        }
    }

    private void OnFrameReceived(CanFrame frame)
    {
        if (frame.Id != _rxId)
            return;

        if (!IsotpCodec.TryDecode(frame.Data.Span, out var isotpFrame))
            return;

        switch (isotpFrame.Type)
        {
            case IsotpFrameType.Single:
                ResetReceive();
                _received.Enqueue(isotpFrame.Payload.ToArray());
                return;

            case IsotpFrameType.First:
                ResetReceive();
                // First-frame prefix contains the total length in its PCI; the
                // escaped form was fully consumed by the codec, so recover the
                // length from the header bytes again for buffer sizing.
                var data = frame.Data.Span;
                int totalLength;
                if ((data[0] & 0x0F) != 0 || (data.Length > 1 && data[1] != 0))
                    totalLength = ((data[0] & 0x0F) << 8) | data[1];
                else
                    totalLength = (data[2] << 24) | (data[3] << 16) | (data[4] << 8) | data[5];

                var prefix = isotpFrame.Payload.Length;
                if (totalLength <= prefix)
                    return;
                _rxBuffer = new byte[totalLength];
                isotpFrame.Payload.Span.CopyTo(_rxBuffer.AsSpan(0, prefix));
                _rxLength = totalLength;
                _rxOffset = prefix;
                _rxExpectedSequence = 1;
                _rxFlowControlSent = false;
                var fcFrame = IsotpCodec.EncodeFlowControl(
                    FlowControlStatus.ContinueToSend,
                    _options.BlockSize,
                    _options.StMinMs);
                // The peer's sender is blocked waiting for this flow control
                // right now — it cannot wait until our next ReceiveAsync call,
                // which may never come while we are sending our own request.
                // Emit it autonomously from the receive callback.
                _rxFlowControlSent = true;
                _ = EmitFlowControlAsync(fcFrame);
                return;

            case IsotpFrameType.Consecutive:
                if (_rxBuffer is null)
                    return;
                if (!(_rxFlowControlSent || _rxOffset == 0))
                    return;
                if (isotpFrame.SequenceNumber != _rxExpectedSequence)
                {
                    // Desynchronized: drop the ongoing message; the next
                    // single/first frame re-arms the receiver.
                    ResetReceive();
                    return;
                }

                var remaining = _rxLength - _rxOffset;
                var take = Math.Min(remaining, isotpFrame.Payload.Length);
                isotpFrame.Payload.Span[..take].CopyTo(_rxBuffer.AsSpan(_rxOffset));
                _rxOffset += take;
                _rxExpectedSequence = (_rxExpectedSequence + 1) & 0x0F;

                if (_rxOffset >= _rxLength)
                {
                    var done = _rxBuffer;
                    ResetReceive();
                    _received.Enqueue(done);
                }
                return;

            case IsotpFrameType.FlowControl:
                OnFlowControlFrame(isotpFrame);
                return;
        }
    }

    // Send-side flow control queue: populated by the rx callback, consumed by
    // the sender between consecutive frames.
    private readonly ConcurrentQueue<IsotpFrame> _flowControls = new();

    private void OnFlowControlFrame(IsotpFrame frame) => _flowControls.Enqueue(frame);

    private async Task<IsotpFrame> ReceiveFlowControlAsync(CancellationToken ct)
    {
        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < _options.FlowControlTimeoutMs)
        {
            if (_flowControls.TryDequeue(out var fc))
                return fc;
            await Task.Delay(_options.PollInterval, ct).ConfigureAwait(false);
        }

        throw new IsotpException(
            $"No flow control received within {_options.FlowControlTimeoutMs} ms (N_Bs timeout).");
    }

    private static int FirstFramePayloadLength(int totalLength) =>
        totalLength <= 4095 ? 6 : 2;

    private void ResetReceive()
    {
        _rxBuffer = null;
        _rxLength = 0;
        _rxOffset = 0;
        _rxExpectedSequence = 1;
        _rxFlowControlSent = false;
    }

    private Task SendCanAsync(byte[] data, CancellationToken ct) =>
        _bus.SendAsync(new CanFrame(_txId, _txId > 0x7FF, data), ct);

    private bool _sending;

    public void Dispose()
    {
        _bus.FrameReceived -= OnFrameReceived;
    }
}

public sealed class IsotpException(string message) : Exception(message);

public sealed record IsotpOptions
{
    /// <summary>Block size we announce as receiver; 0 = unlimited.</summary>
    public byte BlockSize { get; init; } = 0;
    /// <summary>Separation time we announce as receiver, milliseconds.</summary>
    public double StMinMs { get; init; } = 0;
    /// <summary>N_Bs: how long the sender waits for a flow control frame.</summary>
    public int FlowControlTimeoutMs { get; init; } = 1000;
    public TimeSpan PollInterval { get; init; } = TimeSpan.FromMilliseconds(2);
}
