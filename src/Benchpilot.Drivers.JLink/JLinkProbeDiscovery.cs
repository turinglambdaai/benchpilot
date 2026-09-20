using Benchpilot.Core;

namespace Benchpilot.Drivers.JLink;

/// <summary>
/// One probe reported by J-Link Commander's non-destructive ShowEmuList command.
/// This is deliberately driver-specific and does not leak into BenchPilot Core.
/// </summary>
public sealed record JLinkProbeInfo(
    string Connection,
    string SerialNumber,
    string ProductName,
    string? Nickname = null);

/// <summary>
/// Parser and deterministic-selection policy for J-Link probe enumeration.
/// The parser intentionally tolerates additional fields in future Commander
/// versions while requiring the fields BenchPilot needs for safe selection.
/// </summary>
public static class JLinkProbeDiscovery
{
    public static IReadOnlyList<JLinkProbeInfo> Parse(string output)
    {
        ArgumentNullException.ThrowIfNull(output);
        var probes = new List<JLinkProbeInfo>();

        using var reader = new StringReader(output);
        while (reader.ReadLine() is { } rawLine)
        {
            var line = rawLine.Trim();
            if (!line.StartsWith("J-Link[", StringComparison.OrdinalIgnoreCase))
                continue;

            var marker = line.IndexOf("]:", StringComparison.Ordinal);
            if (marker < 0 || marker + 2 >= line.Length)
                continue;

            var fields = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var segment in line[(marker + 2)..]
                         .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                var colon = segment.IndexOf(':');
                if (colon <= 0 || colon + 1 >= segment.Length)
                    continue;

                fields[segment[..colon].Trim()] = segment[(colon + 1)..].Trim();
            }

            if (!fields.TryGetValue("Connection", out var connection)
                || !fields.TryGetValue("Serial number", out var serial)
                || !fields.TryGetValue("ProductName", out var product)
                || string.IsNullOrWhiteSpace(connection)
                || string.IsNullOrWhiteSpace(serial)
                || string.IsNullOrWhiteSpace(product))
            {
                continue;
            }

            fields.TryGetValue("Nickname", out var nickname);
            probes.Add(new JLinkProbeInfo(connection, serial, product, nickname));
        }

        return probes;
    }

    public static ResourceHealthResult Evaluate(
        IReadOnlyList<JLinkProbeInfo> probes,
        string? configuredSerialNumber,
        IReadOnlyDictionary<string, string>? baseDetails = null)
    {
        ArgumentNullException.ThrowIfNull(probes);

        var usb = probes
            .Where(x => string.Equals(x.Connection, "USB", StringComparison.OrdinalIgnoreCase))
            .ToArray();

        var details = baseDetails is null
            ? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            : new Dictionary<string, string>(baseDetails, StringComparer.OrdinalIgnoreCase);

        details["usbProbeCount"] = usb.Length.ToString(System.Globalization.CultureInfo.InvariantCulture);
        details["discoveredSerialNumbers"] = string.Join(",", usb.Select(x => x.SerialNumber));
        details["discoveredProducts"] = string.Join(",", usb.Select(x => x.ProductName));
        details["probeEnumerationChecked"] = "true";
        details["targetConnectivityChecked"] = "false";

        if (usb.Length == 0)
        {
            return new ResourceHealthResult(
                false,
                "No USB J-Link probe was enumerated.",
                details,
                "J-Link Commander is installed, but ShowEmuList USB did not report any USB probe.");
        }

        if (!string.IsNullOrWhiteSpace(configuredSerialNumber))
        {
            var match = usb.FirstOrDefault(x =>
                string.Equals(x.SerialNumber, configuredSerialNumber, StringComparison.OrdinalIgnoreCase));
            if (match is null)
            {
                return new ResourceHealthResult(
                    false,
                    $"Configured J-Link serial number '{configuredSerialNumber}' is not connected.",
                    details,
                    $"Connected USB J-Link serial numbers: {string.Join(", ", usb.Select(x => x.SerialNumber))}.");
            }

            details["selectedSerialNumber"] = match.SerialNumber;
            details["selectedProduct"] = match.ProductName;
            if (!string.IsNullOrWhiteSpace(match.Nickname))
                details["selectedNickname"] = match.Nickname!;

            return new ResourceHealthResult(
                true,
                $"Configured J-Link probe {match.SerialNumber} ({match.ProductName}) is visible over USB.",
                details);
        }

        if (usb.Length > 1)
        {
            return new ResourceHealthResult(
                false,
                $"{usb.Length} USB J-Link probes are connected, but no serialNumber is configured.",
                details,
                "Configure resources.<id>.settings.serialNumber so automated flashing selects one probe deterministically.");
        }

        details["selectedSerialNumber"] = usb[0].SerialNumber;
        details["selectedProduct"] = usb[0].ProductName;
        if (!string.IsNullOrWhiteSpace(usb[0].Nickname))
            details["selectedNickname"] = usb[0].Nickname!;

        return new ResourceHealthResult(
            true,
            $"One J-Link probe {usb[0].SerialNumber} ({usb[0].ProductName}) is visible over USB.",
            details);
    }
}
