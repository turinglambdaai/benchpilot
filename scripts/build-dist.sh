#!/usr/bin/env bash
# Builds one release distribution for the RUNNING platform:
#   scripts/build-dist.sh <version> <rid> <dest-dir>
# Windows: three embed-dlls single-file executables (flat, C#-shaped).
# Unix:    a full `raco distribution` tree (bin/ + lib/).
set -euo pipefail

VER="$1"; RID="$2"; DEST="$3"
cd "$(dirname "$0")/.."

# The launchers require the benchpilot collection; install the link
# (no-op — and non-fatal — when the caller already did).
raco pkg install --auto --name benchpilot --link racket >/dev/null 2>&1 || true

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

case "$RID" in
  win-*)
    raco exe --embed-dlls -o "$WORK/benchpilot.exe" packaging/launchers/benchpilot.rkt
    raco exe --embed-dlls -o "$WORK/benchpilotd.exe" packaging/launchers/benchpilotd.rkt
    raco exe --embed-dlls -o "$WORK/benchpilot-mcp.exe" packaging/launchers/benchpilot-mcp.rkt
    mkdir -p "$DEST"
    cp "$WORK"/benchpilot*.exe "$DEST/"
    ;;
  *)
    raco exe -o "$WORK/benchpilot" packaging/launchers/benchpilot.rkt
    raco exe -o "$WORK/benchpilotd" packaging/launchers/benchpilotd.rkt
    raco exe -o "$WORK/benchpilot-mcp" packaging/launchers/benchpilot-mcp.rkt
    # raco exe writes read-only launchers; `raco distribute` rewrites the
    # copies it assembles and needs them writable.
    chmod u+w "$WORK"/benchpilot "$WORK"/benchpilotd "$WORK"/benchpilot-mcp
    raco distribute "$WORK/dist" \
      "$WORK/benchpilot" "$WORK/benchpilotd" "$WORK/benchpilot-mcp"
    mkdir -p "$DEST"
    cp -R "$WORK/dist/." "$DEST/"
    ;;
esac

echo "distribution for $RID staged at $DEST"
