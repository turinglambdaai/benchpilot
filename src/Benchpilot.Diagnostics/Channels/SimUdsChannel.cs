using Benchpilot.Diagnostics.Flash;
using Benchpilot.Diagnostics.Isotp;
using Benchpilot.Diagnostics.Sim;
using Benchpilot.Diagnostics.Transport;
using Benchpilot.Diagnostics.Uds;

using Benchpilot.Core;

namespace Benchpilot.Diagnostics.Channels;

/// <summary>
/// The simulator's diagnostics channel: a virtual ECU behind a real ISO-TP
/// stack on a virtual CAN segment. Lets agents and CI rehearse the complete
/// UDS flash workflow — session, security access, erase, download, verify,
/// reset — without any hardware, through the same IDiagChannel contract the
/// real transports implement.
/// </summary>
public sealed class SimUdsChannel : IDiagChannel, IDisposable
{
    public const string DriverName = "sim-diagnostics";

    private readonly uint _testerToEcuId;
    private readonly uint _ecuToTesterId;
    private readonly byte? _securityLevel;
    private readonly string _keyDeriverName;
    private readonly int _maxBlockPayload;

    private readonly SimulatedCanBus _bus = new("sim-can0");
    private SimulatedUdsEcu? _ecu;
    private CanUdsChannel? _channel;

    public SimUdsChannel(
        uint testerToEcuId = 0x7E0,
        uint ecuToTesterId = 0x7E8,
        byte? securityLevel = 0x01,
        string keyDeriverName = "xor0x5a",
        int maxBlockPayload = 1024,
        UdsEcuOptions? ecuOptions = null)
    {
        _testerToEcuId = testerToEcuId;
        _ecuToTesterId = ecuToTesterId;
        _securityLevel = securityLevel;
        _keyDeriverName = keyDeriverName;
        _maxBlockPayload = maxBlockPayload;
        EcuOptions = ecuOptions ?? new UdsEcuOptions();
    }

    public UdsEcuOptions EcuOptions { get; }

    public string Transport => "iso-tp/can (simulated)";

    public Task<DiagOpenResult> Open(CancellationToken ct = default)
    {
        if (_channel is not null)
            return Task.FromResult(new DiagOpenResult(true, Transport));

        _ecu = new SimulatedUdsEcu(_bus, _testerToEcuId, _ecuToTesterId, EcuOptions);
        _channel = new CanUdsChannel(
            new SimulatedCanPortBus(_bus.Attach(), "sim-tester"),
            _testerToEcuId,
            _ecuToTesterId,
            _securityLevel,
            _keyDeriverName,
            _maxBlockPayload);
        return Task.FromResult(new DiagOpenResult(true, Transport));
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
        return await _channel!.Request(request, p2TimeoutMs, p2StarTimeoutMs, ct).ConfigureAwait(false);
    }

    public async Task<UdsFlashResult> Flash(UdsFlashPlanSpec plan, CancellationToken ct = default)
    {
        var opened = await Open(ct).ConfigureAwait(false);
        if (!opened.Ok)
            return new UdsFlashResult(false, 0, 0, 0, Array.Empty<FlashStepSummary>(), opened.Error);
        return await _channel!.Flash(plan, ct).ConfigureAwait(false);
    }

    public Task<ResourceHealthResult> CheckHealth(CancellationToken ct = default)
    {
        IReadOnlyDictionary<string, string> details = new Dictionary<string, string>
        {
            ["kind"] = "sim-diagnostics",
            ["transport"] = Transport,
            ["requestId"] = $"0x{_testerToEcuId:X}",
            ["responseId"] = $"0x{_ecuToTesterId:X}",
        };
        return Task.FromResult(new ResourceHealthResult(true, "Simulated UDS ECU is available.", details));
    }

    public void Dispose()
    {
        _channel?.Dispose();
        _ecu?.Dispose();
    }
}
