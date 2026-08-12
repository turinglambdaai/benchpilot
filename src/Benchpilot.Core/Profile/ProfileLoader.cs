using System.Text.Json;

namespace Benchpilot.Core;

// Loads a bench profile from disk or JSON. Unknown fields are ignored so
// profiles keep loading as the schema grows (CAN/DBC/UDS land later).
public static class ProfileLoader
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    public static BenchProfile Load(string path)
    {
        if (!File.Exists(path))
            throw new FileNotFoundException($"Bench profile not found: {path}", path);
        return LoadJson(File.ReadAllText(path));
    }

    public static BenchProfile LoadJson(string json)
    {
        var profile = JsonSerializer.Deserialize<BenchProfile>(json, JsonOpts)
            ?? throw new InvalidOperationException("Failed to parse bench profile JSON.");
        if (string.IsNullOrWhiteSpace(profile.Driver))
            throw new InvalidOperationException("Profile missing required 'driver' field.");
        return profile;
    }

    // Zero-config defaults for the DEMO: a simulated 12V supply, a virtual
    // console port, and a virtual firmware path. Lets `dotnet run` work
    // out of the box without a profile file.
    public static BenchProfile DefaultSimulator() => new()
    {
        Driver = "simulator",
        Board = new Board { Name = "Demo Board", Mcu = "simulated-mcu" },
        Power = new PowerConfig { Voltage = 12, SettleMs = 2000 },
        Serial = new SerialConfig { Port = "SIM0", Baud = 115200 },
        Flash = new FlashConfig { Firmware = "build/app.elf" },
    };
}
