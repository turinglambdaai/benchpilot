#!/usr/bin/env bash
set -euo pipefail

# Package the Racket distribution as a Debian package.
#   usage: build-deb.sh <version> [output-dir]
# Layout: /opt/benchpilot holds the full distribution tree (bin/ + lib/);
# /usr/bin gets thin wrapper scripts so the packaged runtime keeps
# resolving relative to the real launchers.

version="${1:?usage: build-deb.sh <version> [output-dir]}"
case "$version" in
  *[!0-9.]*) version="0.0.0" ;;   # manual workflow_dispatch runs without a tag
esac
out_dir="${2:-artifacts}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$root/build/deb-linux"
pkg="$work/pkg"

rm -rf "$work"
mkdir -p "$work/dist" "$pkg/DEBIAN" "$pkg/opt/benchpilot" "$pkg/usr/bin" "$root/$out_dir"

cd "$root"
bash scripts/build-dist.sh "$version" linux-x64 "$work/dist"

# The tree lands under /opt/benchpilot; wrappers in /usr/bin exec the real
# launchers so their relative lib/ lookup keeps working.
for dir in bin lib; do
  mkdir -p "$pkg/opt/benchpilot/$dir"
  cp -R "$work/dist/$dir/." "$pkg/opt/benchpilot/$dir/"
done
for exe in benchpilot benchpilotd benchpilot-mcp; do
  test -f "$pkg/opt/benchpilot/bin/$exe"
  chmod 0755 "$pkg/opt/benchpilot/bin/$exe"
  cat > "$pkg/usr/bin/$exe" <<WRAPPER
#!/bin/sh
# benchpilot wrapper
exec "/opt/benchpilot/bin/$exe" "\$@"
WRAPPER
  chmod 0755 "$pkg/usr/bin/$exe"
done

cat > "$pkg/DEBIAN/control" <<EOF
Package: benchpilot
Version: ${version}
Section: utils
Priority: optional
Architecture: amd64
Maintainer: turinglambdaai
Homepage: https://benchpilot.jrtx.site/
Description: ECU bench runtime for coding agents
 BenchPilot drives serial, J-Link, power and vehicle networking from one
 resident daemon: power, flash, serial observation and UDS diagnostics
 (ISO-TP over CAN, DoIP). Built for coding agents and CI.
EOF

deb="$root/$out_dir/benchpilot-${version}-linux-x64.deb"
dpkg-deb --build --root-owner-group "$pkg" "$deb"
dpkg-deb --info "$deb" >/dev/null
# Grep -q on a pipe would SIGPIPE the tar inside dpkg-deb; materialize.
dpkg-deb --contents "$deb" > "$work/contents.txt"
grep -q './opt/benchpilot/bin/benchpilot$' "$work/contents.txt"
grep -q './opt/benchpilot/lib/' "$work/contents.txt"

hash="$(sha256sum "$deb" | awk '{print $1}')"
printf '%s  %s' "$hash" "$(basename "$deb")" > "$deb.sha256"
echo "packaged: $deb"
