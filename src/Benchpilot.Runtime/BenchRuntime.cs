using System.Collections.Concurrent;
using Benchpilot.Core;

namespace Benchpilot.Runtime;

public class BenchRuntimeException : Exception
{
    public BenchRuntimeException(string message) : base(message) { }
}

public sealed class BenchValidationException : BenchRuntimeException
{
    public BenchValidationException(string message) : base(message) { }
}

public sealed class BenchTargetNotFoundException : BenchRuntimeException
{
    public BenchTargetNotFoundException(string message) : base(message) { }
}

public sealed class BenchBusyException : BenchRuntimeException
{
    public BenchBusyException(string targetId, string operation)
        : base($"Target '{targetId}' is busy with another mutating operation; '{operation}' was not started.")
    {
        TargetId = targetId;
        Operation = operation;
    }

    public string TargetId { get; }
    public string Operation { get; }
}

/// <summary>
/// Owns live resource instances for one bench process. Device handles are
/// registered once and reused so all shells observe the same state. The
/// registry also owns resource lifetime and disposes driver instances when the
/// resident Runtime stops.
/// </summary>
public sealed class BenchResourceRegistry : IDisposable
{
    private readonly BenchProfile _profile;
    private readonly Dictionary<string, object> _instances =
        new(StringComparer.OrdinalIgnoreCase);
    private bool _disposed;

    public BenchResourceRegistry(BenchProfile profile)
    {
        _profile = profile ?? throw new ArgumentNullException(nameof(profile));
        ProfileLoader.Validate(profile);
    }

    public void Register(string resourceId, object instance)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentException.ThrowIfNullOrWhiteSpace(resourceId);
        ArgumentNullException.ThrowIfNull(instance);

        if (!_profile.Resources.ContainsKey(resourceId))
            throw new KeyNotFoundException(
                $"Cannot register resource '{resourceId}' because it is not declared in the bench profile.");

        if (!_instances.TryAdd(resourceId, instance))
            throw new InvalidOperationException(
                $"Resource '{resourceId}' is already registered in this runtime.");
    }

    public bool IsRegistered(string resourceId)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return _instances.ContainsKey(resourceId);
    }

    public IReadOnlyCollection<string> RegisteredResourceIds
    {
        get
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            return _instances.Keys.ToArray();
        }
    }

    public T Get<T>(string resourceId) where T : class
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (!_instances.TryGetValue(resourceId, out var instance))
            throw new InvalidOperationException(
                $"Resource '{resourceId}' is declared but has no live driver instance.");

        if (instance is not T typed)
            throw new InvalidOperationException(
                $"Resource '{resourceId}' does not implement {typeof(T).Name}. " +
                $"Actual type: {instance.GetType().Name}.");

        return typed;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        var disposed = new HashSet<object>(ReferenceEqualityComparer.Instance);
        foreach (var instance in _instances.Values.Reverse())
        {
            if (!disposed.Add(instance)) continue;
            if (instance is IDisposable disposable)
                disposable.Dispose();
        }

        _instances.Clear();
    }
}

/// <summary>
/// Stateful runtime facade shared by CLI, MCP and Studio. It maps target-level
/// semantic capabilities onto long-lived resource instances and owns the
/// validation/safety boundary. Shells must not call hardware drivers directly.
/// </summary>
public sealed class BenchRuntime : IDisposable
{
    private readonly ConcurrentDictionary<string, SemaphoreSlim> _mutationGates =
        new(StringComparer.OrdinalIgnoreCase);
    private bool _disposed;

    public BenchProfile Profile { get; }
    public BenchResourceRegistry Resources { get; }

    public BenchRuntime(BenchProfile profile, BenchResourceRegistry resources)
    {
        Profile = profile ?? throw new ArgumentNullException(nameof(profile));
        Resources = resources ?? throw new ArgumentNullException(nameof(resources));
        ProfileLoader.Validate(profile);
    }

    public BenchTarget Target(string? targetName = null)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (Profile.Safety.RequireExplicitTarget && string.IsNullOrWhiteSpace(targetName))
            throw new BenchValidationException(
                "This bench requires an explicit target for every operation.");

        var resolvedName = string.IsNullOrWhiteSpace(targetName)
            ? Profile.DefaultTarget
            : targetName;

        if (string.IsNullOrWhiteSpace(resolvedName))
            throw new BenchValidationException(
                "No target was specified and the bench profile has no default target.");

        try
        {
            var target = ProfileLoader.ResolveTarget(Profile, resolvedName);
            return new BenchTarget(this, resolvedName, target);
        }
        catch (KeyNotFoundException ex)
        {
            throw new BenchTargetNotFoundException(ex.Message);
        }
    }

    internal async Task<T> RunTargetMutation<T>(
        string targetId,
        string operation,
        Func<Task<T>> action,
        CancellationToken ct)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var gate = _mutationGates.GetOrAdd(targetId, static _ => new SemaphoreSlim(1, 1));
        if (!await gate.WaitAsync(0, ct))
            throw new BenchBusyException(targetId, operation);

        try
        {
            return await action();
        }
        finally
        {
            gate.Release();
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Resources.Dispose();
        foreach (var gate in _mutationGates.Values)
            gate.Dispose();
        _mutationGates.Clear();
    }
}

/// <summary>
/// A target-oriented view over Runtime. Callers request semantic operations and
/// never need to know which OS device/vendor adapter provides them. This is the
/// single safety/validation choke point shared by IPC, MCP, CLI and GUI.
/// </summary>
public sealed class BenchTarget
{
    private readonly BenchRuntime _runtime;
    private readonly BenchTargetConfig _config;

    internal BenchTarget(BenchRuntime runtime, string id, BenchTargetConfig config)
    {
        _runtime = runtime;
        Id = id;
        _config = config;
    }

    public string Id { get; }
    public string Name => string.IsNullOrWhiteSpace(_config.Name) ? Id : _config.Name;
    public string? Mcu => _config.Mcu;
    public IReadOnlyCollection<string> Capabilities => _config.Bindings.Keys.ToArray();

    public bool HasCapability(string capability) =>
        _config.Bindings.ContainsKey(capability);

    public T Capability<T>(string capability) where T : class
    {
        try
        {
            var binding = ProfileLoader.ResolveResource(_runtime.Profile, capability, Id);
            return _runtime.Resources.Get<T>(binding.ResourceId);
        }
        catch (KeyNotFoundException ex)
        {
            throw new BenchTargetNotFoundException(ex.Message);
        }
    }

    public async Task<PowerOnResult> PowerOn(
        double voltage,
        int settleMs,
        CancellationToken ct = default)
    {
        if (voltage <= 0)
            throw new BenchValidationException("Power voltage must be greater than zero.");
        if (settleMs < 0)
            throw new BenchValidationException("Power settleMs cannot be negative.");

        if (_runtime.Profile.Safety.MaxVoltage is { } maxVoltage && voltage > maxVoltage)
            throw new BenchValidationException(
                $"Requested voltage {voltage:0.###} V exceeds bench safety limit {maxVoltage:0.###} V.");

        return await _runtime.RunTargetMutation(Id, "power.on", async () =>
        {
            var supply = Capability<IPowerSupply>("power");
            var result = await supply.PowerOn(voltage, settleMs, ct);

            if (result.Ok &&
                _runtime.Profile.Safety.MaxCurrentMa is { } maxCurrentMa &&
                result.CurrentMa > maxCurrentMa)
            {
                var off = await supply.PowerOff(ct);
                var suffix = off.Ok ? "Power output was switched off." : "Power-off also reported an error.";
                return result with
                {
                    Ok = false,
                    Settled = false,
                    Error = $"Measured current {result.CurrentMa:0.###} mA exceeds bench safety limit " +
                        $"{maxCurrentMa:0.###} mA. {suffix}",
                };
            }

            return result;
        }, ct);
    }

    /// <summary>
    /// Normal operator shutdown. This participates in the target mutation gate,
    /// so an ordinary CLI/MCP power-off cannot interrupt an active flash/reset.
    /// </summary>
    public Task<PowerOffResult> PowerOff(CancellationToken ct = default) =>
        _runtime.RunTargetMutation(
            Id,
            "power.off",
            () => Capability<IPowerSupply>("power").PowerOff(ct),
            ct);

    /// <summary>
    /// Explicit safety escape hatch. This is the only shell-facing power action
    /// allowed to bypass the mutation gate so an operator can de-energize a
    /// bench during an unsafe condition even while another mutation is active.
    /// </summary>
    public Task<PowerOffResult> EmergencyPowerOff(CancellationToken ct = default) =>
        Capability<IPowerSupply>("power").PowerOff(ct);

    public Task<CurrentReading> ReadCurrent(int windowMs, CancellationToken ct = default)
    {
        if (windowMs <= 0)
            throw new BenchValidationException("Current sampling window must be greater than zero.");
        return Capability<IPowerSupply>("power").ReadCurrent(windowMs, ct);
    }

    public Task<CurrentCheck> CheckCurrent(
        double? ltMa = null,
        double? gtMa = null,
        CancellationToken ct = default)
    {
        if (ltMa is null && gtMa is null)
            throw new BenchValidationException("Current check requires at least one lt/gt threshold.");
        if (ltMa < 0 || gtMa < 0)
            throw new BenchValidationException("Current thresholds cannot be negative.");
        return Capability<IPowerSupply>("power").CheckCurrent(ltMa, gtMa, ct);
    }

    public Task<FlashResult> Flash(
        string firmware,
        string? confirmTarget = null,
        CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(firmware))
            throw new BenchValidationException("Firmware path cannot be empty.");
        ValidateDestructiveConfirmation("flash", confirmTarget);
        return _runtime.RunTargetMutation(
            Id,
            "flash.write",
            () => Capability<IFlashTarget>("flash").Flash(firmware, ct),
            ct);
    }

    public Task<ResetResult> Reset(
        string? confirmTarget = null,
        CancellationToken ct = default)
    {
        ValidateDestructiveConfirmation("reset", confirmTarget);
        return _runtime.RunTargetMutation(
            Id,
            "flash.reset",
            () => Capability<IFlashTarget>("flash").Reset(ct),
            ct);
    }

    public Task<SerialOpenResult> SerialOpen(
        string? port = null,
        int? baud = null,
        CancellationToken ct = default)
    {
        if (port is not null && string.IsNullOrWhiteSpace(port))
            throw new BenchValidationException("Serial port override cannot be empty.");
        if (baud is <= 0)
            throw new BenchValidationException("Serial baud override must be greater than zero.");
        return Capability<ISerialChannel>("serial").Open(port, baud, ct);
    }

    public Task<SerialWaitResult> SerialWaitFor(
        string pattern,
        int timeoutMs,
        CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(pattern))
            throw new BenchValidationException("Serial wait pattern cannot be empty.");
        if (timeoutMs < 0)
            throw new BenchValidationException("Serial timeout cannot be negative.");
        return Capability<ISerialChannel>("serial").WaitFor(pattern, timeoutMs, ct);
    }

    public Task<SerialWindowResult> SerialReadWindow(
        int lines,
        string? filter = null,
        CancellationToken ct = default)
    {
        if (lines <= 0)
            throw new BenchValidationException("Serial window line count must be greater than zero.");
        return Capability<ISerialChannel>("serial").ReadWindow(lines, filter, ct);
    }

    public Task<SerialSendResult> SerialSend(string data, CancellationToken ct = default)
    {
        if (data is null)
            throw new BenchValidationException("Serial data cannot be null.");
        return Capability<ISerialChannel>("serial").Send(data, ct);
    }

    private void ValidateDestructiveConfirmation(string operation, string? confirmTarget)
    {
        if (!_runtime.Profile.Safety.RequireDestructiveConfirmation)
            return;

        if (!string.Equals(confirmTarget, Id, StringComparison.OrdinalIgnoreCase))
        {
            throw new BenchValidationException(
                $"Destructive operation '{operation}' requires confirmTarget matching target id '{Id}'.");
        }
    }
}
