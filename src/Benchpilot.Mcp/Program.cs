using Benchpilot.Client;
using Benchpilot.Mcp.Tools;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

var builder = Host.CreateApplicationBuilder(args);

// MCP speaks over stdout, so every log line must go to stderr instead.
builder.Logging.AddConsole(o => o.LogToStandardErrorThreshold = LogLevel.Trace);

builder.Services.AddMcpServer()
    .WithStdioServerTransport()
    .WithTools<BenchTools>()
    .WithTools<OperationTools>()
    .WithTools<PowerTools>()
    .WithTools<FlashTools>()
    .WithTools<SerialTools>();

// The MCP process is now a thin protocol adapter. It never owns hardware.
// benchpilotd is the single resident process that owns live resources/state.
var endpoint = BenchClient.ResolveEndpoint();
builder.Services.AddSingleton(new BenchClient(endpoint));

await builder.Build().RunAsync();
