namespace Benchpilot.Core;

// Unified result contract per PRD §6.8: every tool returns a flat record
// with an `Ok` flag, its business fields, and an optional `Error`.
// Exit-code semantics (PRD §6.8): 0 ok / 1 generic / 2 validation /
// 3 not-found / 4 device error. For the MCP surface `Ok` + `Error` is
// enough; structured exit codes apply to the CLI shell.

public record PowerOnResult(bool Ok, double Voltage, double CurrentMa, bool Settled, string? Error = null);
public record PowerOffResult(bool Ok, string? Error = null);
public record CurrentReading(bool Ok, double AvgMa, double PeakMa, IReadOnlyList<double> Samples, string? Error = null);
public record CurrentCheck(bool Ok, double ValueMa, bool Passed, string? Error = null);

public record FlashResult(bool Ok, int Bytes, int DurationMs, string? Error = null);
public record ResetResult(bool Ok, string? Error = null);

public record SerialOpenResult(bool Ok, string Port, int Baud, string? Error = null);
public record SerialWaitResult(bool Ok, bool Matched, string? MatchedLine, int ElapsedMs, string? Error = null);
public record SerialWindowResult(bool Ok, IReadOnlyList<string> Lines, string? Error = null);
public record SerialSendResult(bool Ok, string? Error = null);
