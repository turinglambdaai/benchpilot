using Benchpilot.Core;
using Benchpilot.Drivers.JLink;
using Benchpilot.Drivers.ScpiPower;
using Benchpilot.Drivers.Serial;
using Benchpilot.Protocol;
using Benchpilot.Runtime;
using Benchpilot.Simulator;
using Microsoft.AspNetCore.Hosting;

var profilePath = Environment.GetEnvironmentVariable("BENCHPILOT_PROFILE");
var profile = string.IsNullOrWhiteSpace(profilePath)
    ? ProfileLoader.DefaultSimulator()
    : ProfileLoader.Load(profilePath);

var endpointText = Environment.GetEnvironmentVariable("BENCHPILOT_ENDPOINT");
if (string.IsNullOrWhiteSpace(endpointText))
    endpointText = "http://127.0.0.1:5640";

if (!Uri.TryCreate(endpointText, UriKind.Absolute, out var endpoint))
    throw new InvalidOperationException($"Invalid BENCHPILOT_ENDPOINT: {endpointText}");
if (endpoint.Scheme != Uri.UriSchemeHttp)
    throw new InvalidOperationException("The foundation runtime currently supports local HTTP only.");
if (!endpoint.IsLoopback)
    throw new InvalidOperationException(
        "BenchPilot Runtime refuses non-loopback binding at this milestone. " +
        "Remote benches require an authenticated transport and explicit policy.");

var drivers = new BenchDriverRegistry(new IBenchResourceFactory[]
{
    new SimulatorResourceFactory(),
    new SystemSerialResourceFactory(),
    new JLinkResourceFactory(),
    new ScpiPowerResourceFactory(),
});

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls(endpoint.GetLeftPart(UriPartial.Authority));
builder.Services.AddSingleton(profile);
builder.Services.AddSingleton(drivers);
builder.Services.AddSingleton(sp => drivers.CreateRuntime(profile));

var app = builder.Build();

app.MapGet("/healthz", () => Results.Ok(new { ok = true }));

app.MapGet($"{BenchpilotApi.Prefix}/status", (BenchRuntime runtime) =>
{
    var targets = runtime.Profile.Targets
        .Select(x => new TargetSummary(
            x.Key,
            string.IsNullOrWhiteSpace(x.Value.Name) ? x.Key : x.Value.Name,
            x.Value.Mcu,
            x.Value.Bindings.Keys.Order(StringComparer.OrdinalIgnoreCase).ToArray()))
        .OrderBy(x => x.Id, StringComparer.OrdinalIgnoreCase)
        .ToArray();

    var resources = runtime.Profile.Resources
        .Select(x => new ResourceSummary(
            x.Key,
            x.Value.Driver,
            x.Value.Capabilities.Order(StringComparer.OrdinalIgnoreCase).ToArray(),
            runtime.Resources.IsRegistered(x.Key)))
        .OrderBy(x => x.Id, StringComparer.OrdinalIgnoreCase)
        .ToArray();

    return Results.Json(new RuntimeStatusResult(
        true,
        runtime.Profile.Name,
        runtime.Profile.SchemaVersion,
        runtime.Profile.DefaultTarget,
        targets,
        resources));
});

app.MapGet($"{BenchpilotApi.Prefix}/operations", (BenchRuntime runtime) =>
{
    var operations = runtime.ActiveOperations
        .Select(x => new OperationSummary(
            x.Id,
            x.TargetId,
            x.Kind,
            x.ResourceIds,
            x.StartedAtUtc,
            x.CancellationRequested))
        .ToArray();
    return Results.Json(new OperationListResult(true, operations));
});

app.MapPost($"{BenchpilotApi.Prefix}/operations/{{operationId}}/cancel", (
    string operationId,
    BenchRuntime runtime) =>
{
    if (string.IsNullOrWhiteSpace(operationId))
        return Results.BadRequest(new ApiError(false, "validation", "Operation id cannot be empty."));

    if (!runtime.CancelOperation(operationId))
    {
        return Results.NotFound(new ApiError(
            false,
            "not_found",
            $"Active operation '{operationId}' was not found."));
    }

    return Results.Json(new OperationCancelResult(true, operationId, true));
});

app.MapPost($"{BenchpilotApi.Prefix}/preflight", async (
    string? target,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.Preflight(target, ct)));

app.MapPost($"{BenchpilotApi.Prefix}/power/on", async (
    string? target,
    PowerOnRequest request,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.Target(target).PowerOn(request.Voltage, request.SettleMs, ct)));

app.MapPost($"{BenchpilotApi.Prefix}/power/off", async (
    string? target,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.Target(target).PowerOff(ct)));

app.MapPost($"{BenchpilotApi.Prefix}/power/emergency-off", async (
    string? target,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.Target(target).EmergencyPowerOff(ct)));

app.MapPost($"{BenchpilotApi.Prefix}/power/current/read", async (
    string? target,
    CurrentReadRequest request,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.Target(target).ReadCurrent(request.WindowMs, ct)));

app.MapPost($"{BenchpilotApi.Prefix}/power/current/check", async (
    string? target,
    CurrentCheckRequest request,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.Target(target).CheckCurrent(request.LtMa, request.GtMa, ct)));

app.MapPost($"{BenchpilotApi.Prefix}/flash/write", async (
    string? target,
    FlashRequest request,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.Target(target).Flash(request.Firmware, request.ConfirmTarget, ct)));

app.MapPost($"{BenchpilotApi.Prefix}/flash/reset", async (
    string? target,
    ResetRequest request,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.Target(target).Reset(request.ConfirmTarget, ct)));

app.MapPost($"{BenchpilotApi.Prefix}/serial/open", async (
    string? target,
    SerialOpenRequest request,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.Target(target).SerialOpen(request.Port, request.Baud, ct)));

app.MapPost($"{BenchpilotApi.Prefix}/serial/wait", async (
    string? target,
    SerialWaitRequest request,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.Target(target).SerialWaitFor(request.Pattern, request.TimeoutMs, ct)));

app.MapPost($"{BenchpilotApi.Prefix}/serial/window", async (
    string? target,
    SerialWindowRequest request,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.Target(target).SerialReadWindow(request.Lines, request.Filter, ct)));

app.MapPost($"{BenchpilotApi.Prefix}/serial/send", async (
    string? target,
    SerialSendRequest request,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.Target(target).SerialSend(request.Data, ct)));

app.Logger.LogInformation(
    "BenchPilot Runtime '{BenchName}' listening on {Endpoint}. Profile: {Profile}. Drivers: {Drivers}",
    profile.Name,
    endpoint.GetLeftPart(UriPartial.Authority),
    string.IsNullOrWhiteSpace(profilePath) ? "built-in simulator" : profilePath,
    string.Join(", ", drivers.DriverNames.Order(StringComparer.OrdinalIgnoreCase)));

await app.RunAsync();

static async Task<IResult> Execute<T>(Func<Task<T>> operation)
{
    try
    {
        return Results.Json(await operation());
    }
    catch (BenchValidationException ex)
    {
        return Results.BadRequest(new ApiError(false, "validation", ex.Message));
    }
    catch (BenchTargetNotFoundException ex)
    {
        return Results.NotFound(new ApiError(false, "not_found", ex.Message));
    }
    catch (KeyNotFoundException ex)
    {
        return Results.NotFound(new ApiError(false, "not_found", ex.Message));
    }
    catch (BenchBusyException ex)
    {
        return Results.Json(
            new ApiError(
                false,
                "busy",
                ex.Message,
                ex.OwnerOperationId,
                ex.BusyScope,
                ex.BusyId),
            statusCode: StatusCodes.Status409Conflict);
    }
    catch (OperationCanceledException)
    {
        return Results.Json(
            new ApiError(false, "cancelled", "Operation cancelled."),
            statusCode: StatusCodes.Status409Conflict);
    }
    catch (InvalidOperationException ex)
    {
        return Results.Json(
            new ApiError(false, "runtime_state", ex.Message),
            statusCode: StatusCodes.Status409Conflict);
    }
    catch (Exception ex)
    {
        return Results.Json(
            new ApiError(false, "internal", ex.Message),
            statusCode: StatusCodes.Status500InternalServerError);
    }
}
