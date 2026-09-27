using Benchpilot.Diagnostics.Isotp;
using Benchpilot.Diagnostics.Transport;

namespace Benchpilot.Diagnostics.Sim;

/// <summary>
/// A simulated diagnostic ECU on the simulated CAN bus: real ISO-TP
/// endpoints on both sides, the UdsProcessor for behavior, and a background
/// dispatch loop. Deterministic, no hardware, real code path end to end.
/// </summary>
public sealed class SimulatedUdsEcu : IDisposable
{
    private readonly UdsProcessor _processor;
    private readonly IsotpEndpoint _endpoint;
    private readonly SimulatedCanPortBus _bus;
    private readonly CancellationTokenSource _cts = new();
    private readonly Task _loop;

    public UdsProcessor Processor => _processor;

    public SimulatedUdsEcu(
        SimulatedCanBus bus,
        uint testerToEcuId = 0x7E0,
        uint ecuToTesterId = 0x7E8,
        UdsEcuOptions? options = null)
    {
        _processor = new UdsProcessor(options);
        _bus = new SimulatedCanPortBus(bus.Attach(), $"sim-ecu-{testerToEcuId:X3}");
        // Start the receive pump: without it the ECU never sees incoming
        // frames and never answers, deadlocking any multi-frame exchange.
        _ = _bus.OpenAsync();
        _endpoint = new IsotpEndpoint(_bus, ecuToTesterId, testerToEcuId);
        _loop = DispatchLoopAsync(_cts.Token);
    }

    private async Task DispatchLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            byte[] request;
            try
            {
                request = await _endpoint.ReceiveAsync(ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }

            var response = _processor.Process(request);
            if (response.DelayMs < 0 || response.Response.Length == 0)
                continue;

            if (response.DelayMs > 0)
                await Task.Delay(response.DelayMs, ct).ConfigureAwait(false);

            await _endpoint.SendAsync(response.Response, ct).ConfigureAwait(false);
        }
    }

    public void Dispose()
    {
        _cts.Cancel();
        try
        {
            _loop.Wait(2000);
        }
        catch (AggregateException)
        {
            // Loop cancelled.
        }

        _endpoint.Dispose();
        _bus.Dispose();
        _cts.Dispose();
    }
}
