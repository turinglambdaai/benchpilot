---
name: benchpilot
description: Drive a real or simulated ECU bench from an agent - power, flash, serial observation, readiness validation and failure evidence through the BenchPilot CLI. Use when the task involves embedded hardware bring-up, firmware flashing, boot-log waiting, current assertions or diagnosing why a bench operation failed.
---

# BenchPilot: the ECU bench as agent tooling

BenchPilot gives you a stateful, safe interface to one physical (or simulated)
bench: `benchpilotd` owns the hardware; every `benchpilot <command>` call is a
client of that resident runtime. State persists across commands: if you power
a target on, it stays on until you power it off.

## Before you touch hardware

1. `benchpilot status --json` - who is on this bench (targets, resources,
   drivers, runtime version). The first call auto-starts the daemon.
2. `benchpilot bench validate --target <id> --json` - non-destructive
   readiness report. `readyForRealEcuLoop=true` is the gate before any
   destructive work. A failed report includes a `remediation` string per
   check: follow it instead of guessing.
3. `benchpilot doctor --json` - when something feels wrong with the
   installation itself (unreachable runtime, version mismatch, missing
   token). It never changes state.

Destructive operations (flash, reset) additionally require
`--confirm-target <id>` matching the target id when the profile enables
confirmation. Never bypass a safety prompt on the user's behalf.

## The core loop

```bash
benchpilot power on --target ecu --voltage 12 --json
benchpilot flash write build/app.elf --target ecu --confirm-target ecu --json
benchpilot serial wait Ready --target ecu --timeout-ms 10000 --json
benchpilot power check --target ecu --lt-ma 100 --json
benchpilot power off --target ecu --json
```

Exit codes are a stable contract:

| code | meaning |
| --- | --- |
| 0 | success / readiness passed |
| 1 | operation, assertion or readiness failure; cancellation |
| 2 | validation error (bad arguments) |
| 3 | target/resource/operation/observation not found |
| 4 | runtime unreachable, unauthorized, or device/preflight error |
| 5 | busy - another mutating operation holds the target/resource |
| 6 | Runtime execution deadline exceeded |

## Reading results like an engineer

- Every command accepts `--json`. That is the machine contract; parse it
  instead of scraping human output.
- `serial wait` is an **assertion**: unmatched (`matched=false`, exit 1) is a
  normal outcome, not a crash. The failure bundles bounded recent UART lines
  (`serial.failure-window`) plus correlated power context.
- `--deadline-ms` is the outer execution budget enforced by the Runtime.
  `deadline_exceeded` (exit 6) means the operation exceeded that budget - do
  not confuse it with a device timeout.
- On **any** failure, query evidence before retrying:
  `benchpilot history --limit 5 --json`, then
  `benchpilot evidence <operation-id> --json` for mutations or
  `benchpilot observe evidence <observation-id> --json` for serial waits.
  The evidence answers "what actually happened" without reopening a terminal
  emulator or dumping raw logs.
- Exit 5 (`busy`) returns the owning operation id. Cancel it with
  `benchpilot cancel <operation-id> --json` if it is yours to cancel, or
  wait for completion.

## Safety rules

- `bench validate` and `preflight` are always non-destructive; run them first
  on unfamiliar benches.
- `power emergency-off` is the one command allowed to bypass locks. Use it
  only for a real safety event (over-current, smoke, runaway target), never
  as a convenience shutdown.
- Current assertions (`power check --lt-ma`) protect hardware. When a check
  fails, power off and investigate the evidence - do not retry blindly.
- The daemon holds real hardware handles. If you started a long flash, wait
  for it (or `cancel <operation-id>`); killing processes risks a bricked
  bench state that the next operation must clean up.

## Simulator mode

With no profile configured, BenchPilot runs a deterministic virtual bench
(target `demo`): power, serial boot log ("Ready" at ~1.2 s), flash and
current. Use it to rehearse a loop, test scripts or demo agent workflows
without hardware. `bench validate` reports `mode=simulator` - it will
deliberately refuse `readyForRealEcuLoop=true`.

## Configuration

- `BENCHPILOT_ENDPOINT` - runtime endpoint (default `http://127.0.0.1:5640/`).
- `BENCHPILOT_AUTOSTART=0` - require a manually started `benchpilotd`.
- `BENCHPILOT_TOKEN` - local API token override (normally read from
  `~/.benchpilot/token`, created automatically on first daemon start).
- Bench layout (targets, drivers, safety ceilings) lives in a profile JSON;
  point `BENCHPILOT_PROFILE` at one when starting `benchpilotd`. See
  `profiles/real-ecu.example.json` in the repository.
