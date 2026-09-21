using Benchpilot.Core;

namespace Benchpilot.Runtime;

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

    public T Capability<T>(string capability) where T : class =>
        BoundCapability<T>(capability).Capability;

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

        var binding = BoundCapability<IPowerSupply>("power");
        return await _runtime.RunMutation(Id, "power.on", [binding.ResourceId], async operationCt =>
        {
            var result = await binding.Capability.PowerOn(voltage, settleMs, operationCt);

            if (result.Ok &&
                _runtime.Profile.Safety.MaxCurrentMa is { } maxCurrentMa &&
                result.CurrentMa > maxCurrentMa)
            {
                var off = await binding.Capability.PowerOff(CancellationToken.None);
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
    /// Normal operator shutdown. This participates in target and resource
    /// mutation gates so it cannot interrupt an active flash/reset or another
    /// target currently using the same physical power supply.
    /// </summary>
    public Task<PowerOffResult> PowerOff(CancellationToken ct = default)
    {
        var binding = BoundCapability<IPowerSupply>("power");
        return _runtime.RunMutation(
            Id,
            "power.off",
            [binding.ResourceId],
            operationCt => binding.Capability.PowerOff(operationCt),
            ct);
    }

    /// <summary>
    /// Explicit safety escape hatch. It bypasses mutation gates, cannot be
    /// cancelled by a disconnected caller after Runtime accepts it, and is
    /// always written to operation history for auditability.
    /// </summary>
    public Task<PowerOffResult> EmergencyPowerOff(CancellationToken ct = default)
    {
        _ = ct; // Request cancellation must not abort an accepted safety action.
        var binding = BoundCapability<IPowerSupply>("power");
        return _runtime.RunUngatedSafetyOperation(
            Id,
            "power.emergency-off",
            [binding.ResourceId],
            () => binding.Capability.PowerOff(CancellationToken.None));
    }

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

        var binding = BoundCapability<IFlashTarget>("flash");
        return _runtime.RunMutation(
            Id,
            "flash.write",
            [binding.ResourceId],
            operationCt => binding.Capability.Flash(firmware, operationCt),
            ct);
    }

    public Task<ResetResult> Reset(
        string? confirmTarget = null,
        CancellationToken ct = default)
    {
        ValidateDestructiveConfirmation("reset", confirmTarget);

        var binding = BoundCapability<IFlashTarget>("flash");
        return _runtime.RunMutation(
            Id,
            "flash.reset",
            [binding.ResourceId],
            operationCt => binding.Capability.Reset(operationCt),
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

        var binding = BoundCapability<ISerialChannel>("serial");
        return _runtime.RunObservation(
            Id,
            "serial.open",
            [binding.ResourceId],
            async (observationId, observationCt) =>
            {
                var result = await binding.Capability.Open(port, baud, observationCt);
                var identified = result with { ObservationId = observationId };
                return new ObservationExecution<SerialOpenResult>(
                    identified,
                    SerialObservationEvidenceExtractor.FromOpen(identified));
            },
            ct);
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

        var binding = BoundCapability<ISerialChannel>("serial");
        return _runtime.RunObservation(
            Id,
            "serial.wait",
            [binding.ResourceId],
            async (observationId, observationCt) =>
            {
                var result = await binding.Capability.WaitFor(pattern, timeoutMs, observationCt);
                var identified = result with { ObservationId = observationId };

                SerialWindowResult? failureWindow = null;
                if (!identified.Ok || !identified.Matched)
                {
                    // The channel already owns a bounded local line buffer. Read
                    // only a small tail after failure instead of copying the raw
                    // stream into Runtime/Agent context.
                    failureWindow = await binding.Capability.ReadWindow(
                        20,
                        null,
                        CancellationToken.None);
                }

                return new ObservationExecution<SerialWaitResult>(
                    identified,
                    SerialObservationEvidenceExtractor.FromWait(
                        pattern,
                        timeoutMs,
                        identified,
                        failureWindow));
            },
            ct);
    }

    public Task<SerialWindowResult> SerialReadWindow(
        int lines,
        string? filter = null,
        CancellationToken ct = default)
    {
        if (lines <= 0)
            throw new BenchValidationException("Serial window line count must be greater than zero.");

        var binding = BoundCapability<ISerialChannel>("serial");
        return _runtime.RunObservation(
            Id,
            "serial.window",
            [binding.ResourceId],
            async (observationId, observationCt) =>
            {
                var result = await binding.Capability.ReadWindow(lines, filter, observationCt);
                var identified = result with { ObservationId = observationId };
                return new ObservationExecution<SerialWindowResult>(
                    identified,
                    SerialObservationEvidenceExtractor.FromWindow(identified));
            },
            ct);
    }

    public Task<SerialSendResult> SerialSend(string data, CancellationToken ct = default)
    {
        if (data is null)
            throw new BenchValidationException("Serial data cannot be null.");

        var binding = BoundCapability<ISerialChannel>("serial");
        return _runtime.RunObservation(
            Id,
            "serial.send",
            [binding.ResourceId],
            async (observationId, observationCt) =>
            {
                var result = await binding.Capability.Send(data, observationCt);
                var identified = result with { ObservationId = observationId };
                return new ObservationExecution<SerialSendResult>(
                    identified,
                    SerialObservationEvidenceExtractor.FromSend(identified, data.Length));
            },
            ct);
    }

    private (string ResourceId, T Capability) BoundCapability<T>(string capability) where T : class
    {
        try
        {
            var binding = ProfileLoader.ResolveResource(_runtime.Profile, capability, Id);
            return (binding.ResourceId, _runtime.Resources.Get<T>(binding.ResourceId));
        }
        catch (KeyNotFoundException ex)
        {
            throw new BenchTargetNotFoundException(ex.Message);
        }
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
