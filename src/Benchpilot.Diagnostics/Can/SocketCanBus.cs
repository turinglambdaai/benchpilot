using System.Runtime.InteropServices;
using System.Runtime.Versioning;

using Benchpilot.Diagnostics.Isotp;

namespace Benchpilot.Diagnostics.Can;

/// <summary>
/// SocketCAN transport (Linux). One raw CAN socket bound to one interface.
/// Frame layout is the kernel's struct can_frame; the diagnostic stack owns
/// everything above the frame layer.
/// </summary>
[SupportedOSPlatform("linux")]
public sealed class SocketCanBus : ICanBus
{
    private const int PfCan = 29;
    private const int SockRaw = 3;
    private const int CanFrameSize = 16;
    private const uint CanEffFlag = 0x80000000u;
    private const uint CanRtrFlag = 0x40000000u;
    private const uint Siocgifindex = 0x8933;

    private readonly string _interface;
    private int _socket = -1;
    private CancellationTokenSource? _cts;
    private Task? _pump;

    public SocketCanBus(string interfaceName)
    {
        _interface = interfaceName;
    }

    public string Name => _interface;

    public event Action<CanFrame>? FrameReceived;

    public Task OpenAsync(CancellationToken ct = default)
    {
        if (_pump is not null)
            return Task.CompletedTask;

        var fd = socket(PfCan, SockRaw, 0);
        if (fd < 0)
            throw new InvalidOperationException(
                $"SocketCAN: socket() failed (errno {Marshal.GetLastWin32Error()}).");

        var ifr = new Ifreq { Name = _interface };
        if (ioctl(fd, Siocgifindex, ref ifr) < 0)
        {
            close(fd);
            throw new InvalidOperationException(
                $"SocketCAN: interface '{_interface}' not found (errno {Marshal.GetLastWin32Error()}). " +
                "Bring the interface up first, for example: sudo ip link set can0 up type can bitrate 500000");
        }

        var addr = new SockAddrCan { Family = (short)PfCan, IfIndex = ifr.Index };
        if (bind(fd, ref addr, Marshal.SizeOf<SockAddrCan>()) < 0)
        {
            close(fd);
            throw new InvalidOperationException(
                $"SocketCAN: bind failed (errno {Marshal.GetLastWin32Error()}).");
        }

        _socket = fd;
        _cts = new CancellationTokenSource();
        _pump = Task.Run(() => PumpAsync(fd, _cts.Token), CancellationToken.None);
        return Task.CompletedTask;
    }

    public Task SendAsync(CanFrame frame, CancellationToken ct = default)
    {
        if (_socket < 0)
            throw new InvalidOperationException("SocketCAN: bus is not open.");
        if (frame.Data.Length > 8)
            throw new ArgumentException("Classic CAN frames carry at most 8 data bytes.", nameof(frame));

        var buffer = EncodeFrame(frame);
        var written = send(_socket, buffer, (UIntPtr)buffer.Length, 0);
        if (written < 0)
            throw new InvalidOperationException(
                $"SocketCAN: send failed (errno {Marshal.GetLastWin32Error()}).");
        return Task.CompletedTask;
    }

    private async Task PumpAsync(int fd, CancellationToken ct)
    {
        var buffer = new byte[CanFrameSize];
        while (!ct.IsCancellationRequested)
        {
            var read = recv(fd, buffer, (UIntPtr)buffer.Length, 0);
            if (read < CanFrameSize)
                continue;
            if (TryDecodeFrame(buffer, out var frame))
                FrameReceived?.Invoke(frame);
        }
    }

    internal static byte[] EncodeFrame(CanFrame frame)
    {
        var buffer = new byte[CanFrameSize];
        var id = frame.ExtendedId ? frame.Id | CanEffFlag : frame.Id;
        BitConverter.GetBytes(id).CopyTo(buffer, 0);
        buffer[4] = (byte)frame.Data.Length;
        frame.Data.Span.CopyTo(buffer.AsSpan(8, 8));
        return buffer;
    }

    internal static bool TryDecodeFrame(byte[] buffer, out CanFrame frame)
    {
        frame = default;
        var id = BitConverter.ToUInt32(buffer, 0);
        var dlc = buffer[4];
        if (dlc > 8)
            return false;
        if ((id & CanRtrFlag) != 0)
            return false;
        frame = new CanFrame(
            id & ~CanEffFlag & ~CanRtrFlag,
            (id & CanEffFlag) != 0,
            buffer.AsMemory(8, dlc));
        return true;
    }

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

        if (_socket >= 0)
            close(_socket);
        _cts?.Dispose();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1, Size = 40)]
    private struct Ifreq
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 16)]
        public string Name;
        public int Index;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct SockAddrCan
    {
        public short Family;
        public short Pad;
        public int IfIndex;
        public long Pad2;
    }

    [DllImport("libc", SetLastError = true)]
    private static extern int socket(int domain, int type, int protocol);

    [DllImport("libc", SetLastError = true)]
    private static extern int ioctl(int fd, uint request, ref Ifreq ifr);

    [DllImport("libc", SetLastError = true)]
    private static extern int bind(int fd, ref SockAddrCan addr, int addrlen);

    [DllImport("libc", SetLastError = true)]
    private static extern int send(int fd, byte[] buffer, UIntPtr length, int flags);

    [DllImport("libc", SetLastError = true)]
    private static extern int recv(int fd, byte[] buffer, UIntPtr length, int flags);

    [DllImport("libc", SetLastError = true)]
    private static extern int close(int fd);
}
