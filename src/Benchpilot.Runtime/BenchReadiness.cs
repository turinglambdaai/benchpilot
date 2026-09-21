using System.Globalization;
using System.Text.Json;
using Benchpilot.Core;

namespace Benchpilot.Runtime;

public static class BenchReadiness
{
    private static readonly string[] RequiredCapabilities = ["power", "serial", "flash"];

    /// <summary>
    /// Builds a non-destructive report for the minimum real-ECU vertical slice.
    /// It combines static profile/safety assertions with the existing resource
    /// preflight checks. It never powers, resets or flashes the target.
    /// </summary>
    public static async Task<TargetReadinessResult> ValidateTargetReadiness(
        this BenchRuntime runtime,
        string? targetName = null,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(runtime);
        ct.ThrowIfCancellationRequested();

        var target = runtime.Target(targetName);
        var checks = new List<BenchReadinessCheck>();
        var boundRequiredResources = new Dictionary<string, BenchResourceConfig>(StringComparer.OrdinalIgnoreCase);

        foreach (var capability in RequiredCapabilities)
        {
            var present = target.HasCapability(capability);
            IReadOnlyDictionary<string, string>? details = null;
            if (present)
            {
                var binding = ProfileLoader.ResolveResource(runtime.Profile, capability, target.Id);
                boundRequiredResources[binding.ResourceId] = binding.Resource;
                details = new Dictionary<string, string>
                {
                    ["capability"] = capability,
                    ["resourceId"] = binding.ResourceId,
                    ["driver"] = binding.Resource.Driver,
                };
            }

            checks.Add(new BenchReadinessCheck(
                $"capability.{capability}",
                present,
                "error",
                present
                    ? $"Target provides required '{capability}' capability."
                    : $"Target is missing required '{capability}' capability.",
                details));
        }

        var mode = DetermineMode(boundRequiredResources.Values);
        var hardwareOnly = string.Equals(mode, "hardware", StringComparison.Ordinal);
        checks.Add(new BenchReadinessCheck(
            "target.real-hardware",
            hardwareOnly,
            "error",
            mode switch
            {
                "hardware" => "Required capabilities are bound only to real-hardware drivers.",
                "simulator" => "Required capabilities are simulator-backed; this target is not a physical ECU bench.",
                "mixed" => "Required capabilities mix simulator and hardware resources; the physical ECU loop is incomplete.",
                _ => "Could not determine a complete hardware mode for the required capabilities.",
            },
            new Dictionary<string, string> { ["mode"] = mode }));

        var safety = runtime.Profile.Safety;
        checks.Add(SafetyValueCheck(
            "safety.max-voltage",
            "maxVoltage",
            safety.MaxVoltage,
            "V"));
        checks.Add(SafetyValueCheck(
            "safety.max-current",
            "maxCurrentMa",
            safety.MaxCurrentMa,
            "mA"));
        checks.Add(new BenchReadinessCheck(
            "safety.explicit-target",
            safety.RequireExplicitTarget,
            "error",
            safety.RequireExplicitTarget
                ? "Explicit target selection is required by bench policy."
                : "Real-bench readiness requires safety.requireExplicitTarget=true."));
        checks.Add(new BenchReadinessCheck(
            "safety.destructive-confirmation",
            safety.RequireDestructiveConfirmation,
            "error",
            safety.RequireDestructiveConfirmation
                ? "Flash/reset require explicit target confirmation."
                : "Real-bench readiness requires safety.requireDestructiveConfirmation=true."));

        var placeholderPaths = FindPlaceholderPaths(runtime.Profile, target.Id, boundRequiredResources.Keys);
        checks.Add(new BenchReadinessCheck(
            "profile.placeholders",
            placeholderPaths.Count == 0,
            "error",
            placeholderPaths.Count == 0
                ? "No CHANGE_ME placeholders remain in the target's real-bench configuration."
                : $"Profile still contains {placeholderPaths.Count} CHANGE_ME placeholder(s) for this target.",
            placeholderPaths.Count == 0
                ? null
                : new Dictionary<string, string>
                {
                    ["paths"] = string.Join(",", placeholderPaths.Take(20)),
                    ["count"] = placeholderPaths.Count.ToString(CultureInfo.InvariantCulture),
                }));

        var mcuSpecified = !string.IsNullOrWhiteSpace(target.Mcu)
            && !ContainsPlaceholder(target.Mcu!);
        checks.Add(new BenchReadinessCheck(
            "target.mcu-metadata",
            mcuSpecified,
            "warning",
            mcuSpecified
                ? $"Target MCU metadata is set to '{target.Mcu}'."
                : "Target MCU metadata is missing or still a placeholder; this does not block Runtime readiness but should be fixed before publishing the profile."));

        var preflight = await runtime.Preflight(target.Id, ct);
        checks.Add(new BenchReadinessCheck(
            "resources.preflight",
            preflight.Ok,
            "error",
            preflight.Ok
                ? "All target resources passed non-destructive preflight."
                : "One or more target resources failed non-destructive preflight.",
            new Dictionary<string, string>
            {
                ["resourceCount"] = preflight.Resources.Count.ToString(CultureInfo.InvariantCulture),
                ["failedCount"] = preflight.Resources.Count(x => !x.Ok).ToString(CultureInfo.InvariantCulture),
            }));

        var ready = checks.All(x => x.Passed || !string.Equals(x.Severity, "error", StringComparison.OrdinalIgnoreCase));
        return new TargetReadinessResult(
            true,
            ready,
            mode,
            target.Id,
            target.Name,
            RequiredCapabilities,
            checks,
            preflight);
    }

    private static BenchReadinessCheck SafetyValueCheck(
        string code,
        string setting,
        double? value,
        string unit)
    {
        var present = value.HasValue;
        return new BenchReadinessCheck(
            code,
            present,
            "error",
            present
                ? $"Bench safety {setting} is configured at {value!.Value.ToString("0.###", CultureInfo.InvariantCulture)} {unit}."
                : $"Real-bench readiness requires safety.{setting} to be configured.",
            present
                ? new Dictionary<string, string>
                {
                    ["value"] = value!.Value.ToString("0.###", CultureInfo.InvariantCulture),
                    ["unit"] = unit,
                }
                : null);
    }

    private static string DetermineMode(IEnumerable<BenchResourceConfig> resources)
    {
        var drivers = resources
            .Select(x => x.Driver)
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .ToArray();
        if (drivers.Length == 0) return "unknown";

        var simulatorCount = drivers.Count(x =>
            string.Equals(x, "simulator", StringComparison.OrdinalIgnoreCase));
        if (simulatorCount == drivers.Length) return "simulator";
        if (simulatorCount > 0) return "mixed";
        return "hardware";
    }

    private static IReadOnlyList<string> FindPlaceholderPaths(
        BenchProfile profile,
        string targetId,
        IEnumerable<string> resourceIds)
    {
        var result = new List<string>();
        if (profile.Targets.TryGetValue(targetId, out var target)
            && ContainsPlaceholder(target.Mcu))
        {
            result.Add($"targets.{targetId}.mcu");
        }

        foreach (var resourceId in resourceIds.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!profile.Resources.TryGetValue(resourceId, out var resource))
                continue;

            foreach (var setting in resource.Settings)
            {
                if (setting.Value.ValueKind == JsonValueKind.String
                    && ContainsPlaceholder(setting.Value.GetString()))
                {
                    result.Add($"resources.{resourceId}.settings.{setting.Key}");
                }
            }
        }

        return result;
    }

    private static bool ContainsPlaceholder(string? value) =>
        !string.IsNullOrWhiteSpace(value)
        && value.Contains("CHANGE_ME", StringComparison.OrdinalIgnoreCase);
}
