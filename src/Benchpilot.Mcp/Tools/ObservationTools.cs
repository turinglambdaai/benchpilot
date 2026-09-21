using System.ComponentModel;
using Benchpilot.Client;
using Benchpilot.Protocol;
using ModelContextProtocol.Server;

namespace Benchpilot.Mcp.Tools;

/// <summary>
/// Agent-facing access to Runtime-owned non-mutating observations. Serial waits
/// can run alongside target mutations while keeping bounded identity/history/
/// evidence in the resident Runtime.
/// </summary>
internal sealed class ObservationTools
{
    private readonly BenchClient _client;
    public ObservationTools(BenchClient client) => _client = client;

    [McpServerTool]
    [Description("List active non-mutating bench observations, including observation id, target, kind, physical resources, start time and cancellation state.")]
    public async Task<ObservationListResult> ListObservations()
        => await _client.Observations(CancellationToken.None);

    [McpServerTool]
    [Description("List the bounded recent observation audit from Runtime. Serial waits/open/window/send calls appear here independently of mutating-operation history.")]
    public async Task<ObservationHistoryResult> ListObservationHistory(
        [Description("Maximum number of newest records to return, from 1 to 128.")] int limit = 50)
        => await _client.ObservationHistory(limit, CancellationToken.None);

    [McpServerTool]
    [Description("Get compact bounded evidence for one terminal observation. Failed or unmatched serial waits include a small recent serial context window rather than an unbounded raw stream.")]
    public async Task<ObservationEvidenceResult> GetObservationEvidence(
        [Description("Observation id returned by a serial result or ListObservationHistory.")] string observationId)
        => await _client.ObservationEvidence(observationId, CancellationToken.None);

    [McpServerTool]
    [Description("Request cooperative cancellation of one active non-mutating observation, such as a long serial wait.")]
    public async Task<ObservationCancelResult> CancelObservation(
        [Description("Observation id returned by ListObservations.")] string observationId)
        => await _client.CancelObservation(observationId, CancellationToken.None);
}
