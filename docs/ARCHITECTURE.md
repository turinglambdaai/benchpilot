# BenchPilot Architecture

BenchPilot is an **agent-native ECU development runtime**. It is not a CANoe clone and it is not intended to become a general-purpose vehicle-network simulation suite.

The product boundary is the ECU development loop:

```text
Build -> Flash -> Run -> Observe -> Diagnose -> Fix
```

A human, CI job and AI agent must execute the same operations against the same stateful bench runtime.

## Design principles

1. **Target semantics over device names**
   - Callers operate on `radar`, `gateway`, or `bcm`, not `COM7`, `PCAN_USBBUS1`, or a J-Link serial number.
   - A target binds semantic capabilities (`power`, `flash`, `serial`, `can`, `diagnostics`) to bench resources.

2. **Resources are independently replaceable**
   - A real target may combine an SCPI power supply, J-Link, FTDI serial adapter and PEAK CAN interface.
   - There is no monolithic `hardware` driver.

3. **Core is vendor-neutral**
   - Vendor SDKs and native libraries stay behind driver adapters.
   - Core owns domain/profile contracts; protocol/API contracts live separately from vendor drivers.

4. **Exactly one process owns hardware state**
   - `benchpilotd` is the resident owner of live device handles, capture buffers and session/lock state.
   - CLI, MCP and GUI never open the same hardware independently.

5. **All shells cross the same Runtime safety boundary**
   - Target selection, validation and safety checks occur in `Benchpilot.Runtime` before a driver call.
   - A shell cannot bypass voltage/target/destructive-operation policy by calling a lower-level adapter.

6. **Mutations and observations are distinct runtime concepts**
   - State-changing work such as power/flash/reset takes target + physical-resource mutation gates.
   - Non-mutating observations such as `serial wait` do not take those gates, so they can watch a target while it is flashing/booting.
   - Both receive stable identity, cancellation, history and bounded evidence.

7. **Observations, not byte floods**
   - Agent-facing APIs should prefer `wait_signal`, `assert_current`, `wait_boot`, or `capture_failure_window` over unbounded raw streams.
   - Raw data remains local or becomes a bounded/artifact-backed expert view.

8. **Intent is separated from protocol mechanics**
   - A caller asks to `flash(target, image, plan)`.
   - The Flash Engine owns UDS/ISO-TP/DoIP sequencing, retry rules, timing, validation and recovery.

9. **Remote access is not local IPC with the bind address changed**
   - Foundation IPC is loopback-only HTTP JSON.
   - Remote benches require authentication, authorization, TLS/secure transport, resource leases and audit policy before non-loopback binding is permitted.

10. **Hardware lifetime is owned by the resident Runtime host**
    - Host shutdown first stops admitting new work, then requests cancellation of Runtime-owned operations/observations.
    - Hardware resources are disposed only after active work has unwound.
    - If an uncooperative vendor call exceeds the bounded shutdown drain window, the host does not invalidate its handles underneath that call; process teardown is the final fallback.

## Runtime/client topology

```text
                         Agent / Human / CI
                                |
              +-----------------+-----------------+
              |                 |                 |
             CLI               MCP              Studio
              |                 |                 |
              +-----------------+-----------------+
                                |
                         Benchpilot.Client
                                |
                         HTTP JSON /api/v1
                         loopback transport
                                |
                         +------v------+
                         | benchpilotd |
                         +------+------+
                                |
                       Benchpilot.Runtime
              targets + safety + locks + evidence
                                |
       +------------------------+------------------------+
       |                        |                        |
     Power                    Probe                    CAN
    drivers                  drivers                 drivers
       |                        |                        |
     SCPI                    J-Link              SocketCAN/PCAN
                                |
                               ECU
```

The important boundary is not MCP. MCP is a stdio adapter that proxies to `benchpilotd`. A terminal command and an Agent therefore observe the same stateful ECU session.

## Source dependencies

```text
Benchpilot.Core
     ^
     |
Benchpilot.Protocol
     ^
     |
Benchpilot.Client ---------------------+
     ^                                 |
     |                                 |
  CLI / MCP / future Studio            |
                                       |
Benchpilot.Runtime <---- RuntimeHost --+
     ^                    |
     |                    +--> Simulator / Drivers
     |
 future protocol/flash execution layers
```

Rules:

- `Core` must not reference vendor SDKs, ASP.NET, MCP or GUI frameworks.
- `Runtime` must not depend on CLI/MCP/Studio.
- `Client` is the shared shell-side IPC implementation.
- `RuntimeHost` owns transport hosting, driver composition and process-level lifecycle/drain behavior.
- MCP is a protocol adapter, not a second runtime.
- Studio will be a client, regardless of whether its GUI is Avalonia or Racket/Glaze.

## Resource and target model

Example:

```json
{
  "schemaVersion": 1,
  "defaultTarget": "radar",
  "resources": {
    "psu.main": {
      "driver": "scpi",
      "capabilities": ["power"]
    },
    "probe.radar": {
      "driver": "jlink",
      "capabilities": ["flash", "debug"]
    },
    "uart.radar": {
      "driver": "system-serial",
      "capabilities": ["serial"]
    },
    "can.vehicle": {
      "driver": "pcan",
      "capabilities": ["can"]
    }
  },
  "targets": {
    "radar": {
      "mcu": "TC397",
      "bindings": {
        "power": "psu.main",
        "flash": "probe.radar",
        "serial": "uart.radar",
        "can": "can.vehicle"
      }
    }
  },
  "safety": {
    "maxVoltage": 14.5,
    "requireExplicitTarget": true
  }
}
```

This schema is capability-oriented. CAN FD, ISO-TP, UDS and future DoIP support should extend the capability/resource model rather than force a new top-level architecture.

## Runtime execution boundaries

A resource driver remains a low-level implementation detail:

```text
IPowerSupply.PowerOn(...)
IFlashTarget.Flash(...)
ISerialChannel.WaitFor(...)
```

Shells do not receive those interfaces. They request target semantics:

```text
runtime.Target("radar").PowerOn(...)
runtime.Target("radar").Flash(...)
runtime.Target("radar").SerialWaitFor(...)
```

### Mutations

Mutating operations such as `power.on`, `power.off`, `flash.write` and `flash.reset`:

- acquire a non-blocking target gate;
- acquire non-blocking gates for the bound physical resources;
- get an `operationId`;
- can be listed/cancelled across clients;
- produce bounded history and bounded evidence;
- return structured `busy` conflicts identifying the owning target/resource and operation where possible.

`power.emergency-off` is the deliberate exception: it bypasses mutation gates as a safety escape hatch, cannot be cancelled once accepted, and is still audited.

### Observations

Serial `open`, `wait`, `window` and `send` currently use the observation lifecycle:

- no target/resource mutation gate is acquired;
- each call gets an `observationId`;
- active observations can be listed/cancelled across clients;
- terminal state goes to bounded observation history;
- bounded evidence is queryable by observation ID;
- failed/unmatched waits read only a small recent window from the driver's already-bounded line buffer.

Future CAN signal waits and diagnostic response waits should reuse this model rather than create protocol-specific task registries.

## Evidence model

Runtime evidence is intentionally context-sized rather than a raw log mirror.

Current invariants:

- newest 128 operation evidence bundles are retained in memory;
- newest 128 observation evidence bundles are retained in memory;
- each bundle contains at most 8 evidence items;
- evidence text is capped at 4 KiB per item;
- metadata count/key/value sizes are bounded;
- J-Link/driver layers bound vendor output before it reaches the Runtime result/evidence model;
- serial failure windows are small tails of the local line buffer.

Larger future captures (CAN traces, packet captures, crash dumps) should be stored as artifacts and referenced from evidence rather than embedded into Agent context.

## Runtime shutdown lifecycle

`benchpilotd` treats shutdown as a hardware-safety lifecycle, not just process disposal:

```text
ApplicationStopping
       |
       +--> reject new API work (503 runtime_stopping)
       |
       +--> request cancel on active mutations
       +--> request cancel on active observations
       |
       +--> wait bounded drain window
               |
          +----+----+
          |         |
       drained    timeout
          |         |
   dispose live   do not dispose handles
   resources      under active vendor call
          |         |
          +----> process exit
```

The Runtime does **not** automatically power off hardware on daemon shutdown. Power-off policy is target/bench specific and remains an explicit operation. Emergency power-off remains separately available when required.

## IPC contract

Foundation IPC uses a versioned JSON surface. Representative endpoints include:

```text
GET  /api/v1/status

GET  /api/v1/operations
GET  /api/v1/operations/history
GET  /api/v1/operations/{id}/evidence
POST /api/v1/operations/{id}/cancel

GET  /api/v1/observations
GET  /api/v1/observations/history
GET  /api/v1/observations/{id}/evidence
POST /api/v1/observations/{id}/cancel

POST /api/v1/preflight
POST /api/v1/power/on
POST /api/v1/power/off
POST /api/v1/power/emergency-off
POST /api/v1/power/current/read
POST /api/v1/power/current/check
POST /api/v1/flash/write
POST /api/v1/flash/reset
POST /api/v1/serial/open
POST /api/v1/serial/wait
POST /api/v1/serial/window
POST /api/v1/serial/send
```

`target` is an optional query parameter when the profile permits a default target. API request/status records live in `Benchpilot.Protocol`; `Benchpilot.Client` is the canonical client implementation.

This HTTP transport is intentionally an implementation detail behind the client. A future local named-pipe/Unix-domain-socket transport can replace it without changing the target/runtime domain model.

## Project layout

```text
src/
  Benchpilot.Core/          # vendor-neutral domain/profile contracts
  Benchpilot.Protocol/      # versioned IPC request/status contracts
  Benchpilot.Runtime/       # target operations, safety, locks, history/evidence
  Benchpilot.RuntimeHost/   # benchpilotd: resident process + loopback API + lifecycle
  Benchpilot.Client/        # shared client used by every shell
  Benchpilot.Cli/           # deterministic CLI/JSON/exit codes
  Benchpilot.Mcp/           # stdio MCP -> resident Runtime proxy
  Benchpilot.Simulator/     # deterministic virtual bench

  Benchpilot.Drivers.*/     # vendor/OS adapters
  Benchpilot.Protocols.*/   # future CAN/ISO-TP/UDS/DoIP layers
  Benchpilot.Flash/         # future image model + programming workflow engine
  Benchpilot.Studio/        # future GUI client
```

## Workflow / Flash DSL

BenchPilot should eventually support both a visual workflow editor and a textual DSL, but neither is the execution engine.

```text
Visual editor ----+
                  +--> Typed AST --> validation --> Execution Plan --> Runtime
Text DSL ---------+
Agent edits DSL --+
```

The first implementation should use a simple declarative representation and stabilize the domain model before inventing a full programming language. The visual editor edits the same typed model used by the textual form.

## Non-goals

BenchPilot should not attempt to reproduce the whole CANoe surface:

- full residual-bus simulation platform;
- CAPL-compatible general vehicle simulation language;
- ADAS scene simulation;
- vehicle dynamics;
- every automotive network/protocol before a real ECU vertical slice works;
- oscilloscope/logic-analyzer replacement;
- giant collections of analysis windows.

A feature belongs in the core product when it materially helps a human, CI system, or Agent complete an ECU development/debugging loop.
