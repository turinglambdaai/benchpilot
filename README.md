# BenchPilot

> **The hardware runtime for embedded coding agents — focused on ECU development.**

BenchPilot gives humans, CI jobs and AI coding agents one stateful interface to real embedded targets: power them, flash them, observe them, diagnose them and validate behavior.

The product loop is intentionally narrow:

```text
Build -> Flash -> Run -> Observe -> Diagnose -> Fix
```

BenchPilot is **not** a CANoe clone. It does not aim to reproduce full vehicle-network simulation, CAPL, ADAS simulation or hundreds of analysis windows. CAN/CAN FD, DBC, ISO-TP, UDS and DoIP are added when they help complete the ECU development loop.

> Current status: **foundation / simulator milestone**. The repository has a working simulated power + serial + flash loop and is being migrated to a multi-resource Runtime before real hardware drivers land.

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

The caller asks for the `radar` target and a semantic capability. Runtime resolves the actual hardware resource.

This is the foundation for Agent-friendly operations such as:

```text
flash(radar)
wait_boot(radar)
wait_signal(radar, "RadarStatus", RUNNING)
assert_current(radar, < 100 mA)
capture_failure_window(radar)
```

rather than forcing a language model to consume unbounded raw serial/CAN streams.

## Current demo

The simulator behaves like one small physical bench:

- virtual bench supply with inrush -> settle -> idle current;
- virtual firmware boot log;
- flash/reset behavior;
- shared state across power, serial and flash;
- context-compressed `serial_wait_for` observation;
- MCP tool surface.

No physical hardware is required.

### Requirements

- .NET SDK 10.0+
- Git
- an MCP-capable client for Agent use (optional)

### Build and test

```bash
git clone https://github.com/turinglambdaai/benchpilot.git
cd benchpilot
dotnet build
dotnet test
```

### Run the MCP server

```bash
dotnet run --project src/Benchpilot.Mcp
```

Set `BENCHPILOT_PROFILE` to a profile path to override the built-in simulator profile.

Example Agent task:

> Power on the demo ECU at 12 V, flash `build/app.elf`, wait for the console to print `Ready`, verify idle current is below 100 mA, then power it off.

## Resource / target profile

BenchPilot no longer assumes that a real bench has one `hardware` driver. A target can combine independent vendor resources:

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

Legacy P0 profiles are normalized automatically so the simulator demo remains compatible.

## Architecture

```text
                    Human / CI / Agent
                           |
                 +---------+---------+
                 |         |         |
                CLI       MCP      Studio
                 |         |         |
                 +---------+---------+
                           |
                  BenchPilot Runtime
                 state / safety / plans
                           |
           +---------------+---------------+
           |               |               |
         Power           Probe          Networks
           |               |               |
         SCPI            J-Link      SocketCAN / PCAN
                           |
                          ECU
```

The important boundary is **Runtime**, not MCP. MCP is one replaceable shell. CLI, GUI and future integrations must use the same stateful runtime and safety behavior.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design principles.

## Project structure

```text
benchpilot/
├── src/
│   ├── Benchpilot.Core/         # vendor-neutral domain contracts/profile model
│   ├── Benchpilot.Runtime/      # target -> capability -> live resource runtime
│   ├── Benchpilot.Simulator/    # deterministic virtual bench
│   └── Benchpilot.Mcp/          # thin MCP adapter
├── tests/
│   └── Benchpilot.Core.Tests/
├── profiles/
│   └── demo.profile.json
├── docs/
│   ├── ARCHITECTURE.md
│   └── adr/
└── ROADMAP.md
```

Planned boundaries include `Benchpilot.Cli`, hardware driver projects, automotive protocol layers, a professional Flash Engine and a GUI client.

## Product priorities

Near-term work is deliberately a vertical slice rather than broad protocol coverage:

1. resident Runtime + CLI + stable structured errors;
2. real serial + J-Link + SCPI power;
3. CAN/CAN FD + DBC observations via SocketCAN and PCAN;
4. ISO-TP + UDS;
5. professional, hardware-aware UDS Flash Engine;
6. DoIP after the CAN/UDS path is strong;
7. Studio GUI over the same Runtime API.

See [ROADMAP.md](ROADMAP.md).

## GUI and language strategy

The hardware-facing Runtime is implemented in .NET/C# to reduce native/vendor integration risk. GUI technology is intentionally decoupled from Runtime.

That means an Avalonia frontend is a conservative option, while a Racket/Glaze frontend remains viable if it demonstrates a concrete development-speed or UX advantage. BenchPilot should choose technology per layer based on product risk, not language preference.

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

Apache License 2.0. See [LICENSE](LICENSE).
