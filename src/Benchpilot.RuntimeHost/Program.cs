using Benchpilot.Core;
using Benchpilot.Drivers.JLink;
using Benchpilot.Drivers.ScpiPower;
using Benchpilot.Drivers.Serial;
using Benchpilot.Protocol;
using Benchpilot.Runtime;
using Benchpilot.RuntimeHost;
using Benchpilot.Simulator;
using Microsoft.AspNetCore.Hosting;

var profilePath = Environment.GetEnvironmentVariable("BENCHPILOT_PROFILE");
var profile = string.IsNullOrWhiteSpace(profilePath)
    ? ProfileLoader.DefaultSimulator()
    : ProfileLoader.Load(profilePath);

// Autostart mode: before anything can write to (or merely keep open) the
// console we inherited from the spawning shell, release those handles. A
// daemon holding its parent's stdout pipe prevents the parent's readers
// from ever seeing EOF, hanging shells, CI and test harnesses.
var quietConsole = !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("BENCHPILOT_QUIET"));
if (quietConsole)
    StdioDetach.DisconnectConsole();

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
var runtime = drivers.CreateRuntime(profile);

// Detached/autostart mode continues: console output stays disabled and
// durable logs go to the requested file instead.
var logFilePath = Environment.GetEnvironmentVariable("BENCHPILOT_LOG_FILE");

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls(endpoint.GetLeftPart(UriPartial.Authority));
if (quietConsole)
    builder.Logging.ClearProviders();
if (!string.IsNullOrWhiteSpace(logFilePath))
{
    builder.Logging.AddProvider(new SimpleFileLoggerProvider(logFilePath));
    builder.Logging.SetMinimumLevel(LogLevel.Information);
}

// The daemon binds to loopback only, but any local process could still call
// it. A per-user token file makes the API usable by the same user's shells
// while rejecting every other local caller. healthz stays open so autostart
// and monitoring can probe liveness without credentials.
var apiToken = LocalAuth.ResolveOrCreateToken();
builder.Services.AddSingleton(apiToken);
builder.Services.AddSingleton(profile);
builder.Services.AddSingleton(drivers);
// Register the already-created instance so the host shutdown service, not the
// DI container, owns the exact point at which hardware resources are released.
builder.Services.AddSingleton(runtime);
builder.Services.AddSingleton<RuntimeHostLifecycle>();
builder.Services.AddHostedService<RuntimeShutdownService>();

var app = builder.Build();
var lifecycle = app.Services.GetRequiredService<RuntimeHostLifecycle>();
app.Lifetime.ApplicationStopping.Register(lifecycle.BeginStopping);

// Authentication precedes every other consideration: an unauthenticated
// caller learns nothing, not even shutdown state. healthz stays open.
app.Use(async (context, next) =>
{
    if (context.Request.Path.StartsWithSegments("/healthz"))
    {
        await next();
        return;
    }

    var presented = context.Request.Headers[LocalAuth.HeaderName].FirstOrDefault();
    if (!string.Equals(presented, apiToken, StringComparison.Ordinal))
    {
        context.Response.StatusCode = StatusCodes.Status401Unauthorized;
        await context.Response.WriteAsJsonAsync(new ApiError(
            false,
            "unauthorized",
            "Missing or invalid BenchPilot token. The token file is created by benchpilotd at " +
            LocalAuth.TokenFilePath + "; clients read it automatically or honor BENCHPILOT_TOKEN."));
        return;
    }

    await next();
});

// Once shutdown begins no new non-health request is admitted. Requests that
// crossed this middleware immediately before ApplicationStopping remain counted
// until their complete HTTP execution leaves the middleware, allowing shutdown
// to wait even for work that has not yet registered an operation/observation.
app.Use(async (context, next) =>
{
    if (context.Request.Path.StartsWithSegments("/healthz"))
    {
        await next();
        return;
    }

    if (!lifecycle.TryEnterRequest(out var requestLease))
    {
        context.Response.StatusCode = StatusCodes.Status503ServiceUnavailable;
        await context.Response.WriteAsJsonAsync(new ApiError(
            false,
            "runtime_stopping",
            "BenchPilot Runtime is stopping and is not accepting new work."));
        return;
    }

    using (requestLease)
        await next();
});

app.MapGet("/healthz", () =>
    lifecycle.IsStopping
        ? Results.Json(
            new { ok = false, state = "stopping", version = BenchpilotRuntimeInfo.Version },
            statusCode: StatusCodes.Status503ServiceUnavailable)
        : Results.Ok(new { ok = true, state = "running", version = BenchpilotRuntimeInfo.Version }));

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
        resources,
        RuntimeVersion: BenchpilotRuntimeInfo.Version));
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
            x.DeadlineAtUtc,
            x.CancellationRequested,
            x.DeadlineExceeded))
        .ToArray();
    return Results.Json(new OperationListResult(true, operations));
});

app.MapGet($"{BenchpilotApi.Prefix}/operations/history", (
    int? limit,
    BenchRuntime runtime) =>
{
    try
    {
        var operations = runtime.RecentOperations(limit ?? 50)
            .Select(x => new OperationHistorySummary(
                x.Id,
                x.TargetId,
                x.Kind,
                x.ResourceIds,
                x.StartedAtUtc,
                x.CompletedAtUtc,
                x.DurationMs,
                x.DeadlineAtUtc,
                x.State,
                x.Error))
            .ToArray();
        return Results.Json(new OperationHistoryResult(true, operations));
    }
    catch (BenchValidationException ex)
    {
        return Results.BadRequest(new ApiError(false, "validation", ex.Message));
    }
});

app.MapGet($"{BenchpilotApi.Prefix}/operations/{{operationId}}/evidence", (
    string operationId,
    BenchRuntime runtime) =>
{
    if (string.IsNullOrWhiteSpace(operationId))
        return Results.BadRequest(new ApiError(false, "validation", "Operation id cannot be empty."));

    var evidence = runtime.GetOperationEvidence(operationId);
    if (evidence is null)
    {
        return Results.NotFound(new ApiError(
            false,
            "not_found",
            $"Evidence for operation '{operationId}' was not found."));
    }

    var items = evidence.Items
        .Select(x => new EvidenceItemSummary(x.Kind, x.Summary, x.Text, x.Metadata))
        .ToArray();
    return Results.Json(new OperationEvidenceResult(
        true,
        evidence.OperationId,
        evidence.TargetId,
        evidence.OperationKind,
        evidence.ResourceIds,
        evidence.CreatedAtUtc,
        items));
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

app.MapGet($"{BenchpilotApi.Prefix}/observations", (BenchRuntime runtime) =>
{
    var observations = runtime.ActiveObservations
        .Select(x => new ObservationSummary(
            x.Id,
            x.TargetId,
            x.Kind,
            x.ResourceIds,
            x.StartedAtUtc,
            x.DeadlineAtUtc,
            x.CancellationRequested,
            x.DeadlineExceeded))
        .ToArray();
    return Results.Json(new ObservationListResult(true, observations));
});

app.MapGet($"{BenchpilotApi.Prefix}/observations/history", (
    int? limit,
    BenchRuntime runtime) =>
{
    try
    {
        var observations = runtime.RecentObservations(limit ?? 50)
            .Select(x => new ObservationHistorySummary(
                x.Id,
                x.TargetId,
                x.Kind,
                x.ResourceIds,
                x.StartedAtUtc,
                x.CompletedAtUtc,
                x.DurationMs,
                x.DeadlineAtUtc,
                x.State,
                x.Error))
            .ToArray();
        return Results.Json(new ObservationHistoryResult(true, observations));
    }
    catch (BenchValidationException ex)
    {
        return Results.BadRequest(new ApiError(false, "validation", ex.Message));
    }
});

app.MapGet($"{BenchpilotApi.Prefix}/observations/{{observationId}}/evidence", (
    string observationId,
    BenchRuntime runtime) =>
{
    if (string.IsNullOrWhiteSpace(observationId))
        return Results.BadRequest(new ApiError(false, "validation", "Observation id cannot be empty."));

    var evidence = runtime.GetObservationEvidence(observationId);
    if (evidence is null)
    {
        return Results.NotFound(new ApiError(
            false,
            "not_found",
            $"Evidence for observation '{observationId}' was not found."));
    }

    var items = evidence.Items
        .Select(x => new EvidenceItemSummary(x.Kind, x.Summary, x.Text, x.Metadata))
        .ToArray();
    return Results.Json(new ObservationEvidenceResult(
        true,
        evidence.ObservationId,
        evidence.TargetId,
        evidence.ObservationKind,
        evidence.ResourceIds,
        evidence.CreatedAtUtc,
        items));
});

app.MapPost($"{BenchpilotApi.Prefix}/observations/{{observationId}}/cancel", (
    string observationId,
    BenchRuntime runtime) =>
{
    if (string.IsNullOrWhiteSpace(observationId))
        return Results.BadRequest(new ApiError(false, "validation", "Observation id cannot be empty."));

    if (!runtime.CancelObservation(observationId))
    {
        return Results.NotFound(new ApiError(
            false,
            "not_found",
            $"Active observation '{observationId}' was not found."));
    }

    return Results.Json(new ObservationCancelResult(true, observationId, true));
});

app.MapPost($"{BenchpilotApi.Prefix}/preflight", async (
    string? target,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.Preflight(target, ct)));

app.MapPost($"{BenchpilotApi.Prefix}/validate", async (
    string? target,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.ValidateTargetReadiness(target, ct)));

app.MapPost($"{BenchpilotApi.Prefix}/power/on", async (
    string? target,
    int? deadlineMs,
    PowerOnRequest request,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.Target(target).PowerOn(
        request.Voltage,
        request.SettleMs,
        deadlineMs,
        ct)));

app.MapPost($"{BenchpilotApi.Prefix}/power/off", async (
    string? target,
    int? deadlineMs,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.Target(target).PowerOff(deadlineMs, ct)));

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
    int? deadlineMs,
    FlashRequest request,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.Target(target).Flash(
        request.Firmware,
        request.ConfirmTarget,
        deadlineMs,
        ct)));

app.MapPost($"{BenchpilotApi.Prefix}/flash/reset", async (
    string? target,
    int? deadlineMs,
    ResetRequest request,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.Target(target).Reset(
        request.ConfirmTarget,
        deadlineMs,
        ct)));

app.MapPost($"{BenchpilotApi.Prefix}/serial/open", async (
    string? target,
    int? deadlineMs,
    SerialOpenRequest request,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.Target(target).SerialOpen(
        request.Port,
        request.Baud,
        deadlineMs,
        ct)));

app.MapPost($"{BenchpilotApi.Prefix}/serial/wait", async (
    string? target,
    int? deadlineMs,
    SerialWaitRequest request,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.Target(target).SerialWaitFor(
        request.Pattern,
        request.TimeoutMs,
        deadlineMs,
        ct)));

app.MapPost($"{BenchpilotApi.Prefix}/serial/window", async (
    string? target,
    int? deadlineMs,
    SerialWindowRequest request,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.Target(target).SerialReadWindow(
        request.Lines,
        request.Filter,
        deadlineMs,
        ct)));

app.MapPost($"{BenchpilotApi.Prefix}/serial/send", async (
    string? target,
    int? deadlineMs,
    SerialSendRequest request,
    BenchRuntime runtime,
    CancellationToken ct) =>
    await Execute(() => runtime.Target(target).SerialSend(
        request.Data,
        deadlineMs,
        ct)));

app.Logger.LogInformation(
    "BenchPilot Runtime {Version} ('{BenchName}') listening on {Endpoint}. Profile: {Profile}. Drivers: {Drivers}",
    BenchpilotRuntimeInfo.Version,
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
    catch (BenchDeadlineExceededException ex)
    {
        return Results.Json(
            new ApiError(
                false,
                "deadline_exceeded",
                ex.Message,
                DeadlineMs: ex.DeadlineMs,
                DeadlineAtUtc: ex.DeadlineAtUtc),
            statusCode: StatusCodes.Status408RequestTimeout);
    }
    catch (OperationCanceledException)
    {
        return Results.Json(
            new ApiError(false, "cancelled", "Request cancelled."),
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