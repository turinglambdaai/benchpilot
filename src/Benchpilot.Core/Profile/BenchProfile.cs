using System.Text.Json.Serialization;

namespace Benchpilot.Core;

// Bench profile schema v0.1 — PRD §5. P0 scope keeps it to power + serial +
// flash over a single board. CAN, DBC, UDS and the `autosar` field arrive in
// later schema versions; the loader ignores unknown fields so old profiles
// keep loading as the schema grows.
public record BenchProfile
{
    [JsonPropertyName("driver")] public string Driver { get; init; } = "simulator";
    [JsonPropertyName("board")] public Board Board { get; init; } = new();
    [JsonPropertyName("power")] public PowerConfig? Power { get; init; }
    [JsonPropertyName("serial")] public SerialConfig? Serial { get; init; }
    [JsonPropertyName("flash")] public FlashConfig? Flash { get; init; }
}

public record Board
{
    [JsonPropertyName("name")] public string Name { get; init; } = "Demo Board";
    [JsonPropertyName("mcu")] public string Mcu { get; init; } = "simulated-mcu";
}

public record PowerConfig
{
    [JsonPropertyName("voltage")] public double Voltage { get; init; } = 12;
    [JsonPropertyName("settleMs")] public int SettleMs { get; init; } = 2000;
}

public record SerialConfig
{
    [JsonPropertyName("port")] public string Port { get; init; } = "SIM0";
    [JsonPropertyName("baud")] public int Baud { get; init; } = 115200;
}

public record FlashConfig
{
    [JsonPropertyName("firmware")] public string Firmware { get; init; } = "build/app.elf";
}
