# install.ps1 — install fels from an extracted release archive (Windows).
#
# Run from inside the extracted archive (this script sits next to bin/ and lib/):
#   .\install.ps1                      # → %LOCALAPPDATA%\fels, adds bin to PATH
#   .\install.ps1 -Prefix D:\tools\fels  # custom location
#   .\install.ps1 -NoPath              # copy only, don't touch PATH
#
# fels finds its standard library + linker relative to fels.exe, so the whole install
# is just `bin/` + `lib/` kept together. We also set FELS_HOME as a robust fallback.
[CmdletBinding()]
param(
    [string] $Prefix = (Join-Path $env:LOCALAPPDATA "fels"),
    [switch] $NoPath
)
$ErrorActionPreference = "Stop"
$src = $PSScriptRoot

if (-not (Test-Path (Join-Path $src "bin/fels.exe"))) {
    throw "run this from inside the extracted fels archive (no bin/fels.exe next to install.ps1)"
}

# 1. Copy the layout to $Prefix (replacing any prior install).
Write-Host "Installing fels -> $Prefix"
foreach ($d in @("bin", "lib")) {
    $dst = Join-Path $Prefix $d
    if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
}
New-Item -ItemType Directory -Force $Prefix | Out-Null
Copy-Item -Recurse -Force (Join-Path $src "bin") (Join-Path $Prefix "bin")
Copy-Item -Recurse -Force (Join-Path $src "lib") (Join-Path $Prefix "lib")
foreach ($m in @("LICENSE-APACHE-2.0.txt", "LICENSE-GPLv3.txt", "NOTICE", "README.md", "VERSION.txt")) {
    if (Test-Path (Join-Path $src $m)) { Copy-Item -Force (Join-Path $src $m) $Prefix }
}

# 2. PATH + FELS_HOME (user scope; idempotent).
$bin = Join-Path $Prefix "bin"
if (-not $NoPath) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (($userPath -split ';') -notcontains $bin) {
        [Environment]::SetEnvironmentVariable("Path", "$bin;$userPath", "User")
        Write-Host "Added $bin to your user PATH."
    } else {
        Write-Host "$bin already on PATH."
    }
    [Environment]::SetEnvironmentVariable("FELS_HOME", $Prefix, "User")
}

$ver = if (Test-Path (Join-Path $Prefix "VERSION.txt")) { (Get-Content (Join-Path $Prefix "VERSION.txt") -First 1) } else { "" }
Write-Host ""
Write-Host "fels $ver installed. Open a NEW terminal, then:  fels version"
