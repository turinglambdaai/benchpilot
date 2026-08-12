namespace Benchpilot.Core;

// The "pacemaker" channel (PRD §6.1). A real SCPI bench supply and the
// simulator both implement this; the kernel and MCP tools only know the
// interface, so swapping the driver is a DI registration change.
public interface IPowerSupply
{
    Task<PowerOnResult> PowerOn(double voltage, int settleMs, CancellationToken ct = default);
    Task<PowerOffResult> PowerOff(CancellationToken ct = default);
    Task<CurrentReading> ReadCurrent(int windowMs, CancellationToken ct = default);
    Task<CurrentCheck> CheckCurrent(double? ltMa = null, double? gtMa = null, CancellationToken ct = default);

    bool IsOn { get; }
}
