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
cli preflight --json
cli power on --voltage 12 --settle-ms 200 --json
# No --port/--baud here: the shell must let the resource profile own device details.
cli serial open --json
cli flash write build/app.elf --json
# Completed mutations must disappear from Runtime-owned operation state.
cli operations --json
cli serial wait Ready --timeout-ms 5000 --json
cli power check --lt-ma 100 --json
cli power off --json

echo "BenchPilot resident runtime smoke test passed."
