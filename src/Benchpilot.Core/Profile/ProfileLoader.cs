using System.Text.Json;

namespace Benchpilot.Core;

/// <summary>
/// Loads, normalizes and validates bench profiles.
///
/// Profiles created by the P0 demo used a single top-level driver. That shape
/// cannot represent a real automotive bench where a target may use a PEAK CAN
/// adapter, J-Link probe, FTDI serial adapter and SCPI power supply at once.
/// The normalized model therefore always exposes Resources + Targets.
/// </summary>
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
        var parsed = JsonSerializer.Deserialize<BenchProfile>(json, JsonOpts)
            ?? throw new InvalidOperationException("Failed to parse bench profile JSON.");

        var profile = Normalize(parsed);
        Validate(profile);
        return profile;
    }

    /// <summary>
    /// Convert a P0 single-driver profile to the resource/target schema. New
    /// profiles are copied into case-insensitive dictionaries so ids and
    /// capability names behave consistently across JSON and programmatic use.
    /// </summary>
    public static BenchProfile Normalize(BenchProfile profile)
    {
        if (profile.Resources.Count > 0 || profile.Targets.Count > 0)
        {
            var resources = profile.Resources.ToDictionary(
                pair => pair.Key,
                pair => pair.Value with
                {
                    Settings = new Dictionary<string, JsonElement>(
                        pair.Value.Settings,
                        StringComparer.OrdinalIgnoreCase),
                },
                StringComparer.OrdinalIgnoreCase);

            var targets = profile.Targets.ToDictionary(
                pair => pair.Key,
                pair => pair.Value with
                {
                    Bindings = new Dictionary<string, string>(
                        pair.Value.Bindings,
                        StringComparer.OrdinalIgnoreCase),
                },
                StringComparer.OrdinalIgnoreCase);

            var defaultTarget = profile.DefaultTarget;
            if (string.IsNullOrWhiteSpace(defaultTarget) && targets.Count == 1)
                defaultTarget = targets.Keys.First();

            return profile with
            {
                DefaultTarget = defaultTarget,
                Resources = resources,
                Targets = targets,
            };
        }

        if (string.IsNullOrWhiteSpace(profile.Driver))
            throw new InvalidOperationException(
                "Profile must define 'resources' + 'targets', or use the legacy 'driver' field.");

        const string resourceId = "legacy.bench";
        const string targetId = "default";

        var capabilities = new List<string>();
        var bindings = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var settings = new Dictionary<string, JsonElement>(StringComparer.OrdinalIgnoreCase);

        if (profile.Power is not null)
        {
            capabilities.Add("power");
            bindings["power"] = resourceId;
            settings["voltage"] = JsonSerializer.SerializeToElement(profile.Power.Voltage);
            settings["settleMs"] = JsonSerializer.SerializeToElement(profile.Power.SettleMs);
        }

        if (profile.Serial is not null)
        {
            capabilities.Add("serial");
            bindings["serial"] = resourceId;
            settings["port"] = JsonSerializer.SerializeToElement(profile.Serial.Port);
            settings["baud"] = JsonSerializer.SerializeToElement(profile.Serial.Baud);
        }

        if (profile.Flash is not null)
        {
            capabilities.Add("flash");
            bindings["flash"] = resourceId;
            settings["firmware"] = JsonSerializer.SerializeToElement(profile.Flash.Firmware);
        }

        return profile with
        {
            SchemaVersion = 1,
            Name = profile.Board?.Name ?? profile.Name,
            DefaultTarget = targetId,
            Resources = new Dictionary<string, BenchResourceConfig>(StringComparer.OrdinalIgnoreCase)
            {
                [resourceId] = new()
                {
                    Driver = profile.Driver,
                    Capabilities = capabilities,
                    Settings = settings,
                },
            },
            Targets = new Dictionary<string, BenchTargetConfig>(StringComparer.OrdinalIgnoreCase)
            {
                [targetId] = new()
                {
                    Name = profile.Board?.Name ?? "Legacy target",
                    Mcu = profile.Board?.Mcu,
                    Bindings = bindings,
                },
            },
        };
    }

    public static BenchTargetConfig ResolveTarget(BenchProfile profile, string? targetName = null)
    {
        var id = string.IsNullOrWhiteSpace(targetName) ? profile.DefaultTarget : targetName;
        if (string.IsNullOrWhiteSpace(id))
            throw new InvalidOperationException(
                "No target was specified and the profile has no 'defaultTarget'.");

        if (!profile.Targets.TryGetValue(id, out var target))
            throw new KeyNotFoundException($"Target '{id}' does not exist in this bench profile.");

        return target;
    }

    public static (string ResourceId, BenchResourceConfig Resource) ResolveResource(
        BenchProfile profile,
        string capability,
        string? targetName = null)
    {
        var target = ResolveTarget(profile, targetName);
        if (!target.Bindings.TryGetValue(capability, out var resourceId))
            throw new InvalidOperationException(
                $"Target '{targetName ?? profile.DefaultTarget}' has no '{capability}' binding.");

        if (!profile.Resources.TryGetValue(resourceId, out var resource))
            throw new InvalidOperationException(
                $"Target binding '{capability}' references missing resource '{resourceId}'.");

        if (!resource.Capabilities.Contains(capability, StringComparer.OrdinalIgnoreCase))
            throw new InvalidOperationException(
                $"Resource '{resourceId}' is bound as '{capability}' but does not advertise that capability.");

        return (resourceId, resource);
    }

    public static void Validate(BenchProfile profile)
    {
        if (profile.SchemaVersion != 1)
            throw new InvalidOperationException(
                $"Unsupported bench profile schemaVersion '{profile.SchemaVersion}'. Expected 1.");

        if (profile.Resources.Count == 0)
            throw new InvalidOperationException("Bench profile must contain at least one resource.");

        if (profile.Targets.Count == 0)
            throw new InvalidOperationException("Bench profile must contain at least one target.");

        if (string.IsNullOrWhiteSpace(profile.DefaultTarget) && profile.Targets.Count > 1)
            throw new InvalidOperationException(
                "Profiles with multiple targets must define 'defaultTarget' or callers must select a target explicitly.");

        if (!string.IsNullOrWhiteSpace(profile.DefaultTarget)
            && !profile.Targets.ContainsKey(profile.DefaultTarget))
        {
            throw new InvalidOperationException(
                $"Default target '{profile.DefaultTarget}' does not exist in 'targets'.");
        }

        if (profile.Safety.MaxVoltage is { } maxVoltage &&
            (!double.IsFinite(maxVoltage) || maxVoltage <= 0))
        {
            throw new InvalidOperationException(
                "Safety maxVoltage must be a finite value greater than zero when configured.");
        }

        if (profile.Safety.MaxCurrentMa is { } maxCurrentMa &&
            (!double.IsFinite(maxCurrentMa) || maxCurrentMa <= 0))
        {
            throw new InvalidOperationException(
                "Safety maxCurrentMa must be a finite value greater than zero when configured.");
        }

        foreach (var (resourceId, resource) in profile.Resources)
        {
            if (string.IsNullOrWhiteSpace(resourceId))
                throw new InvalidOperationException("Resource ids cannot be empty.");
            if (string.IsNullOrWhiteSpace(resource.Driver))
                throw new InvalidOperationException($"Resource '{resourceId}' is missing a driver.");
            if (resource.Capabilities.Count == 0)
                throw new InvalidOperationException($"Resource '{resourceId}' advertises no capabilities.");
        }

        foreach (var (targetId, target) in profile.Targets)
        {
            if (target.Bindings.Count == 0)
                throw new InvalidOperationException($"Target '{targetId}' has no resource bindings.");

            foreach (var (capability, resourceId) in target.Bindings)
            {
                if (!profile.Resources.TryGetValue(resourceId, out var resource))
                    throw new InvalidOperationException(
                        $"Target '{targetId}' binding '{capability}' references missing resource '{resourceId}'.");

                if (!resource.Capabilities.Contains(capability, StringComparer.OrdinalIgnoreCase))
                    throw new InvalidOperationException(
                        $"Target '{targetId}' binds '{capability}' to resource '{resourceId}', " +
                        "but that resource does not advertise the capability.");
            }
        }
    }

    // Zero-config simulator profile. One composite simulator resource exposes
    // power + serial + flash so all channels share the same virtual ECU state.
    public static BenchProfile DefaultSimulator() => new()
    {
        SchemaVersion = 1,
        Name = "BenchPilot simulator",
        DefaultTarget = "demo",
        Resources = new Dictionary<string, BenchResourceConfig>(StringComparer.OrdinalIgnoreCase)
        {
            ["sim.demo"] = new()
            {
                Driver = "simulator",
                Capabilities = ["power", "serial", "flash"],
                Settings = new Dictionary<string, JsonElement>(StringComparer.OrdinalIgnoreCase)
                {
                    ["voltage"] = JsonSerializer.SerializeToElement(12.0),
                    ["settleMs"] = JsonSerializer.SerializeToElement(2000),
                    ["port"] = JsonSerializer.SerializeToElement("SIM0"),
                    ["baud"] = JsonSerializer.SerializeToElement(115200),
                    ["firmware"] = JsonSerializer.SerializeToElement("build/app.elf"),
                },
            },
        },
        Targets = new Dictionary<string, BenchTargetConfig>(StringComparer.OrdinalIgnoreCase)
        {
            ["demo"] = new()
            {
                Name = "Demo ECU",
                Mcu = "simulated-mcu",
                Bindings = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                {
                    ["power"] = "sim.demo",
                    ["serial"] = "sim.demo",
                    ["flash"] = "sim.demo",
                },
            },
        },
        Safety = new BenchSafetyPolicy
        {
            MaxVoltage = 14.5,
            MaxCurrentMa = 2000,
        },
    };
}
