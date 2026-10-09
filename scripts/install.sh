#!/usr/bin/env bash
# BenchPilot installer.
#
# Downloads the latest release archive for this platform, verifies it against
# the release SHA256SUMS manifest, and installs the three executables into
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
# Family manifest name is SHA256SUMS; releases older than the rename ship
# SHA256SUMS.txt — accept both so the installer works across the transition.
SUMS=SHA256SUMS
fetch "$BASE/$SUMS" "$TMP/$SUMS" || { SUMS=SHA256SUMS.txt; fetch "$BASE/$SUMS" "$TMP/$SUMS"; }

(
  cd "$TMP"
  sha256sum --ignore-missing -c "$SUMS"
)

# Unix archives are a full distribution tree (bin/ + lib/); it installs to
# lib/benchpilot/<version> and bin/ gets thin wrappers so the packaged
# runtime keeps resolving relative to the real launchers.
DIST="$PREFIX/lib/benchpilot/$VER"
mkdir -p "$DIST" "$PREFIX/bin"
tar -xzf "$TMP/$ARCHIVE" -C "$DIST" --strip-components=1
for name in benchpilot benchpilotd benchpilot-mcp; do
  chmod +x "$DIST/bin/$name"
  cat > "$PREFIX/bin/$name" <<WRAPPER
#!/bin/sh
# benchpilot wrapper
exec "$DIST/bin/$name" "\$@"
WRAPPER
  chmod +x "$PREFIX/bin/$name"
done

log "installed $VER ($RID) into $DIST"
BIN="$PREFIX/bin"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *)
    log "add to PATH, e.g.:  echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.$(basename "${SHELL:-bash}")"
    ;;
esac
log "next: benchpilot doctor && benchpilot daemon start"
