using Benchpilot.Diagnostics.Isotp;

namespace Benchpilot.Diagnostics.Transport;

/// <summary>
/// Exposes one SimulatedCanBus port as an ICanBus so the ISO-TP endpoint can
/// attach to it exactly like it would attach to SocketCAN or PCAN.
/// </summary>
public sealed class SimulatedCanPortBus : ICanBus
{
    private readonly SimulatedCanBus.Port _port;
    private readonly string _name;
    private CancellationTokenSource? _cts;
    private Task? _pump;

    public SimulatedCanPortBus(SimulatedCanBus.Port port, string? name = null)
    {
        _port = port;
        _name = name ?? "sim-can-port";
    }

    public string Name => _name;

    public event Action<CanFrame>? FrameReceived;

    public Task OpenAsync(CancellationToken ct = default)
    {
        _cts ??= new CancellationTokenSource();
        _pump ??= PumpAsync(_cts.Token);
        return Task.CompletedTask;
    }

    private async Task PumpAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            CanFrame frame;
            try
            {
                frame = await _port.ReceiveAsync(ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }

            FrameReceived?.Invoke(frame);
        }
    }

    public async Task SendAsync(CanFrame frame, CancellationToken ct = default) =>
        await _port.SendAsync(frame, ct).ConfigureAwait(false);

    public void Dispose()
    {
        _cts?.Cancel();
        try
        {
            _pump?.Wait(1000);
        }
        catch (AggregateException)
        {
            // Pump cancelled.
        }
    }
}
