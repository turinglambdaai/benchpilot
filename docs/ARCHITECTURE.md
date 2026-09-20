# BenchPilot Architecture

BenchPilot is an **agent-native ECU development runtime**. It is not a CANoe clone and it is not intended to become a general-purpose vehicle-network simulation suite.

The product boundary is the ECU development loop:

```text
Build -> Flash -> Run -> Observe -> Diagnose -> Fix
```

A human, CI job and AI agent must be able to execute the same operations against the same stateful bench runtime.

## Design principles

1. **Target semantics over device names**
   - Callers operate on `radar`, `gateway`, or `bcm`, not `COM7`, `PCAN_USBBUS1`, or a J-Link serial number.
   - A target binds semantic capabilities (`power`, `flash`, `serial`, `can`, `diagnostics`) to bench resources.

2. **Resources are independently replaceable**
   - A real target may combine an SCPI power supply, J-Link, FTDI serial adapter and PEAK CAN interface.
   - There is no monolithic `hardware` driver.

3. **Core is vendor-neutral**
   - Vendor SDKs and native libraries stay behind driver adapters.
   - Core owns domain contracts, plans, observations, safety rules and stable error semantics.

4. **Runtime is stateful; shells are replaceable**
   - Hardware connections, capture buffers and ECU state live in one resident runtime.
   - CLI, MCP and GUI are clients/adapters, not alternate implementations of hardware logic.

5. **Observations, not byte floods**
   - Agent-facing APIs should prefer `wait_signal`, `assert_current`, `wait_boot`, or `capture_failure_window` over unbounded raw streams.
   - Raw data remains available as an artifact or expert/debug view.

6. **Intent is separated from protocol mechanics**
   - A caller asks to `flash(target, image, plan)`.
   - The Flash Engine owns UDS/ISO-TP/DoIP sequencing, retry rules, timing, validation and recovery.

7. **Safety is enforced below the Agent**
   - Voltage/current limits, target identity checks, protected memory, UDS permissions and destructive-operation policy belong in Runtime.
   - An Agent cannot bypass those rules by choosing a lower-level shell.

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
  }
}
```

This schema is intentionally capability-oriented. CAN FD, ISO-TP, UDS and future DoIP support should extend the model rather than force a new top-level architecture.

## Intended component boundaries

```text
                        Human / CI / Agent
                               |
                 +-------------+-------------+
                 |             |             |
                CLI           MCP          Studio
                 |             |             |
                 +-------------+-------------+
                               |
                     BenchPilot Runtime
                    (resident process)
                               |
          +--------------------+--------------------+
          |                    |                    |
      Execution            Observation           Safety
        Plans                Engine              Policy
          |                    |                    |
          +--------------------+--------------------+
                               |
       +-------------+---------+---------+-------------+
       |             |                   |             |
     Power         Probe              Serial          CAN
    drivers       drivers             drivers        drivers
       |             |                   |             |
     SCPI          J-Link              FTDI       SocketCAN/PCAN
                               |
                              ECU
```

Planned source layout:

```text
src/
  Benchpilot.Core/          # domain contracts, profiles, plans, observations
  Benchpilot.Runtime/       # resident resource/session lifecycle and execution
  Benchpilot.Drivers.*/     # vendor/OS adapters
  Benchpilot.Protocols.*/   # CAN/ISO-TP/UDS/DoIP where appropriate
  Benchpilot.Flash/         # image model + programming workflow engine
  Benchpilot.Cli/           # stable command + JSON contract
  Benchpilot.Mcp/           # thin Agent adapter
  Benchpilot.Simulator/     # deterministic virtual bench
  Benchpilot.Studio/        # GUI client; technology intentionally decoupled
```

The repository is currently migrating toward this layout incrementally. P0 remains runnable while the runtime boundary is introduced.

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
