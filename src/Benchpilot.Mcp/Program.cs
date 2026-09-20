using Benchpilot.Core;
using Benchpilot.Mcp.Tools;
using Benchpilot.Runtime;
using Benchpilot.Simulator;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

// Resolve the bench profile: an explicit path via BENCHPILOT_PROFILE, or the
// zero-config simulator defaults so `dotnet run` works with nothing else.
var profilePath = Environment.GetEnvironmentVariable("BENCHPILOT_PROFILE");
var profile = string.IsNullOrWhiteSpace(profilePath)
    ? ProfileLoader.DefaultSimulator()
    : ProfileLoader.Load(profilePath);

var builder = Host.CreateApplicationBuilder(args);

// MCP speaks over stdout, so every log line must go to stderr instead.
builder.Logging.AddConsole(o => o.LogToStandardErrorThreshold = LogLevel.Trace);

builder.Services.AddMcpServer()
    .WithStdioServerTransport()
    .WithTools<PowerTools>()
    .WithTools<FlashTools>()
    .WithTools<SerialTools>();

builder.Services.AddSingleton(profile);

// P0/P1 bridge: the profile and Runtime already understand independent
// resources, while the only shipped backend is still one composite simulator.
// Real SCPI, serial, probe and CAN resources will register their own live
// instances in BenchRuntime; shells will not change.
var power = ProfileLoader.ResolveResource(profile, "power");
var serial = ProfileLoader.ResolveResource(profile, "serial");
var flash = ProfileLoader.ResolveResource(profile, "flash");

var simulatorBindings = new[] { power, serial, flash };
var allSimulator = simulatorBindings.All(x =>
    string.Equals(x.Resource.Driver, "simulator", StringComparison.OrdinalIgnoreCase));
var oneCompositeResource = simulatorBindings
    .Select(x => x.ResourceId)
    .Distinct(StringComparer.OrdinalIgnoreCase)
    .Count() == 1;

if (!allSimulator || !oneCompositeResource)
{
    throw new InvalidOperationException(
        "This milestone ships only the composite simulator backend. " +
        "The profile model and Runtime already support independent resources; " +
        "real hardware drivers land behind that boundary next.");
}

builder.Services.AddSingleton<SimulatedBench>();
builder.Services.AddSingleton(sp =>
{
    var registry = new BenchResourceRegistry(profile);
    registry.Register(power.ResourceId, sp.GetRequiredService<SimulatedBench>());
    return new BenchRuntime(profile, registry);
});

await builder.Build().RunAsync();
