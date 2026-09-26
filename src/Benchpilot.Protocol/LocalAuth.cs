using System.Security.Cryptography;
using System.Text;

namespace Benchpilot.Protocol;

/// <summary>
/// Loopback API authentication shared by benchpilotd and every client shell.
/// The daemon generates a random token on first start and stores it under the
/// user profile; clients read the same file so only local user processes can
/// call the API even though it binds to loopback.
/// </summary>
public static class LocalAuth
{
    public const string HeaderName = "X-Benchpilot-Token";

    public static string DirectoryPath
    {
        get
        {
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            return Path.Combine(home, ".benchpilot");
        }
    }

    public static string TokenFilePath => Path.Combine(DirectoryPath, "token");

    public static string LogDirectoryPath => Path.Combine(DirectoryPath, "logs");

    /// <summary>
    /// Returns the local API token, generating and persisting one on first use.
    /// </summary>
    public static string ResolveOrCreateToken()
    {
        var existing = ReadToken();
        if (existing is not null)
            return existing;

        var bytes = RandomNumberGenerator.GetBytes(32);
        var token = Convert.ToHexString(bytes).ToLowerInvariant();

        Directory.CreateDirectory(DirectoryPath);
        File.WriteAllText(TokenFilePath, token, new UTF8Encoding(false));
        try
        {
            if (!OperatingSystem.IsWindows())
                File.SetUnixFileMode(
                    TokenFilePath,
                    UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
        catch (PlatformNotSupportedException)
        {
            // Best effort hardening on platforms without Unix file modes.
        }

        return token;
    }

    /// <summary>
    /// Returns the local API token for client shells, or null when the daemon
    /// has not created one yet (for example before the first start).
    /// </summary>
    public static string? ReadToken()
    {
        try
        {
            var value = File.ReadAllText(TokenFilePath).Trim();
            return value.Length == 0 ? null : value;
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
    }
}
