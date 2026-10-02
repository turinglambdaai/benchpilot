#!/usr/bin/env bash
# A SIGTERM must drain active work: the in-flight serial wait finishes its
# observation window and the daemon exits cleanly afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${BENCHPILOT_SMOKE_PORT:-5641}"
ENDPOINT="http://127.0.0.1:$PORT/"
export BENCHPILOT_ENDPOINT="$ENDPOINT"
export BENCHPILOT_QUIET=1
LOG="$(mktemp /tmp/benchpilotd-shutdown.XXXXXX.log)"

cleanup() { [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null || true; }
trap cleanup EXIT

racket racket/benchpilot/runtime-host/daemon.rkt >"$LOG" 2>&1 &
DAEMON_PID=$!

for _ in $(seq 1 50); do
  curl -fsS "${ENDPOINT}healthz" >/dev/null 2>&1 && break
  sleep 0.2
done
curl -fsS "${ENDPOINT}healthz" >/dev/null || { echo "daemon never became healthy"; exit 1; }

# Long serial wait in the background; the daemon should cancel it gracefully.
racket racket/benchpilot/client/cli.rkt serial wait __SMOKE_NEVER__ --timeout-ms 30000 --json > /tmp/bp-wait-out.json 2>&1 &
WAIT_PID=$!
sleep 1

kill "$DAEMON_PID"
for _ in $(seq 1 50); do
  kill -0 "$DAEMON_PID" 2>/dev/null || break
  sleep 0.2
done
if kill -0 "$DAEMON_PID" 2>/dev/null; then
  echo "daemon did not exit after SIGTERM; log:"; cat "$LOG"; exit 1
fi
wait "$WAIT_PID" || true
echo "smoke-shutdown: ok"
