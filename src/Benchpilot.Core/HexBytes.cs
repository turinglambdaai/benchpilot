using System.Globalization;

namespace Benchpilot.Core;

/// <summary>
/// Hex serialization shared by every shell: CLI input is hex, JSON responses
/// are lowercase hex, logs are truncated hex.
/// </summary>
public static class HexBytes
{
    /// <summary>
    /// Parses hex with or without a 0x prefix and with optional interior
    /// spaces; odd-length input is rejected.
    /// </summary>
    public static byte[] Parse(string hex)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(hex);

        var cleaned = hex.Trim();
        if (cleaned.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
            cleaned = cleaned[2..];
        cleaned = cleaned.Replace(" ", string.Empty).Replace("-", string.Empty);

        if (cleaned.Length == 0)
            throw new ArgumentException("Hex payload is empty.", nameof(hex));
        if (cleaned.Length % 2 != 0)
            throw new ArgumentException($"Hex payload has an odd number of digits: '{hex}'.", nameof(hex));

        var bytes = new byte[cleaned.Length / 2];
        for (var i = 0; i < bytes.Length; i++)
        {
            if (!byte.TryParse(
                    cleaned.AsSpan(i * 2, 2),
                    NumberStyles.HexNumber,
                    CultureInfo.InvariantCulture,
                    out var value))
                throw new ArgumentException($"Hex payload contains non-hex characters: '{hex}'.", nameof(hex));
            bytes[i] = value;
        }

        return bytes;
    }

    public static string ToHex(ReadOnlySpan<byte> bytes) =>
        Convert.ToHexString(bytes).ToLowerInvariant();

    public static string TruncateHex(ReadOnlySpan<byte> bytes, int maxBytes = 64)
    {
        if (bytes.Length <= maxBytes)
            return ToHex(bytes);
        return ToHex(bytes[..maxBytes]) + $"…(+{bytes.Length - maxBytes} bytes)";
    }
}
