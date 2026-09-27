using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;
using Benchpilot.Diagnostics.Uds;

namespace Benchpilot.Diagnostics.Flash;

/// <summary>One contiguous memory segment to program.</summary>
public sealed record FlashSegment(
    [property: JsonPropertyName("address")] long Address,
    [property: JsonPropertyName("data")] byte[] Data);

/// <summary>
/// A declarative flash definition, transport independent: the same plan runs
/// over ISO-TP/CAN or DoIP with identical safety behavior.
/// </summary>
public sealed record UdsFlashPlan
{
    [JsonPropertyName("segments")]
    public IReadOnlyList<FlashSegment> Segments { get; init; } = Array.Empty<FlashSegment>();

    /// <summary>Max payload bytes per TransferData block, transport dependent.</summary>
    [JsonPropertyName("maxBlockPayload")]
    public int MaxBlockPayload { get; init; } = 1024;

    /// <summary>Programming session the engine enters before touching flash.</summary>
    [JsonPropertyName("session")] public byte Session { get; init; } = 0x02;

    /// <summary>Odd security access level to request a seed for; null skips security access.</summary>
    [JsonPropertyName("securityLevel")] public byte? SecurityLevel { get; init; }

    /// <summary>Named key deriver registered with the engine (never serialized keys).</summary>
    [JsonPropertyName("keyDeriver")] public string? KeyDeriver { get; init; }

    [JsonPropertyName("eraseRoutineId")] public ushort EraseRoutineId { get; init; } = 0xFF00;
    [JsonPropertyName("verifyRoutineId")] public ushort VerifyRoutineId { get; init; } = 0xFF01;

    /// <summary>Retries per failed TransferData block before the workflow fails.</summary>
    [JsonPropertyName("blockRetries")] public int BlockRetries { get; init; } = 0;

    [JsonPropertyName("p2TimeoutMs")] public int P2TimeoutMs { get; init; } = 1000;
    [JsonPropertyName("p2StarTimeoutMs")] public int P2StarTimeoutMs { get; init; } = 10000;

    public static UdsFlashPlan FromJson(string json) =>
        JsonSerializer.Deserialize<UdsFlashPlan>(json, JsonOptions.Value)
        ?? throw new UdsFlashException("Flash plan JSON deserialized to null.");

    public static UdsFlashPlan FromJsonFile(string path) =>
        FromJson(File.ReadAllText(path));

    [JsonIgnore]
    internal static Lazy<JsonSerializerOptions> JsonOptions { get; } = new(() => new(JsonSerializerDefaults.Web));
}

/// <summary>One audit entry of the flash workflow, LLM-context friendly.</summary>
public sealed record FlashAuditStep(
    string Step,
    bool Ok,
    string Detail,
    double DurationMs,
    string? Nrc = null);

/// <summary>Machine-readable result of one flash workflow execution.</summary>
public sealed record UdsFlashExecution(
    bool Ok,
    int SegmentCount,
    long TotalBytes,
    double DurationMs,
    IReadOnlyList<FlashAuditStep> Steps,
    string? Error = null)
{
    public static UdsFlashExecution Fail(IReadOnlyList<FlashAuditStep> steps, string error, double durationMs) =>
        new(false, 0, 0, durationMs, steps, error);
}

public sealed class UdsFlashException : Exception
{
    public UdsFlashException(string message, UdsFlashExecution execution) : base(message)
        => Execution = execution;

    public UdsFlashException(string message) : base(message)
    {
    }

    public UdsFlashExecution? Execution { get; }
}

/// <summary>
/// Seeds become keys. Implementations must be registered per plan name at
/// engine construction; the plan JSON never carries keys.
/// </summary>
public delegate byte[] UdsKeyDeriver(byte[] seed);

/// <summary>
/// Executes a UdsFlashPlan against a UdsClient: session, security access,
/// erase routine, per-segment download (RequestDownload / TransferData /
/// RequestTransferExit), verification routine and ECU reset. Every step is
/// audited; failures surface the audit trail.
/// </summary>
public sealed class UdsFlashEngine
{
    private readonly UdsClient _client;
    private readonly IReadOnlyDictionary<string, UdsKeyDeriver> _keyDerivers;

    public UdsFlashEngine(UdsClient client, IReadOnlyDictionary<string, UdsKeyDeriver>? keyDerivers = null)
    {
        _client = client;
        _keyDerivers = keyDerivers ?? new Dictionary<string, UdsKeyDeriver>();
    }

    public async Task<UdsFlashExecution> ExecuteAsync(
        UdsFlashPlan plan,
        CancellationToken ct = default)
    {
        var sw = Stopwatch.StartNew();
        var steps = new List<FlashAuditStep>();
        long totalBytes = plan.Segments.Sum(x => x.Data.LongLength);

        try
        {
            await EnterSessionAsync(plan, steps, ct).ConfigureAwait(false);
            await SecurityAccessAsync(plan, steps, ct).ConfigureAwait(false);
            await EraseAsync(plan, steps, ct).ConfigureAwait(false);

            foreach (var segment in plan.Segments)
                await DownloadSegmentAsync(plan, segment, steps, ct).ConfigureAwait(false);

            await VerifyAsync(plan, totalBytes, steps, ct).ConfigureAwait(false);
            await ResetAsync(steps, ct).ConfigureAwait(false);

            return new UdsFlashExecution(
                true,
                plan.Segments.Count,
                totalBytes,
                sw.Elapsed.TotalMilliseconds,
                steps);
        }
        catch (Exception ex) when (ex is UdsProtocolException or UdsFlashException or OperationCanceledException)
        {
            var nrc = ex is UdsProtocolException uds && uds.Nrc is { } nrcValue
                ? $"0x{(byte)nrcValue:X2}"
                : null;
            steps.Add(new FlashAuditStep(
                "abort", false, ex.Message, sw.Elapsed.TotalMilliseconds, nrc));
            throw new UdsFlashException(
                $"Flash workflow failed: {ex.Message}",
                new UdsFlashExecution(false, plan.Segments.Count, totalBytes, sw.Elapsed.TotalMilliseconds, steps, ex.Message));
        }
    }

    private async Task EnterSessionAsync(UdsFlashPlan plan, List<FlashAuditStep> steps, CancellationToken ct)
    {
        var sw = Stopwatch.StartNew();
        await _client.RequirePositiveAsync(
            UdsMessages.DiagnosticSession((UdsSession)plan.Session),
            new UdsTiming { P2TimeoutMs = plan.P2TimeoutMs, P2StarTimeoutMs = plan.P2StarTimeoutMs },
            ct).ConfigureAwait(false);
        steps.Add(new FlashAuditStep(
            "diagnostic-session", true, $"session 0x{plan.Session:X2} accepted.", sw.Elapsed.TotalMilliseconds));
    }

    private async Task SecurityAccessAsync(UdsFlashPlan plan, List<FlashAuditStep> steps, CancellationToken ct)
    {
        if (plan.SecurityLevel is null)
            return;
        if (plan.KeyDeriver is null || !_keyDerivers.TryGetValue(plan.KeyDeriver, out var deriver))
            throw new UdsFlashException(
                $"Plan references key deriver '{plan.KeyDeriver}' but no such deriver is registered.");

        var level = plan.SecurityLevel.Value;
        if ((level & 0x01) == 0)
            throw new UdsFlashException($"Security access level 0x{level:X2} must be odd (request seed).");

        var timing = new UdsTiming { P2TimeoutMs = plan.P2TimeoutMs, P2StarTimeoutMs = plan.P2StarTimeoutMs };
        var sw = Stopwatch.StartNew();

        var seedResponse = await _client.RequirePositiveAsync(
            UdsMessages.SecurityAccessRequestSeed(level), timing, ct).ConfigureAwait(false);
        if (seedResponse.Length < 2)
            throw new UdsFlashException("SecurityAccess seed response malformed.");
        var seed = seedResponse[1..].ToArray();

        var key = deriver(seed);
        await _client.RequirePositiveAsync(
            UdsMessages.SecurityAccessSendKey((byte)(level + 1), key), timing, ct).ConfigureAwait(false);
        steps.Add(new FlashAuditStep(
            "security-access", true, $"level 0x{level:X2} unlocked (seed {seed.Length} bytes).", sw.Elapsed.TotalMilliseconds));
    }

    private async Task EraseAsync(UdsFlashPlan plan, List<FlashAuditStep> steps, CancellationToken ct)
    {
        var timing = new UdsTiming { P2TimeoutMs = plan.P2TimeoutMs, P2StarTimeoutMs = plan.P2StarTimeoutMs };
        var sw = Stopwatch.StartNew();

        foreach (var segment in plan.Segments)
        {
            var record = EncodeRoutineAddressAndSize(segment.Address, segment.Data.LongLength);
            var response = await _client.RequirePositiveAsync(
                UdsMessages.RoutineControl(RoutineKind.Start, plan.EraseRoutineId, record),
                timing, ct).ConfigureAwait(false);
            // Payload has the positive SID already stripped: [subFunction,
            // routineIdHi, routineIdLo, routineStatusRecord...].
            if (response.Length < 4 ||
                response.Span[0] != (byte)RoutineKind.Start ||
                (response.Span[1] << 8 | response.Span[2]) != plan.EraseRoutineId)
                throw new UdsFlashException($"Erase routine response mismatch (got {Convert.ToHexString(response.Span)}).");
        }

        steps.Add(new FlashAuditStep(
            "erase", true, $"{plan.Segments.Count} segment(s) erased via routine 0x{plan.EraseRoutineId:X4}.",
            sw.Elapsed.TotalMilliseconds));
    }

    private async Task DownloadSegmentAsync(
        UdsFlashPlan plan,
        FlashSegment segment,
        List<FlashAuditStep> steps,
        CancellationToken ct)
    {
        var timing = new UdsTiming { P2TimeoutMs = plan.P2TimeoutMs, P2StarTimeoutMs = plan.P2StarTimeoutMs };
        var sw = Stopwatch.StartNew();

        var payload = await _client.RequirePositiveAsync(
            UdsMessages.RequestDownload(segment.Address, segment.Data.LongLength),
            timing, ct).ConfigureAwait(false);

        // maxNumberOfBlockLength: lengthOrFormat byte + value bytes.
        if (payload.Length < 2)
            throw new UdsFlashException("RequestDownload response malformed.");
        var sizeBytes = payload.Span[0] & 0x0F;
        long maxBlockLength = 0;
        for (var i = 1; i <= sizeBytes && i < payload.Length; i++)
            maxBlockLength = (maxBlockLength << 8) | payload.Span[i];

        var maxBlockPayload = (int)Math.Min(plan.MaxBlockPayload, Math.Max(2L, maxBlockLength - 2));

        var data = segment.Data;
        var offset = 0;
        var blockSequenceCounter = (byte)0x01;
        var retries = 0;

        while (offset < data.Length)
        {
            var chunk = Math.Min(data.Length - offset, maxBlockPayload);
            try
            {
                await _client.RequirePositiveAsync(
                    UdsMessages.TransferData(blockSequenceCounter, data.AsSpan(offset, chunk)),
                    timing, ct).ConfigureAwait(false);
            }
            catch (UdsProtocolException) when (retries < plan.BlockRetries)
            {
                retries++;
                // Same block again: the sequence counter stays on this block.
                continue;
            }

            offset += chunk;
            blockSequenceCounter = (byte)((blockSequenceCounter + 1) & 0xFF);
            if (blockSequenceCounter == 0)
                blockSequenceCounter = 1;
        }

        await _client.RequirePositiveAsync(
            UdsMessages.RequestTransferExit(), timing, ct).ConfigureAwait(false);

        steps.Add(new FlashAuditStep(
            "download",
            true,
            $"segment @0x{segment.Address:X8}: {data.Length} bytes, {maxBlockPayload}B blocks" +
            (retries > 0 ? $", {retries} retried block(s)" : string.Empty),
            sw.Elapsed.TotalMilliseconds));
    }

    private async Task VerifyAsync(
        UdsFlashPlan plan,
        long totalBytes,
        List<FlashAuditStep> steps,
        CancellationToken ct)
    {
        var timing = new UdsTiming { P2TimeoutMs = plan.P2TimeoutMs, P2StarTimeoutMs = plan.P2StarTimeoutMs };
        var sw = Stopwatch.StartNew();

        var crc = Crc32.Compute(plan.Segments);
        var record = new byte[4];
        record[0] = (byte)((crc >> 24) & 0xFF);
        record[1] = (byte)((crc >> 16) & 0xFF);
        record[2] = (byte)((crc >> 8) & 0xFF);
        record[3] = (byte)(crc & 0xFF);

        var response = await _client.RequirePositiveAsync(
            UdsMessages.RoutineControl(RoutineKind.Start, plan.VerifyRoutineId, record),
            timing, ct).ConfigureAwait(false);
        if (response.Length < 4 ||
            response.Span[0] != (byte)RoutineKind.Start ||
            (response.Span[1] << 8 | response.Span[2]) != plan.VerifyRoutineId)
            throw new UdsFlashException($"Verify routine response mismatch (got {Convert.ToHexString(response.Span)}).");

        steps.Add(new FlashAuditStep(
            "verify",
            true,
            $"CRC32 0x{crc:X8} over {totalBytes} bytes accepted by routine 0x{plan.VerifyRoutineId:X4}.",
            sw.Elapsed.TotalMilliseconds));
    }

    private async Task ResetAsync(List<FlashAuditStep> steps, CancellationToken ct)
    {
        var sw = Stopwatch.StartNew();
        await _client.RequirePositiveAsync(
            UdsMessages.EcuReset(0x01), new UdsTiming { P2TimeoutMs = 5000 }, ct).ConfigureAwait(false);
        steps.Add(new FlashAuditStep("ecu-reset", true, "hard reset accepted.", sw.Elapsed.TotalMilliseconds));
    }

    private static byte[] EncodeRoutineAddressAndSize(long address, long size)
    {
        var addressSize = UdsMessages.AddressLength(address);
        var record = new byte[addressSize + 4];
        var offset = 0;
        for (var shift = (addressSize - 1) * 8; shift >= 0; shift -= 8)
            record[offset++] = (byte)((address >> shift) & 0xFF);
        for (var shift = 24; shift >= 0; shift -= 8)
            record[offset++] = (byte)((size >> shift) & 0xFF);
        return record;
    }
}

public static class Crc32
{
    private static readonly uint[] Table = BuildTable();

    public static uint Compute(IReadOnlyList<FlashSegment> segments)
    {
        uint crc = 0xFFFFFFFF;
        foreach (var segment in segments)
            foreach (var b in segment.Data)
                crc = (crc >> 8) ^ Table[(crc ^ b) & 0xFF];
        return ~crc;
    }

    private static uint[] BuildTable()
    {
        var table = new uint[256];
        for (uint i = 0; i < 256; i++)
        {
            var value = i;
            for (var bit = 0; bit < 8; bit++)
                value = (value & 1) != 0 ? (value >> 1) ^ 0xEDB88320 : value >> 1;
            table[i] = value;
        }

        return table;
    }
}
