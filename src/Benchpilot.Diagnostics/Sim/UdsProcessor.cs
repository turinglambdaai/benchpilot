using System.Diagnostics;
using Benchpilot.Diagnostics.Flash;
using Benchpilot.Diagnostics.Uds;

namespace Benchpilot.Diagnostics.Sim;

/// <summary>One processed request: response bytes plus an artificial delay.</summary>
public sealed record UdsServerResponse(ReadOnlyMemory<byte> Response, int DelayMs = 0)
{
    public static readonly UdsServerResponse NoReply = new(ReadOnlyMemory<byte>.Empty, -1);
}

/// <summary>
/// Server-side UDS responder used by the simulator. Models the behavioral
/// surface a real ECU presents to a flash tool: sessions with S3 timeout,
/// security access with attempt counting, DID read/write, erase/verify
/// routines and the RequestDownload/TransferData/Exit state machine with
/// proper NRCs. Semantics follow ISO 14229; the implementation is original.
/// </summary>
public sealed class UdsProcessor
{
    private readonly UdsEcuOptions _options;
    private readonly object _gate = new();

    private byte _session = (byte)UdsSession.Default;
    private long _lastActivityTicks;
    private byte _securityLevelUnlocked;
    private int _securityAttempts;
    private byte[]? _pendingSeed;

    // Transfer state.
    private bool _transferActive;
    private long _transferAddress;
    private long _transferLength;
    private long _transferred;
    private byte _expectedBlockSequence = 0x01;
    private readonly List<byte> _transferBuffer = new();
    private byte[] _lastImage = Array.Empty<byte>();

    private bool _erased;
    private int _eraseCount;
    private int _verifyCount;

    public UdsProcessor(UdsEcuOptions? options = null)
    {
        _options = options ?? new UdsEcuOptions();
        _lastActivityTicks = Stopwatch.GetTimestamp();
    }

    public bool Erased
    {
        get { lock (_gate) return _erased; }
    }

    public int EraseCount
    {
        get { lock (_gate) return _eraseCount; }
    }

    public int VerifyCount
    {
        get { lock (_gate) return _verifyCount; }
    }

    /// <summary>The complete image of the last successful transfer; survives ECU reset.</summary>
    public byte[] ReceivedImage
    {
        get { lock (_gate) return _lastImage.ToArray(); }
    }

    /// <summary>Processes one request PDU and returns the response, if any.</summary>
    public UdsServerResponse Process(ReadOnlySpan<byte> request)
    {
        CheckS3Timeout();
        lock (_gate)
            _lastActivityTicks = Stopwatch.GetTimestamp();

        if (request.Length < 1)
            return Negative(request.IsEmpty ? default : request[0], Nrc.IncorrectMessageLengthOrInvalidFormat);

        if (request[0] == 0x7F)
            return Negative(request[0], Nrc.SubFunctionNotSupported);

        if (request.Length >= 3 && request[0] == 0x7F)
            return Negative(request[1], (Nrc)request[2]);

        return request[0] switch
        {
            UdsService.DiagnosticSessionControl => HandleSession(request),
            UdsService.TesterPresent => HandleTesterPresent(request),
            UdsService.ReadDataByIdentifier => HandleReadDid(request),
            UdsService.WriteDataByIdentifier => HandleWriteDid(request),
            UdsService.SecurityAccess => HandleSecurityAccess(request),
            UdsService.RoutineControl => HandleRoutine(request),
            UdsService.RequestDownload => HandleRequestDownload(request),
            UdsService.TransferData => HandleTransferData(request),
            UdsService.RequestTransferExit => HandleTransferExit(request),
            UdsService.EcuReset => HandleEcuReset(request),
            _ => Negative(request[0], Nrc.ServiceNotSupported),
        };
    }

    private UdsServerResponse HandleSession(ReadOnlySpan<byte> request)
    {
        if (request.Length != 2)
            return Negative(request[0], Nrc.IncorrectMessageLengthOrInvalidFormat);
        var requested = request[1];
        if (requested is not ((byte)UdsSession.Default or (byte)UdsSession.Extended or (byte)UdsSession.Programming))
            return Negative(request[0], Nrc.SubFunctionNotSupported);

        byte previous;
        lock (_gate)
        {
            previous = _session;
            _session = requested;
            if (requested != (byte)UdsSession.Programming)
            {
                _securityLevelUnlocked = 0;
                _pendingSeed = null;
            }
        }

        if (previous == (byte)UdsSession.Programming && requested != (byte)UdsSession.Programming)
            ResetTransfer();

        // Positive: SID | session byte (real servers echo P2/P2* timings too).
        return new UdsServerResponse(new byte[] {(byte)(request[0] | 0x40), requested, 0x00, 0x32, 0x01, 0xF4}, _options.ResponseDelayMs);
    }

    private UdsServerResponse HandleTesterPresent(ReadOnlySpan<byte> request)
    {
        if (request.Length != 2 || (request[1] & 0x7F) != 0x00)
            return Negative(request[0], Nrc.IncorrectMessageLengthOrInvalidFormat);
        if ((request[1] & 0x80) != 0)
            return UdsServerResponse.NoReply;
        return new UdsServerResponse(new byte[] {(byte)(request[0] | 0x40), 0x00}, _options.ResponseDelayMs);
    }

    private UdsServerResponse HandleReadDid(ReadOnlySpan<byte> request)
    {
        if (request.Length != 3)
            return Negative(request[0], Nrc.IncorrectMessageLengthOrInvalidFormat);
        var did = (ushort)((request[1] << 8) | request[2]);
        if (!_options.DataIdentifiers.TryGetValue(did, out var value))
            return Negative(request[0], Nrc.RequestOutOfRange);
        var response = new byte[3 + value.Length];
        response[0] = (byte)(request[0] | 0x40);
        response[1] = request[1];
        response[2] = request[2];
        value.CopyTo(response.AsSpan(3));
        return new UdsServerResponse(response, _options.ResponseDelayMs);
    }

    private UdsServerResponse HandleWriteDid(ReadOnlySpan<byte> request)
    {
        if (request.Length < 4)
            return Negative(request[0], Nrc.IncorrectMessageLengthOrInvalidFormat);
        var did = (ushort)((request[1] << 8) | request[2]);
        if (!_options.WritableIdentifiers.Contains(did))
            return Negative(request[0], Nrc.RequestOutOfRange);
        if (_session == (byte)UdsSession.Default)
            return Negative(request[0], Nrc.ServiceNotSupportedInActiveSession);
        _options.DataIdentifiers[did] = request[3..].ToArray();
        return new UdsServerResponse(new byte[] {(byte)(request[0] | 0x40), request[1], request[2]}, _options.ResponseDelayMs);
    }

    private UdsServerResponse HandleSecurityAccess(ReadOnlySpan<byte> request)
    {
        if (request.Length < 2)
            return Negative(request[0], Nrc.IncorrectMessageLengthOrInvalidFormat);
        var level = request[1];

        if (request[0] == UdsService.SecurityAccess && level == 0x00)
            return Negative(request[0], Nrc.SubFunctionNotSupported);

        if ((level & 0x01) != 0)
        {
            // Request seed.
            if (request.Length != 2)
                return Negative(request[0], Nrc.IncorrectMessageLengthOrInvalidFormat);
            lock (_gate)
            {
                if (_securityLevelUnlocked >= level)
                    return new UdsServerResponse(new byte[] {(byte)(request[0] | 0x40), level, 0}, _options.ResponseDelayMs);
                _pendingSeed = new byte[4];
                new Random(_options.SeedBase + _securityAttempts).NextBytes(_pendingSeed);
            }

            var response = new byte[2 + 4];
            response[0] = (byte)(request[0] | 0x40);
            response[1] = level;
            _pendingSeed!.CopyTo(response, 2);
            return new UdsServerResponse(response, _options.ResponseDelayMs);
        }

        // Send key.
        lock (_gate)
        {
            if (_pendingSeed is null || _pendingSeed.Length == 0)
                return Negative(request[0], Nrc.RequestSequenceError);
            if (request.Length != 2 + _pendingSeed.Length)
                return Negative(request[0], Nrc.IncorrectMessageLengthOrInvalidFormat);

            var expected = _options.KeyDeriver(_pendingSeed);
            var provided = request[2..].ToArray();
            if (!expected.AsSpan().SequenceEqual(provided))
            {
                _securityAttempts++;
                _pendingSeed = null;
                return Negative(request[0],
                    _securityAttempts >= _options.MaxSecurityAttempts
                        ? Nrc.ExceedNumberOfAttempts
                        : Nrc.InvalidKey);
            }

            _securityLevelUnlocked = (byte)(level - 1);
            _pendingSeed = null;
            return new UdsServerResponse(new byte[] {(byte)(request[0] | 0x40), level}, _options.ResponseDelayMs);
        }
    }

    private UdsServerResponse HandleRoutine(ReadOnlySpan<byte> request)
    {
        if (request.Length < 4)
            return Negative(request[0], Nrc.IncorrectMessageLengthOrInvalidFormat);
        var kind = request[1];
        if (kind is not ((byte)RoutineKind.Start or (byte)RoutineKind.Stop or (byte)RoutineKind.RequestResults))
            return Negative(request[0], Nrc.SubFunctionNotSupported);
        var routineId = (ushort)((request[2] << 8) | request[3]);
        var record = request[4..].ToArray();

        if (_session != (byte)UdsSession.Programming &&
            routineId is (ushort)BuiltinRoutineId.Erase or (ushort)BuiltinRoutineId.Verify)
            return Negative(request[0], Nrc.ServiceNotSupportedInActiveSession);

        switch ((BuiltinRoutineId)routineId)
        {
            case BuiltinRoutineId.Erase when kind == (byte)RoutineKind.Start:
            {
                if (_securityLevelUnlocked == 0)
                    return Negative(request[0], Nrc.SecurityAccessDenied);
                if (record.Length != 8)
                    return Negative(request[0], Nrc.IncorrectMessageLengthOrInvalidFormat);
                long address = 0;
                long size = 0;
                for (var i = 0; i < 4; i++)
                    address = (address << 8) | record[i];
                for (var i = 4; i < 8; i++)
                    size = (size << 8) | record[i];

                lock (_gate)
                {
                    _erased = true;
                    _eraseCount++;
                    _transferBuffer.Clear();
                }

                var response = new byte[6];
                response[0] = (byte)(request[0] | 0x40);
                response[1] = request[1];
                response[2] = request[2];
                response[3] = request[3];
                response[4] = 0x00; // routineStatusRecord: complete
                return new UdsServerResponse(response, _options.EraseDelayMs);
            }

            case BuiltinRoutineId.Verify when kind == (byte)RoutineKind.Start:
            {
                if (record.Length != 4)
                    return Negative(request[0], Nrc.IncorrectMessageLengthOrInvalidFormat);
                long expected = 0;
                foreach (var b in record)
                    expected = (expected << 8) | b;

                byte[] image;
                lock (_gate)
                {
                    if (!_erased)
                        return Negative(request[0], Nrc.RequestSequenceError);
                    image = _transferBuffer.ToArray();
                }

                var actual = Crc32.Compute([new FlashSegment(0, image)]);
                if (actual != expected)
                {
                    return Negative(request[0], Nrc.GeneralProgrammingFailure);
                }

                lock (_gate)
                    _verifyCount++;
                return new UdsServerResponse(
                    new byte[] { (byte)(request[0] | 0x40), request[1], request[2], request[3], 0x00 },
                    _options.VerifyDelayMs);
            }

            case BuiltinRoutineId.Erase or BuiltinRoutineId.Verify when kind == (byte)RoutineKind.RequestResults:
                return new UdsServerResponse(
                    new byte[] { (byte)(request[0] | 0x40), request[1], request[2], request[3], 0x00 },
                    _options.ResponseDelayMs);

            default:
                return Negative(request[0], Nrc.RequestOutOfRange);
        }
    }

    private UdsServerResponse HandleRequestDownload(ReadOnlySpan<byte> request)
    {
        if (_session != (byte)UdsSession.Programming)
            return Negative(request[0], Nrc.ServiceNotSupportedInActiveSession);
        if (_securityLevelUnlocked == 0)
            return Negative(request[0], Nrc.SecurityAccessDenied);
        if (_transferActive)
            return Negative(request[0], Nrc.RequestSequenceError);

        // compressionAndEncryption(1) + lengthFormat(1) + address(n) + length(4)
        if (request.Length < 4)
            return Negative(request[0], Nrc.IncorrectMessageLengthOrInvalidFormat);
        var addressSize = request[2] >> 4;
        var lengthSize = request[2] & 0x0F;
        if (addressSize is < 1 or > 8 || lengthSize is < 1 or > 8)
            return Negative(request[0], Nrc.IncorrectMessageLengthOrInvalidFormat);
        if (request.Length != 3 + addressSize + lengthSize)
            return Negative(request[0], Nrc.IncorrectMessageLengthOrInvalidFormat);

        long address = 0;
        for (var i = 0; i < addressSize; i++)
            address = (address << 8) | request[3 + i];
        long length = 0;
        for (var i = 0; i < lengthSize; i++)
            length = (length << 8) | request[3 + addressSize + i];

        lock (_gate)
        {
            if (!_erased)
                return Negative(request[0], Nrc.UploadDownloadNotAccepted);
            _transferActive = true;
            _transferAddress = address;
            _transferLength = length;
            _transferred = 0;
            _expectedBlockSequence = 0x01;
            _transferBuffer.Clear();
        }

        // maxNumberOfBlockLength: format byte (low nibble = value byte
        // count) + 4-byte value 1026 = 2 (SID+BSC) + 1024 payload.
        return new UdsServerResponse(
            new byte[] { (byte)(request[0] | 0x40), 0x04, 0x00, 0x00, 0x04, 0x02 },
            _options.ResponseDelayMs);
    }

    private UdsServerResponse HandleTransferData(ReadOnlySpan<byte> request)
    {
        if (!_transferActive)
            return Negative(request[0], Nrc.RequestSequenceError);
        if (request.Length < 2)
            return Negative(request[0], Nrc.IncorrectMessageLengthOrInvalidFormat);

        lock (_gate)
        {
            if (request[1] != _expectedBlockSequence)
                return Negative(request[0], Nrc.WrongBlockSequenceCounter);
            var chunk = request[2..];
            if (_transferred + chunk.Length > _transferLength)
                return Negative(request[0], Nrc.IncorrectMessageLengthOrInvalidFormat);

            _transferBuffer.AddRange(chunk);
            _transferred += chunk.Length;
            _expectedBlockSequence = (byte)((_expectedBlockSequence + 1) & 0xFF);
            if (_expectedBlockSequence == 0)
                _expectedBlockSequence = 1;
        }

        return new UdsServerResponse(new byte[] {(byte)(request[0] | 0x40), request[1]}, _options.ResponseDelayMs);
    }

    private UdsServerResponse HandleTransferExit(ReadOnlySpan<byte> request)
    {
        if (!_transferActive)
            return Negative(request[0], Nrc.RequestSequenceError);
        lock (_gate)
        {
            if (_transferred != _transferLength)
            {
                ResetTransfer();
                return Negative(request[0], Nrc.RequestSequenceError);
            }

            _lastImage = _transferBuffer.ToArray();
            _transferActive = false;
        }

        return new UdsServerResponse(
            new byte[] { (byte)(request[0] | 0x40) },
            _options.ResponseDelayMs);
    }

    private UdsServerResponse HandleEcuReset(ReadOnlySpan<byte> request)
    {
        if (request.Length != 2)
            return Negative(request[0], Nrc.IncorrectMessageLengthOrInvalidFormat);
        if (request[1] is not (0x01 or 0x03))
            return Negative(request[0], Nrc.SubFunctionNotSupported);

        lock (_gate)
        {
            _session = (byte)UdsSession.Default;
            _securityLevelUnlocked = 0;
            ResetTransfer();
            _erased = false;
        }

        return new UdsServerResponse(new byte[] {(byte)(request[0] | 0x40), request[1]}, _options.ResponseDelayMs);
    }

    private UdsServerResponse Negative(byte sid, Nrc nrc) =>
        new(new byte[] {0x7F, sid, (byte)nrc}, 0);

    private void ResetTransfer()
    {
        _transferActive = false;
        _transferred = 0;
        _transferBuffer.Clear();
        _expectedBlockSequence = 0x01;
    }

    private void CheckS3Timeout()
    {
        lock (_gate)
        {
            if (_session == (byte)UdsSession.Default)
                return;
            var elapsedMs = (Stopwatch.GetTimestamp() - _lastActivityTicks) * 1000.0 / Stopwatch.Frequency;
            if (elapsedMs >= _options.S3TimeoutMs)
            {
                _session = (byte)UdsSession.Default;
                _securityLevelUnlocked = 0;
                ResetTransfer();
            }
        }
    }
}

public enum BuiltinRoutineId : ushort
{
    Erase = 0xFF00,
    Verify = 0xFF01,
}

/// <summary>Configuration of the simulated ECU's diagnostic behavior.</summary>
public sealed record UdsEcuOptions
{
    public int ResponseDelayMs { get; init; } = 2;
    public int EraseDelayMs { get; init; } = 10;
    public int VerifyDelayMs { get; init; } = 10;
    public int S3TimeoutMs { get; init; } = 5000;
    public int MaxSecurityAttempts { get; init; } = 3;
    public int SeedBase { get; init; } = 0x1234;

    /// <summary>Default XOR-based deriver: each seed byte folded with 0x5A.</summary>
    public Func<byte[], byte[]> KeyDeriver { get; init; } =
        seed => seed.Select(b => (byte)(b ^ 0x5A)).ToArray();

    public Dictionary<ushort, byte[]> DataIdentifiers { get; init; } = new()
    {
        [0xF195] = "BenchPilot sim-ecu v1.0.4"u8.ToArray(),
        [0xF186] = [(byte)UdsSession.Default],
        [0xFD00] = "ready"u8.ToArray(),
    };

    public HashSet<ushort> WritableIdentifiers { get; init; } = new() { 0xFD00 };
}
