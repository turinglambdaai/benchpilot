#!/usr/bin/env bash
set -euo pipefail

# Package the three BenchPilot executables as a Debian package.
#   usage: build-deb.sh <version> [output-dir]
# Layout: /opt/benchpilot/{benchpilot,benchpilotd,benchpilot-mcp} with
# symlinks in /usr/bin so sibling-daemon resolution keeps working.

version="${1:?usage: build-deb.sh <version> [output-dir]}"
case "$version" in
  *[!0-9.]*) version="0.0.0" ;;   # manual workflow_dispatch runs without a tag
esac
out_dir="${2:-artifacts}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$root/build/deb-linux"
pkg="$work/pkg"

rm -rf "$work"
mkdir -p "$work/publish" "$pkg/DEBIAN" "$pkg/opt/benchpilot" "$pkg/usr/bin" "$root/$out_dir"

cd "$root"
for project in Benchpilot.RuntimeHost Benchpilot.Cli Benchpilot.Mcp; do
  dotnet publish "src/$project" \
    -c Release -r linux-x64 \
    --self-contained true \
    -p:PublishSingleFile=true \
    -p:IncludeNativeLibrariesForSelfExtract=true \
    -p:DebugType=None \
    -p:DebugSymbols=false \
    -p:Version="$version" \
    -o "$work/publish"
done

for exe in benchpilot benchpilotd benchpilot-mcp; do
  test -f "$work/publish/$exe"
  install -m 0755 "$work/publish/$exe" "$pkg/opt/benchpilot/$exe"
  ln -s "/opt/benchpilot/$exe" "$pkg/usr/bin/$exe"
done

cat > "$pkg/DEBIAN/control" <<EOF
Package: benchpilot
Version: ${version}
Section: utils
Priority: optional
Architecture: amd64
Maintainer: turinglambdaai
Homepage: https://benchpilot.jrtx.site/
Depends: libicu72 | libicu74 | libicu76
Description: ECU bench runtime for coding agents
 BenchPilot drives serial, J-Link, power and vehicle networking from one
 resident daemon: power, flash, serial observation and UDS diagnostics
 (ISO-TP over CAN, DoIP). Built for coding agents and CI.
EOF

deb="$root/$out_dir/benchpilot-${version}-linux-x64.deb"
dpkg-deb --build --root-owner-group "$pkg" "$deb"
dpkg-deb --info "$deb" >/dev/null
dpkg-deb --contents "$deb" | grep -q './opt/benchpilot/benchpilot$'

hash="$(sha256sum "$deb" | awk '{print $1}')"
printf '%s  %s' "$hash" "$(basename "$deb")" > "$deb.sha256"
echo "packaged: $deb"
