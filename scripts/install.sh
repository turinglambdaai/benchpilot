#!/usr/bin/env bash
# BenchPilot installer.
#
# Downloads the latest release archive for this platform, verifies it against
# the release SHA256SUMS.txt, and installs the three executables into
# ~/.benchpilot/bin. Idempotent: re-running upgrades in place.
#
# Usage:  curl -fsSL <raw-install.sh-url> | bash
# Env:    BENCHPILOT_REPO    GitHub repository (default turinglambdaai/benchpilot)
#         BENCHPILOT_PREFIX  install root (default ~/.benchpilot)
set -euo pipefail

REPO="${BENCHPILOT_REPO:-turinglambdaai/benchpilot}"
PREFIX="${BENCHPILOT_PREFIX:-$HOME/.benchpilot}"

log() { printf 'benchpilot-install: %s\n' "$*"; }
fail() { printf 'benchpilot-install: error: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"; }
need uname
need tar
need sha256sum
if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL -o "$2" "$1"; }
  fetch_stdout() { curl -fsSL "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -qO "$2" "$1"; }
  fetch_stdout() { wget -qO - "$1"; }
else
  fail "need curl or wget"
fi

case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) RID=osx-arm64 ;;
  Darwin/x86_64) RID=osx-x64 ;;
  Linux/aarch64 | Linux/arm64) RID=linux-arm64 ;;
  Linux/x86_64) RID=linux-x64 ;;
  *) fail "unsupported platform: $(uname -s)/$(uname -m)" ;;
esac

API="https://api.github.com/repos/$REPO/releases/latest"
log "resolving latest release from $REPO"
VER="$(fetch_stdout "$API" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
[ -n "$VER" ] || fail "could not determine the latest release tag"

BASE="https://github.com/$REPO/releases/download/$VER"
ARCHIVE="benchpilot-$VER-$RID.tar.gz"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
log "downloading $ARCHIVE"
fetch "$BASE/$ARCHIVE" "$TMP/$ARCHIVE"
fetch "$BASE/SHA256SUMS.txt" "$TMP/SHA256SUMS.txt"

(
  cd "$TMP"
  sha256sum --ignore-missing -c SHA256SUMS.txt
)

BIN="$PREFIX/bin"
mkdir -p "$BIN"
tar -xzf "$TMP/$ARCHIVE" -C "$BIN" --strip-components=1
chmod +x "$BIN/benchpilot" "$BIN/benchpilotd" "$BIN/benchpilot-mcp"

log "installed $VER ($RID) into $BIN"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *)
    log "add to PATH, e.g.:  echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.$(basename "${SHELL:-bash}")"
    ;;
esac
log "next: benchpilot doctor && benchpilot daemon start"
