using System.Runtime.InteropServices;

namespace Benchpilot.Client;

/// <summary>
/// Makes the current shell's stdio handles non-inheritable before spawning
/// benchpilotd. Process creation on every platform hands *all* inheritable
/// handles to the child, not just the three std slots: without this, the
/// daemon would keep a copy of the parent's stdout/stderr pipe handles, and
/// whoever reads the parent's output (a shell pipeline, CI, a test host,
/// an MCP client) waits for EOF forever after the short-lived shell exits.
/// The daemon-side NUL redirect (RuntimeHost.StdioDetach) remains necessary:
/// it releases the redirect pipes this shell creates for the daemon itself.
/// </summary>
public static class StdioInheritance
{
    private const int HandleFlagInherit = 0x00000001;
    private const int FSetFd = 2;
    private const int FdCloexec = 1;

    /// <summary>
    /// Clears the inherit flag on stdin/stdout/stderr. Idempotent and safe
    /// when handles are consoles or files; only pipe inheritance matters
    /// here, and consoles/files have no reader that waits on EOF.
    /// </summary>
    public static void PreventInheritance()
    {
        if (OperatingSystem.IsWindows())
        {
            ClearWindowsInherit(-10);
            ClearWindowsInherit(-11);
            ClearWindowsInherit(-12);
        }
        else
        {
            for (var fd = 0; fd <= 2; fd++)
                fcntl(fd, FSetFd, FdCloexec);
        }
    }

    private static void ClearWindowsInherit(int stdHandleNumber)
    {
        var handle = GetStdHandle(stdHandleNumber);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1))
            return;
        SetHandleInformation(handle, HandleFlagInherit, 0);
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetHandleInformation(IntPtr hObject, int dwMask, int dwFlags);

    [DllImport("libc", SetLastError = true)]
    private static extern int fcntl(int fd, int cmd, int arg);
}
