# BenchPilot installer for Windows.
#
# Downloads the latest release zip for win-x64 (or win-arm64), verifies it
# against the release SHA256SUMS manifest, and installs the three executables into
# ~\.benchpilot\bin. Idempotent: re-running upgrades in place.
#
# Usage:  irm <raw-install.ps1-url> | iex
# Env:    BENCHPILOT_REPO    GitHub repository (default turinglambdaai/benchpilot)
#         BENCHPILOT_PREFIX  install root (default $HOME\.benchpilot)
$ErrorActionPreference = "Stop"

$Repo = if ($env:BENCHPILOT_REPO) { $env:BENCHPILOT_REPO } else { "turinglambdaai/benchpilot" }
$Prefix = if ($env:BENCHPILOT_PREFIX) { $env:BENCHPILOT_PREFIX } else { Join-Path $HOME ".benchpilot" }
$Rid = if ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq "Arm64") { "win-arm64" } else { "win-x64" }

function Fail([string]$Message) { throw "benchpilot-install: $Message" }

$Api = "https://api.github.com/repos/$Repo/releases/latest"
Write-Host "benchpilot-install: resolving latest release from $Repo"
try {
    $Latest = Invoke-RestMethod -Uri $Api -Headers @{ "User-Agent" = "benchpilot-install" }
} catch {
    Fail "could not query the latest release: $_"
}
$Version = $Latest.tag_name
if (-not $Version) { Fail "could not determine the latest release tag" }

$Base = "https://github.com/$Repo/releases/download/$Version"
$Archive = "benchpilot-$Version-$Rid.zip"
$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("benchpilot-install-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $Tmp -Force | Out-Null
try {
    Write-Host "benchpilot-install: downloading $Archive"
    Invoke-WebRequest -Uri "$Base/$Archive" -OutFile (Join-Path $Tmp $Archive) -UseBasicParsing
    # Family manifest name is SHA256SUMS; releases older than the rename
    # ship SHA256SUMS.txt — accept both across the transition.
    $Sums = "SHA256SUMS"
    try {
        Invoke-WebRequest -Uri "$Base/$Sums" -OutFile (Join-Path $Tmp $Sums) -UseBasicParsing
    } catch {
        $Sums = "SHA256SUMS.txt"
        Invoke-WebRequest -Uri "$Base/$Sums" -OutFile (Join-Path $Tmp $Sums) -UseBasicParsing
    }

    $expected = (Get-Content (Join-Path $Tmp $Sums)) |
        Where-Object { $_ -match [regex]::Escape($Archive) } |
        ForEach-Object { ($_ -split '\s+', 2)[0] } | Select-Object -First 1
    if (-not $expected) { Fail "SHA256SUMS has no entry for $Archive" }
    $actual = (Get-FileHash (Join-Path $Tmp $Archive) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected.ToLowerInvariant()) { Fail "SHA256 mismatch for $Archive" }

    $Bin = Join-Path $Prefix "bin"
    New-Item -ItemType Directory -Path $Bin -Force | Out-Null
    Expand-Archive -Path (Join-Path $Tmp $Archive) -DestinationPath $Tmp -Force
    foreach ($exe in @("benchpilot.exe", "benchpilotd.exe", "benchpilot-mcp.exe")) {
        Copy-Item (Join-Path $Tmp "benchpilot-$Version-$Rid\$exe") (Join-Path $Bin $exe) -Force
    }

    Write-Host "benchpilot-install: installed $Version ($Rid) into $Bin"
    if (($env:Path -split ";") -notcontains $Bin) {
        Write-Host "benchpilot-install: add to PATH, e.g.:"
        Write-Host "  [Environment]::SetEnvironmentVariable('Path', `"$Bin;`$env:Path`", 'User')"
    }
    Write-Host "benchpilot-install: next: benchpilot doctor && benchpilot daemon start"
} finally {
    Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}
