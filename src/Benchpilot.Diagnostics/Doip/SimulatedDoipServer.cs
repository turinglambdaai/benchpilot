using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using Benchpilot.Diagnostics.Sim;
using Benchpilot.Diagnostics.Uds;

namespace Benchpilot.Diagnostics.Doip;

/// <summary>
/// A simulated DoIP entity for the simulator: answers UDP vehicle
/// identification requests, accepts one TCP routing activation and serves
/// diagnostic messages through the shared UdsProcessor. Lets the whole DoIP
/// diagnostic path run without hardware.
/// </summary>
public sealed class SimulatedDoipServer : IDisposable
{
    private readonly UdsProcessor _processor;
    private readonly ushort _testerAddress;
    private readonly ushort _ecuAddress;
    private readonly TcpListener _tcp;
    private readonly UdpClient? _udp;
    private readonly CancellationTokenSource _cts = new();
    private readonly List<Task> _tasks = new();

    public UdsProcessor Processor => _processor;
    public IPEndPoint? ListenEndPoint { get; private set; }

    private SimulatedDoipServer(
        UdsProcessor processor,
        ushort testerAddress,
        ushort ecuAddress,
        TcpListener tcp,
        UdpClient? udp,
        string vin,
        ushort announcedLogicalAddress)
    {
        _processor = processor;
        _testerAddress = testerAddress;
        _ecuAddress = ecuAddress;
        _tcp = tcp;
        _udp = udp;

        _tasks.Add(Task.Run(() => AcceptLoopAsync(vin, announcedLogicalAddress, _cts.Token)));
        if (udp is not null)
            _tasks.Add(Task.Run(() => DiscoveryLoopAsync(vin, announcedLogicalAddress, _cts.Token)));
    }

    /// <summary>Starts TCP (and optional UDP discovery) on the loopback interface.</summary>
    public static async Task<SimulatedDoipServer> StartAsync(
        ushort testerAddress = 0x0E00,
        ushort ecuAddress = 0x0E10,
        string vin = "BPILSIMECU0000001",
        bool enableDiscovery = true,
        UdsEcuOptions? options = null,
        CancellationToken ct = default)
    {
        var tcp = new TcpListener(IPAddress.Loopback, 0);
        tcp.Start();
        var endpoint = (IPEndPoint)tcp.LocalEndpoint;

        UdpClient? udp = null;
        if (enableDiscovery)
        {
            udp = new UdpClient();
            udp.Client.Bind(new IPEndPoint(IPAddress.Loopback, DoipClient.DoipPort));
        }

        return new SimulatedDoipServer(
            new UdsProcessor(options),
            testerAddress,
            ecuAddress,
            tcp,
            udp,
            vin,
            ecuAddress)
        {
            ListenEndPoint = endpoint,
        };
    }

    private async Task AcceptLoopAsync(string vin, ushort logicalAddress, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await _tcp.AcceptTcpClientAsync(ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (SocketException)
            {
                return;
            }

            _tasks.Add(Task.Run(() => ServeClientAsync(client, vin, logicalAddress, ct), ct));
        }
    }

    private async Task ServeClientAsync(TcpClient client, string vin, ushort logicalAddress, CancellationToken ct)
    {
        using var disposable = client;
        var stream = client.GetStream();
        var reader = new FrameReader(stream);

        // Routing activation: exactly one per connection (single tester sim).
        var activation = await reader.ReadFrameAsync(ct).ConfigureAwait(false);
        if (activation.Type != DoipPayloadType.RoutingActivationRequest || activation.Payload.Length < 3)
        {
            await WriteFrameAsync(GenericNack(), stream, ct).ConfigureAwait(false);
            return;
        }

        var source = BinaryPrimitives.ReadUInt16BigEndian(activation.Payload.AsSpan(0, 2));
        var response = new DoipFrame
        {
            Type = DoipPayloadType.RoutingActivationResponse,
            Payload =
            [
                .. BitConverter.GetBytes(logicalAddress).Reverse(),
                .. BitConverter.GetBytes(source).Reverse(),
                (byte)RoutingActivationResult.Accepted,
                0, 0, 0, 0,
            ],
        };
        await WriteFrameAsync(response, stream, ct).ConfigureAwait(false);

        while (!ct.IsCancellationRequested)
        {
            DoipFrame frame;
            try
            {
                frame = await reader.ReadFrameAsync(ct).ConfigureAwait(false);
            }
            catch (DoipException)
            {
                return;
            }

            switch (frame.Type)
            {
                case DoipPayloadType.DiagnosticMessage when frame.Payload.Length >= 4:
                {
                    var target = BinaryPrimitives.ReadUInt16BigEndian(frame.Payload.AsSpan(2, 2));
                    if (target != _ecuAddress)
                    {
                        await WriteFrameAsync(DiagNack(frame), stream, ct).ConfigureAwait(false);
                        continue;
                    }

                    var request = DoipFrame.GetDiagnosticUserData(frame);
                    var result = _processor.Process(request.Span);

                    if (result.DelayMs < 0)
                        continue;
                    if (result.DelayMs > 0)
                        await Task.Delay(result.DelayMs, ct).ConfigureAwait(false);

                    var reply = DoipFrame.DiagnosticMessage(_ecuAddress, source, result.Response.Span);
                    await WriteFrameAsync(reply, stream, ct).ConfigureAwait(false);
                    continue;
                }

                case DoipPayloadType.AliveCheckRequest:
                    await WriteFrameAsync(new DoipFrame
                    {
                        Type = DoipPayloadType.AliveCheckResponse,
                        Payload = [0x00, 0x00],
                    }, stream, ct).ConfigureAwait(false);
                    continue;

                default:
                    continue;
            }
        }
    }

    private async Task DiscoveryLoopAsync(string vin, ushort logicalAddress, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            UdpReceiveResult request;
            try
            {
                request = await _udp!.ReceiveAsync(ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (SocketException)
            {
                continue;
            }

            if (!DoipFrame.TryDecode(request.Buffer, out var frame, out _) ||
                frame.Type != DoipPayloadType.VehicleIdentificationRequest)
                continue;

            var payload = new byte[32];
            var vinBytes = System.Text.Encoding.ASCII.GetBytes(vin);
            Array.Copy(vinBytes, payload, Math.Min(17, vinBytes.Length));
            BinaryPrimitives.WriteUInt16BigEndian(payload.AsSpan(17), logicalAddress);
            // EID/GID/reserved/sync stay zero-filled, matching the response shape.

            var response = new DoipFrame
            {
                Type = DoipPayloadType.VehicleIdentificationResponse,
                Payload = payload,
            };
            try
            {
                await _udp!.SendAsync(response.ToBytes(), request.RemoteEndPoint).ConfigureAwait(false);
            }
            catch (SocketException)
            {
                // Discovery answers are best-effort.
            }
        }
    }

    private static DoipFrame GenericNack() =>
        new() { Type = DoipPayloadType.GenericHeaderNegativeAcknowledge, Payload = [0x02] };

    private static DoipFrame DiagNack(DoipFrame frame) => new()
    {
        Type = DoipPayloadType.DiagnosticNegativeAcknowledgement,
        Payload =
        [
            .. frame.Payload.AsSpan(2, 2).ToArray(), // target becomes source of the ack
            .. frame.Payload.AsSpan(0, 2).ToArray(),
            0x02, // invalid source address
        ],
    };

    private sealed class FrameReader(NetworkStream stream)
    {
        private readonly byte[] _buffer = new byte[16 * 1024];
        private int _buffered;

        public async Task<DoipFrame> ReadFrameAsync(CancellationToken ct)
        {
            while (true)
            {
                if (DoipFrame.TryDecode(_buffer.AsSpan(0, _buffered), out var frame, out var consumed))
                {
                    _buffered -= consumed;
                    if (_buffered > 0)
                        Buffer.BlockCopy(_buffer, consumed, _buffer, 0, _buffered);
                    return frame;
                }

                var read = await stream.ReadAsync(_buffer.AsMemory(_buffered), ct).ConfigureAwait(false);
                if (read == 0)
                    throw new DoipException("DoIP client connection closed.");
                _buffered += read;
            }
        }
    }

    private static async Task WriteFrameAsync(DoipFrame frame, NetworkStream stream, CancellationToken ct)
    {
        var bytes = frame.ToBytes();
        await stream.WriteAsync(bytes, ct).ConfigureAwait(false);
        await stream.FlushAsync(ct).ConfigureAwait(false);
    }

    public void Dispose()
    {
        _cts.Cancel();
        _tcp.Stop();
        _udp?.Dispose();
        try
        {
            Task.WaitAll(_tasks.ToArray(), 3000);
        }
        catch (AggregateException)
        {
            // Server tasks cancelled with the shutdown.
        }

        _cts.Dispose();
    }
}
