using System.Buffers.Binary;

namespace Benchpilot.Diagnostics.Doip;

/// <summary>ISO 13400-2 payload types used by the diagnostic tool path.</summary>
public enum DoipPayloadType : ushort
{
    GenericHeaderNegativeAcknowledge = 0x0000,
    VehicleIdentificationRequest = 0x0001,
    VehicleIdentificationRequestWithEid = 0x0002,
    VehicleIdentificationRequestWithVin = 0x0003,
    VehicleIdentificationResponse = 0x0004,
    RoutingActivationRequest = 0x0005,
    RoutingActivationResponse = 0x0006,
    AliveCheckRequest = 0x0007,
    AliveCheckResponse = 0x0008,
    DiagnosticMessage = 0x8001,
    DiagnosticPositiveAcknowledgement = 0x8002,
    DiagnosticNegativeAcknowledgement = 0x8003,
}

public enum RoutingActivationResult : byte
{
    Accepted = 0x10,
    Confirmed = 0x11,
    AlreadyActive = 0x12,
    Reserved = 0x00,
    UnknownSourceAddress = 0x02,
    DeniedByGateway = 0x03,
    InvalidSocketAddress = 0x04,
    ConcurrentRegistrations = 0x05,
}

public sealed record DoipVehicleIdentity(
    string Vin,
    ushort LogicalAddress,
    string? IpAddress = null);

public sealed class DoipFrame
{
    public const byte ProtocolVersion = 0x02; // ISO 13400-2:2019
    public const int HeaderLength = 8;
    public const byte InverseVersion = 0xFD;

    public DoipPayloadType Type { get; init; }
    public byte[] Payload { get; init; } = Array.Empty<byte>();

    public byte[] ToBytes()
    {
        var buffer = new byte[HeaderLength + Payload.Length];
        buffer[0] = ProtocolVersion;
        buffer[1] = InverseVersion;
        BinaryPrimitives.WriteUInt16BigEndian(buffer.AsSpan(2), (ushort)Type);
        BinaryPrimitives.WriteUInt32BigEndian(buffer.AsSpan(4), (uint)Payload.Length);
        Payload.CopyTo(buffer, HeaderLength);
        return buffer;
    }

    /// <summary>
    /// Attempts to decode one frame from the buffered bytes. Returns false
    /// when more bytes are needed; throws when the header is malformed.
    /// </summary>
    public static bool TryDecode(ReadOnlySpan<byte> available, out DoipFrame frame, out int consumed)
    {
        frame = new DoipFrame();
        consumed = 0;
        if (available.Length < HeaderLength)
            return false;

        var version = available[0];
        var inverse = available[1];
        if (version != ProtocolVersion || inverse != InverseVersion)
            throw new DoipException($"Invalid DoIP header version {version:X2}/{inverse:X2}.");

        var type = BinaryPrimitives.ReadUInt16BigEndian(available.Slice(2, 2));
        var length = BinaryPrimitives.ReadUInt32BigEndian(available.Slice(4, 4));
        if (available.Length < HeaderLength + (int)length)
            return false;

        frame = new DoipFrame
        {
            Type = (DoipPayloadType)type,
            Payload = available.Slice(HeaderLength, (int)length).ToArray(),
        };
        consumed = HeaderLength + (int)length;
        return true;
    }

    public static DoipFrame DiagnosticMessage(ushort source, ushort target, ReadOnlySpan<byte> userData)
    {
        var payload = new byte[4 + userData.Length];
        BinaryPrimitives.WriteUInt16BigEndian(payload.AsSpan(0), source);
        BinaryPrimitives.WriteUInt16BigEndian(payload.AsSpan(2), target);
        userData.CopyTo(payload.AsSpan(4));
        return new DoipFrame { Type = DoipPayloadType.DiagnosticMessage, Payload = payload };
    }

    public static DoipFrame RoutingActivationRequest(ushort sourceAddress, byte activationType = 0x00)
    {
        var payload = new byte[7];
        BinaryPrimitives.WriteUInt16BigEndian(payload.AsSpan(0), sourceAddress);
        payload[2] = activationType;
        // 4 reserved bytes stay zero.
        return new DoipFrame { Type = DoipPayloadType.RoutingActivationRequest, Payload = payload };
    }

    public static DoipFrame VehicleIdentificationRequest() =>
        new() { Type = DoipPayloadType.VehicleIdentificationRequest, Payload = Array.Empty<byte>() };

    public static ushort? TryGetDiagnosticSource(DoipFrame frame)
    {
        if (frame.Type != DoipPayloadType.DiagnosticMessage || frame.Payload.Length < 4)
            return null;
        return BinaryPrimitives.ReadUInt16BigEndian(frame.Payload.AsSpan(0, 2));
    }

    public static ushort? TryGetDiagnosticTarget(DoipFrame frame)
    {
        if (frame.Type != DoipPayloadType.DiagnosticMessage || frame.Payload.Length < 4)
            return null;
        return BinaryPrimitives.ReadUInt16BigEndian(frame.Payload.AsSpan(2, 2));
    }

    public static ReadOnlyMemory<byte> GetDiagnosticUserData(DoipFrame frame) =>
        frame.Type == DoipPayloadType.DiagnosticMessage && frame.Payload.Length >= 4
            ? frame.Payload.AsMemory(4)
            : ReadOnlyMemory<byte>.Empty;
}

public sealed class DoipException : Exception
{
    public DoipException(string message) : base(message)
    {
    }
}
