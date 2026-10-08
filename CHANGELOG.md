# Changelog

All notable changes to BenchPilot are documented here.

## 0.6.0 - 2026-10-02

The Racket port completes ([ADR 0002](docs/adr/0002-racket-port.md)); the
C#/.NET tree of the 0.5.x line is removed and the release ships from the
Racket sources only, at full contract parity (same frozen JSON API, CLI
exit codes and E2E suite).

### Added

- Real-hardware drivers (phase 4): SocketCAN (Linux) and PCAN-Basic
  (Windows) CAN transports behind the shared `can-iso-tp` profile driver,
  and the `system-serial` serial console driver (POSIX termios + Windows
  CommAPI backends) with bounded line buffering.
- The resident daemon now composes the same seven resource factories as
  the C# RuntimeHost did (simulator, sim-diagnostics, can-iso-tp, doip,
  system-serial, jlink, scpi-power).
- `benchpilot report --format html`: one self-contained static HTML
  evidence report (bench status, readiness verdict, histories, newest
  operation/observation evidence).
- MCP adapter (`benchpilot-mcp`) with the full 26-tool proxy surface over
  the resident daemon.
- Debian package now ships the full Racket distribution tree under
  `/opt/benchpilot` with thin `/usr/bin` wrappers; Homebrew formula and
  the installers follow the same layout.
- Post-port feature batch: persistent evidence/artifact storage across
  restarts, device error taxonomy, Intel HEX / S-record image models,
  UDS DTC primitives (0x19/0x14), security providers
  (`command:<id>` external algorithms), CAN capture + DBC signal
  decode/encode, team leases with a persistent audit trail, and flash
  hardening (fingerprint gate, in-programming power guard, recovery
  strategies) — with `store` / `can` / `lease` CLI command families.

### Changed

- Release matrix drops `win-arm64`: Racket publishes no official Windows
  ARM64 builds. Windows remains a single-file x64 build; scoop serves
  64bit only.
- The Unix release archives now carry a `bin/` + `lib/` distribution tree;
  installers wrap the real launchers so self-update keeps swapping in
  place.
- The J-Link health check parses `ShowEmuList` output and applies the
  deterministic USB probe selection policy (configured serial number wins;
  multiple USB probes require one).
- SCPI health check performs a real identify query without changing the
  output state.
- DoIP discovery returns an empty result on hosts without a broadcast
  route instead of failing.

### Fixed

- Any request carrying a query string failed with an empty reply (the
  HTTP server mis-indexed its query regex groups); the E2E suite was the
  first harness to exercise query parameters.
- CLI exit codes for `busy` (5) and `deadline_exceeded` (6) were
  unreachable — string error codes were compared against symbol datums.
- `benchpilot shutdown` stopped accepting work but never drained and
  exited; it now follows the same graceful path as SIGTERM.
- Structured error fields (`deadlineMs`, `deadlineAtUtc`, `busyScope`,
  `operationId`) survive into the CLI's printed error JSON.
- The J-Link driver consumed its subprocess pipes in the wrong order,
  which would have hung real hardware runs.

## Unreleased

Racket port kickoff ([ADR 0002](docs/adr/0002-racket-port.md)):

- Decision: port the runtime from .NET/C# to Racket in staged phases under
  the frozen JSON API / CLI / E2E contract; the C# tree remains the shipping
  implementation until the port completes.
- Added `racket/` with the first ported slice (bench profile model, loader,
  normalization, validation and the pure readiness helpers), covered by 29
  contract tests; CI runs the ported tree on Windows and Linux.
- Note: v0.5.1 release notes below describe the C#-based 0.5.x line.

## 0.5.1 - 2026-09-28

Self-update: the CLI upgrades itself from the release feed.

### Added

- `benchpilot update --check`: compares the installed version against the
  release feed (GitHub releases; `BENCHPILOT_UPDATE_REPO` /
  `BENCHPILOT_UPDATE_FEED` overrides) without touching anything.
- `benchpilot update`: downloads the platform archive, verifies
  `SHA256SUMS.txt`, refuses while hardware operations are active, stops the
  resident daemon through the new graceful shutdown endpoint, swaps the
  executables in place (`.old` backups; running shells renamed per Windows
  rules) and lets autostart bring the daemon back.
- `benchpilot shutdown`: idempotent graceful daemon stop (drains active work,
  releases hardware handles) — also usable standalone.

## 0.5.0 - 2026-09-27

Diagnostics: the UDS flash workflow ships for both CAN and automotive Ethernet.

### Added

- `Benchpilot.Diagnostics`: ISO-TP (ISO 15765-2) codec and endpoint, UDS
  client (ISO 14229) with P2/P2* timing and NRC 0x78 handling, and a
  transport-independent `UdsFlashEngine`: session -> security access ->
  erase -> per-segment download (RequestDownload/TransferData/Exit, block
  retries) -> CRC32 verify routine -> ECU reset, fully audited per step.
- DoIP client (ISO 13400-2): UDP vehicle discovery, TCP routing activation,
  alive-check handling, diagnostic message transport. A 100BASE-T1 media
  converter plus RJ45 is enough to drive a real DoIP ECU from a laptop.
- Real CAN drivers: SocketCAN (Linux) and PCAN-Basic (Windows).
- Simulated diagnostics: a virtual UDS ECU behind the real protocol stack on
  a simulated CAN bus, plus a simulated DoIP entity — the complete flash
  workflow runs hardware-free in CI on Windows and Linux.
- CLI: `uds request`, `uds read-did`, `uds session`, `uds flash`, and
  `doip discover`. API: `/uds/request`, `/uds/flash`, `/doip/discover`.
  MCP: `UdsRequest`, `UdsReadDid`, `UdsFlash`, `DoipDiscover`.
- Repository hygiene: merged feature branches pruned; docs example profile
  for CAN and DoIP benches.

### Notes

- `uds flash` is a destructive mutation: it participates in the same
  confirm-target policy as J-Link flash. Session/security state stays
  resident in the daemon like a real tool session.

## 0.4.0 - 2026-09-26

Commercial readiness of the shell layer: the product is now installable,
single-command and authenticated, with black-box end-to-end coverage.

### Added

- Product versioning: shared `VersionPrefix`, `benchpilot --version` /
  `benchpilot version`, `version` in `/healthz` and `status` output.
- Release workflow: tag-triggered self-contained single-file packages for
  `win-x64`, `linux-x64`, `linux-arm64`, `osx-arm64` with `SHA256SUMS.txt`
  and automated GitHub releases.
- On-demand daemon start: the first CLI/MCP command launches `benchpilotd`
  detached (logs under `~/.benchpilot/logs/`) and later commands reuse the
  resident state; `BENCHPILOT_AUTOSTART=0` opts out. Agent and CI workflows
  no longer need a separately prepared terminal.
- Local API authentication: `benchpilotd` requires a per-user token
  (`~/.benchpilot/token`, auto-generated, `BENCHPILOT_TOKEN` override) on
  every non-health endpoint; clients attach it transparently.
- `benchpilot doctor`: non-mutating installation diagnostics (runtime
  reachability, CLI/runtime version match, token presence, daemon
  discovery) with actionable remediation.
- Agent integration package: `integrations/agent/SKILL.md` for coding
  agents (command map, exit-code contract, evidence-first debugging, safety
  rules).
- Black-box e2e test suite (`Benchpilot.E2E.Tests`) running the real
  `benchpilotd` + `benchpilot` processes over real HTTP on Windows and
  Linux CI: full simulator ECU loop, deadline/exit-code semantics, failure
  evidence correlation, token enforcement, doctor, autostart residency.

### Fixed

- Daemon autostart no longer hangs shell pipelines, CI harnesses and test
  hosts: the spawning shell clears the inherit flag on its stdio handles
  (`SetHandleInformation` / `FD_CLOEXEC`) and the detached daemon replaces
  inherited stdio with the NUL device, so no process keeps a reader waiting
  for EOF after the CLI exits. Detached daemons also log to disk instead of
  relying on a parent that will die.

### Notes

- The loopback API now rejects requests without a valid token; shell
  upgrades and daemons ship together so normal CLI/MCP use is unaffected.
- Exit code 4 now also covers `unauthorized`.
