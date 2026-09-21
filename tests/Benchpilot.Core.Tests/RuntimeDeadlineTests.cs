using Benchpilot.Core;
using Benchpilot.Runtime;

namespace Benchpilot.Core.Tests;

public sealed class RuntimeDeadlineTests
{
    [Fact]
    public async Task Mutation_deadline_has_distinct_history_exception_and_evidence()
    {
        using var runtime = NewRuntime(new BlockingDevice());

        var error = await Assert.ThrowsAsync<BenchDeadlineExceededException>(
            () => runtime.Target("ecu").Flash(
                "app.elf",
                confirmTarget: null,
                deadlineMs: 60));

        Assert.Equal("ecu", error.TargetId);
        Assert.Equal("flash.write", error.Operation);
        Assert.Equal(60, error.DeadlineMs);

        var history = Assert.Single(runtime.RecentOperations());
        Assert.Equal("deadline_exceeded", history.State);
        Assert.NotNull(history.DeadlineAtUtc);
        Assert.Contains("60 ms", history.Error);

        var evidence = Assert.IsType<BenchOperationEvidence>(
            runtime.GetOperationEvidence(history.Id));
        var item = Assert.Single(evidence.Items);
        Assert.Equal("runtime.deadline", item.Kind);
        Assert.Equal("60", item.Metadata!["deadlineMs"]);
        Assert.True(item.Metadata.ContainsKey("deadlineAtUtc"));
    }

    [Fact]
    public async Task Observation_deadline_is_not_semantic_serial_wait_timeout()
    {
        using var runtime = NewRuntime(new BlockingDevice());

        var error = await Assert.ThrowsAsync<BenchDeadlineExceededException>(
            () => runtime.Target("ecu").SerialWaitFor(
                "READY",
                timeoutMs: 5000,
                deadlineMs: 60));

        Assert.Equal("serial.wait", error.Operation);
        var history = Assert.Single(runtime.RecentObservations());
        Assert.Equal("deadline_exceeded", history.State);
        Assert.NotNull(history.DeadlineAtUtc);

        var evidence = Assert.IsType<BenchObservationEvidence>(
            runtime.GetObservationEvidence(history.Id));
        var item = Assert.Single(evidence.Items);
        Assert.Equal("runtime.deadline", item.Kind);
        Assert.Equal("60", item.Metadata!["deadlineMs"]);
    }

    [Fact]
    public async Task Caller_cancellation_remains_cancelled_not_deadline()
    {
        using var runtime = NewRuntime(new BlockingDevice());
        using var cts = new CancellationTokenSource();

        var flash = runtime.Target("ecu").Flash("app.elf", ct: cts.Token);
        var active = Assert.Single(runtime.ActiveOperations);
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () => await flash);

        var history = Assert.Single(runtime.RecentOperations());
        Assert.Equal("cancelled", history.State);
        Assert.Null(history.DeadlineAtUtc);
        var evidence = Assert.IsType<BenchOperationEvidence>(
            runtime.GetOperationEvidence(active.Id));
        Assert.Equal("runtime.cancelled", Assert.Single(evidence.Items).Kind);
    }

    [Fact]
    public async Task Late_success_from_uncooperative_driver_is_rejected_after_deadline()
    {
        using var runtime = NewRuntime(new LateSuccessDevice());

        await Assert.ThrowsAsync<BenchDeadlineExceededException>(
            () => runtime.Target("ecu").Flash(
                "app.elf",
                confirmTarget: null,
                deadlineMs: 30));

        var history = Assert.Single(runtime.RecentOperations());
        Assert.Equal("deadline_exceeded", history.State);
    }

    [Fact]
    public async Task Active_operation_exposes_deadline_without_marking_explicit_cancel()
    {
        using var runtime = NewRuntime(new BlockingDevice());
        var flash = runtime.Target("ecu").Flash(
            "app.elf",
            confirmTarget: null,
            deadlineMs: 5000);

        var active = Assert.Single(runtime.ActiveOperations);
        Assert.NotNull(active.DeadlineAtUtc);
        Assert.False(active.CancellationRequested);
        Assert.False(active.DeadlineExceeded);

        Assert.True(runtime.CancelOperation(active.Id));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () => await flash);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    public async Task Non_positive_deadline_is_validation_error(int deadlineMs)
    {
        using var runtime = NewRuntime(new BlockingDevice());

        var error = await Assert.ThrowsAsync<BenchValidationException>(
            () => runtime.Target("ecu").Flash(
                "app.elf",
                confirmTarget: null,
                deadlineMs: deadlineMs));

        Assert.Contains("deadlineMs", error.Message);
        Assert.Empty(runtime.RecentOperations());
    }

    private static BenchRuntime NewRuntime(CompositeDevice device)
    {
        var profile = new BenchProfile
        {
            Name = "Deadline test bench",
            DefaultTarget = "ecu",
            Resources = new Dictionary<string, BenchResourceConfig>(StringComparer.OrdinalIgnoreCase)
            {
                ["device.ecu"] = new()
                {
                    Driver = "test",
                    Capabilities = ["flash", "serial"],
                },
            },
            Targets = new Dictionary<string, BenchTargetConfig>(StringComparer.OrdinalIgnoreCase)
            {
                ["ecu"] = new()
                {
                    Bindings = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                    {
                        ["flash"] = "device.ecu",
                        ["serial"] = "device.ecu",
                    },
                },
            },
        };

        var registry = new BenchResourceRegistry(profile);
        registry.Register("device.ecu", device);
        return new BenchRuntime(profile, registry);
    }

    private abstract class CompositeDevice : IFlashTarget, ISerialChannel
    {
        public bool IsOpen => true;

        public abstract Task<FlashResult> Flash(
            string firmwarePath,
            CancellationToken ct = default);

        public Task<ResetResult> Reset(CancellationToken ct = default) =>
            Task.FromResult(new ResetResult(true));

        public Task<SerialOpenResult> Open(
            string? port = null,
            int? baud = null,
            CancellationToken ct = default) =>
            Task.FromResult(new SerialOpenResult(true, port ?? "TEST", baud ?? 115200));

        public abstract Task<SerialWaitResult> WaitFor(
            string pattern,
            int timeoutMs,
            CancellationToken ct = default);

        public Task<SerialWindowResult> ReadWindow(
            int lines,
            string? filter,
            CancellationToken ct = default) =>
            Task.FromResult(new SerialWindowResult(true, Array.Empty<string>()));

        public Task<SerialSendResult> Send(string data, CancellationToken ct = default) =>
            Task.FromResult(new SerialSendResult(true));
    }

    private sealed class BlockingDevice : CompositeDevice
    {
        public override async Task<FlashResult> Flash(
            string firmwarePath,
            CancellationToken ct = default)
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, ct);
            throw new InvalidOperationException("Unreachable after infinite cancellable delay.");
        }

        public override async Task<SerialWaitResult> WaitFor(
            string pattern,
            int timeoutMs,
            CancellationToken ct = default)
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, ct);
            throw new InvalidOperationException("Unreachable after infinite cancellable delay.");
        }
    }

    private sealed class LateSuccessDevice : CompositeDevice
    {
        public override async Task<FlashResult> Flash(
            string firmwarePath,
            CancellationToken ct = default)
        {
            await Task.Delay(120, CancellationToken.None);
            return new FlashResult(true, 1024, 120);
        }

        public override Task<SerialWaitResult> WaitFor(
            string pattern,
            int timeoutMs,
            CancellationToken ct = default) =>
            Task.FromResult(new SerialWaitResult(true, false, null, timeoutMs));
    }
}