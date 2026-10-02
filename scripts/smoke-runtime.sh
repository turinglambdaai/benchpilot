#!/usr/bin/env bash
# Boots the real benchpilotd and exercises the CLI against it end to end.
set -euo pipefail
cd "$(dirname "$0")/.."

ENDPOINT="${BENCHPILOT_ENDPOINT:-http://127.0.0.1:5640/}"
export BENCHPILOT_ENDPOINT="$ENDPOINT"
export BENCHPILOT_QUIET=1
LOG="$(mktemp /tmp/benchpilotd-smoke.XXXXXX.log)"

cleanup() { [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null || true; }
trap cleanup EXIT

racket racket/benchpilot/runtime-host/daemon.rkt >"$LOG" 2>&1 &
DAEMON_PID=$!

for _ in $(seq 1 50); do
  if curl -fsS "${ENDPOINT}healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
curl -fsS "${ENDPOINT}healthz" >/dev/null || { echo "daemon never became healthy; log:"; cat "$LOG"; exit 1; }

racket racket/benchpilot/client/cli.rkt status --json >/dev/null
racket racket/benchpilot/client/cli.rkt power on --voltage 12 --settle-ms 100 --json >/dev/null
racket racket/benchpilot/client/cli.rkt power off --json >/dev/null
racket racket/benchpilot/client/cli.rkt history --limit 5 --json | grep -q '"kind":"power.on"'
echo "smoke-runtime: ok"
