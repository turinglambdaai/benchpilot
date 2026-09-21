# BenchPilot Roadmap

BenchPilot is developed as an **agent-native ECU development runtime**, not as a feature-for-feature CANoe replacement.

The roadmap prioritizes one complete real-ECU loop over broad protocol coverage. The current gate is **physical bench validation and bounded failure evidence**, not adding more protocols.

## Foundation — complete

Goal: make the original P0 demo architecture capable of growing into a real bench without rewriting the product.

- [x] simulator-backed power / serial / flash loop;
- [x] MCP thin shell;
- [x] resource + target bench profile model;
- [x] compatibility loader for P0 single-driver profiles;
- [x] initial bench-level safety policy schema;
- [x] resident `benchpilotd` process owning live resource state;
- [x] versioned local `/api/v1` transport contracts;
- [x] shared `Benchpilot.Client` used by shells;
- [x] CLI with deterministic JSON output and documented exit codes;
- [x] MCP converted from hardware owner to resident-Runtime proxy;
- [x] loopback-only local IPC between shells and Runtime;
- [x] target operation boundary enforcing validation/safety before driver calls;
- [x] Windows/Linux build + test CI;
- [x] resident-runtime smoke test through the real CLI/IPC path.

Foundation exit criterion achieved:

```text
benchpilotd owns simulator state
        |
        +--> CLI  --+
        |           +--> same target/resource state
        +--> MCP  --+

power -> flash -> wait Ready -> current check -> power off
```

## Runtime safety and observability — local bench baseline complete

These are now Runtime properties shared by CLI, MCP and future Studio clients, rather than shell-specific behavior.

- [x] resource lifetime and deterministic disposal;
- [x] target-level non-blocking mutation gates;
- [x] physical-resource locking across different targets sharing one PSU/probe/resource;
- [x] structured `busy` conflicts identifying target/resource scope;
- [x] active operation IDs with target, operation kind, resources and start time;
- [x] cooperative cancellation through Runtime into supported drivers;
- [x] busy responses identify the owning operation when available;
- [x] bounded in-memory operation history with `completed` / `cancelled` / `faulted` execution states;
- [x] explicit normal shutdown versus emergency shutdown semantics;
- [x] emergency power-off bypasses mutation gates, is non-cancellable once accepted, and is audited;
- [x] destructive flash/reset confirmation policy;
- [x] maximum voltage/current bench safety enforcement;
- [x] stable validation / not-found / busy / cancelled / runtime-state API error classes;

Still intentionally incomplete:

- [ ] richer device/runtime error taxonomy for vendor-specific failures without leaking vendor SDK types into Core;
- [ ] one Runtime-level deadline/timeout model across all long operations (drivers already enforce bounded device timeouts where required);
- [ ] bounded failure-window evidence/artifact store tied to operation IDs;
- [ ] graceful Runtime shutdown that waits for cancelled in-flight hardware operations to unwind before disposing shared resources;
- [ ] remote/team leases — local mutation locks are **not** a substitute for authenticated remote ownership.

## Real bench vertical slice — in progress

Goal: control one real ECU end to end without changing CLI/MCP semantics.

Architecture prerequisite:

- [x] replace RuntimeHost's simulator-only composition with a resource-driver factory registry;
- [x] define driver lifetime/disposal without leaking vendor SDK types into Core;

First real drivers:

- [x] `system-serial` backend implementation;
- [x] J-Link Commander backend for flash/reset;
- [x] SCPI TCP power-supply backend;
- [x] non-destructive `preflight` path exposed through Runtime / CLI / MCP;
- [x] serial OS-device visibility check;
- [x] SCPI `*IDN?` connectivity check;
- [x] J-Link Commander discovery;
- [x] non-destructive J-Link `ShowEmuList USB` probe enumeration;
- [x] deterministic J-Link serial-number matching when multiple probes are present;
- [ ] physical serial + J-Link validation against a real ECU;
- [ ] physical SCPI PSU validation against a real ECU bench;
- [ ] one documented, repeatable real-ECU smoke profile checked into `profiles/` after hardware validation.

Serial design:

- port/baud live in the resource profile by default;
- CLI/MCP port/baud values are optional expert overrides;
- one resident OS serial handle is owned by `benchpilotd`;
- raw input is converted into a bounded line buffer for `wait`/`window` observations.

J-Link design:

- BenchPilot invokes the user's installed SEGGER J-Link Commander and does not redistribute SEGGER binaries;
- device/interface/speed/probe serial/executable are profile settings;
- preflight enumerates USB probes without selecting a device, connecting to the MCU, halting or resetting it;
- flash/reset execution is bounded by timeout/cancellation and captures bounded diagnostics;
- `.bin` images require an explicit `binAddress`; BenchPilot does not guess flash addresses.

SCPI power design:

- TCP SCPI connection details live in the resource profile;
- `preflight` uses read-only `*IDN?`;
- over-voltage requests are rejected before driver calls;
- measured over-current after power-on triggers best-effort shutdown;
- protocol/measurement failure after output enable triggers best-effort `OUTP OFF`;
- device timeout and user/operation cancellation are distinguished;
- explicit emergency shutdown is the only shell-facing path allowed to bypass target/resource locks.

### Next implementation gate: failure evidence

Before CAN/UDS, make failures explainable to an Agent without dumping unbounded raw logs.

- [ ] bounded evidence model keyed by operation ID;
- [ ] capture the final bounded J-Link stdout/stderr window for failed flash/reset operations;
- [ ] capture bounded UART lines around boot/wait failures;
- [ ] capture relevant power/current measurements around power/flash failures;
- [ ] CLI/MCP query for an operation's evidence;
- [ ] preserve strict size/count limits so evidence remains LLM-context friendly.

Real-bench exit criterion:

```text
preflight
   -> power on + current safety check
   -> flash
   -> reset
   -> wait for UART Ready
   -> current check
   -> normal power off
```

runs against a physical ECU through both CLI and an Agent, and a failed run returns enough bounded evidence to diagnose the failure without manually opening vendor tools.

## Automotive communication vertical slice — after real-bench exit criterion

Goal: make the same real ECU observable through its vehicle network.

Initial adapters:

- [ ] SocketCAN on Linux;
- [ ] PEAK PCAN on Windows.

Protocol/semantic layer:

- [ ] CAN / CAN FD transmit and capture;
- [ ] bounded capture artifacts;
- [ ] DBC decoding;
- [ ] `wait_signal` / `assert_signal` / `measure_signal` observations;
- [ ] ISO-TP transport.

Exit criterion: Agent validates ECU behavior from decoded signals without consuming an unbounded CAN log.

## Diagnostics and professional flashing

Goal: make programming a first-class, safe transaction rather than a collection of raw UDS calls.

UDS core:

- [ ] sessions and timing (`P2`, `P2*`, `S3`);
- [ ] structured NRC handling, including `ResponsePending`;
- [ ] DID / DTC / RoutineControl primitives;
- [ ] Security Provider abstraction;
- [ ] ISO-TP first, DoIP later.

Flash Engine:

- [ ] BIN / Intel HEX / S-record image model;
- [ ] memory segments and metadata;
- [ ] typed flash workflow / execution plan;
- [ ] preflight target fingerprint;
- [ ] voltage/current monitoring during programming;
- [ ] erase / RequestDownload / TransferData / TransferExit / verify / reset;
- [ ] explicit recovery strategies;
- [ ] audit trace and machine-readable result;
- [ ] declarative workflow format before a custom language;
- [ ] visual workflow editor only after the typed model is stable.

Exit criterion: the same flash definition can be executed by GUI, CLI, CI and Agent with identical safety behavior.

## Automotive Ethernet

Only after the CAN/UDS vertical slice is strong:

- [ ] Ethernet capture and bounded observations;
- [ ] DoIP;
- [ ] later: selective SOME/IP support where it directly improves ECU development loops.

## Studio

The Studio is a client of Runtime, not the owner of hardware state.

First useful screens:

- [ ] Bench / Targets;
- [ ] Flash;
- [ ] Console;
- [ ] CAN signals/capture;
- [ ] Diagnostics;
- [ ] Run/Agent timeline backed by Runtime active-operation + history/evidence APIs.

GUI technology is deliberately decoupled. Avalonia is the conservative default; a Racket/Glaze frontend remains viable only if it proves a concrete productivity or UX advantage over the stable Runtime API.

## Remote / team benches

Do not implement remote control by simply binding the local HTTP API to `0.0.0.0`.

Required before remote operation:

- [ ] authenticated transport;
- [ ] authorization / role policy;
- [ ] TLS or equivalent secure channel;
- [ ] resource leases and ownership across users/processes;
- [ ] persistent audit trail;
- [ ] bench scheduling / reservation;
- [ ] explicit policy for destructive operations.

## Explicitly deferred

These are not product priorities until real customer evidence says otherwise:

- full residual-bus simulation;
- CAPL replacement;
- ADAS/vehicle-dynamics simulation;
- comprehensive FlexRay support;
- SPI/I2C as headline features;
- complete SOME/IP/AUTOSAR authoring suite;
- custom hardware manufacturing;
- a large collection of CANoe-style analysis windows.

The recurring product test is:

> Does this capability materially help a human, CI system, or AI Agent complete the ECU development loop faster and more reliably?
