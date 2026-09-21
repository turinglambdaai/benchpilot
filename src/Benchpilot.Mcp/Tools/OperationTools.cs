using System.ComponentModel;
using Benchpilot.Client;
using Benchpilot.Protocol;
using ModelContextProtocol.Server;

namespace Benchpilot.Mcp.Tools;

/// <summary>
/// Agent-facing control over Runtime-owned mutating operations. These tools do
/// not own task state themselves; they inspect/cancel operations registered by
/// benchpilotd so CLI, MCP and future Studio clients see the same activity.
/// </summary>
internal sealed class OperationTools
{
    private readonly BenchClient _client;
    public OperationTools(BenchClient client) => _client = client;

    [McpServerTool]
    [Description("List active mutating bench operations, including operation id, semantic target, operation kind, physical resources, start time and whether cancellation has been requested.")]
    public async Task<OperationListResult> ListOperations()
        => await _client.Operations(CancellationToken.None);

    [McpServerTool]
    [Description("List the bounded recent mutation audit from Runtime. Each record includes operation id, target, kind, physical resources, timestamps, duration, terminal execution state (completed/cancelled/faulted) and bounded fault text when present.")]
    public async Task<OperationHistoryResult> ListOperationHistory(
        [Description("Maximum number of newest records to return, from 1 to 128.")] int limit = 50)
        => await _client.OperationHistory(limit, CancellationToken.None);

    [McpServerTool]
    [Description("Request cooperative cancellation of one active bench operation by operation id. Use ListOperations first. Cancellation propagates into supported hardware drivers; the operation disappears after the driver exits and Runtime releases its locks.")]
    public async Task<OperationCancelResult> CancelOperation(
        [Description("Operation id returned by ListOperations or a busy error.")] string operationId)
        => await _client.CancelOperation(operationId, CancellationToken.None);
}
