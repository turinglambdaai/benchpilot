using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using Benchpilot.Diagnostics.Uds;

namespace Benchpilot.Diagnostics.Doip;

/// <summary>
/// ISO 13400-2 diagnostic tool client over TCP: routing activation, alive
/// check answering and diagnostic message transport. Implements the UDS
/// byte pipe, so the same UdsClient and flash engine drive CAN and DoIP.
/// </summary>
public sealed class DoipClient : IUdsTransport, IDisposable
{
    private readonly ushort _testerAddress;
    private readonly ushort _ecuAddress;
    private readonly TcpClient _tcp = new();
    private NetworkStream? _stream;
    private readonly byte[] _buffer = new byte[16 * 1024];
    private int _buffered;

    public DoipClient(ushort testerAddress, ushort ecuAddress)
    {
        _testerAddress = testerAddress;
        _ecuAddress = ecuAddress;
    }

    /// <summary>
    /// Discovers vehicles by UDP broadcast on the DoIP port. Returns every
    /// answer received within the window.
    /// </summary>
    public static async Task<IReadOnlyList<DoipVehicleIdentity>> DiscoverAsync(
        int windowMs = 500,
        CancellationToken ct = default)
    {
        using var udp = new UdpClient();
        udp.EnableBroadcast = true;
        var request = DoipFrame.VehicleIdentificationRequest().ToBytes();
        // Loopback unicast first: simulators and containerized entities bind
        // loopback only, where broadcast is not delivered. The broadcast copy
        // afterwards reaches real entities on the LAN.
        try
        {
            await udp.SendAsync(request, new IPEndPoint(IPAddress.Loopback, DoipPort)).ConfigureAwait(false);
        }
        catch (SocketException)
        {
            // Fall through to broadcast.
        }

        await udp.SendAsync(request, new IPEndPoint(IPAddress.Broadcast, DoipPort)).ConfigureAwait(false);

        var identities = new List<DoipVehicleIdentity>();
        var receiveTask = Task.Run(async () =>
        {
            var deadline = DateTimeOffset.UtcNow.AddMilliseconds(windowMs);
            while (DateTimeOffset.UtcNow < deadline)
            {
                using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                timeoutCts.CancelAfter((int)(deadline - DateTimeOffset.UtcNow).TotalMilliseconds + 50);
                try
                {
                    var result = await udp.ReceiveAsync(timeoutCts.Token).ConfigureAwait(false);
                    if (TryDecodeVehicleResponse(result.Buffer, out var identity))
                    {
                        identity = identity with { IpAddress = result.RemoteEndPoint.Address.ToString() };
                        identities.Add(identity);
                    }
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                catch (SocketException)
                {
                    // Windows raises ConnectionReset on the receive after an
                    // ICMP port-unreachable (for example from the broadcast
                    // copy); keep listening for unicast answers.
                    continue;
                }
            }
        }, ct);

        try
        {
            await receiveTask.WaitAsync(TimeSpan.FromMilliseconds(windowMs + 2000), ct).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            // Discovery window over; return what arrived.
        }

        return identities;
    }

    public const int DoipPort = 13400;

    /// <summary>Connects TCP, then performs the routing activation handshake.</summary>
    public async Task ConnectAsync(string host, int port = DoipPort, CancellationToken ct = default)
    {
        await _tcp.ConnectAsync(host, port, ct).ConfigureAwait(false);
        _stream = _tcp.GetStream();

        await WriteFrameAsync(DoipFrame.RoutingActivationRequest(_testerAddress), ct).ConfigureAwait(false);
        var response = await ReadFrameAsync(ct).ConfigureAwait(false);
        if (response.Type != DoipPayloadType.RoutingActivationResponse || response.Payload.Length < 5)
            throw new DoipException($"Unexpected routing activation response type {response.Type}.");
        var code = response.Payload[4];
        if (code is not ((byte)RoutingActivationResult.Accepted or
                (byte)RoutingActivationResult.Confirmed or
                (byte)RoutingActivationResult.AlreadyActive))
            throw new DoipException($"Routing activation denied (code 0x{code:X2}).");
    }

    public async Task SendRequestAsync(ReadOnlyMemory<byte> request, CancellationToken ct)
    {
        if (_stream is null)
            throw new DoipException("DoIP client is not connected.");
        await WriteFrameAsync(
            DoipFrame.DiagnosticMessage(_testerAddress, _ecuAddress, request.Span), ct).ConfigureAwait(false);
    }

    public async Task<ReadOnlyMemory<byte>> ReceiveResponseAsync(CancellationToken ct)
    {
        if (_stream is null)
            throw new DoipException("DoIP client is not connected.");

        while (true)
        {
            var frame = await ReadFrameAsync(ct).ConfigureAwait(false);
            switch (frame.Type)
            {
                case DoipPayloadType.DiagnosticMessage:
                    if (DoipFrame.TryGetDiagnosticTarget(frame) != _testerAddress)
                        continue;
                    return DoipFrame.GetDiagnosticUserData(frame);

                case DoipPayloadType.DiagnosticNegativeAcknowledgement:
                    throw new DoipException(
                        $"DoIP negative acknowledgement (code 0x{(frame.Payload.Length > 4 ? frame.Payload[4] : 0):X2}).");

                case DoipPayloadType.AliveCheckRequest:
                    await WriteFrameAsync(new DoipFrame
                    {
                        Type = DoipPayloadType.AliveCheckResponse,
                        Payload = [0x00, 0x00],
                    }, ct).ConfigureAwait(false);
                    continue;

                case DoipPayloadType.GenericHeaderNegativeAcknowledge:
                    throw new DoipException("DoIP generic header negative acknowledgement.");

                default:
                    continue;
            }
        }
    }

    private async Task WriteFrameAsync(DoipFrame frame, CancellationToken ct)
    {
        if (_stream is null)
            throw new DoipException("DoIP client is not connected.");
        var bytes = frame.ToBytes();
        await _stream.WriteAsync(bytes, ct).ConfigureAwait(false);
        await _stream.FlushAsync(ct).ConfigureAwait(false);
    }

    private async Task<DoipFrame> ReadFrameAsync(CancellationToken ct)
    {
        if (_stream is null)
            throw new DoipException("DoIP client is not connected.");

        while (true)
        {
            if (DoipFrame.TryDecode(_buffer.AsSpan(0, _buffered), out var frame, out var consumed))
            {
                _buffered -= consumed;
                if (_buffered > 0)
                    Buffer.BlockCopy(_buffer, consumed, _buffer, 0, _buffered);
                return frame;
            }

            if (_buffered >= _buffer.Length)
                throw new DoipException("DoIP receive buffer exhausted.");

            var read = await _stream.ReadAsync(_buffer.AsMemory(_buffered), ct).ConfigureAwait(false);
            if (read == 0)
                throw new DoipException("DoIP connection closed by peer.");
            _buffered += read;
        }
    }

    private static bool TryDecodeVehicleResponse(ReadOnlySpan<byte> bytes, out DoipVehicleIdentity identity)
    {
        identity = new DoipVehicleIdentity(string.Empty, 0);
        if (!DoipFrame.TryDecode(bytes, out var frame, out _) ||
            frame.Type != DoipPayloadType.VehicleIdentificationResponse ||
            frame.Payload.Length < 21)
            return false;

        var vin = System.Text.Encoding.ASCII.GetString(frame.Payload.AsSpan(0, 17)).TrimEnd('\0');
        var logicalAddress = BinaryPrimitives.ReadUInt16BigEndian(frame.Payload.AsSpan(17, 2));
        identity = new DoipVehicleIdentity(vin, logicalAddress);
        return true;
    }

    public void Dispose()
    {
        _stream?.Dispose();
        _tcp.Dispose();
    }
}
