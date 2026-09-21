using Benchpilot.Core;
using Benchpilot.Runtime;

namespace Benchpilot.Core.Tests;

public class BenchReadinessTests
{
    [Fact]
    public async Task Hardware_target_with_required_capabilities_safety_and_preflight_is_ready()
    {
        using var runtime = CreateRuntime(CreateProfile(), healthOk: true);

        var result = await runtime.ValidateTargetReadiness("ecu");

        Assert.True(result.Ok, result.Error);
        Assert.True(result.ReadyForRealEcuLoop);
        Assert.Equal("hardware", result.Mode);
        Assert.All(result.Checks.Where(x => x.Severity == "error"), check => Assert.True(check.Passed, check.Summary));
        Assert.True(result.Preflight.Ok, result.Preflight.Error);
    }

    [Fact]
    public async Task Missing_required_capability_blocks_readiness_with_remediation()
    {
        using var runtime = CreateRuntime(CreateProfile(includeFlash: false), healthOk: true);

        var result = await runtime.ValidateTargetReadiness("ecu");

        Assert.False(result.ReadyForRealEcuLoop);
        var check = Assert.Single(result.Checks, x => x.Code == "capability.flash");
        Assert.False(check.Passed);
        Assert.Contains("bindings.flash", check.Remediation, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Advertised_capability_without_live_runtime_contract_blocks_readiness()
    {
        var profile = CreateProfile();
        var registry = new BenchResourceRegistry(profile);
        registry.Register("hw.ecu", new FlashOnlyHardwareResource());
        using var runtime = new BenchRuntime(profile, registry);

        var result = await runtime.ValidateTargetReadiness("ecu");

        Assert.False(result.ReadyForRealEcuLoop);
        Assert.True(Find(result, "runtime-capability.flash").Passed);

        var power = Find(result, "runtime-capability.power");
        Assert.False(power.Passed);
        Assert.Equal(nameof(IPowerSupply), power.Details!["requiredContract"]);
        Assert.Contains("do not advertise", power.Remediation, StringComparison.OrdinalIgnoreCase);

        var serial = Find(result, "runtime-capability.serial");
        Assert.False(serial.Passed);
        Assert.Equal(nameof(ISerialChannel), serial.Details!["requiredContract"]);
    }

    [Fact]
    public async Task Simulator_backing_is_not_accepted_as_real_hardware_readiness()
    {
        using var runtime = CreateRuntime(CreateProfile(driver: "simulator"), healthOk: true);

        var result = await runtime.ValidateTargetReadiness("ecu");

        Assert.False(result.ReadyForRealEcuLoop);
        Assert.Equal("simulator", result.Mode);
        var check = Assert.Single(result.Checks, x => x.Code == "target.real-hardware");
        Assert.False(check.Passed);
        Assert.NotNull(check.Remediation);
    }

    [Fact]
    public async Task Missing_safety_policy_blocks_real_bench_readiness()
    {
        using var runtime = CreateRuntime(CreateProfile(safety: new BenchSafetyPolicy()), healthOk: true);

        var result = await runtime.ValidateTargetReadiness("ecu");

        Assert.False(result.ReadyForRealEcuLoop);
        Assert.False(Find(result, "safety.max-voltage").Passed);
        Assert.False(Find(result, "safety.max-current").Passed);
        Assert.False(Find(result, "safety.explicit-target").Passed);
        Assert.False(Find(result, "safety.destructive-confirmation").Passed);
    }

    [Fact]
    public async Task Failed_non_destructive_preflight_blocks_readiness()
    {
        using var runtime = CreateRuntime(CreateProfile(), healthOk: false);

        var result = await runtime.ValidateTargetReadiness("ecu");

        Assert.False(result.ReadyForRealEcuLoop);
        Assert.False(result.Preflight.Ok);
        var check = Find(result, "resources.preflight");
        Assert.False(check.Passed);
        Assert.Contains("preflight", check.Remediation, StringComparison.OrdinalIgnoreCase);
        var resource = Assert.Single(result.Preflight.Resources);
        Assert.False(resource.Ok);
    }

    [Fact]
    public async Task Change_me_placeholder_blocks_readiness_and_names_profile_path()
    {
        var profile = CreateProfile();
        profile.Resources["hw.ecu"] = profile.Resources["hw.ecu"] with
        {
            Settings = new Dictionary<string, System.Text.Json.JsonElement>(StringComparer.OrdinalIgnoreCase)
            {
                ["serialNumber"] = System.Text.Json.JsonSerializer.SerializeToElement("CHANGE_ME_TO_SERIAL"),
            },
        };
        using var runtime = CreateRuntime(profile, healthOk: true);

        var result = await runtime.ValidateTargetReadiness("ecu");

        Assert.False(result.ReadyForRealEcuLoop);
        var check = Find(result, "profile.placeholders");
        Assert.False(check.Passed);
        Assert.Contains("resources.hw.ecu.settings.serialNumber", check.Details!["paths"], StringComparison.Ordinal);
    }

    private static BenchReadinessCheck Find(TargetReadinessResult result, string code) =>
        Assert.Single(result.Checks, x => x.Code == code);

    private static BenchRuntime CreateRuntime(BenchProfile profile, bool healthOk)
    {
        var registry = new BenchResourceRegistry(profile);
        registry.Register("hw.ecu", new FakeHardwareResource(healthOk));
        return new BenchRuntime(profile, registry);
    }

    private static BenchProfile CreateProfile(
        bool includeFlash = true,
        string driver = "fake-hardware",
        BenchSafetyPolicy? safety = null)
    {
        var capabilities = includeFlash
            ? new[] { "power", "serial", "flash" }
            : new[] { "power", "serial" };
        var bindings = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["power"] = "hw.ecu",
            ["serial"] = "hw.ecu",
        };
        if (includeFlash)
            bindings["flash"] = "hw.ecu";

        return new BenchProfile
        {
            Name = "Readiness test bench",
            DefaultTarget = "ecu",
            Resources = new Dictionary<string, BenchResourceConfig>(StringComparer.OrdinalIgnoreCase)
            {
                ["hw.ecu"] = new()
                {
                    Driver = driver,
                    Capabilities = capabilities,
                },
            },
            Targets = new Dictionary<string, BenchTargetConfig>(StringComparer.OrdinalIgnoreCase)
            {
                ["ecu"] = new()
                {
                    Name = "Test ECU",
                    Mcu = "TEST-MCU",
                    Bindings = bindings,
                },
            },
            Safety = safety ?? new BenchSafetyPolicy
            {
                MaxVoltage = 14.5,
                MaxCurrentMa = 2500,
                RequireExplicitTarget = true,
                RequireDestructiveConfirmation = true,
            },
        };
    }

    private sealed class FakeHardwareResource :
        IPowerSupply,
        ISerialChannel,
        IFlashTarget,
        IResourceHealthCheck
    {
        private readonly bool _healthOk;

        public FakeHardwareResource(bool healthOk) => _healthOk = healthOk;

        public bool IsOn => false;
        public bool IsOpen => false;

        public Task<ResourceHealthResult> CheckHealth(CancellationToken ct = default) =>
            Task.FromResult(new ResourceHealthResult(
                _healthOk,
                _healthOk ? "Fake hardware is reachable." : "Fake hardware is unavailable.",
                Error: _healthOk ? null : "Injected readiness failure."));

        public Task<PowerOnResult> PowerOn(double voltage, int settleMs, CancellationToken ct = default) =>
            Task.FromResult(new PowerOnResult(true, voltage, 100, true));

        public Task<PowerOffResult> PowerOff(CancellationToken ct = default) =>
            Task.FromResult(new PowerOffResult(true));

        public Task<CurrentReading> ReadCurrent(int windowMs, CancellationToken ct = default) =>
            Task.FromResult(new CurrentReading(true, 100, 100, new[] { 100.0 }));

        public Task<CurrentCheck> CheckCurrent(double? ltMa = null, double? gtMa = null, CancellationToken ct = default) =>
            Task.FromResult(new CurrentCheck(true, 100, true));

        public Task<FlashResult> Flash(string firmwarePath, CancellationToken ct = default) =>
            Task.FromResult(new FlashResult(true, 1, 1));

        public Task<ResetResult> Reset(CancellationToken ct = default) =>
            Task.FromResult(new ResetResult(true));

        public Task<SerialOpenResult> Open(string? port = null, int? baud = null, CancellationToken ct = default) =>
            Task.FromResult(new SerialOpenResult(true, port ?? "FAKE", baud ?? 115200));

        public Task<SerialWaitResult> WaitFor(string pattern, int timeoutMs, CancellationToken ct = default) =>
            Task.FromResult(new SerialWaitResult(true, false, null, 0));

        public Task<SerialWindowResult> ReadWindow(int lines, string? filter, CancellationToken ct = default) =>
            Task.FromResult(new SerialWindowResult(true, Array.Empty<string>()));

        public Task<SerialSendResult> Send(string data, CancellationToken ct = default) =>
            Task.FromResult(new SerialSendResult(true));
    }

    private sealed class FlashOnlyHardwareResource : IFlashTarget, IResourceHealthCheck
    {
        public Task<ResourceHealthResult> CheckHealth(CancellationToken ct = default) =>
            Task.FromResult(new ResourceHealthResult(true, "Flash-only fake hardware is reachable."));

        public Task<FlashResult> Flash(string firmwarePath, CancellationToken ct = default) =>
            Task.FromResult(new FlashResult(true, 1, 1));

        public Task<ResetResult> Reset(CancellationToken ct = default) =>
            Task.FromResult(new ResetResult(true));
    }
}