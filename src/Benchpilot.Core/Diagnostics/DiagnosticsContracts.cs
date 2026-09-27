namespace Benchpilot.Core;

/// <summary>
/// The vendor-neutral diagnostics capability: one channel to one ECU logical
/// address, over ISO-TP/CAN or DoIP. Raw UDS escape, semantic reads and the
/// flash workflow all run through this one boundary, so the Runtime can gate,
/// audit and evidence them exactly like power/flash/serial.
/// </summary>
public interface IDiagChannel : IResourceHealthCheck
{
    /// <summary>Transport name reported in results (for example "iso-tp/can" or "doip").</summary>
    string Transport { get; }

    /// <summary>Idempotent connect/open of the underlying transport.</summary>
    Task<DiagOpenResult> Open(CancellationToken ct = default);

    /// <summary>
    /// Raw UDS escape: sends one request PDU and returns the decoded outcome.
    /// For expert callers and agent exploration; the flash workflow uses the
    /// same path internally.
    /// </summary>
    Task<UdsRequestResult> Request(
        ReadOnlyMemory<byte> request,
        int p2TimeoutMs,
        int p2StarTimeoutMs,
        CancellationToken ct = default);

    /// <summary>
    /// Executes a declarative flash plan (segments + workflow options) over
    /// this channel. Destructive; callers gate with confirm-target.
    /// </summary>
    Task<UdsFlashResult> Flash(UdsFlashPlanSpec plan, CancellationToken ct = default);
}

public record DiagOpenResult(bool Ok, string Transport, string? Error = null);

public record UdsRequestResult(
    bool Ok,
    bool Positive,
    string RequestHex,
    string? ResponseHex,
    string? Nrc,
    string? Error = null);

/// <summary>
/// Transport-independent flash definition handed to a channel. Segments may
/// carry inline data or a file path the channel resolves.
/// </summary>
public sealed record UdsFlashPlanSpec
{
    public IReadOnlyList<UdsFlashSegmentSpec> Segments { get; init; } =
        Array.Empty<UdsFlashSegmentSpec>();

    public int MaxBlockPayload { get; init; } = 1024;
    public byte Session { get; init; } = 0x02;
    public byte? SecurityLevel { get; init; }
    public string? KeyDeriver { get; init; }
    public ushort EraseRoutineId { get; init; } = 0xFF00;
    public ushort VerifyRoutineId { get; init; } = 0xFF01;
    public int BlockRetries { get; init; } = 0;
    public int P2TimeoutMs { get; init; } = 1000;
    public int P2StarTimeoutMs { get; init; } = 10000;
}

public sealed record UdsFlashSegmentSpec(long Address, byte[]? Data = null, string? File = null);

public sealed record FlashStepSummary(
    string Step,
    bool Ok,
    string Detail,
    double DurationMs,
    string? Nrc = null);

public record UdsFlashResult(
    bool Ok,
    int SegmentCount,
    long TotalBytes,
    double DurationMs,
    IReadOnlyList<FlashStepSummary> Steps,
    string? Error = null);
