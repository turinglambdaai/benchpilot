#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
TAG="${1:-}"

fail() {
  echo "release preflight: $*" >&2
  exit 1
}

[[ -n "$VERSION" ]] || fail "VERSION is empty"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || \
  fail "VERSION '$VERSION' is not a supported semantic version"

if [[ -n "$TAG" ]]; then
  TAG_VERSION="${TAG#v}"
  [[ "$TAG_VERSION" == "$VERSION" ]] || \
    fail "tag '$TAG' does not match VERSION '$VERSION'"
fi

# The Studio app manifest carries the product version on this tree.
STUDIO_VERSION="$(sed -n 's/.*(version . "\([^"]*\)").*/\1/p' "$ROOT/studio/rivet.rktd" | head -n1)"
[[ "$STUDIO_VERSION" == "$VERSION" ]] || \
  fail "studio/rivet.rktd version '$STUDIO_VERSION' does not match VERSION '$VERSION'"

# The CLI/runtime embeds the release identity (self-updater feed comparison).
grep -qF "(define benchpilot-version \"$VERSION\")" \
  "$ROOT/racket/benchpilot/protocol/local-auth.rkt" || \
  fail "racket/benchpilot/protocol/local-auth.rkt benchpilot-version does not match VERSION '$VERSION'"

# The Studio updater embeds its own release identity (signed-feed check).
grep -qF "(define app-version \"$VERSION\")" \
  "$ROOT/studio/app/updater.rkt" || \
  fail "studio/app/updater.rkt app-version does not match VERSION '$VERSION'"

echo "release preflight: version $VERSION is aligned (VERSION == studio/rivet.rktd == CLI runtime == Studio updater)"
