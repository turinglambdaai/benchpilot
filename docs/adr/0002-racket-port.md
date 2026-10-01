# ADR 0002: Port the BenchPilot runtime from .NET/C# to Racket

- Status: Accepted
- Date: 2026-10-01
- Supersedes: [ADR 0001](0001-runtime-language.md), via that ADR's own revisit criteria

## Context

ADR 0001 chose .NET/C# to minimize hardware-integration risk. Six weeks later,
the facts that decision relied on have changed:

1. **The C# tree holds no hardware-validated knowledge.** The runtime was
   written simulator-only. CI proves the protocol stacks are self-consistent
   against a simulated ECU; nothing has been validated against a real bench.
   The expensive part of a hardware stack — real-ECU validation, timing
   quirks, vendor workarounds — has not been paid down in any language.
2. **The native-interop surface turned out to be small.** ADR 0001 bet on
   "low-friction P/Invoke and vendor SDK coverage". Measured reality: exactly
   two P/Invoke files (`SocketCanBus`, `PcanBus`); J-Link and SCPI are
   process/serial wrappers. The argument for .NET never got cashed.
3. **The Racket ecosystem investment matured.** rivet 0.5.0 (records/enums,
   schema gates, six-architecture matrix), the glaze platform hardening and
   the taskly rebuild are shipped and maintained first-party.
4. **The port cost is at its historical minimum right now.** 8.2k LOC of
   unvalidated C# plus 3.8k LOC of tests plus a frozen JSON API make this a
   tests-as-spec port, not a rewrite from requirements. Every week of
   real-ECU validation from here on adds C#-specific fixes and raises the
   port cost continuously.

ADR 0001 listed revisit criteria. Criterion three — "a stable service boundary
makes the implementation language of a subsystem irrelevant enough to choose
another language for that subsystem" — is met: the flat JSON result contract,
the CLI exit-code table and the E2E suite *are* that boundary. Criterion one
(first-class Racket bindings for the hardware ecosystem) is what this port
creates instead of waits for.

## Decision

Port BenchPilot to **Racket (Racket CS)**, staged, inside this repository under
`racket/`, with the existing test suite as the acceptance spec.

### The frozen contract

The Racket port must be contract-identical to the C# implementation. Normative
artifacts:

- JSON API shapes: `src/Benchpilot.Protocol/ApiModels.cs` (camelCase keys,
  flat `Ok`-first records, stable error codes);
- CLI exit codes and stdout behavior: the "CLI exit codes" section of
  `README.md`;
- behavioral semantics: `tests/Benchpilot.E2E.Tests` (real process/HTTP
  boundary) and the per-project unit tests.

"Ported test green" means the ported test, unchanged in its assertions,
passes against the Racket implementation.

### Rivet's role

Rivet is a first-party native **GUI application** framework (WinUI 3 /
SwiftUI / GTK4 hosts around a Racket backend). BenchPilot is a headless
product: its clients are terminals, agents and CI. The daemon and CLI are
therefore plain Racket programs, not rivet apps — forcing a UI-host model
onto a headless runtime would be framework contortion.

Rivet enters this product at two points:

- contract discipline: schema-governed records/enums for the core surfaces
  where it fits without changing the wire format;
- `Benchpilot.Studio` (README product priority 5), if and when the GUI
  becomes real, as a rivet native shell over the same frozen API.

### Staged plan with machine-checkable gates

Each phase ends in a gate that CI or a script can verify. The C# tree remains
the shipping/fix line until Phase 5 completes.

| Phase | Scope | Gate |
| --- | --- | --- |
| 0 — this ADR | `racket/` scaffold, CI job (`raco test racket/`), profile core | ported profile tests green on Windows + Linux CI |
| 1 — core | profiles, readiness/preflight semantics, safety policy, result contracts | ported `Benchpilot.Core.Tests` green |
| 2 — protocol | ISO-TP codec/endpoint, UDS client (P2/P2\*/NRC 0x78), DoIP client, simulated CAN | ported `Benchpilot.Diagnostics.Tests` green hardware-free in CI — protocol parity proven without hardware |
| 3 — runtime + host | mutation gates, deadlines, cancellation, audit/evidence, observations, token auth, loopback HTTP API, autostart, graceful shutdown | ported `Benchpilot.E2E.Tests` green against the Racket daemon on Windows + Linux CI |
| 4 — drivers | serial FFI, SocketCAN FFI, PCAN-Basic FFI, J-Link wrapper, SCPI driver | simulator-backed suite green; hardware smoke on the real bench when available |
| 5 — product surface | CLI, MCP adapter, self-update, packaging (native executables per platform, installer/deb), docs and agent skill parity; the human-facing evidence layer (`--format html` static reports, designed 2026-10-01) lands on the Racket CLI | full parity: release matrix builds, E2E green, docs updated; C# tree removed; release v0.6.0 |

Porting order inside each phase is bottom-up: data contracts first, then pure
logic, then I/O — so every step lands testable.

### Abort criteria

The staged gates exist so the port can stop without leaving a half-shipped
product. Abort the port (and keep C#) if:

- serial or CAN FFI on Windows proves materially worse than the existing
  P/Invoke path in Phase 4 hardware smoke (throughput, latency or stability);
- the Phase 3 E2E parity stall exceeds the time real-ECU validation would
  have taken on the C# tree.

## Consequences

Positive:

- BenchPilot joins the family stack its maintainer actually ships with
  (rivet, glaze, taskly, regexmate), concentrating maintenance attention;
- the tests-as-spec port de-risks protocol logic: parity is proven
  hardware-free before any driver FFI is written;
- the frozen API means agents, CLI users and the MCP surface see no change
  during the entire port;
- Rivet gains a defined future adopter (Studio) without distorting a headless
  product into a GUI shape.

Costs:

- CAN/CAN FD capture + DBC decoding (product priority 3) and real-ECU
  validation queue behind the port;
- two trees to fix during the transition window (C# for shipped fixes,
  Racket for the port);
- Racket FFI and GC characteristics must be validated at Phase 4 against
  real CAN traffic and ISO-TP block pacing.

## Revisit criteria

Revisit this decision if either abort criterion fires, or if the Phase 3
parity gate slips past 2026-11-15 without a credible path to green.
