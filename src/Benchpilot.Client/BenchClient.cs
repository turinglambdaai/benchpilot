using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Benchpilot.Core;
using Benchpilot.Protocol;

namespace Benchpilot.Client;

public sealed class BenchClientException : Exception
{
    public BenchClientException(
        HttpStatusCode statusCode,
        string code,
        string message,
        string? operationId = null,
        string? busyScope = null,
        string? busyId = null)
        : base(message)
    {
        StatusCode = statusCode;
        Code = code;
        OperationId = operationId;
        BusyScope = busyScope;
        BusyId = busyId;
    }

    public HttpStatusCode StatusCode { get; }
    public string Code { get; }
    public string? OperationId { get; }
    public string? BusyScope { get; }
    public string? BusyId { get; }
}

/// <summary>
/// Thin client for the resident BenchPilot runtime. CLI, MCP and Studio should
/// use this class instead of opening hardware independently.
/// </summary>
public sealed class BenchClient : IDisposable
{
    public const string DefaultEndpoint = "http://127.0.0.1:5640/";

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly HttpClient _http;
    private readonly bool _ownsClient;

    public BenchClient(Uri endpoint, HttpClient? httpClient = null)
    {
        ArgumentNullException.ThrowIfNull(endpoint);
        if (!endpoint.IsAbsoluteUri)
            throw new ArgumentException("BenchPilot endpoint must be an absolute URI.", nameof(endpoint));

        _ownsClient = httpClient is null;
        _http = httpClient ?? new HttpClient();
        _http.BaseAddress = EnsureTrailingSlash(endpoint);
        _http.Timeout = Timeout.InfiniteTimeSpan;
    }

    public static Uri ResolveEndpoint(string? explicitEndpoint = null)
    {
        var value = explicitEndpoint;
        if (string.IsNullOrWhiteSpace(value))
            value = Environment.GetEnvironmentVariable("BENCHPILOT_ENDPOINT");
        if (string.IsNullOrWhiteSpace(value))
            value = DefaultEndpoint;

        if (!Uri.TryCreate(value, UriKind.Absolute, out var endpoint))
            throw new ArgumentException($"Invalid BenchPilot endpoint URI: {value}");
        return endpoint;
    }

    public Task<RuntimeStatusResult> Status(CancellationToken ct = default) =>
        Send<RuntimeStatusResult>(HttpMethod.Get, "api/v1/status", null, ct);

    public Task<OperationListResult> Operations(CancellationToken ct = default) =>
        Send<OperationListResult>(HttpMethod.Get, "api/v1/operations", null, ct);

    public Task<OperationHistoryResult> OperationHistory(
        int limit = 50,
        CancellationToken ct = default) =>
        Send<OperationHistoryResult>(
            HttpMethod.Get,
            $"api/v1/operations/history?limit={limit}",
            null,
            ct);

    public Task<OperationEvidenceResult> OperationEvidence(
        string operationId,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(operationId);
        return Send<OperationEvidenceResult>(
            HttpMethod.Get,
            $"api/v1/operations/{Uri.EscapeDataString(operationId)}/evidence",
            null,
            ct);
    }

    public Task<OperationCancelResult> CancelOperation(
        string operationId,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(operationId);
        return Send<OperationCancelResult>(
            HttpMethod.Post,
            $"api/v1/operations/{Uri.EscapeDataString(operationId)}/cancel",
            null,
            ct);
    }

    public Task<TargetPreflightResult> Preflight(
        string? target = null,
        CancellationToken ct = default) =>
        Send<TargetPreflightResult>(HttpMethod.Post, WithTarget("api/v1/preflight", target), null, ct);

    public Task<PowerOnResult> PowerOn(
        double voltage,
        int settleMs,
        string? target = null,
        CancellationToken ct = default) =>
        Send<PowerOnResult>(HttpMethod.Post, WithTarget("api/v1/power/on", target),
            new PowerOnRequest(voltage, settleMs), ct);

    public Task<PowerOffResult> PowerOff(string? target = null, CancellationToken ct = default) =>
        Send<PowerOffResult>(HttpMethod.Post, WithTarget("api/v1/power/off", target), null, ct);

    public Task<PowerOffResult> EmergencyPowerOff(
        string? target = null,
        CancellationToken ct = default) =>
        Send<PowerOffResult>(HttpMethod.Post, WithTarget("api/v1/power/emergency-off", target), null, ct);

    public Task<CurrentReading> ReadCurrent(
        int windowMs,
        string? target = null,
        CancellationToken ct = default) =>
        Send<CurrentReading>(HttpMethod.Post, WithTarget("api/v1/power/current/read", target),
            new CurrentReadRequest(windowMs), ct);

    public Task<CurrentCheck> CheckCurrent(
        double? ltMa,
        double? gtMa,
        string? target = null,
        CancellationToken ct = default) =>
        Send<CurrentCheck>(HttpMethod.Post, WithTarget("api/v1/power/current/check", target),
            new CurrentCheckRequest(ltMa, gtMa), ct);

    public Task<FlashResult> Flash(
        string firmware,
        string? target = null,
        CancellationToken ct = default) =>
        Flash(firmware, target, null, ct);

    public Task<FlashResult> Flash(
        string firmware,
        string? target,
        string? confirmTarget,
        CancellationToken ct = default) =>
        Send<FlashResult>(HttpMethod.Post, WithTarget("api/v1/flash/write", target),
            new FlashRequest(firmware, confirmTarget), ct);

    public Task<ResetResult> Reset(string? target = null, CancellationToken ct = default) =>
        Reset(target, null, ct);

    public Task<ResetResult> Reset(
        string? target,
        string? confirmTarget,
        CancellationToken ct = default) =>
        Send<ResetResult>(HttpMethod.Post, WithTarget("api/v1/flash/reset", target),
            new ResetRequest(confirmTarget), ct);

    public Task<SerialOpenResult> SerialOpen(
        string? port = null,
        int? baud = null,
        string? target = null,
        CancellationToken ct = default) =>
        Send<SerialOpenResult>(HttpMethod.Post, WithTarget("api/v1/serial/open", target),
            new SerialOpenRequest(port, baud), ct);

    public Task<SerialWaitResult> SerialWaitFor(
        string pattern,
        int timeoutMs,
        string? target = null,
        CancellationToken ct = default) =>
        Send<SerialWaitResult>(HttpMethod.Post, WithTarget("api/v1/serial/wait", target),
            new SerialWaitRequest(pattern, timeoutMs), ct);

    public Task<SerialWindowResult> SerialReadWindow(
        int lines,
        string? filter,
        string? target = null,
        CancellationToken ct = default) =>
        Send<SerialWindowResult>(HttpMethod.Post, WithTarget("api/v1/serial/window", target),
            new SerialWindowRequest(lines, filter), ct);

    public Task<SerialSendResult> SerialSend(
        string data,
        string? target = null,
        CancellationToken ct = default) =>
        Send<SerialSendResult>(HttpMethod.Post, WithTarget("api/v1/serial/send", target),
            new SerialSendRequest(data), ct);

    private async Task<T> Send<T>(
        HttpMethod method,
        string relativePath,
        object? body,
        CancellationToken ct)
    {
        using var request = new HttpRequestMessage(method, relativePath);
        if (body is not null)
            request.Content = JsonContent.Create(body, options: JsonOptions);

        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);

        if (!response.IsSuccessStatusCode)
        {
            ApiError? apiError = null;
            try
            {
                apiError = await response.Content.ReadFromJsonAsync<ApiError>(JsonOptions, ct);
            }
            catch (JsonException)
            {
                // Fall through to a stable generic error when a proxy/server
                // returns a non-BenchPilot response.
            }

            throw new BenchClientException(
                response.StatusCode,
                apiError?.Code ?? "http_error",
                apiError?.Error ?? $"BenchPilot runtime returned HTTP {(int)response.StatusCode}.",
                apiError?.OperationId,
                apiError?.BusyScope,
                apiError?.BusyId);
        }

        var value = await response.Content.ReadFromJsonAsync<T>(JsonOptions, ct);
        return value ?? throw new BenchClientException(
            response.StatusCode,
            "invalid_response",
            "BenchPilot runtime returned an empty or invalid JSON response.");
    }

    private static string WithTarget(string path, string? target) =>
        string.IsNullOrWhiteSpace(target)
            ? path
            : $"{path}?target={Uri.EscapeDataString(target)}";

    private static Uri EnsureTrailingSlash(Uri endpoint) =>
        endpoint.AbsoluteUri.EndsWith("/", StringComparison.Ordinal)
            ? endpoint
            : new Uri(endpoint.AbsoluteUri + "/");

    public void Dispose()
    {
        if (_ownsClient)
            _http.Dispose();
    }
}
