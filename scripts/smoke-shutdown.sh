#!/usr/bin/env bash
set -euo pipefail

export BENCHPILOT_ENDPOINT="${BENCHPILOT_SHUTDOWN_ENDPOINT:-http://127.0.0.1:5641/}"
RUNTIME_LOG="${TMPDIR:-/tmp}/benchpilot-shutdown-runtime-$$.log"
WAIT_LOG="${TMPDIR:-/tmp}/benchpilot-shutdown-wait-$$.log"
RUNTIME_PID=""
WAIT_PID=""

cleanup() {
  local code=$?
  if [[ -n "$WAIT_PID" ]] && kill -0 "$WAIT_PID" 2>/dev/null; then
    kill "$WAIT_PID" 2>/dev/null || true
    wait "$WAIT_PID" 2>/dev/null || true
  fi
  if [[ -n "$RUNTIME_PID" ]] && kill -0 "$RUNTIME_PID" 2>/dev/null; then
    kill -KILL "$RUNTIME_PID" 2>/dev/null || true
    wait "$RUNTIME_PID" 2>/dev/null || true
  fi
  if [[ $code -ne 0 ]]; then
    echo "--- benchpilotd shutdown smoke log ---" >&2
    cat "$RUNTIME_LOG" >&2 || true
    echo "--- serial wait client log ---" >&2
    cat "$WAIT_LOG" >&2 || true
  fi
  rm -f "$RUNTIME_LOG" "$WAIT_LOG"
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

cli power on --voltage 12 --settle-ms 50 --json >/dev/null
cli serial open --json >/dev/null

# Keep one real HTTP request blocked in Runtime-owned observation state. The
# shutdown path must request cancellation and let the observation unwind before
# shared resources are disposed.
set +e
cli serial wait __BENCHPILOT_SHUTDOWN_NEVER_MATCH__ --timeout-ms 60000 --json >"$WAIT_LOG" 2>&1 &
WAIT_PID=$!
set -e

observed=0
for _ in $(seq 1 50); do
  count="$(cli observe list --json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["observations"]))' 2>/dev/null || echo 0)"
  if [[ "$count" -gt 0 ]]; then
    observed=1
    break
  fi
  sleep 0.1
done
if [[ $observed -ne 1 ]]; then
  echo "serial wait never appeared as an active observation" >&2
  exit 1
fi

kill -TERM "$RUNTIME_PID"

exited=0
for _ in $(seq 1 80); do
  if ! kill -0 "$RUNTIME_PID" 2>/dev/null; then
    exited=1
    break
  fi
  sleep 0.1
done
if [[ $exited -ne 1 ]]; then
  echo "benchpilotd did not exit within the bounded graceful-shutdown window" >&2
  exit 1
fi

# Reap both processes. The blocked CLI request may terminate with a cancellation
# response or a connection-close error depending on HTTP shutdown timing; the
# invariant under test is the Runtime's own drain before hardware disposal.
wait "$RUNTIME_PID" || true
RUNTIME_PID=""
wait "$WAIT_PID" 2>/dev/null || true
WAIT_PID=""

if ! grep -q "active work drained and hardware resources released" "$RUNTIME_LOG"; then
  echo "benchpilotd exited without logging successful Runtime drain/resource release" >&2
  exit 1
fi

if grep -q "shutdown timed out" "$RUNTIME_LOG"; then
  echo "benchpilotd reported a graceful-shutdown timeout" >&2
  exit 1
fi

echo "BenchPilot graceful shutdown smoke test passed."
