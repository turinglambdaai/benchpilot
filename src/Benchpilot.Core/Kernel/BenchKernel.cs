namespace Benchpilot.Core;

// The resident kernel (PRD §2.3). Holds the live channel instances for the
// active bench profile; the MCP tools and any future CLI/GUI shell all
// consume the same kernel. Connections are long-lived and stateful, so the
// kernel is a singleton scoped to the host process — that is exactly why
// the agent surface is an MCP server rather than a stateless CLI (PRD §2.2).
public sealed class BenchKernel
{
    public BenchProfile Profile { get; }
    public IPowerSupply Power { get; }
    public ISerialChannel Serial { get; }
    public IFlashTarget Flash { get; }

    public BenchKernel(BenchProfile profile, IPowerSupply power, ISerialChannel serial, IFlashTarget flash)
    {
        Profile = profile;
        Power = power;
        Serial = serial;
        Flash = flash;
    }
}
