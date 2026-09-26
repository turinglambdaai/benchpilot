# Changelog

All notable changes to BenchPilot are documented here.

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
