# BenchPilot

> **The hardware runtime for embedded coding agents — focused on ECU development.**

BenchPilot gives humans, CI jobs and AI coding agents one stateful interface to real embedded targets: power them, flash them, observe them, diagnose them and validate behavior.

The product loop is intentionally narrow:

```text
Build -> Flash -> Run -> Observe -> Diagnose -> Fix
```

BenchPilot is **not** a CANoe clone. It does not aim to reproduce full vehicle-network simulation, CAPL, ADAS simulation or hundreds of analysis windows. CAN/CAN FD, DBC, ISO-TP, UDS and DoIP are added when they help complete the ECU development loop.

> Current status: **real-bench software foundation ready for physical validation**. The resident Runtime, versioned local API, CLI and MCP adapter share one hardware state and safety boundary. Real `system-serial`, J-Link Commander and SCPI power drivers, non-destructive preflight/readiness checks, bounded operation/observation evidence and graceful Runtime shutdown are implemented. Windows/Linux CI is green. The next gate is validation against an actual ECU + J-Link + serial + bench supply, not adding more protocols.

## Why BenchPilot?

A coding agent can edit and build firmware, but a real ECU is surrounded by fragmented tools:

```text
J-Link / OpenOCD
+ serial terminal
+ CAN adapter
+ SCPI power supply
+ UDS tool
+ scripts
```

Those tools expose device-centric primitives and independent state. BenchPilot adds an ECU-centric layer:

```text
Target: radar
  power  -> psu.main
  flash  -> probe.radar
  serial -> uart.radar
  can    -> can.vehicle
```

The caller asks for the `radar` target and a semantic operation. Runtime resolves the actual hardware resource and enforces validation/safety before a driver call.

This is the foundation for Agent-friendly operations such as:

```text
flash(radar)
wait_boot(radar)
wait_signal(radar, "RadarStatus", RUNNING)
assert_current(radar, < 100 mA)
capture_failure_window(radar)
```

rather than forcing a language model to consume unbounded raw serial/CAN streams.

## Runtime model

BenchPilot has exactly one owner of live hardware state:

```text
                  Human / CI / Agent
                         |
              +----------+----------+
              |          |          |
             CLI        MCP       Studio
              |          |          |
              +----------+----------+
                         |
                  Benchpilot.Client
                         |
                  local /api/v1
                         |
                    benchpilotd
                  state + safety
                         |
        +----------------+----------------+
        |                |                |
      Power            Probe           Networks
        |                |                |
      SCPI             J-Link       SocketCAN / PCAN
                         |
                        ECU
```

`benchpilotd` is the resident process. CLI, MCP and future GUI clients **must not open hardware independently**. This guarantees shared device state, one safety boundary and one place for resource locking, observations and evidence.

The foundation transport is HTTP JSON bound to loopback only. `benchpilotd` refuses non-loopback binding until an authenticated remote-bench transport exists.

## Current simulator

The simulator behaves like one small physical bench:

- virtual bench supply with inrush -> settle -> idle current;
- virtual firmware boot log;
- flash/reset behavior;
- shared state across power, serial and flash;
- context-compressed serial wait observations;
- Runtime safety validation;
- CLI and MCP clients over the same resident state.

No physical hardware is required for the simulator path.

### Requirements

- .NET SDK 10.0+
- Git
- an MCP-capable client for Agent use (optional)
- for physical benches: the vendor/OS tools referenced by the selected profile, such as SEGGER J-Link Commander

### Build and test

```bash
git clone https://github.com/turinglambdaai/benchpilot.git
cd benchpilot
dotnet build
dotnet test
```

## Quick start

### 1. Start the resident Runtime

```bash
dotnet run --project src/Benchpilot.RuntimeHost
```

Defaults:

```text
BENCHPILOT_ENDPOINT=http://127.0.0.1:5640/
profile=built-in simulator
```

Set `BENCHPILOT_PROFILE` to a profile path to override the built-in simulator profile.

### 2. Inspect the bench from CLI

```bash
dotnet run --project src/Benchpilot.Cli -- status
```

Machine-oriented output:

```bash
dotnet run --project src/Benchpilot.Cli -- status --json
```

The first useful simulated ECU loop is:

```bash
dotnet run --project src/Benchpilot.Cli -- power on --voltage 12 --json
dotnet run --project src/Benchpilot.Cli -- flash write build/app.elf --json
dotnet run --project src/Benchpilot.Cli -- serial wait Ready --timeout-ms 5000 --json
dotnet run --project src/Benchpilot.Cli -- power check --lt-ma 100 --json
dotnet run --project src/Benchpilot.Cli -- power off --json
```

### 3. Validate a physical bench before touching the ECU

Start from the checked-in example profile and replace every `CHANGE_ME` value with your actual bench information:

```text
profiles/real-ecu.example.json
```

Then start Runtime with that profile and run the readiness report **before** power/reset/flash:

```bash
BENCHPILOT_PROFILE=profiles/real-ecu.example.json \
  dotnet run --project src/Benchpilot.RuntimeHost

# In another terminal:
dotnet run --project src/Benchpilot.Cli -- \
  bench validate --target ecu --json
```

`bench validate` is deliberately non-destructive. It checks:

- required `power`, `serial` and `flash` bindings;
- that those capabilities are backed by real hardware drivers rather than the simulator;
- `maxVoltage` / `maxCurrentMa` safety ceilings;
- explicit-target and destructive-operation confirmation policy;
- unresolved `CHANGE_ME` placeholders;
- non-destructive serial/J-Link/SCPI preflight results.

Every failed check carries a stable machine-facing code and an actionable `remediation` string. A report can therefore be consumed directly by a human, CI job or Agent without guessing what to fix next.

A physical target is ready for the first real-ECU loop only when the report contains:

```json
{
  "ok": true,
  "readyForRealEcuLoop": true,
  "mode": "hardware"
}
```

Only then move on to the destructive path:

```text
preflight
  -> power on
  -> serial open
  -> flash / reset
  -> wait for Ready
  -> current check
  -> normal power off
```

### 4. Run the MCP adapter

With `benchpilotd` still running:

```bash
dotnet run --project src/Benchpilot.Mcp
```

The MCP process is only a stdio protocol adapter. It calls the same resident Runtime as CLI, so an Agent and a terminal observe the same ECU/bench state. The MCP `BenchValidate` tool exposes the same non-destructive readiness report as CLI.

Example Agent task:

> Validate the `ecu` target for real-bench readiness. Do not power, reset or flash anything. If it is not ready, tell me exactly which checks failed and how to fix them.

After the target is ready, an Agent can execute a constrained bench loop such as:

> Power on the ECU at 12 V, flash the selected firmware, wait for the console to print `Ready`, verify idle current is below the configured threshold, then power it off.

## CLI exit codes

CLI exit codes are intentionally stable and machine-friendly:

```text
0 success / readiness passed
1 operation, assertion or readiness failure; cancellation
2 validation error
3 target/resource/operation/observation/evidence not found
4 runtime/device unavailable or device/preflight error
5 target/resource busy because another mutating operation is active
```

A `bench validate` exit code of `1` does **not** mean the readiness API failed. It means the report executed successfully but one or more blocking readiness checks failed; inspect the JSON checks and remediation fields.

## Resource / target profile

BenchPilot does not assume that a real bench has one monolithic `hardware` driver. A target can combine independent vendor resources:

```json
{
  "schemaVersion": 1,
  "defaultTarget": "radar",
  "resources": {
    "psu.main": {
      "driver": "scpi-power",
      "capabilities": ["power"]
    },
    "probe.radar": {
      "driver": "jlink",
      "capabilities": ["flash"]
    },
    "uart.radar": {
      "driver": "system-serial",
      "capabilities": ["serial"]
    }
  },
  "targets": {
    "radar": {
      "mcu": "TC397",
      "bindings": {
        "power": "psu.main",
        "flash": "probe.radar",
        "serial": "uart.radar"
      }
    }
  },
  "safety": {
    "maxVoltage": 14.5,
    "maxCurrentMa": 2500,
    "requireExplicitTarget": true,
    "requireDestructiveConfirmation": true
  }
}
```

Legacy P0 profiles are normalized automatically so the simulator demo remains compatible.

## Project structure

```text
benchpilot/
├── src/
│   ├── Benchpilot.Core/              # vendor-neutral domain/profile contracts
│   ├── Benchpilot.Protocol/          # versioned local API contracts
│   ├── Benchpilot.Runtime/           # target operations, safety, evidence/readiness
│   ├── Benchpilot.RuntimeHost/       # benchpilotd resident loopback API process
│   ├── Benchpilot.Client/            # shared IPC client for every shell
│   ├── Benchpilot.Cli/               # stable commands, JSON and exit codes
│   ├── Benchpilot.Mcp/               # thin stdio MCP -> Runtime proxy
│   ├── Benchpilot.Simulator/         # deterministic virtual bench
│   ├── Benchpilot.Drivers.Serial/    # system serial backend
│   ├── Benchpilot.Drivers.JLink/     # SEGGER J-Link Commander adapter
│   └── Benchpilot.Drivers.ScpiPower/ # TCP SCPI power-supply adapter
├── tests/
│   └── Benchpilot.Core.Tests/
├── profiles/
│   ├── demo.profile.json
│   └── real-ecu.example.json
├── scripts/
│   ├── smoke-runtime.sh
│   └── smoke-shutdown.sh
├── docs/
│   ├── ARCHITECTURE.md
│   └── adr/
└── ROADMAP.md
```

Future CAN/protocol/Flash/Studio projects plug into these boundaries rather than opening parallel hardware stacks.

## Product priorities

Near-term work remains a vertical slice rather than broad protocol coverage:

1. validate `system-serial` + J-Link + SCPI power against one physical ECU and check in a repeatable known-good profile;
2. correlate power/current context with flash/boot failures and strengthen real-bench evidence;
3. CAN/CAN FD + DBC observations via SocketCAN and PCAN;
4. ISO-TP + UDS;
5. professional, hardware-aware UDS Flash Engine;
6. DoIP after the CAN/UDS path is strong;
7. Studio GUI over the same Runtime API.

See [ROADMAP.md](ROADMAP.md).

## GUI and language strategy

The hardware-facing Runtime is implemented in .NET/C# to reduce native/vendor integration risk. GUI technology is intentionally decoupled from Runtime.

That means an Avalonia frontend is a conservative option, while a Racket/Glaze frontend remains viable if it demonstrates a concrete development-speed or UX advantage. Both would use `Benchpilot.Client` / the same versioned local API rather than owning devices.

See [ADR 0001](docs/adr/0001-runtime-language.md).

## Long-term flashing direction

Professional flashing is a first-class product capability, not three raw UDS calls. The intended architecture separates:

```text
Flash workflow
      |
Flash Engine
      |
UDS client
      |
ISO-TP / DoIP
      |
CAN FD / Ethernet
```

A future visual workflow editor and textual DSL will compile to the same typed execution plan. Safety, target fingerprinting, voltage/current monitoring, Security Provider integration, verification and recovery belong below the Agent surface.

## License

GNU Affero General Public License v3.0. See [LICENSE](LICENSE).
