#!/usr/bin/env bash
# Build update-manifest.json for a Studio release and sign it (the family
# format — see taskly's scripts/make-update-manifest.sh).
#
#   scripts/make-update-manifest.sh <tag> <dist-dir> [key-path]
#
#   <tag>       release tag, e.g. v0.2.0 (must match the VERSION file)
#   <dist-dir>  directory containing the Studio release artifacts, i.e. the
#               names the release pipeline produces:
#                 benchpilot-studio-<ver>-macos-arm64.zip
#                 benchpilot-studio-<ver>-macos-x64.zip
#                 benchpilot-studio-<ver>-windows-x64.zip
#   <key-path>  Ed25519 private key PEM (default: $UPDATE_KEY_PATH, then
#               ~/.benchpilot/update-signing-key.pem)
#
# Emits <dist-dir>/update-manifest.json — a single self-contained signed
# wrapper (schema + base64 payload + signature block): the family format
# every rivet/distribution client verifies, hosts included. The Studio
# portable zips ARE the feed (the mac host swaps them in place; the
# Windows host consumes the same entries through the backend RPCs).
# Requires racket with rivet linked (the release publish job installs the
# pinned checkout) and OpenSSL 3 for the PEM → DER key conversion.
set -euo pipefail

TAG="${1:?usage: make-update-manifest.sh <tag> <dist-dir> [key-path]}"
DIST="${2:?usage: make-update-manifest.sh <tag> <dist-dir> [key-path]}"
KEY="${3:-${UPDATE_KEY_PATH:-$HOME/.benchpilot/update-signing-key.pem}}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${TAG#v}"
[[ "$VERSION" == "$(tr -d '[:space:]' < "$ROOT/VERSION")" ]] || {
  echo "error: tag $TAG does not match VERSION '$(cat "$ROOT/VERSION")'" >&2; exit 1; }

for artifact in "$DIST/benchpilot-studio-$VERSION-macos-arm64.zip" \
                "$DIST/benchpilot-studio-$VERSION-macos-x64.zip" \
                "$DIST/benchpilot-studio-$VERSION-windows-x64.zip"; do
  [[ -f "$artifact" ]] || { echo "error: missing $artifact" >&2; exit 1; }
done
[[ -f "$KEY" ]] || { echo "error: missing signing key $KEY (see scripts/update-keys.sh)" >&2; exit 1; }

BASE_URL="${RELEASE_ASSET_BASE_URL:-https://github.com/turinglambdaai/benchpilot/releases/download/$TAG}"

# Ed25519 needs OpenSSL 3+ (macOS ships LibreSSL, which cannot do it).
OPENSSL_BIN="${OPENSSL_BIN:-}"
if [[ -z "$OPENSSL_BIN" ]]; then
  for candidate in /opt/homebrew/opt/openssl@3/bin/openssl \
                   /usr/local/opt/openssl@3/bin/openssl openssl; do
    if command -v "$candidate" >/dev/null 2>&1 \
       && "$candidate" version 2>/dev/null | grep -q "OpenSSL 3"; then
      OPENSSL_BIN="$candidate"
      break
    fi
  done
fi
[[ -n "$OPENSSL_BIN" ]] || {
  echo "error: OpenSSL 3.x required for Ed25519 (brew install openssl@3," >&2
  echo "       or set OPENSSL_BIN=/path/to/openssl)" >&2
  exit 1
}

SCRIPT="$(mktemp /tmp/benchpilot-manifest-XXXXXX.rkt)"
KEY_DER="$(mktemp /tmp/benchpilot-key-XXXXXX.der)"
trap 'rm -f "$SCRIPT" "$KEY_DER"' EXIT

# rivet's signer reads DER (OneAsymmetricKey); convert the PEM once here.
"$OPENSSL_BIN" pkey -in "$KEY" -outform DER -out "$KEY_DER"

cat > "$SCRIPT" <<RKT
#lang racket/base
(require rivet/distribution
         racket/date
         racket/file
         racket/format)
(define version "$VERSION")
(define base-url "$BASE_URL")
(define dist (path->complete-path "$DIST"))
(define key-path (path->complete-path "$KEY_DER"))
(define key-id "benchpilot-2026-10")
(define build (hash-ref (file->value (build-path (path->complete-path "$ROOT") "studio" "rivet.rktd")) 'build))

(define (artifact platform architecture file installer)
  (define path (build-path dist file))
  (unless (file-exists? path)
    (error 'make-update-manifest "missing installer: ~a" path))
  (update-artifact platform architecture
                   (string-append base-url "/" file)
                   (sha256-file/hex path)
                   (file-size path)
                   installer
                   '()))

(define manifest
  (update-manifest "site.jrtx.benchpilot-studio"
                   version
                   build
                   'stable
                   ;; published-at: RFC 3339, second precision, UTC
                   (let ([d (seconds->date (current-seconds) #f)])
                     (format "~a-~a-~aT~a:~a:~aZ"
                             (date-year d)
                             (~r (date-month d) #:min-width 2 #:pad-string "0")
                             (~r (date-day d) #:min-width 2 #:pad-string "0")
                             (~r (date-hour d) #:min-width 2 #:pad-string "0")
                             (~r (date-minute d) #:min-width 2 #:pad-string "0")
                             (~r (date-second d) #:min-width 2 #:pad-string "0")))
                   "0.0.0"
                   #f
                   #t
                   100
                   (list (artifact 'macos 'arm64
                                   (format "benchpilot-studio-~a-macos-arm64.zip" version) 'zip)
                         (artifact 'macos 'x64
                                   (format "benchpilot-studio-~a-macos-x64.zip" version) 'zip)
                         (artifact 'windows 'x64
                                   (format "benchpilot-studio-~a-windows-x64.zip" version) 'zip))))

;; write-signed-manifest validates the struct against the manifest schema
;; before signing, so a malformed manifest fails the release instead of
;; shipping something every client would reject.
(call-with-output-file (build-path dist "update-manifest.json")
  #:exists 'truncate/replace
  (lambda (out)
    (write-signed-manifest manifest
                           (read-ed25519-private-key key-path)
                           key-id
                           out)
    (newline out)))
(printf "manifest: ~a (3 artifacts, key-id ~a)\\n"
        (build-path dist "update-manifest.json") key-id)
RKT

# rivet must be installed for the signer; the release publish job links a
# checkout at the release pin.
racket "$SCRIPT"
