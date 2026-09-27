namespace Benchpilot.Diagnostics.Isotp;

public enum IsotpFrameType : byte
{
    Single = 0,
    First = 1,
    Consecutive = 2,
    FlowControl = 3,
}

public enum FlowControlStatus : byte
{
    ContinueToSend = 0,
    Wait = 1,
    Overflow = 2,
}

/// <summary>One decoded ISO-TP network-layer frame (ISO 15765-2).</summary>
public readonly struct IsotpFrame
{
    public IsotpFrameType Type { get; init; }
    /// <summary>Sequence number of Consecutive frames (0..15, starts at 1).</summary>
    public int SequenceNumber { get; init; }
    /// <summary>Payload carried by Single/First frames (First carries only its prefix).</summary>
    public ReadOnlyMemory<byte> Payload { get; init; }
    public FlowControlStatus FlowStatus { get; init; }
    /// <summary>Block size announced by a Flow Control frame; 0 = send all.</summary>
    public byte BlockSize { get; init; }
    /// <summary>Separation time announced by a Flow Control frame, in milliseconds.</summary>
    public double StMinMs { get; init; }

    public static IsotpFrame FlowControl(FlowControlStatus status, byte blockSize, double stMinMs) => new()
    {
        Type = IsotpFrameType.FlowControl,
        FlowStatus = status,
        BlockSize = blockSize,
        StMinMs = stMinMs,
    };
}

/// <summary>
/// Encodes and decodes ISO 15765-2 frames on classic 8-byte CAN. Standard
/// addressing (no extra address byte); SF escape for payloads over 7 bytes
/// and FF escape for lengths over 4095 are both supported.
/// </summary>
public static class IsotpCodec
{
    public const int ClassicDataLength = 8;
    private const byte TypeMask = 0xF0;
    private const byte NibbleMask = 0x0F;

    public static bool TryDecode(ReadOnlySpan<byte> data, out IsotpFrame frame)
    {
        frame = default;
        if (data.Length < 1)
            return false;

        var pci = data[0];
        switch ((IsotpFrameType)((pci & TypeMask) >> 4))
        {
            case IsotpFrameType.Single:
            {
                var length = pci & NibbleMask;
                ReadOnlySpan<byte> payload;
                if (length != 0)
                {
                    if (data.Length < 1 + length)
                        return false;
                    payload = data.Slice(1, length);
                }
                else
                {
                    // Escape: 0x00 + 12-bit length, payload from byte 2.
                    if (data.Length < 2)
                        return false;
                    length = ((data[1] & 0x0F) << 8) | data[2];
                    if (length == 0 || data.Length < 3 + length)
                        return false;
                    payload = data.Slice(3, length);
                }

                frame = new IsotpFrame { Type = IsotpFrameType.Single, Payload = payload.ToArray() };
                return true;
            }

            case IsotpFrameType.First:
            {
                int length;
                int payloadStart;
                // Short form whenever the length nibble is nonzero, or the
                // low byte is nonzero (length < 256 with a zero nibble);
                // the escaped form is exactly 0x10 0x00 + 32-bit length.
                if ((pci & NibbleMask) != 0 || (data.Length > 1 && data[1] != 0))
                {
                    if (data.Length < 2)
                        return false;
                    length = ((pci & NibbleMask) << 8) | data[1];
                    payloadStart = 2;
                }
                else
                {
                    // Escape: 0x10 0x00 + 32-bit length.
                    if (data.Length < 6)
                        return false;
                    length = (data[2] << 24) | (data[3] << 16) | (data[4] << 8) | data[5];
                    payloadStart = 6;
                }

                if (data.Length < payloadStart)
                    return false;
                frame = new IsotpFrame
                {
                    Type = IsotpFrameType.First,
                    Payload = data[payloadStart..].ToArray(),
                };
                _ = length; // Total length is tracked by the endpoint state machine.
                return true;
            }

            case IsotpFrameType.Consecutive:
            {
                var sequence = pci & NibbleMask;
                if (data.Length < 2)
                    return false;
                frame = new IsotpFrame
                {
                    Type = IsotpFrameType.Consecutive,
                    SequenceNumber = sequence,
                    Payload = data[1..].ToArray(),
                };
                return true;
            }

            case IsotpFrameType.FlowControl:
            {
                if (data.Length < 3)
                    return false;
                var status = (FlowControlStatus)(pci & NibbleMask);
                if (status is not (FlowControlStatus.ContinueToSend or FlowControlStatus.Wait or FlowControlStatus.Overflow))
                    return false;
                frame = new IsotpFrame
                {
                    Type = IsotpFrameType.FlowControl,
                    FlowStatus = status,
                    BlockSize = data[1],
                    StMinMs = DecodeStMin(data[2]),
                };
                return true;
            }

            default:
                return false;
        }
    }

    /// <summary>
    /// Encodes one frame into a classic 8-byte CAN payload, zero-padded.
    /// Classic CAN single frames carry at most 7 payload bytes; larger
    /// payloads must go through the first/consecutive machinery.
    /// </summary>
    public static byte[] EncodeSingle(ReadOnlySpan<byte> payload)
    {
        if (payload.Length > 7)
            throw new ArgumentException(
                "Classic CAN single frames carry at most 7 bytes; use first/consecutive frames.",
                nameof(payload));

        var frame = new byte[ClassicDataLength];
        frame[0] = (byte)payload.Length;
        payload.CopyTo(frame.AsSpan(1));
        return frame;
    }

    public static byte[] EncodeFirstPrefix(ReadOnlySpan<byte> payload)
    {
        var frame = new byte[ClassicDataLength];
        if (payload.Length <= 4095)
        {
            frame[0] = (byte)(0x10 | ((payload.Length >> 8) & 0x0F));
            frame[1] = (byte)(payload.Length & 0xFF);
            payload[..6].CopyTo(frame.AsSpan(2));
            return frame;
        }

        // Escape first frame with 32-bit length.
        frame[0] = 0x10;
        frame[1] = 0x00;
        frame[2] = (byte)((payload.Length >> 24) & 0xFF);
        frame[3] = (byte)((payload.Length >> 16) & 0xFF);
        frame[4] = (byte)((payload.Length >> 8) & 0xFF);
        frame[5] = (byte)(payload.Length & 0xFF);
        payload[..2].CopyTo(frame.AsSpan(6));
        return frame;
    }

    public static byte[] EncodeConsecutive(int sequenceNumber, ReadOnlySpan<byte> chunk)
    {
        var frame = new byte[ClassicDataLength];
        frame[0] = (byte)(0x20 | (sequenceNumber & NibbleMask));
        chunk[..Math.Min(chunk.Length, ClassicDataLength - 1)].CopyTo(frame.AsSpan(1));
        return frame;
    }

    public static byte[] EncodeFlowControl(FlowControlStatus status, byte blockSize, double stMinMs) =>
    [
        (byte)(0x30 | (byte)status),
        blockSize,
        EncodeStMin(stMinMs),
        0, 0, 0, 0, 0,
    ];

    /// <summary>
    /// Encodes STmin per ISO 15765-2: 0x00-0x7F are milliseconds (max 127),
    /// 0xF1-0xF9 are 100-900 microseconds; values of 1 ms or more use the
    /// millisecond range, clamped at 127 ms.
    /// </summary>
    public static byte EncodeStMin(double stMinMs)
    {
        if (stMinMs <= 0)
            return 0x00;
        if (stMinMs < 1)
        {
            var hundredsOfUs = (int)Math.Round(stMinMs * 10);
            return (byte)(0xF0 + Math.Clamp(hundredsOfUs, 1, 9));
        }

        return (byte)Math.Clamp((int)Math.Round(stMinMs), 0, 0x7F);
    }

    public static double DecodeStMin(byte value) => value switch
    {
        >= 0xF1 and <= 0xF9 => (value - 0xF0) * 0.1,
        <= 0x7F => value,
        _ => 0,
    };
}
