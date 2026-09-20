using Benchpilot.Core;
using Benchpilot.Mcp.Tools;
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

// P0/P1 bridge: the profile is already multi-resource/multi-target capable,
// while the only shipped backend is still one composite simulator instance.
// Real hardware drivers will register each resource independently in the
// resident Runtime instead of adding another monolithic "hardware" driver.
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
        "The profile model already supports independent resources; real SCPI, serial, " +
        "probe and CAN drivers will be hosted by Benchpilot.Runtime in the next milestone.");
}

builder.Services.AddSingleton<SimulatedBench>();
builder.Services.AddSingleton<IPowerSupply>(sp => sp.GetRequiredService<SimulatedBench>());
builder.Services.AddSingleton<ISerialChannel>(sp => sp.GetRequiredService<SimulatedBench>());
builder.Services.AddSingleton<IFlashTarget>(sp => sp.GetRequiredService<SimulatedBench>());
builder.Services.AddSingleton<BenchKernel>();

await builder.Build().RunAsync();
