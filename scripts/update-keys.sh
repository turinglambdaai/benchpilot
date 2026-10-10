#!/usr/bin/env bash
# Generate the Ed25519 keypair used to sign update manifests (the family
# updater contract; see taskly's scripts/update-keys.sh).
#
#   scripts/update-keys.sh [private-key-path]
#
# Default private key location: ~/.benchpilot/update-signing-key.pem —
# OUTSIDE the repository. The public key is printed base64 twice: raw 32
# bytes for embedding in studio/macos-host/.../UpdateService.swift, and
# SubjectPublicKeyInfo DER for studio/app/updater.rkt. After generating,
# store the private key in the Sync/Keys vault ([benchpilot]
# UPDATE_ED25519_PRIVATE_KEY_B64) and delete the file.
#
# One-time: also put the PEM into the GitHub secret
# UPDATE_ED25519_PRIVATE_KEY so the release workflow can sign manifests.
set -euo pipefail

KEY_PATH="${1:-$HOME/.benchpilot/update-signing-key.pem}"

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

if [[ -f "$KEY_PATH" ]]; then
  echo "Private key already exists: $KEY_PATH" >&2
  echo "Delete it first if you really want to rotate (rotating requires a" >&2
  echo "public-key rollout release)." >&2
  exit 1
fi

mkdir -p "$(dirname "$KEY_PATH")"
umask 077
"$OPENSSL_BIN" genpkey -algorithm ed25519 -out "$KEY_PATH"

PUB_B64="$("$OPENSSL_BIN" pkey -in "$KEY_PATH" -pubout -outform DER 2>/dev/null | tail -c 32 | base64)"
PUB_SPKI_B64="$("$OPENSSL_BIN" pkey -in "$KEY_PATH" -pubout -outform DER 2>/dev/null | base64 | tr -d '\n')"

echo "Private key: $KEY_PATH  (back this up in the Sync/Keys vault; put the"
echo "             PEM in the GitHub secret UPDATE_ED25519_PRIVATE_KEY)"
echo "Public key (base64, raw 32 bytes — embed in UpdateService.swift): $PUB_B64"
echo "Public key (base64, SubjectPublicKeyInfo DER — embed in updater.rkt): $PUB_SPKI_B64"
