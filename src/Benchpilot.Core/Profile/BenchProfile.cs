using System.Text.Json;
using System.Text.Json.Serialization;

namespace Benchpilot.Core;

/// <summary>
/// Describes a physical or simulated bench. A bench owns reusable resources
/// (power supplies, probes, buses, serial ports, ...); targets bind semantic
/// capabilities such as "power" or "flash" to those resources.
///
/// The legacy P0 fields are intentionally retained for profile compatibility.
/// ProfileLoader normalizes old profiles into the resource/target model.
/// </summary>
public record BenchProfile
{
    [JsonPropertyName("schemaVersion")] public int SchemaVersion { get; init; } = 1;
    [JsonPropertyName("name")] public string Name { get; init; } = "BenchPilot bench";
    [JsonPropertyName("defaultTarget")] public string? DefaultTarget { get; init; }

    [JsonPropertyName("resources")]
    public Dictionary<string, BenchResourceConfig> Resources { get; init; }
        = new(StringComparer.OrdinalIgnoreCase);

    [JsonPropertyName("targets")]
    public Dictionary<string, BenchTargetConfig> Targets { get; init; }
        = new(StringComparer.OrdinalIgnoreCase);

    [JsonPropertyName("safety")] public BenchSafetyPolicy Safety { get; init; } = new();

    // P0 compatibility. New profiles should use resources + targets instead.
    [JsonPropertyName("driver")] public string? Driver { get; init; }
    [JsonPropertyName("board")] public Board? Board { get; init; }
    [JsonPropertyName("power")] public PowerConfig? Power { get; init; }
    [JsonPropertyName("serial")] public SerialConfig? Serial { get; init; }
    [JsonPropertyName("flash")] public FlashConfig? Flash { get; init; }
}

/// <summary>
/// A concrete device/backend on the bench. One resource may expose multiple
/// capabilities; the simulator is the first example (power + serial + flash).
/// Driver-specific values live in Settings so Core does not take dependencies
/// on vendor SDKs or transport packages.
/// </summary>
public record BenchResourceConfig
{
    [JsonPropertyName("driver")] public string Driver { get; init; } = string.Empty;

    [JsonPropertyName("capabilities")]
    public IReadOnlyList<string> Capabilities { get; init; } = Array.Empty<string>();

    [JsonPropertyName("settings")]
    public Dictionary<string, JsonElement> Settings { get; init; }
        = new(StringComparer.OrdinalIgnoreCase);
}

/// <summary>
/// A semantic ECU/target. Bindings map a capability to a resource id, e.g.
/// "power" -> "psu.main", "can" -> "can.vehicle", "flash" -> "probe.radar".
/// Agents operate on targets rather than OS device names.
/// </summary>
public record BenchTargetConfig
{
    [JsonPropertyName("name")] public string Name { get; init; } = string.Empty;
    [JsonPropertyName("mcu")] public string? Mcu { get; init; }

    [JsonPropertyName("bindings")]
    public Dictionary<string, string> Bindings { get; init; }
        = new(StringComparer.OrdinalIgnoreCase);
}

/// <summary>
/// Cross-cutting safety constraints. The schema deliberately starts small;
/// protocol-specific policy (UDS services, CAN tx ids, protected memory, ...)
/// will be added without putting secrets or vendor logic in Core.
/// </summary>
public record BenchSafetyPolicy
{
    [JsonPropertyName("maxVoltage")] public double? MaxVoltage { get; init; }
    [JsonPropertyName("maxCurrentMa")] public double? MaxCurrentMa { get; init; }
    [JsonPropertyName("requireExplicitTarget")] public bool RequireExplicitTarget { get; init; }
}

// Legacy P0 records. Kept so existing profiles continue to deserialize.
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
