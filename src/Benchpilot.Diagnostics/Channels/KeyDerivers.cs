using Benchpilot.Diagnostics.Flash;

namespace Benchpilot.Diagnostics.Channels;

/// <summary>
/// Named seed-to-key algorithms selectable from driver settings. Real ECUs
/// use vendor algorithms; custom derivers plug in here by name, never as
/// inline plan data.
/// </summary>
public static class KeyDerivers
{
    public static readonly IReadOnlyDictionary<string, UdsKeyDeriver> Builtin =
        new Dictionary<string, UdsKeyDeriver>(StringComparer.OrdinalIgnoreCase)
        {
            // Demo algorithm used by the simulator: fold every seed byte.
            ["xor0x5a"] = seed => seed.Select(b => (byte)(b ^ 0x5A)).ToArray(),

            // Additive deriver: key[i] = (seed[i] + i + 1).
            ["addindex"] = seed => seed.Select((b, i) => (byte)(b + i + 1)).ToArray(),
        };
}
