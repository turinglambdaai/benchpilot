using Benchpilot.Core;
using Benchpilot.Runtime;

namespace Benchpilot.Core.Tests;

public sealed class ObservationEvidenceTests
{
    private static BenchRuntime NewRuntime(
        ISerialChannel serial,
        IFlashTarget? flash = null)
    {
        var resources = new Dictionary<string, BenchResourceConfig>(StringComparer.OrdinalIgnoreCase)
        {
            ["serial.test"] = new()
            {
                Driver = "test",
                Capabilities = ["serial"],
            },
        };
        var bindings = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["serial"] = "serial.test",
        };

        if (flash is not null)
        {
            resources["flash.test"] = new BenchResourceConfig
            {
                Driver = "test",
                Capabilities = ["flash"],
            };
            bindings["flash"] = "flash.test";
        }

        var profile = new BenchProfile
        {
            SchemaVersion = 1,
            Name = "Observation test bench",
            DefaultTarget = "ecu",
            Resources = resources,
            Targets = new Dictionary<string, BenchTargetConfig>(StringComparer.OrdinalIgnoreCase)
            {
                ["ecu"] = new()
                {
                    Bindings = bindings,
                },
            },
        };

        var registry = new BenchResourceRegistry(profile);
        registry.Register("serial.test", serial);
        if (flash is not null)
            registry.Register("flash.test", flash);
        return new BenchRuntime(profile, registry);
    }

    [Fact]
    public async Task Unmatched_serial_wait_gets_identity_history_and_bounded_failure_window()
    {
        using var runtime = NewRuntime(new FixedSerialChannel(
            new SerialWaitResult(true, false, null, 42),
            ["Booting...", "Init peripherals", "FAULT: missing calibration", "tail"]));

        var result = await runtime.Target().SerialWaitFor("System Ready", 1000);

        Assert.True(result.Ok);
        Assert.False(result.Matched);
        Assert.False(string.IsNullOrWhiteSpace(result.ObservationId));
        Assert.Empty(runtime.ActiveObservations);

        var history = Assert.Single(runtime.RecentObservations());
        Assert.Equal(result.ObservationId, history.Id);
        Assert.Equal("serial.wait", history.Kind);
        Assert.Equal("completed", history.State);

        var evidence = Assert.IsType<BenchObservationEvidence>(
            runtime.GetObservationEvidence(result.ObservationId!));
        Assert.Equal("serial.wait", evidence.ObservationKind);
        Assert.Equal(["serial.test"], evidence.ResourceIds);
        Assert.Equal(2, evidence.Items.Count);

        var wait = evidence.Items[0];
        Assert.Equal("serial.wait", wait.Kind);
        Assert.Equal("false", wait.Metadata!["matched"]);
        Assert.Equal("System Ready", wait.Metadata["pattern"]);
        Assert.Equal("1000", wait.Metadata["timeoutMs"]);
        Assert.Equal("42", wait.Metadata["elapsedMs"]);

        var window = evidence.Items[1];
        Assert.Equal("serial.failure-window", window.Kind);
        Assert.Contains("FAULT: missing calibration", window.Text!);
        Assert.Equal("4", window.Metadata!["lineCount"]);
    }

    [Fact]
    public async Task Active_observation_does_not_take_target_or_resource_mutation_gate()
    {
        var serial = new BlockingSerialChannel();
        using var runtime = NewRuntime(serial, new ImmediateFlashTarget());
        var target = runtime.Target();

        var waitTask = target.SerialWaitFor("Ready", 60_000);
        await serial.Started.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var observation = Assert.Single(runtime.ActiveObservations);
        Assert.Equal("serial.wait", observation.Kind);

        var flash = await target.Flash("build/app.elf");
        Assert.True(flash.Ok);
        Assert.Single(runtime.ActiveObservations);
        Assert.Empty(runtime.ActiveOperations);

        Assert.True(runtime.CancelObservation(observation.Id));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () => await waitTask);
    }

    [Fact]
    public async Task Cancelling_observation_records_cancelled_history_and_evidence()
    {
        var serial = new BlockingSerialChannel();
        using var runtime = NewRuntime(serial);
        var waitTask = runtime.Target().SerialWaitFor("Ready", 60_000);
        await serial.Started.Task.WaitAsync(TimeSpan.FromSeconds(2));

        var active = Assert.Single(runtime.ActiveObservations);
        Assert.True(runtime.CancelObservation(active.Id));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () => await waitTask);

        Assert.Empty(runtime.ActiveObservations);
        var history = Assert.Single(runtime.RecentObservations());
        Assert.Equal(active.Id, history.Id);
        Assert.Equal("cancelled", history.State);

        var evidence = Assert.IsType<BenchObservationEvidence>(
            runtime.GetObservationEvidence(active.Id));
        var item = Assert.Single(evidence.Items);
        Assert.Equal("runtime.cancelled", item.Kind);
        Assert.Equal("Observation cancelled.", item.Text);
    }

    [Fact]
    public async Task Observation_evidence_store_is_bounded_to_newest_128_entries()
    {
        using var runtime = NewRuntime(new FixedSerialChannel(
            new SerialWaitResult(true, true, "Ready", 1),
            ["Ready"]));
        var target = runtime.Target();

        var first = await target.SerialOpen();
        Assert.NotNull(first.ObservationId);
        Assert.NotNull(runtime.GetObservationEvidence(first.ObservationId!));

        for (var i = 0; i < 128; i++)
            Assert.NotNull((await target.SerialSend($"ping-{i}")).ObservationId);

        Assert.Null(runtime.GetObservationEvidence(first.ObservationId!));
        var newest = runtime.RecentObservations(1).Single();
        Assert.NotNull(runtime.GetObservationEvidence(newest.Id));
    }

    private sealed class FixedSerialChannel : ISerialChannel
    {
        private readonly SerialWaitResult _wait;
        private readonly IReadOnlyList<string> _window;

        public FixedSerialChannel(SerialWaitResult wait, IReadOnlyList<string> window)
        {
            _wait = wait;
            _window = window;
        }

        public Task<SerialOpenResult> Open(string? port = null, int? baud = null, CancellationToken ct = default)
        {
            ct.ThrowIfCancellationRequested();
            return Task.FromResult(new SerialOpenResult(true, port ?? "TEST0", baud ?? 115200));
        }

        public Task<SerialWaitResult> WaitFor(string pattern, int timeoutMs, CancellationToken ct = default)
        {
            ct.ThrowIfCancellationRequested();
            return Task.FromResult(_wait);
        }

        public Task<SerialWindowResult> ReadWindow(int lines, string? filter, CancellationToken ct = default)
        {
            ct.ThrowIfCancellationRequested();
            return Task.FromResult(new SerialWindowResult(true, _window.TakeLast(lines).ToArray()));
        }

        public Task<SerialSendResult> Send(string data, CancellationToken ct = default)
        {
            ct.ThrowIfCancellationRequested();
            return Task.FromResult(new SerialSendResult(true));
        }
    }

    private sealed class BlockingSerialChannel : ISerialChannel
    {
        public TaskCompletionSource<bool> Started { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public Task<SerialOpenResult> Open(string? port = null, int? baud = null, CancellationToken ct = default) =>
            Task.FromResult(new SerialOpenResult(true, port ?? "TEST0", baud ?? 115200));

        public async Task<SerialWaitResult> WaitFor(string pattern, int timeoutMs, CancellationToken ct = default)
        {
            Started.TrySetResult(true);
            await Task.Delay(Timeout.InfiniteTimeSpan, ct);
            throw new InvalidOperationException("Unreachable");
        }

        public Task<SerialWindowResult> ReadWindow(int lines, string? filter, CancellationToken ct = default) =>
            Task.FromResult(new SerialWindowResult(true, Array.Empty<string>()));

        public Task<SerialSendResult> Send(string data, CancellationToken ct = default) =>
            Task.FromResult(new SerialSendResult(true));
    }

    private sealed class ImmediateFlashTarget : IFlashTarget
    {
        public Task<FlashResult> Flash(string firmwarePath, CancellationToken ct = default)
        {
            ct.ThrowIfCancellationRequested();
            return Task.FromResult(new FlashResult(true, 1024, 1));
        }

        public Task<ResetResult> Reset(CancellationToken ct = default)
        {
            ct.ThrowIfCancellationRequested();
            return Task.FromResult(new ResetResult(true));
        }
    }
}
