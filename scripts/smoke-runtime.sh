#!/usr/bin/env bash
set -euo pipefail

export BENCHPILOT_ENDPOINT="${BENCHPILOT_ENDPOINT:-http://127.0.0.1:5640/}"
RUNTIME_LOG="${TMPDIR:-/tmp}/benchpilot-runtime-$$.log"

cleanup() {
  local code=$?
  if [[ -n "${RUNTIME_PID:-}" ]] && kill -0 "$RUNTIME_PID" 2>/dev/null; then
    kill "$RUNTIME_PID" 2>/dev/null || true
    wait "$RUNTIME_PID" 2>/dev/null || true
  fi
  if [[ $code -ne 0 ]]; then
    echo "--- benchpilotd log ---" >&2
    cat "$RUNTIME_LOG" >&2 || true
  fi
  rm -f "$RUNTIME_LOG"
  exit "$code"
}
trap cleanup EXIT

dotnet run --project src/Benchpilot.RuntimeHost -c Release --no-build >"$RUNTIME_LOG" 2>&1 &
RUNTIME_PID=$!

ready=0
for _ in $(seq 1 50); do
  if curl -fsS "${BENCHPILOT_ENDPOINT%/}/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.2
done

if [[ $ready -ne 1 ]]; then
  echo "benchpilotd did not become ready" >&2
  exit 1
fi

cli() {
  dotnet run --project src/Benchpilot.Cli -c Release --no-build -- "$@"
}

cli status --json
cli operations --json
cli history --limit 10 --json
cli observe list --json
cli observe history --limit 10 --json
cli preflight --json

# The built-in simulator must never be reported as a physical real-ECU bench.
# `bench validate` is an assertion-style command: the report itself succeeds,
# but a not-ready target returns exit code 1 and actionable remediation.
set +e
readiness_json="$(cli bench validate --target demo --json)"
readiness_code=$?
set -e
printf '%s\n' "$readiness_json"
if [[ $readiness_code -ne 1 ]]; then
  echo "expected simulator bench validation to return exit code 1, got $readiness_code" >&2
  exit 1
fi
printf '%s' "$readiness_json" | python3 -c '
import json,sys
r=json.load(sys.stdin)
assert r["ok"] is True
assert r["readyForRealEcuLoop"] is False
assert r["mode"] == "simulator"
real=next(x for x in r["checks"] if x["code"] == "target.real-hardware")
assert real["passed"] is False
assert real.get("remediation")
'

cli power on --voltage 12 --settle-ms 200 --json
# No --port/--baud here: the shell must let the resource profile own device details.
cli serial open --json
cli flash write build/app.elf --json
# Completed mutations must disappear from Runtime-owned operation state.
cli operations --json
# Query compact mutation evidence through the same CLI -> Client -> HTTP Runtime path.
latest_operation_id="$(cli history --limit 1 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["operations"][0]["id"])')"
cli evidence "$latest_operation_id" --json
cli serial wait Ready --timeout-ms 5000 --json

# An unmatched wait is an assertion-style failure (exit 1), not a device error.
# It must create bounded UART failure evidence and automatically correlate the
# already-recorded target power/current context without performing new I/O.
if cli serial wait __BENCHPILOT_NEVER_MATCH__ --timeout-ms 50 --json; then
  echo "expected unmatched serial wait to return non-zero" >&2
  exit 1
fi
cli observe list --json
latest_observation_id="$(cli observe history --limit 1 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["observations"][0]["id"])')"
observation_evidence="$(cli observe evidence "$latest_observation_id" --json)"
printf '%s\n' "$observation_evidence"
printf '%s' "$observation_evidence" | python3 -c '
import json,sys
r=json.load(sys.stdin)
kinds=[item["kind"] for item in r["items"]]
assert "serial.wait" in kinds
assert "serial.failure-window" in kinds
assert "context.power-on" in kinds
ctx=next(item for item in r["items"] if item["kind"] == "context.power-on")
assert ctx["metadata"]["voltageV"] == "12"
assert "capturedAtUtc" in ctx["metadata"]
assert "ageMs" in ctx["metadata"]
'

cli power check --lt-ma 100 --json
cli power off --json
# Completed mutations and observations remain available as bounded Runtime audit trails.
cli history --limit 10 --json
cli observe history --limit 10 --json

echo "BenchPilot resident runtime smoke test passed."
