using System.Runtime.InteropServices;

namespace Benchpilot.RuntimeHost;

/// <summary>
/// Detaches the daemon from the console handles it inherited from the shell
/// that spawned it (autostart). Without this, the daemon keeps the parent's
/// stdout/stderr pipe handles open: the parent exits, but whoever reads that
/// pipe waits for EOF forever because a live process still holds the write
/// end. Replacing stdio with the NUL device releases the inherited handles
/// while keeping writes harmless if something ever logs to the console.
/// </summary>
internal static class StdioDetach
{
    private const int StdInputHandle = -10;
    private const int StdOutputHandle = -11;
    private const int StdErrorHandle = -12;

    public static void DisconnectConsole()
    {
        if (OperatingSystem.IsWindows())
            DisconnectWindows();
        else
            RedirectPosix();
    }

    private static void DisconnectWindows()
    {
        var nul = CreateFileW(
            "NUL",
            GenericRead | GenericWrite,
            FileShareRead | FileShareWrite,
            IntPtr.Zero,
            OpenExisting,
            0,
            IntPtr.Zero);
        if (nul == InvalidHandle)
            return;

        ReplaceStandardHandle(StdInputHandle, nul);
        ReplaceStandardHandle(StdOutputHandle, nul);
        ReplaceStandardHandle(StdErrorHandle, nul);
    }

    private static void ReplaceStandardHandle(int stdHandleNumber, IntPtr replacement)
    {
        var previous = GetStdHandle(stdHandleNumber);
        if (previous == InvalidHandle || previous == IntPtr.Zero)
            return;
        SetStdHandle(stdHandleNumber, replacement);
        CloseHandle(previous);
    }

    private static void RedirectPosix()
    {
        // dup2 /dev/null over fd 0/1/2: the inherited pipe fds are closed by
        // dup2 itself, and any later console write lands in /dev/null.
        var nullFd = open("/dev/null", OpenWriteOnly);
        if (nullFd < 0)
            return;
        var inputFd = open("/dev/null", OpenReadOnly);
        if (inputFd >= 0)
        {
            dup2(inputFd, 0);
            if (inputFd > 2)
                close(inputFd);
        }
        dup2(nullFd, 1);
        dup2(nullFd, 2);
        if (nullFd > 2)
            close(nullFd);
    }

    private const uint GenericRead = 0x80000000;
    private const uint GenericWrite = 0x40000000;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint OpenExisting = 3;
    private static readonly IntPtr InvalidHandle = new(-1);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateFileW(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetStdHandle(int nStdHandle, IntPtr hHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("libc", SetLastError = true)]
    private static extern int open(string path, int flags);

    [DllImport("libc", SetLastError = true)]
    private static extern int dup2(int oldFd, int newFd);

    [DllImport("libc", SetLastError = true)]
    private static extern int close(int fd);

    private const int OpenReadOnly = 0;
    private const int OpenWriteOnly = 1;
}
