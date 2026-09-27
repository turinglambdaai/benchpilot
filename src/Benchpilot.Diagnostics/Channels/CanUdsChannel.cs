using System.Text.Json;
using Benchpilot.Diagnostics.Flash;
using Benchpilot.Diagnostics.Isotp;
using Benchpilot.Diagnostics.Uds;

using Benchpilot.Core;

namespace Benchpilot.Diagnostics.Channels;

/// <summary>
/// UDS diagnostics over ISO-TP on any ICanBus (SocketCAN, PCAN or the
/// simulated bus). Owns one (txId, rxId) address pair and keeps the UDS
/// session/security state resident, like a real tool session.
/// </summary>
public sealed class CanUdsChannel : IDiagChannel, IDisposable
{
    private readonly ICanBus _bus;
    private readonly uint _txId;
    private readonly uint _rxId;
    private readonly byte? _securityLevel;
    private readonly string _keyDeriverName;
    private readonly int _maxBlockPayload;
    private readonly IsotpOptions _isotpOptions;

    private IsotpEndpoint? _endpoint;
    private UdsClient? _client;
    private UdsFlashEngine? _engine;

    public CanUdsChannel(
        ICanBus bus,
        uint txId,
        uint rxId,
        byte? securityLevel = null,
        string keyDeriverName = "xor0x5a",
        int maxBlockPayload = 1024,
        IsotpOptions? isotpOptions = null)
    {
        _bus = bus;
        _txId = txId;
        _rxId = rxId;
        _securityLevel = securityLevel;
        _keyDeriverName = keyDeriverName;
        _maxBlockPayload = maxBlockPayload;
        _isotpOptions = isotpOptions ?? new IsotpOptions();
    }

    public string Transport => "iso-tp/can";

    public async Task<DiagOpenResult> Open(CancellationToken ct = default)
    {
        if (_client is not null)
            return new DiagOpenResult(true, Transport);

        try
        {
            await _bus.OpenAsync(ct).ConfigureAwait(false);
            _endpoint = new IsotpEndpoint(_bus, _txId, _rxId, _isotpOptions);
            _client = new UdsClient(new IsotpUdsTransport(_endpoint));
            _engine = new UdsFlashEngine(_client, KeyDerivers.Builtin);
            return new DiagOpenResult(true, Transport);
        }
        catch (Exception ex) when (ex is IOException or InvalidOperationException or UnauthorizedAccessException)
        {
            return new DiagOpenResult(false, Transport, ex.Message);
        }
    }

    public async Task<UdsRequestResult> Request(
        ReadOnlyMemory<byte> request,
        int p2TimeoutMs,
        int p2StarTimeoutMs,
        CancellationToken ct = default)
    {
        var opened = await Open(ct).ConfigureAwait(false);
        if (!opened.Ok)
            return new UdsRequestResult(false, false, ToHex(request.Span), null, null, opened.Error);

        var client = _client!;
        var hex = ToHex(request.Span);
        try
        {
            var response = await client.SendAsync(
                request,
                new UdsTiming { P2TimeoutMs = p2TimeoutMs, P2StarTimeoutMs = p2StarTimeoutMs },
                ct).ConfigureAwait(false);

            if (response.Positive)
                return new UdsRequestResult(true, true, hex, ToHex(response.Payload.Span), null);
            return new UdsRequestResult(
                true,
                false,
                hex,
                null,
                NrcNames.Name(response.Nrc!.Value));
        }
        catch (UdsProtocolException ex)
        {
            return new UdsRequestResult(
                false,
                false,
                hex,
                null,
                ex.Nrc is { } nrc ? NrcNames.Name(nrc) : null,
                ex.Message);
        }
    }

    public async Task<UdsFlashResult> Flash(UdsFlashPlanSpec spec, CancellationToken ct = default)
    {
        var opened = await Open(ct).ConfigureAwait(false);
        if (!opened.Ok)
            return new UdsFlashResult(false, 0, 0, 0, Array.Empty<FlashStepSummary>(), opened.Error);

        var plan = new UdsFlashPlan
        {
            Segments = spec.Segments
                .Select(x => new FlashSegment(x.Address, ResolveSegmentData(x)))
                .ToArray(),
            MaxBlockPayload = spec.MaxBlockPayload,
            Session = spec.Session,
            SecurityLevel = spec.SecurityLevel,
            KeyDeriver = spec.SecurityLevel is null ? null : spec.KeyDeriver,
            EraseRoutineId = spec.EraseRoutineId,
            VerifyRoutineId = spec.VerifyRoutineId,
            BlockRetries = spec.BlockRetries,
            P2TimeoutMs = spec.P2TimeoutMs,
            P2StarTimeoutMs = spec.P2StarTimeoutMs,
        };

        try
        {
            var execution = await _engine!.ExecuteAsync(plan, ct).ConfigureAwait(false);
            return ToResult(execution);
        }
        catch (UdsFlashException ex) when (ex.Execution is not null)
        {
            return ToResult(ex.Execution);
        }
    }

    public Task<ResourceHealthResult> CheckHealth(CancellationToken ct = default)
    {
        IReadOnlyDictionary<string, string> details = new Dictionary<string, string>
        {
            ["kind"] = "can-uds",
            ["transport"] = Transport,
            ["txId"] = $"0x{_txId:X}",
            ["rxId"] = $"0x{_rxId:X}",
        };
        return Task.FromResult(new ResourceHealthResult(true, "CAN UDS channel is configured.", details));
    }

    private static byte[] ResolveSegmentData(UdsFlashSegmentSpec segment)
    {
        if (segment.Data is { Length: > 0 })
            return segment.Data;
        if (string.IsNullOrWhiteSpace(segment.File))
            throw new UdsFlashException(
                $"Flash segment @0x{segment.Address:X} defines neither inline data nor a file.");
        return File.ReadAllBytes(segment.File);
    }

    private static UdsFlashResult ToResult(UdsFlashExecution execution) => new(
        execution.Ok,
        execution.SegmentCount,
        execution.TotalBytes,
        execution.DurationMs,
        execution.Steps
            .Select(x => new FlashStepSummary(x.Step, x.Ok, x.Detail, x.DurationMs, x.Nrc))
            .ToArray(),
        execution.Error);

    internal static string ToHex(ReadOnlySpan<byte> bytes) =>
        Convert.ToHexString(bytes).ToLowerInvariant();

    public void Dispose()
    {
        _endpoint?.Dispose();
        _bus.Dispose();
    }
}
