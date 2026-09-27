namespace Benchpilot.Diagnostics.Uds;

/// <summary>ISO 14229 service identifiers used by the flash workflow.</summary>
public static class UdsService
{
    public const byte DiagnosticSessionControl = 0x10;
    public const byte EcuReset = 0x11;
    public const byte ReadDataByIdentifier = 0x22;
    public const byte ReadMemoryByAddress = 0x23;
    public const byte WriteDataByIdentifier = 0x2E;
    public const byte SecurityAccess = 0x27;
    public const byte RoutineControl = 0x31;
    public const byte RequestDownload = 0x34;
    public const byte RequestUpload = 0x35;
    public const byte TransferData = 0x36;
    public const byte RequestTransferExit = 0x37;
    public const byte TesterPresent = 0x3E;

    public static string Name(byte sid) => sid switch
    {
        DiagnosticSessionControl => "DiagnosticSessionControl",
        EcuReset => "EcuReset",
        ReadDataByIdentifier => "ReadDataByIdentifier",
        ReadMemoryByAddress => "ReadMemoryByAddress",
        WriteDataByIdentifier => "WriteDataByIdentifier",
        SecurityAccess => "SecurityAccess",
        RoutineControl => "RoutineControl",
        RequestDownload => "RequestDownload",
        RequestUpload => "RequestUpload",
        TransferData => "TransferData",
        RequestTransferExit => "RequestTransferExit",
        TesterPresent => "TesterPresent",
        _ => $"0x{sid:X2}",
    };
}

/// <summary>Negative response codes (ISO 14229-1 Table A.1).</summary>
public enum Nrc : byte
{
    GeneralReject = 0x10,
    ServiceNotSupported = 0x11,
    SubFunctionNotSupported = 0x12,
    IncorrectMessageLengthOrInvalidFormat = 0x13,
    ResponseTooLong = 0x14,
    BusyRepeatRequest = 0x21,
    ConditionsNotCorrect = 0x22,
    RequestSequenceError = 0x24,
    NoResponseFromSubnetComponent = 0x25,
    RequestOutOfRange = 0x31,
    SecurityAccessDenied = 0x33,
    InvalidKey = 0x35,
    ExceedNumberOfAttempts = 0x36,
    RequiredTimeDelayNotExpired = 0x37,
    UploadDownloadNotAccepted = 0x70,
    TransferDataSuspended = 0x71,
    GeneralProgrammingFailure = 0x72,
    WrongBlockSequenceCounter = 0x73,
    RequestCorrectlyReceivedResponsePending = 0x78,
    SubFunctionNotSupportedInActiveSession = 0x7E,
    ServiceNotSupportedInActiveSession = 0x7F,
}

public static class NrcNames
{
    public static string Name(Nrc nrc) => nrc switch
    {
        Nrc.GeneralReject => "generalReject",
        Nrc.ServiceNotSupported => "serviceNotSupported",
        Nrc.SubFunctionNotSupported => "subFunctionNotSupported",
        Nrc.IncorrectMessageLengthOrInvalidFormat => "incorrectMessageLength",
        Nrc.ResponseTooLong => "responseTooLong",
        Nrc.BusyRepeatRequest => "busyRepeatRequest",
        Nrc.ConditionsNotCorrect => "conditionsNotCorrect",
        Nrc.RequestSequenceError => "requestSequenceError",
        Nrc.NoResponseFromSubnetComponent => "noResponseFromSubnetComponent",
        Nrc.RequestOutOfRange => "requestOutOfRange",
        Nrc.SecurityAccessDenied => "securityAccessDenied",
        Nrc.InvalidKey => "invalidKey",
        Nrc.ExceedNumberOfAttempts => "exceedNumberOfAttempts",
        Nrc.RequiredTimeDelayNotExpired => "requiredTimeDelayNotExpired",
        Nrc.UploadDownloadNotAccepted => "uploadDownloadNotAccepted",
        Nrc.TransferDataSuspended => "transferDataSuspended",
        Nrc.GeneralProgrammingFailure => "generalProgrammingFailure",
        Nrc.WrongBlockSequenceCounter => "wrongBlockSequenceCounter",
        Nrc.RequestCorrectlyReceivedResponsePending => "responsePending",
        Nrc.SubFunctionNotSupportedInActiveSession => "subFunctionNotSupportedInActiveSession",
        Nrc.ServiceNotSupportedInActiveSession => "serviceNotSupportedInActiveSession",
        _ => $"0x{(byte)nrc:X2}",
    };
}

public enum UdsSession : byte
{
    Default = 0x01,
    Extended = 0x03,
    Programming = 0x02,
}

public enum RoutineKind : byte
{
    Start = 0x01,
    Stop = 0x02,
    RequestResults = 0x03,
}

/// <summary>Timing profile of one diagnostic transaction (ISO 14229-1 9.4).</summary>
public sealed record UdsTiming
{
    /// <summary>P2 server default: how long to wait for the first response.</summary>
    public int P2TimeoutMs { get; init; } = 1000;
    /// <summary>P2* server: additional wait while NRC 0x78 keeps arriving.</summary>
    public int P2StarTimeoutMs { get; init; } = 5000;
}

public sealed class UdsProtocolException : Exception
{
    public UdsProtocolException(string message, Nrc? nrc = null) : base(message)
        => Nrc = nrc;

    public Nrc? Nrc { get; }
}

/// <summary>
/// One completed UDS transaction: positive payload or structured negative
/// response. Success carries the response bytes after the positive SID.
/// </summary>
public sealed record UdsResponse(
    bool Positive,
    byte RequestServiceId,
    ReadOnlyMemory<byte> Payload,
    Nrc? Nrc = null)
{
    public static UdsResponse PositiveResponse(byte sid, ReadOnlyMemory<byte> payload) =>
        new(true, sid, payload);

    public static UdsResponse NegativeResponse(byte sid, Nrc nrc) =>
        new(false, sid, ReadOnlyMemory<byte>.Empty, nrc);
}

public static class UdsMessages
{
    public static byte[] DiagnosticSession(UdsSession session) =>
        [UdsService.DiagnosticSessionControl, (byte)session];

    public static byte[] TesterPresent(bool responseRequired = true) =>
        [UdsService.TesterPresent, responseRequired ? (byte)0x00 : (byte)0x80];

    public static byte[] ReadDid(ushort did) =>
        [UdsService.ReadDataByIdentifier, (byte)(did >> 8), (byte)(did & 0xFF)];

    public static byte[] WriteDid(ushort did, ReadOnlySpan<byte> value)
    {
        var request = new byte[3 + value.Length];
        request[0] = UdsService.WriteDataByIdentifier;
        request[1] = (byte)(did >> 8);
        request[2] = (byte)(did & 0xFF);
        value.CopyTo(request.AsSpan(3));
        return request;
    }

    public static byte[] SecurityAccessRequestSeed(byte level) =>
        [UdsService.SecurityAccess, level];

    public static byte[] SecurityAccessSendKey(byte level, ReadOnlySpan<byte> key)
    {
        var request = new byte[2 + key.Length];
        request[0] = UdsService.SecurityAccess;
        request[1] = level;
        key.CopyTo(request.AsSpan(2));
        return request;
    }

    public static byte[] RoutineControl(RoutineKind kind, ushort routineId, ReadOnlySpan<byte> record)
    {
        var request = new byte[4 + record.Length];
        request[0] = UdsService.RoutineControl;
        request[1] = (byte)kind;
        request[2] = (byte)(routineId >> 8);
        request[3] = (byte)(routineId & 0xFF);
        record.CopyTo(request.AsSpan(4));
        return request;
    }

    public static byte[] RequestDownload(long address, long length, byte compression = 0x00, byte encryption = 0x00)
    {
        var addressSize = AddressLength(address);
        var request = new byte[3 + addressSize + 4];
        request[0] = UdsService.RequestDownload;
        request[1] = (byte)(compression << 4 | encryption);
        request[2] = (byte)(addressSize << 4 | 0x04);
        var offset = 3;
        for (var shift = (addressSize - 1) * 8; shift >= 0; shift -= 8)
            request[offset++] = (byte)((address >> shift) & 0xFF);
        for (var shift = 24; shift >= 0; shift -= 8)
            request[offset++] = (byte)((length >> shift) & 0xFF);
        return request;
    }

    public static byte[] TransferData(byte blockSequenceCounter, ReadOnlySpan<byte> data)
    {
        var request = new byte[2 + data.Length];
        request[0] = UdsService.TransferData;
        request[1] = blockSequenceCounter;
        data.CopyTo(request.AsSpan(2));
        return request;
    }

    public static byte[] RequestTransferExit() => [UdsService.RequestTransferExit];

    public static byte[] EcuReset(byte resetType = 0x01) =>
        [UdsService.EcuReset, resetType];

    public static int AddressLength(long address) =>
        address > 0xFFFFFFFF ? 8 : address > 0xFFFFFF ? 4 : address > 0xFFFF ? 3 : address > 0xFF ? 2 : 1;
}

/// <summary>
/// Runs ISO 14229 transactions over a request/response byte pipe, enforcing
/// P2/P2* timing and NRC 0x78 pending handling. The transport sends one
/// request and returns response PDUs until the transaction completes.
/// </summary>
public sealed class UdsClient
{
    private readonly IUdsTransport _transport;

    public UdsClient(IUdsTransport transport) => _transport = transport;

    public async Task<UdsResponse> SendAsync(
        ReadOnlyMemory<byte> request,
        UdsTiming? timing = null,
        CancellationToken ct = default)
    {
        if (request.Length < 1)
            throw new ArgumentException("UDS request cannot be empty.", nameof(request));

        var t = timing ?? new UdsTiming();
        var sid = request.Span[0];
        await _transport.SendRequestAsync(request, ct).ConfigureAwait(false);

        var firstDeadline = DateTimeOffset.UtcNow.AddMilliseconds(t.P2TimeoutMs);
        var pendingDeadline = firstDeadline.AddMilliseconds(t.P2StarTimeoutMs);

        while (true)
        {
            var response = await _transport.ReceiveResponseAsync(ct).ConfigureAwait(false);
            if (response.Length < 3 && !(response.Length > 0 && response.Span[0] == (sid | 0x40)))
                throw new UdsProtocolException("UDS response too short to be valid.");

            if (response.Span[0] == (sid | 0x40))
                return UdsResponse.PositiveResponse(sid, response[1..]);

            if (response.Span[0] != 0x7F || response.Length < 3)
                throw new UdsProtocolException(
                    $"UDS response does not match request SID 0x{sid:X2} (got 0x{response.Span[0]:X2}).");
            if (response.Span[1] != sid)
                throw new UdsProtocolException(
                    $"UDS negative response references SID 0x{response.Span[1]:X2}, expected 0x{sid:X2}.");

            var nrc = (Nrc)response.Span[2];
            if (nrc == Nrc.RequestCorrectlyReceivedResponsePending)
            {
                if (DateTimeOffset.UtcNow > pendingDeadline)
                    throw new UdsProtocolException(
                        $"Server kept responding NRC 0x78 beyond P2* ({t.P2StarTimeoutMs} ms).", nrc);
                continue;
            }

            return UdsResponse.NegativeResponse(sid, nrc);
        }
    }

    /// <summary>
    /// Positive responses only; negative responses throw with their NRC.
    /// </summary>
    public async Task<ReadOnlyMemory<byte>> RequirePositiveAsync(
        ReadOnlyMemory<byte> request,
        UdsTiming? timing = null,
        CancellationToken ct = default)
    {
        var response = await SendAsync(request, timing, ct).ConfigureAwait(false);
        if (!response.Positive)
            throw new UdsProtocolException(
                $"{UdsService.Name(response.RequestServiceId)} rejected: {NrcNames.Name(response.Nrc!.Value)} (0x{(byte)response.Nrc.Value:X2}).",
                response.Nrc);
        return response.Payload;
    }
}

/// <summary>
/// The byte pipe under UdsClient: transports frame UDS PDUs (ISO-TP over
/// CAN, DoIP diagnostic messages) and expose them here.
/// </summary>
public interface IUdsTransport
{
    Task SendRequestAsync(ReadOnlyMemory<byte> request, CancellationToken ct);

    /// <summary>Returns the next response PDU from the server for the active request.</summary>
    Task<ReadOnlyMemory<byte>> ReceiveResponseAsync(CancellationToken ct);
}
