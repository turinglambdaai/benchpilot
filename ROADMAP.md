# BenchPilot Roadmap

BenchPilot is developed as an **agent-native ECU development runtime**, not as a feature-for-feature CANoe replacement.

The roadmap prioritizes one complete real-ECU loop over broad protocol coverage.

## Foundation — now

Goal: make the P0 demo architecture capable of growing into a real bench without rewriting the product.

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
- [ ] structured device/runtime error taxonomy beyond the initial API error envelope;
- [ ] resource lifecycle and deterministic disposal;
- [ ] resource locking / leases for concurrent clients;
- [ ] operation IDs, cancellation and timeout semantics across IPC;
- [ ] bounded artifact/event store for observations and failure windows.

Exit criterion: simulator can be driven through one resident Runtime by CLI and MCP without either shell owning device state.

## Real bench vertical slice

Goal: control one real ECU end to end.

- [ ] system serial backend;
- [ ] J-Link backend for flash/reset and basic debug observations;
- [ ] SCPI power backend;
- [ ] power/current safety enforcement against real instruments;
- [ ] target identity and explicit destructive-operation guardrails;
- [ ] failure-window artifacts around flash/boot failures.

Exit criterion:

```text
Build -> power check -> flash -> reset -> wait for UART Ready -> current check
```

runs against a physical ECU through both CLI and an Agent.

## Automotive communication vertical slice

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

Exit criterion: Agent validates an ECU behavior from decoded signals without consuming an unbounded CAN log.

## Diagnostics and professional flashing

Goal: make programming a first-class, safe transaction rather than a collection of raw UDS calls.

UDS core:

- [ ] sessions and timing (`P2`, `P2*`, `S3`);
- [ ] structured NRC handling, including ResponsePending;
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
- [ ] Run/Agent timeline.

GUI technology is deliberately decoupled. Avalonia is the conservative default; a Racket/Glaze frontend remains viable if it proves a concrete productivity or UX advantage over the stable Runtime API.

## Remote / team benches

Do not implement remote control by simply binding the local HTTP API to `0.0.0.0`.

Required before remote operation:

- [ ] authenticated transport;
- [ ] authorization / role policy;
- [ ] TLS or equivalent secure channel;
- [ ] resource leases and ownership;
- [ ] audit trail;
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
