using System.Collections.Concurrent;
using Benchpilot.Diagnostics.Isotp;

namespace Benchpilot.Diagnostics.Transport;

/// <summary>
/// In-process CAN bus segment for the simulator: endpoints attach a port,
/// every sent frame fans out to all ports (including the sender, like a real
/// bus), and each port raises its own receive event. Deterministic and frame
/// accurate, so ISO-TP state machines run the real code path without
/// hardware. ISotpEndpoint filters frames by its rxId, so loopback is safe.
/// </summary>
public sealed class SimulatedCanBus : IDisposable
{
    private readonly string _name;
    private readonly ConcurrentDictionary<Port, byte> _ports = new();
    private readonly ConcurrentQueue<CanFrame> _log = new();
    private readonly object _logGate = new();

    public SimulatedCanBus(string name = "sim-can0")
    {
        _name = name;
    }

    public string Name => _name;

    public int FramesExchanged
    {
        get
        {
            lock (_logGate)
                return _log.Count;
        }
    }

    public Port Attach()
    {
        var port = new Port(this);
        _ports[port] = 0;
        return port;
    }

    public Task SendAsync(CanFrame frame, CancellationToken ct = default)
    {
        lock (_logGate)
            _log.Enqueue(frame);
        foreach (var port in _ports.Keys)
            port.Deliver(frame);
        return Task.CompletedTask;
    }

    public IReadOnlyList<CanFrame> SnapshotLog(int limit = 256)
    {
        lock (_logGate)
            return _log.TakeLast(limit).ToArray();
    }

    public void Dispose() => _ports.Clear();

    public sealed class Port
    {
        private readonly SimulatedCanBus _bus;
        private readonly ConcurrentQueue<CanFrame> _inbox = new();
        private readonly SemaphoreSlim _signal = new(0);

        internal Port(SimulatedCanBus bus) => _bus = bus;

        /// <summary>Sent by the bus when any port transmits; fans into the inbox.</summary>
        internal void Deliver(CanFrame frame)
        {
            _inbox.Enqueue(frame);
            _signal.Release();
        }

        /// <summary>Next frame on the wire for this port (includes loopback).</summary>
        public async Task<CanFrame> ReceiveAsync(CancellationToken ct = default)
        {
            while (true)
            {
                if (_inbox.TryDequeue(out var frame))
                    return frame;
                await _signal.WaitAsync(ct).ConfigureAwait(false);
            }
        }

        public async Task SendAsync(CanFrame frame, CancellationToken ct = default) =>
            await _bus.SendAsync(frame, ct).ConfigureAwait(false);
    }
}
