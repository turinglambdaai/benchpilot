namespace Benchpilot.Core;

// Unified result contract per PRD §6.8: every tool returns a flat record
// with an `Ok` flag, its business fields, and an optional `Error`.
// Exit-code semantics are owned by the CLI shell; MCP uses Ok + Error.

public record PowerOnResult(bool Ok, double Voltage, double CurrentMa, bool Settled, string? Error = null);
public record PowerOffResult(bool Ok, string? Error = null);
public record CurrentReading(bool Ok, double AvgMa, double PeakMa, IReadOnlyList<double> Samples, string? Error = null);
public record CurrentCheck(bool Ok, double ValueMa, bool Passed, string? Error = null);

public record FlashResult(bool Ok, int Bytes, int DurationMs, string? Error = null);
public record ResetResult(bool Ok, string? Error = null);

// Serial calls are non-mutating observations/actions. Runtime attaches a stable
// observation id so a caller can correlate the returned result with bounded
// history/evidence without turning reads into mutation-gated operations.
public record SerialOpenResult(
    bool Ok,
    string Port,
    int Baud,
    string? Error = null,
    string? ObservationId = null);
public record SerialWaitResult(
    bool Ok,
    bool Matched,
    string? MatchedLine,
    int ElapsedMs,
    string? Error = null,
    string? ObservationId = null);
public record SerialWindowResult(
    bool Ok,
    IReadOnlyList<string> Lines,
    string? Error = null,
    string? ObservationId = null);
public record SerialSendResult(
    bool Ok,
    string? Error = null,
    string? ObservationId = null);

public record ResourceHealthResult(
    bool Ok,
    string Summary,
    IReadOnlyDictionary<string, string>? Details = null,
    string? Error = null);

public record ResourcePreflightResult(
    string ResourceId,
    string Driver,
    IReadOnlyList<string> Capabilities,
    bool Ok,
    string Summary,
    IReadOnlyDictionary<string, string>? Details = null,
    string? Error = null);

public record TargetPreflightResult(
    bool Ok,
    string TargetId,
    string TargetName,
    IReadOnlyList<ResourcePreflightResult> Resources,
    string? Error = null);

/// <summary>
/// One deterministic onboarding/readiness assertion. Severity is currently
/// `error` or `warning`; only failed error checks block ReadyForRealEcuLoop.
/// Codes are stable machine-facing identifiers for CLI/CI/Agent consumers.
/// </summary>
public record BenchReadinessCheck(
    string Code,
    bool Passed,
    string Severity,
    string Summary,
    IReadOnlyDictionary<string, string>? Details = null);

/// <summary>
/// Non-destructive report answering whether one semantic target has the minimum
/// capabilities, safety policy and live resource readiness required for the
/// first real-ECU BenchPilot loop (power + serial + flash).
/// </summary>
public record TargetReadinessResult(
    bool Ok,
    bool ReadyForRealEcuLoop,
    string Mode,
    string TargetId,
    string TargetName,
    IReadOnlyList<string> RequiredCapabilities,
    IReadOnlyList<BenchReadinessCheck> Checks,
    TargetPreflightResult Preflight,
    string? Error = null);
