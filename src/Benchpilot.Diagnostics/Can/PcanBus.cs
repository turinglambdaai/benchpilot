using System.Runtime.InteropServices;
using System.Runtime.Versioning;

using Benchpilot.Diagnostics.Isotp;

namespace Benchpilot.Diagnostics.Can;

/// <summary>
/// PEAK PCAN-Basic transport (Windows). Requires the vendor driver and
/// PCANBasic.dll next to the runtime (BenchPilot never redistributes vendor
/// binaries). One channel, event-driven receive, classic CAN frames.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class PcanBus : ICanBus
{
    private const int PcanNoneValue = 0x00;
    private const int PcanParameterMessageFilter = 0x2004;
    private const int PcanAcceptanceFilterAll = 0x0000;
    private const uint PcanMessageExtended = 0x0004;
    private const uint PcanMessageRtr = 0x0002;
    private const uint PcanEventReceive = 0x0020;
    private const int PcanMaxFrameLength = 8;

    public const ushort PcanNoneBus = 0x00;

    private readonly ushort _channel;
    private readonly int _bitrate;
    private readonly bool _extendedIds;
    private CancellationTokenSource? _cts;
    private Task? _pump;

    public PcanBus(ushort channel, int bitrate, bool extendedIds = false)
    {
        _channel = channel;
        _bitrate = bitrate;
        _extendedIds = extendedIds;
    }

    public string Name => $"PCAN {_channel}";

    public event Action<CanFrame>? FrameReceived;

    public Task OpenAsync(CancellationToken ct = default)
    {
        if (_pump is not null)
            return Task.CompletedTask;

        var status = CAN_Initialize(_channel, (uint)_bitrate);
        if (status != PcanNoneValue)
            throw new InvalidOperationException(
                $"PCAN: initialize failed for channel {_channel} with status 0x{status:X2}. " +
                "Check that the PCAN driver is installed and the channel is not in use.");

        uint filter = PcanAcceptanceFilterAll;
        CAN_SetValue(_channel, PcanParameterMessageFilter, ref filter, sizeof(uint));

        _cts = new CancellationTokenSource();
        _pump = Task.Run(() => PumpAsync(_cts.Token), CancellationToken.None);
        return Task.CompletedTask;
    }

    public Task SendAsync(CanFrame frame, CancellationToken ct = default)
    {
        if (_pump is null)
            throw new InvalidOperationException("PCAN: bus is not open.");
        if (frame.Data.Length > PcanMaxFrameLength)
            throw new ArgumentException("Classic CAN frames carry at most 8 data bytes.", nameof(frame));

        uint flags = 0;
        if (frame.ExtendedId)
            flags |= PcanMessageExtended;
        if (frame.Id > 0x7FF && !frame.ExtendedId)
            throw new ArgumentException(
                $"CAN id 0x{frame.Id:X} requires extended frames (--extended).", nameof(frame));

        var message = PcanMessage.Create();
        message.Id = frame.Id;
        message.Type = flags;
        message.Length = (byte)frame.Data.Length;
        frame.Data.Span.CopyTo(message.Data);

        var status = CAN_Write(_channel, ref message);
        if (status != PcanNoneValue)
            throw new InvalidOperationException($"PCAN: write failed with status 0x{status:X2}.");
        return Task.CompletedTask;
    }

    private async Task PumpAsync(CancellationToken ct)
    {
        var message = PcanMessage.Create();
        while (!ct.IsCancellationRequested)
        {
            var status = CAN_Read(_channel, ref message, out var timestamp);
            if (status == PcanNoneValue)
            {
                if ((message.Type & PcanMessageRtr) == 0)
                {
                    FrameReceived?.Invoke(new CanFrame(
                        message.Id,
                        (message.Type & PcanMessageExtended) != 0,
                        message.Data.AsMemory(0, message.Length)));
                }

                continue;
            }

            if (status == QrcPcanReceiveQueueEmpty)
            {
                // Wait on the receive event to avoid polling at 100% CPU.
                _ = WaitForSingleObject(PcanReceiveEventHandle(_channel), 50);
                continue;
            }

            await Task.Delay(10, ct).ConfigureAwait(false);
        }
    }

    private const int QrcPcanReceiveQueueEmpty = 0x0100;

    private static IntPtr PcanReceiveEventHandle(ushort channel)
    {
        var handle = IntPtr.Zero;
        var size = (uint)IntPtr.Size;
        CAN_GetValue(channel, PcanEventReceiveInt, ref handle, size);
        return handle;
    }

    private const int PcanEventReceiveInt = unchecked((int)PcanEventReceive);

    public void Dispose()
    {
        _cts?.Cancel();
        try
        {
            _pump?.Wait(1000);
        }
        catch (AggregateException)
        {
        }

        _ = CAN_Uninitialize(_channel);
        _cts?.Dispose();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct PcanMessage
    {
        public uint Id;
        public uint Type;
        public byte Length;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)]
        public byte[] Data;

        public static PcanMessage Create() => new()
        {
            Data = new byte[8],
        };
    }

    [DllImport("PCANBasic", SetLastError = false)]
    private static extern int CAN_Initialize(ushort channel, uint bitrate);

    [DllImport("PCANBasic", SetLastError = false)]
    private static extern int CAN_Uninitialize(ushort channel);

    [DllImport("PCANBasic", SetLastError = false)]
    private static extern int CAN_Write(ushort channel, ref PcanMessage message);

    [DllImport("PCANBasic", SetLastError = false)]
    private static extern int CAN_Read(ushort channel, ref PcanMessage message, out ulong timestamp);

    [DllImport("PCANBasic", SetLastError = false)]
    private static extern int CAN_SetValue(ushort channel, int parameter, ref uint value, uint size);

    [DllImport("PCANBasic", SetLastError = false)]
    private static extern int CAN_GetValue(ushort channel, int parameter, ref IntPtr value, uint size);

    [DllImport("kernel32")]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
}
