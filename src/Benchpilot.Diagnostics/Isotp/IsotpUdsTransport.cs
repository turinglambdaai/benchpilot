using Benchpilot.Diagnostics.Uds;

namespace Benchpilot.Diagnostics.Isotp;

/// <summary>
/// Bridges the ISO-TP network layer into the UDS byte-pipe contract.
/// Diagnostic traffic is half-duplex: one request, then responses until
/// complete, then the next request.
/// </summary>
public sealed class IsotpUdsTransport(IsotpEndpoint endpoint) : IUdsTransport
{
    public async Task SendRequestAsync(ReadOnlyMemory<byte> request, CancellationToken ct) =>
        await endpoint.SendAsync(request, ct).ConfigureAwait(false);

    public async Task<ReadOnlyMemory<byte>> ReceiveResponseAsync(CancellationToken ct)
    {
        var payload = await endpoint.ReceiveAsync(ct).ConfigureAwait(false);
        return payload;
    }
}

/// <summary>
/// Opens a UdsClient on top of an ISO-TP endpoint, wired to the given
/// CAN bus and address pair.
/// </summary>
public static class IsotpUdsTransportFactory
{
    public static UdsClient Create(ICanBus bus, uint txId, uint rxId, IsotpOptions? options = null)
    {
        var endpoint = new IsotpEndpoint(bus, txId, rxId, options);
        return new UdsClient(new IsotpUdsTransport(endpoint));
    }
}
