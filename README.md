# BenchPilot

**The hardware runtime for embedded coding agents — power, flash, observe, diagnose and validate real ECUs from one stateful interface.**
Humans, CI jobs and AI coding agents share one resident runtime with a safety boundary; agents speak JSON natively over a versioned local API, CLI and MCP.

[![CI](https://github.com/turinglambdaai/benchpilot/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/benchpilot/actions/workflows/ci.yml) [![release](https://img.shields.io/github/v/release/turinglambdaai/benchpilot)](https://github.com/turinglambdaai/benchpilot/releases/latest) ![platform](https://img.shields.io/badge/platform-Windows_%7C_Linux_%7C_macOS-lightgrey) [![built with](https://img.shields.io/badge/built%20with-Racket-9F1D35)](https://racket-lang.org/) [![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

**English** · [中文](README.zh-CN.md)

BenchPilot gives humans, CI jobs and AI coding agents one stateful interface to real embedded targets: power them, flash them, observe them, diagnose them and validate behavior.

The product loop is intentionally narrow:

```text
Build -> Flash -> Run -> Observe -> Diagnose -> Fix
```

BenchPilot is **not** a CANoe clone. It does not aim to reproduce full vehicle-network simulation, CAPL, ADAS simulation or hundreds of analysis windows. CAN/CAN FD, DBC, ISO-TP, UDS and DoIP are added when they help complete the ECU development loop.

> Current status: **v0.1.0 — first release of the reset version epoch: the Racket runtime at full contract parity plus BenchPilot Studio enters 0.x feature validation.** UDS diagnostics and flashing over ISO-TP/CAN and DoIP, a built-in simulated ECU for hardware-free end-to-end runs, SocketCAN/PCAN adapters and system-serial/J-Link/SCPI power drivers behind one readiness gate. Persistent evidence/artifact storage, device error taxonomy, HEX/S-record image models, UDS DTC, security providers, CAN capture + DBC signal decoding, team leases with audit, and flash hardening (fingerprint gate, in-programming power guard, recovery strategies) are in. **BenchPilot Studio** — the first-party native desktop app on the Rivet line — ships for macOS (Apple Silicon and Intel) and Windows (portable zip); the Linux host is a developer preview. The next gate is physical validation against a real ECU + J-Link + serial + bench supply, not adding more protocols.

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
- virtual firmware boot log with time-based line visibility;
- flash/reset behavior;
- shared state across power, serial and flash;
- context-compressed serial wait observations;
- Runtime safety validation;
- CLI and MCP clients over the same resident state.

No physical hardware is required for the simulator path.

### Requirements

- nothing to *run* a release; Racket 9.3+ (CS) to build from source
- Git
- an MCP-capable client for Agent use (optional)
- for physical benches: the vendor/OS tools referenced by the selected profile, such as SEGGER J-Link Commander

### Build and test

```bash
git clone https://github.com/turinglambdaai/benchpilot.git
cd benchpilot
raco pkg install --auto --name benchpilot --link racket
raco test racket/benchpilot
```

## Quick start

### 0. Install

One line per platform (downloads the latest release, verifies SHA256, installs
the three executables into `~/.benchpilot/bin`):

```bash
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/turinglambdaai/benchpilot/main/scripts/install.sh | bash
```

```powershell
# Windows PowerShell
irm https://raw.githubusercontent.com/turinglambdaai/benchpilot/main/scripts/install.ps1 | iex
```

What each release ships (all of it covered by the release's `SHA256SUMS`
checksum manifest):

| platform | CLI (portable) | CLI (installer) | Studio (desktop app) |
| --- | --- | --- | --- |
| macOS Apple silicon | `benchpilot-<version>-osx-arm64.tar.gz` | — | `benchpilot-studio-<version>-macos-arm64.dmg` + portable `.zip` |
| macOS Intel | `benchpilot-<version>-osx-x64.tar.gz` | — | `benchpilot-studio-<version>-macos-x64.dmg` + portable `.zip` |
| Windows x64 | `benchpilot-<version>-win-x64.zip` | — | `benchpilot-studio-<version>-windows-x64.zip` (portable) |
| Linux x64 | `benchpilot-<version>-linux-x64.tar.gz` | `benchpilot-<version>-linux-x64.deb` | planned (host is a developer preview) |
| Linux arm64 | `benchpilot-<version>-linux-arm64.tar.gz` | — | planned |

Package-manager routes: each release also carries a generated Homebrew
formula (`benchpilot.rb`) and scoop manifest (`benchpilot.scoop.json`) — copy
them into your tap/bucket, or install manually from the
[latest release](https://github.com/turinglambdaai/benchpilot/releases/latest)
(`benchpilot-<version>-<platform>.zip/.tar.gz`) and put the three executables
on your `PATH`:

| executable | role |
| --- | --- |
| `benchpilotd` | resident runtime owning hardware state |
| `benchpilot` | CLI for humans, CI and agents |
| `benchpilot-mcp` | stdio MCP adapter for agent clients |

Desktop app: download `benchpilot-studio-<version>-macos-<arch>.dmg` from the
[latest release](https://github.com/turinglambdaai/benchpilot/releases/latest)
(macOS 14+, Apple Silicon or Intel), drag **BenchPilot Studio** to
Applications and launch. On Windows, unpack
`benchpilot-studio-<version>-windows-x64.zip` and run `RivetHost.exe`.
Studio is a client over the same resident runtime — start
`benchpilotd` (any CLI/MCP command does it automatically) and the app
connects; without the runtime it shows a reachable/diagnostic state instead.
The Windows host covers the bench essentials (status, power, DTC read,
history); the Linux host is a developer preview and not packaged yet.

From source instead:

```bash
git clone https://github.com/turinglambdaai/benchpilot.git
cd benchpilot
raco pkg install --auto --name benchpilot --link racket
racket packaging/launchers/benchpilot.rkt status --json
```

### 0.5. Stay updated

```bash
benchpilot update --check   # compare against the latest release
benchpilot update           # download, verify SHA256, stop the daemon
                            # gracefully, swap in place, autostart restores it
```

The updater refuses to run while hardware operations are active, and leaves
`.old` backups next to the replaced executables. If an agent hosts
`benchpilot-mcp`, restart that MCP server after updating.

Scope, stated plainly: the CLI self-updater covers the three executables —
its feed is this repo's GitHub releases, and integrity comes from the
release's `SHA256SUMS` manifest. Studio (the desktop app) updates in-app on
macOS: "Check for Updates…" in the app menu, silent check at most once per
4 hours; the feed is the release's Ed25519-signed `update-manifest.json`
covering the portable zips, verified in-app before an atomic in-place swap
(only a copy under /Applications self-updates). The Windows host has no
in-app updater yet: replace it from the
[latest release](https://github.com/turinglambdaai/benchpilot/releases/latest).

### 1. Just run a command

There is no separate "start the runtime" step for casual and agent use: the
first `benchpilot` command starts `benchpilotd` automatically (detached, logs
in `~/.benchpilot/logs/`) and every later command reuses that resident
process and its state.

```bash
benchpilot status --json
```

Set `BENCHPILOT_AUTOSTART=0` if you prefer to run `benchpilotd` yourself, for
example with a specific profile:

```bash
BENCHPILOT_PROFILE=profiles/real-ecu.example.json benchpilotd
```

`benchpilot doctor --json` checks the installation (runtime reachability,
versions, token, daemon discovery) without changing anything.

### 2. Drive the bench

The first useful simulated ECU loop is:

```bash
benchpilot power on --voltage 12 --json
benchpilot flash write build/app.elf --json
benchpilot serial wait Ready --timeout-ms 5000 --json
benchpilot power check --lt-ma 100 --json
benchpilot power off --json
```

When installed from source, prefix the commands with
`racket packaging/launchers/benchpilot.rkt` instead.

Long mutations and serial observations can also carry a Runtime execution budget:

```bash
racket packaging/launchers/benchpilot.rkt -- \
  flash write build/app.elf --deadline-ms 30000 --json

racket packaging/launchers/benchpilot.rkt -- \
  serial wait Ready --timeout-ms 5000 --deadline-ms 7000 --json
```

`--deadline-ms` is deliberately different from a device/protocol timeout or `serial wait --timeout-ms`. The serial timeout is the semantic wait window: reaching it normally produces an unmatched assertion. The Runtime deadline is the outer execution budget shared by CLI/MCP/Agent workflows. When it expires, Runtime records `deadline_exceeded` in history and evidence and rejects even a late success returned by a driver that ignored cancellation.

### 3. Validate a physical bench before touching the ECU

Start from the checked-in example profile and replace every `CHANGE_ME` value with your actual bench information:

```text
profiles/real-ecu.example.json
```

Then run the readiness report **before** power/reset/flash:

```bash
BENCHPILOT_PROFILE=profiles/real-ecu.example.json benchpilotd

# In another terminal (or just benchpilot with autostart pointing at the same endpoint):
benchpilot bench validate --target ecu --json
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

```bash
benchpilot-mcp
```

The MCP process is only a stdio protocol adapter. It also starts the resident
Runtime on demand, so an Agent and a terminal observe the same ECU/bench
state. The MCP `BenchValidate` tool exposes the same non-destructive readiness
report as CLI. Long power/flash/serial tools also expose an optional
`deadlineMs`, enforced and audited by Runtime rather than by the MCP process.

### 5. Wire the agent skill

`integrations/agent/SKILL.md` is a ready-made skill package for coding agents
(operate the bench safely, read evidence before retrying, respect the safety
gates). Point your agent at that file, or copy it into your skills directory.
`benchpilot doctor` and `benchpilot status --json` are deliberately agent
friendly entry points.

Example Agent task:

> Validate the `ecu` target for real-bench readiness. Do not power, reset or flash anything. If it is not ready, tell me exactly which checks failed and how to fix them.

After the target is ready, an Agent can execute a constrained bench loop such as:

> Power on the ECU at 12 V, flash the selected firmware, wait for the console to print `Ready`, verify idle current is below the configured threshold, then power it off.

### 6. Attach a bench report

One static, self-contained HTML artifact covering the bench state, the
readiness verdict, operation/observation history and the newest evidence —
attach it to a bench session log or an ECU release note:

```bash
benchpilot report --out bench-report.html
```

## CLI exit codes

CLI exit codes are intentionally stable and machine-friendly:

```text
0 success / readiness passed
1 operation, assertion or readiness failure; cancellation
2 validation error
3 target/resource/operation/observation/evidence not found
4 runtime unreachable, unauthorized, or device/preflight error
5 target/resource busy because another mutating operation is active
6 Runtime execution deadline exceeded
```

A `bench validate` exit code of `1` does **not** mean the readiness API failed. It means the report executed successfully but one or more blocking readiness checks failed; inspect the JSON checks and remediation fields.

A deadline failure is returned as `code=deadline_exceeded` with `deadlineMs` and `deadlineAtUtc`; active and history records also expose deadline metadata. Emergency power-off intentionally has no Runtime deadline once accepted, because a safety shutdown must not be abandoned just because a shell budget expired.

## UDS diagnostics and flashing (CAN and DoIP)

BenchPilot includes a full UDS (ISO 14229) diagnostic stack: ISO-TP (ISO 15765-2) over SocketCAN/PCAN, and DoIP (ISO 13400-2) over Ethernet. The same flash engine drives both transports.

```bash
# Discover DoIP entities on the network (a 100BASE-T1 media converter with
# an RJ45 cable to the laptop is enough to reach a real ECU):
benchpilot doip discover --json

# Enter programming session and read a version DID:
benchpilot uds session programming --target ecu --json
benchpilot uds read-did 0xF195 --target ecu --json

# Raw UDS escape (expert):
benchpilot uds request "10 03" --target ecu --json

# Destructive UDS flash over the bound diagnostic channel:
benchpilot uds flash build/app.bin --address 0x08020000   --confirm-target ecu --target ecu --deadline-ms 300000 --json
```

Multi-segment images use a declarative flash plan:

```json
{
  "segments": [
    { "address": 134217728, "file": "bootloader.bin" },
    { "address": 134480896, "file": "application.bin" }
  ],
  "session": 2,
  "securityLevel": 1,
  "keyDeriver": "xor0x5a",
  "maxBlockPayload": 1024
}
```

```bash
benchpilot uds flash build/app.bin --plan flash.plan.json --confirm-target ecu --json
```

Every flash step (session, security access, erase, per-segment download,
verify, reset) is audited in the operation evidence, so a failed programming
session explains itself: `benchpilot history`, then `benchpilot evidence <id>`.

Without hardware, the built-in simulator includes a virtual UDS ECU behind
the real protocol stack: `benchpilot uds read-did 0xF195` against the default
`demo` target answers through ISO-TP on a simulated CAN bus, and the same
flash workflow can be rehearsed end to end before touching a real bench.

## Local security model

`benchpilotd` binds to loopback only and refuses non-loopback endpoints. Loopback alone is not an auth boundary on a shared machine, so the API additionally requires a per-user token:

- on first start the daemon generates a random token at `~/.benchpilot/token` (user-only permissions on Unix);
- CLI, MCP and `Benchpilot.Client` attach it automatically; `BENCHPILOT_TOKEN` overrides the file;
- `/healthz` is intentionally open so autostart, monitoring and `doctor` can probe liveness without credentials;
- a second daemon for another user account on the same machine cannot read this user's token file and cannot drive this user's bench.

Remote/team access (authenticated transport, leases, scheduling) is deliberately out of scope until the local single-bench experience is validated on hardware.

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
├── racket/
│   └── benchpilot/core/              # Racket port (ADR 0002): profiles + readiness
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
2. validate the UDS flash workflow against real ECUs over CAN and DoIP;
3. CAN/CAN FD capture + DBC decoding and signal observations;
4. a richer vendor-neutral device/runtime error taxonomy and production-grade evidence/artifact references;
5. ~~Studio GUI over the same Runtime API.~~ Shipped: BenchPilot Studio covers power, flash, serial, UDS diagnostics and DoIP discovery on macOS.

See [ROADMAP.md](ROADMAP.md).

## Implementation language

The Runtime is implemented in **Racket** (Racket CS)
([ADR 0002](docs/adr/0002-racket-port.md), which supersedes
[ADR 0001](docs/adr/0001-runtime-language.md)). The C#/.NET tree of the
0.5.x line was retired after the port reached full contract
parity: same frozen JSON API, same CLI exit codes, same E2E suite. GUI
technology stays decoupled from the Runtime: BenchPilot Studio speaks the
same versioned local API rather than owning devices.

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