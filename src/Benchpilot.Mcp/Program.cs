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

// Driver selection (PRD §2.1): the kernel and tools only know the channel
// interfaces, so swapping the bench backend is a registration change here.
// The DEMO ships the simulator; a future hardware driver plugs into the same
// three interfaces without touching anything above.
builder.Services.AddSingleton(profile);
switch (profile.Driver)
{
    case "simulator":
        // One shared virtual bench backs all three channels so power / serial /
        // flash share state and behave like a single board.
        builder.Services.AddSingleton<SimulatedBench>();
        builder.Services.AddSingleton<IPowerSupply>(sp => sp.GetRequiredService<SimulatedBench>());
        builder.Services.AddSingleton<ISerialChannel>(sp => sp.GetRequiredService<SimulatedBench>());
        builder.Services.AddSingleton<IFlashTarget>(sp => sp.GetRequiredService<SimulatedBench>());
        break;
    default:
        throw new InvalidOperationException(
            $"Unknown driver '{profile.Driver}'. The DEMO supports 'simulator'; " +
            "a 'hardware' driver lands when the SCPI/probe backend is implemented.");
}
builder.Services.AddSingleton<BenchKernel>();

await builder.Build().RunAsync();
