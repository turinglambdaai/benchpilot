#!/usr/bin/env bash
# Generates distribution manifests for a BenchPilot release from its
# SHA256SUMS: a Homebrew formula (benchpilot.rb) and a scoop manifest
# (benchpilot.scoop.json). Run in the release job after checksum generation.
#
# Usage: gen-dist-manifests.sh <version> <artifacts-dir>
set -euo pipefail

ver="${1:?usage: gen-dist-manifests.sh <version> <artifacts-dir>}"
dir="${2:-artifacts}"
cd "$dir"

# Tolerate both `<hash>  file` (Linux sha256sum) and `<hash> *file` (Git Bash
# binary mode), and strip any CR from CRLF-generated manifests.
hash_of() { awk -v f="$1" '{ sub(/^\*/, "", $2); sub(/\r$/, "", $2) } $2 == f { print $1; exit }' SHA256SUMS; }

mac_arm="$(hash_of "benchpilot-$ver-osx-arm64.tar.gz")"
mac_x64="$(hash_of "benchpilot-$ver-osx-x64.tar.gz")"
lin_arm="$(hash_of "benchpilot-$ver-linux-arm64.tar.gz")"
lin_x64="$(hash_of "benchpilot-$ver-linux-x64.tar.gz")"
win_x64="$(hash_of "benchpilot-$ver-win-x64.zip")"

missing=0
for v in "$mac_arm" "$mac_x64" "$lin_arm" "$lin_x64" "$win_x64"; do
  [ -n "$v" ] || { echo "SHA256SUMS has no entry for one of the release archives" >&2; missing=1; }
done
[ "$missing" -eq 0 ] || exit 1

base="https://github.com/turinglambdaai/benchpilot/releases/download/v$ver"

cat > benchpilot.rb <<EOF
class Benchpilot < Formula
  desc "ECU bench runtime for agents: power, flash, serial, UDS over CAN/DoIP"
  homepage "https://github.com/turinglambdaai/benchpilot"
  version "$ver"
  license "AGPL-3.0"

  if OS.mac? && Hardware::CPU.arm?
    url "$base/benchpilot-$ver-osx-arm64.tar.gz"
    sha256 "$mac_arm"
  elsif OS.mac?
    url "$base/benchpilot-$ver-osx-x64.tar.gz"
    sha256 "$mac_x64"
  elsif Hardware::CPU.arm?
    url "$base/benchpilot-$ver-linux-arm64.tar.gz"
    sha256 "$lin_arm"
  else
    url "$base/benchpilot-$ver-linux-x64.tar.gz"
    sha256 "$lin_x64"
  end

  def rid
    if OS.mac?
      Hardware::CPU.arm? ? "osx-arm64" : "osx-x64"
    else
      Hardware::CPU.arm? ? "linux-arm64" : "linux-x64"
    end
  end

  def install
    # The archive is a full distribution tree (bin/ + lib/). It installs to
    # libexec and bin gets thin wrappers so the packaged runtime keeps
    # resolving relative to the real launchers.
    %w[benchpilot benchpilotd benchpilot-mcp].each do |exe|
      chmod 0755, "benchpilot-#{version}-#{rid}/bin/#{exe}"
      (libexec/"bin").install "benchpilot-#{version}-#{rid}/bin/#{exe}"
      (bin/exe).write <<~WRAPPER
        #!/bin/sh
        # benchpilot wrapper
        exec "#{libexec}/bin/#{exe}" "$@"
      WRAPPER
    end
    (libexec/"lib").install Dir["benchpilot-#{version}-#{rid}/lib/*"]
  end

  def caveats
    <<~EOS
      The resident runtime (benchpilotd) is started on demand by the CLI.
      After installing, run: benchpilot doctor
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/benchpilot --version")
  end
end
EOF

cat > benchpilot.scoop.json <<EOF
{
  "version": "$ver",
  "architecture": {
    "64bit": {
      "url": "$base/benchpilot-$ver-win-x64.zip",
      "hash": "$win_x64",
      "extract_dir": "benchpilot-$ver-win-x64"
    }
  },
  "bin": ["benchpilot.exe", "benchpilotd.exe", "benchpilot-mcp.exe"],
  "checkver": "github",
  "autoupdate": {
    "architecture": {
      "64bit": {
        "url": "https://github.com/turinglambdaai/benchpilot/releases/download/v\$version/benchpilot-\$version-win-x64.zip",
        "extract_dir": "benchpilot-\$version-win-x64"
      }
    }
  }
}
EOF

echo "generated benchpilot.rb and benchpilot.scoop.json for $ver"
