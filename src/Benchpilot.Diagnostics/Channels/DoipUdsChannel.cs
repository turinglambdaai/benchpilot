using System.Net.Sockets;
using Benchpilot.Diagnostics.Doip;
using Benchpilot.Diagnostics.Flash;
using Benchpilot.Diagnostics.Uds;

using Benchpilot.Core;

namespace Benchpilot.Diagnostics.Channels;

/// <summary>
/// UDS diagnostics over ISO 13400-2 (DoIP). Connects TCP, activates routing
/// once, then serves UDS transactions over diagnostic messages. The same
/// flash engine drives this channel unchanged.
/// </summary>
public sealed class DoipUdsChannel : IDiagChannel, IDisposable
{
    private readonly string _host;
    private readonly int _port;
    private readonly ushort _testerAddress;
    private readonly ushort _ecuAddress;
    private readonly byte? _securityLevel;
    private readonly string _keyDeriverName;
    private readonly int _maxBlockPayload;

    private DoipClient? _client;
    private UdsClient? _uds;
    private UdsFlashEngine? _engine;
    private readonly SemaphoreSlim _connectGate = new(1, 1);

    public DoipUdsChannel(
        string host,
        int port,
        ushort testerAddress,
        ushort ecuAddress,
        byte? securityLevel = null,
        string keyDeriverName = "xor0x5a",
        int maxBlockPayload = 1024)
    {
        _host = host;
        _port = port;
        _testerAddress = testerAddress;
        _ecuAddress = ecuAddress;
        _securityLevel = securityLevel;
        _keyDeriverName = keyDeriverName;
        _maxBlockPayload = maxBlockPayload;
    }

    public string Transport => "doip";

    public async Task<DiagOpenResult> Open(CancellationToken ct = default)
    {
        if (_client is not null)
            return new DiagOpenResult(true, Transport);

        await _connectGate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (_client is not null)
                return new DiagOpenResult(true, Transport);

            var client = new DoipClient(_testerAddress, _ecuAddress);
            try
            {
                await client.ConnectAsync(_host, _port, ct).ConfigureAwait(false);
                _client = client;
                _uds = new UdsClient(client);
                _engine = new UdsFlashEngine(_uds, KeyDerivers.Builtin);
                return new DiagOpenResult(true, Transport);
            }
            catch (Exception ex) when (ex is SocketException or IOException or DoipException)
            {
                client.Dispose();
                return new DiagOpenResult(false, Transport, ex.Message);
            }
        }
        finally
        {
            _connectGate.Release();
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
            return new UdsRequestResult(false, false, CanUdsChannel.ToHex(request.Span), null, null, opened.Error);

        var hex = CanUdsChannel.ToHex(request.Span);
        try
        {
            var response = await _uds!.SendAsync(
                request,
                new UdsTiming { P2TimeoutMs = p2TimeoutMs, P2StarTimeoutMs = p2StarTimeoutMs },
                ct).ConfigureAwait(false);

            if (response.Positive)
                return new UdsRequestResult(true, true, hex, CanUdsChannel.ToHex(response.Payload.Span), null);
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
        catch (DoipException ex)
        {
            // Connection-level failure resets the channel; the next call reconnects.
            DisposeClient();
            return new UdsRequestResult(false, false, hex, null, null, ex.Message);
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
        catch (DoipException ex)
        {
            DisposeClient();
            return new UdsFlashResult(
                false, 0, 0, 0, Array.Empty<FlashStepSummary>(), ex.Message);
        }
    }

    public Task<ResourceHealthResult> CheckHealth(CancellationToken ct = default)
    {
        IReadOnlyDictionary<string, string> details = new Dictionary<string, string>
        {
            ["kind"] = "doip",
            ["host"] = _host,
            ["port"] = _port.ToString(),
            ["testerAddress"] = $"0x{_testerAddress:X4}",
            ["ecuAddress"] = $"0x{_ecuAddress:X4}",
        };
        return Task.FromResult(new ResourceHealthResult(true, "DoIP channel is configured.", details));
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

    private void DisposeClient()
    {
        _client?.Dispose();
        _client = null;
        _uds = null;
        _engine = null;
    }

    public void Dispose()
    {
        DisposeClient();
        _connectGate.Dispose();
    }
}
