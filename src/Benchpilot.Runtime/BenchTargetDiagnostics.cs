using System.Globalization;
using System.Text.Json;
using Benchpilot.Core;

namespace Benchpilot.Runtime;

/// <summary>
/// Diagnostics operations on a target: raw UDS escape requests (observations)
/// and the destructive UDS flash workflow (mutation with confirm-target).
/// Transport (ISO-TP/CAN or DoIP) is resolved from the "diagnostics"
/// capability binding exactly like every other capability.
/// </summary>
public sealed partial class BenchTarget
{
    public Task<UdsRequestResult> UdsRequest(
        ReadOnlyMemory<byte> request,
        CancellationToken ct = default) =>
        UdsRequest(request, null, null, null, ct);

    public Task<UdsRequestResult> UdsRequest(
        ReadOnlyMemory<byte> request,
        int? p2TimeoutMs,
        int? p2StarTimeoutMs,
        int? deadlineMs,
        CancellationToken ct = default)
    {
        if (request.Length == 0)
            throw new BenchValidationException("UDS request bytes cannot be empty.");

        var binding = BoundCapability<IDiagChannel>("diagnostics");
        var requestCopy = request.ToArray();
        return _runtime.RunObservation(
            Id,
            "uds.request",
            [binding.ResourceId],
            async (observationId, observationCt) =>
            {
                var result = await binding.Capability.Request(
                    requestCopy,
                    p2TimeoutMs ?? 1000,
                    p2StarTimeoutMs ?? 5000,
                    observationCt);
                return new ObservationExecution<UdsRequestResult>(
                    result,
                    DiagObservationEvidence.FromUdsRequest(result));
            },
            ct,
            deadlineMs);
    }

    public Task<UdsFlashResult> UdsFlash(
        string firmwarePath,
        long address,
        string? confirmTarget,
        int? deadlineMs,
        CancellationToken ct = default) =>
        UdsFlash(firmwarePath, planPath: null, address, maxBlockPayload: null, confirmTarget, deadlineMs, ct);

    public async Task<UdsFlashResult> UdsFlash(
        string firmwarePath,
        string? planPath,
        long? address,
        int? maxBlockPayload,
        string? confirmTarget,
        int? deadlineMs,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(firmwarePath);
        ValidateDestructiveConfirmation("uds flash", confirmTarget);

        var spec = BuildFlashPlan(firmwarePath, planPath, address, maxBlockPayload);
        if (spec.Segments.Count == 0)
            throw new BenchValidationException(
                "Flash plan has no segments; provide a firmware file with --address or a plan file.");

        var totalBytes = spec.Segments.Sum(x => (long?)x.Data?.LongLength ?? 0);
        var binding = BoundCapability<IDiagChannel>("diagnostics");
        return await _runtime.RunMutation(
            Id,
            "uds.flash",
            [binding.ResourceId],
            async operationCt =>
            {
                var result = await binding.Capability.Flash(spec, operationCt);
                return result with
                {
                    TotalBytes = totalBytes,
                };
            },
            ct,
            deadlineMs);
    }

    private UdsFlashPlanSpec BuildFlashPlan(
        string firmwarePath,
        string? planPath,
        long? address,
        int? maxBlockPayload)
    {
        if (!File.Exists(firmwarePath))
            throw new BenchValidationException($"Firmware file not found: {firmwarePath}");

        UdsFlashPlanSpec spec;
        if (!string.IsNullOrWhiteSpace(planPath))
        {
            if (!File.Exists(planPath))
                throw new BenchValidationException($"Flash plan file not found: {planPath}");
            spec = JsonSerializer.Deserialize<UdsFlashPlanSpec>(
                    File.ReadAllText(planPath),
                    new JsonSerializerOptions(JsonSerializerDefaults.Web))
                ?? throw new BenchValidationException("Flash plan JSON deserialized to null.");

            // Segment file references resolve relative to the plan file.
            var baseDirectory = Path.GetDirectoryName(Path.GetFullPath(planPath))!;
            spec = spec with
            {
                Segments = spec.Segments
                    .Select(x => x.Data is { Length: > 0 }
                        ? x
                        : x with { Data = ReadSegmentFile(x.File, baseDirectory) })
                    .ToArray(),
            };
        }
        else
        {
            if (address is null)
                throw new BenchValidationException(
                    "Provide --address (flash start address, for example 0x08000000) or a flash plan file.");
            spec = new UdsFlashPlanSpec
            {
                Segments = [new UdsFlashSegmentSpec(address.Value, File.ReadAllBytes(firmwarePath))],
            };
        }

        if (maxBlockPayload is { } max)
            spec = spec with { MaxBlockPayload = max };
        return spec;
    }

    private static byte[] ReadSegmentFile(string? file, string baseDirectory)
    {
        if (string.IsNullOrWhiteSpace(file))
            throw new BenchValidationException("Flash plan segment has no data and no file reference.");
        var path = Path.IsPathRooted(file) ? file : Path.Combine(baseDirectory, file);
        if (!File.Exists(path))
            throw new BenchValidationException($"Flash plan segment file not found: {path}");
        return File.ReadAllBytes(path);
    }
}

internal static class DiagObservationEvidence
{
    private const int MaxHexChars = 512;

    public static IReadOnlyList<BenchEvidenceItem> FromUdsRequest(UdsRequestResult result) =>
    [
        Item(
            "uds.request",
            result.Ok
                ? (result.Positive
                    ? "UDS request answered with a positive response."
                    : $"UDS request rejected by the ECU (NRC {result.Nrc}).")
                : "UDS request failed at the transport layer.",
            result.Error,
            new Dictionary<string, string>
            {
                ["ok"] = Bool(result.Ok),
                ["positive"] = Bool(result.Positive),
                ["nrc"] = result.Nrc ?? string.Empty,
                ["request"] = Truncate(result.RequestHex),
                ["response"] = Truncate(result.ResponseHex ?? string.Empty),
            })
    ];

    public static IReadOnlyList<BenchEvidenceItem> FromUdsFlash(UdsFlashResult result) =>
    [
        Item(
            "uds.flash",
            result.Ok
                ? $"UDS flash workflow completed ({result.TotalBytes} bytes in {result.SegmentCount} segment(s))."
                : $"UDS flash workflow failed: {result.Error}",
            result.Error,
            new Dictionary<string, string>
            {
                ["ok"] = Bool(result.Ok),
                ["totalBytes"] = result.TotalBytes.ToString(CultureInfo.InvariantCulture),
                ["stepCount"] = result.Steps.Count.ToString(CultureInfo.InvariantCulture),
            }),
        ..result.Steps.Select(step => Item(
            "uds.flash.step",
            step.Detail,
            step.Nrc,
            new Dictionary<string, string>
            {
                ["step"] = step.Step,
                ["ok"] = Bool(step.Ok),
                ["nrc"] = step.Nrc ?? string.Empty,
                ["durationMs"] = step.DurationMs.ToString("0.0", CultureInfo.InvariantCulture),
            })),
    ];

    private static string Truncate(string hex) =>
        hex.Length <= MaxHexChars ? hex : hex[..MaxHexChars] + $"…(+{hex.Length - MaxHexChars})";

    private static BenchEvidenceItem Item(
        string kind,
        string summary,
        string? text,
        Dictionary<string, string> metadata) =>
        new(kind, summary, text ?? string.Empty, metadata);

    private static string Bool(bool value) => value ? "true" : "false";
}
