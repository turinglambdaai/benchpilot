using Benchpilot.Core;
using Benchpilot.Runtime;

namespace Benchpilot.Simulator;

public sealed class SimulatorResourceFactory : IBenchResourceFactory
{
    public string DriverName => "simulator";

    public object Create(string resourceId, BenchResourceConfig config)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(resourceId);
        ArgumentNullException.ThrowIfNull(config);
        return new SimulatedBench();
    }
}
