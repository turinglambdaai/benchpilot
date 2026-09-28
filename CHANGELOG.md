# Changelog

All notable changes to BenchPilot are documented here.

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
