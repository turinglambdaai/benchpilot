using Benchpilot.Core;
using Benchpilot.Runtime;

namespace Benchpilot.Core.Tests;

public sealed class RuntimeDrainTests
{
    [Fact]
    public async Task Drain_cancels_active_mutation_and_observation_before_resource_disposal()
    {
        var resource = new BlockingSharedResource();
        using var runtime = NewSharedRuntime(resource);
        var target = runtime.Target();

        var flashTask = target.Flash("build/app.elf");
        var waitTask = target.SerialWaitFor("Ready", 60_000);
        await Task.WhenAll(
            resource.FlashStarted.Task.WaitAsync(TimeSpan.FromSeconds(2)),
            resource.WaitStarted.Task.WaitAsync(TimeSpan.FromSeconds(2)));

        var result = await runtime.DrainAsync(TimeSpan.FromSeconds(2));

        Assert.True(result.Drained);
        Assert.Equal(1, result.CancelRequestedOperations);
        Assert.Equal(1, result.CancelRequestedObservations);
        Assert.Empty(result.RemainingOperationIds);
        Assert.Empty(result.RemainingObservationIds);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () => await flashTask);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () => await waitTask);
        Assert.Empty(runtime.ActiveOperations);
        Assert.Empty(runtime.ActiveObservations);
        Assert.False(resource.Disposed);

        var operation = Assert.Single(runtime.RecentOperations());
        Assert.Equal("cancelled", operation.State);
        var observation = Assert.Single(runtime.RecentObservations());
        Assert.Equal("cancelled", observation.State);
    }

    [Fact]
    public async Task Drain_times_out_without_disposing_under_uncooperative_driver()
    {
        var flash = new StubbornFlashTarget();
        using var runtime = NewFlashRuntime(flash);
        var flashTask = runtime.Target().Flash("build/app.elf");
        await flash.Started.Task.WaitAsync(TimeSpan.FromSeconds(2));

        var active = Assert.Single(runtime.ActiveOperations);
        var result = await runtime.DrainAsync(TimeSpan.FromMilliseconds(75));

        Assert.False(result.Drained);
        Assert.Equal(1, result.CancelRequestedOperations);
        Assert.Contains(active.Id, result.RemainingOperationIds);
        Assert.False(flash.Disposed);

        flash.Release.TrySetResult(true);
        var completed = await flashTask.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.True(completed.Ok);
        Assert.Empty(runtime.ActiveOperations);
    }

    private static BenchRuntime NewSharedRuntime(BlockingSharedResource resource)
    {
        var profile = new BenchProfile
        {
            SchemaVersion = 1,
            Name = "Drain shared bench",
            DefaultTarget = "ecu",
            Resources = new Dictionary<string, BenchResourceConfig>(StringComparer.OrdinalIgnoreCase)
            {
                ["shared.test"] = new()
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
                        ["flash"] = "shared.test",
                        ["serial"] = "shared.test",
                    },
                },
            },
        };

        var registry = new BenchResourceRegistry(profile);
        registry.Register("shared.test", resource);
        return new BenchRuntime(profile, registry);
    }

    private static BenchRuntime NewFlashRuntime(StubbornFlashTarget flash)
    {
        var profile = new BenchProfile
        {
            SchemaVersion = 1,
            Name = "Drain flash bench",
            DefaultTarget = "ecu",
            Resources = new Dictionary<string, BenchResourceConfig>(StringComparer.OrdinalIgnoreCase)
            {
                ["flash.test"] = new()
                {
                    Driver = "test",
                    Capabilities = ["flash"],
                },
            },
            Targets = new Dictionary<string, BenchTargetConfig>(StringComparer.OrdinalIgnoreCase)
            {
                ["ecu"] = new()
                {
                    Bindings = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                    {
                        ["flash"] = "flash.test",
                    },
                },
            },
        };

        var registry = new BenchResourceRegistry(profile);
        registry.Register("flash.test", flash);
        return new BenchRuntime(profile, registry);
    }

    private sealed class BlockingSharedResource : IFlashTarget, ISerialChannel, IDisposable
    {
        public TaskCompletionSource<bool> FlashStarted { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource<bool> WaitStarted { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public bool IsOpen => true;
        public bool Disposed { get; private set; }

        public async Task<FlashResult> Flash(string firmwarePath, CancellationToken ct = default)
        {
            FlashStarted.TrySetResult(true);
            await Task.Delay(Timeout.InfiniteTimeSpan, ct);
            throw new InvalidOperationException("Unreachable");
        }

        public Task<ResetResult> Reset(CancellationToken ct = default) =>
            Task.FromResult(new ResetResult(true));

        public Task<SerialOpenResult> Open(string? port = null, int? baud = null, CancellationToken ct = default) =>
            Task.FromResult(new SerialOpenResult(true, port ?? "TEST0", baud ?? 115200));

        public async Task<SerialWaitResult> WaitFor(string pattern, int timeoutMs, CancellationToken ct = default)
        {
            WaitStarted.TrySetResult(true);
            await Task.Delay(Timeout.InfiniteTimeSpan, ct);
            throw new InvalidOperationException("Unreachable");
        }

        public Task<SerialWindowResult> ReadWindow(int lines, string? filter, CancellationToken ct = default) =>
            Task.FromResult(new SerialWindowResult(true, Array.Empty<string>()));

        public Task<SerialSendResult> Send(string data, CancellationToken ct = default) =>
            Task.FromResult(new SerialSendResult(true));

        public void Dispose() => Disposed = true;
    }

    private sealed class StubbornFlashTarget : IFlashTarget, IDisposable
    {
        public TaskCompletionSource<bool> Started { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource<bool> Release { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public bool Disposed { get; private set; }

        public async Task<FlashResult> Flash(string firmwarePath, CancellationToken ct = default)
        {
            Started.TrySetResult(true);
            // Intentionally ignore ct to model a vendor SDK call that cannot be
            // interrupted cooperatively.
            await Release.Task;
            return new FlashResult(true, 1024, 1);
        }

        public Task<ResetResult> Reset(CancellationToken ct = default) =>
            Task.FromResult(new ResetResult(true));

        public void Dispose() => Disposed = true;
    }
}
