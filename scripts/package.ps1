# scripts/package.ps1 — build + bundle a relocatable k2 release archive.
#
# Produces  dist/k2-<version>-x86_64-windows.zip  laid out as:
#   k2-<version>-x86_64-windows/
#     bin/   k2.exe, LLVM-C.dll, lld-link.exe, ld.lld.exe, [libclang.dll]
#     lib/   std/...
#     LICENSE-*.txt, NOTICE, README.md, VERSION.txt
# which the relocatable runtime (Phase 0) finds with no flags: std via ../lib,
# the linker beside k2.exe, the DLLs via the OS loader.
#
# Usage:  pwsh scripts/package.ps1 -LlvmPath <llvm-dir> [-Version 0.1.0-beta.1] [-Optimize ReleaseSafe]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $LlvmPath,   # LLVM dir (with bin/, lib/, include/)
    [string] $Version = "",                              # override; else build.zig.zon (+git sha)
    [string] $OutDir = "dist",
    [string] $Optimize = "ReleaseSafe"
)
$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

# 1. Build the compiler (release), injecting the version when given.
$buildArgs = @("build", "-Dllvm-path=$LlvmPath", "-Doptimize=$Optimize")
if ($Version) { $buildArgs += "-Dversion=$Version" }
Write-Host "==> zig $($buildArgs -join ' ')"
Push-Location $repo
try { & zig @buildArgs; if ($LASTEXITCODE -ne 0) { throw "zig build failed ($LASTEXITCODE)" } }
finally { Pop-Location }

# 2. The version is whatever the binary reports — the single source of truth.
# (`k2 version` prints to stderr; route through cmd so PowerShell doesn't treat
# native stderr as a terminating error under ErrorActionPreference=Stop.)
$k2exe = Join-Path $repo "zig-out/bin/k2.exe"
$reported = (& cmd /c "`"$k2exe`" version 2>&1") | Select-Object -First 1
$ver = ($reported -replace '^k2\s+', '').Trim()
if (-not $ver) { throw "could not read version from k2.exe" }
# The archive filename drops SemVer build metadata (`+sha`) — the tag/version
# already identifies it, and `+` is awkward in URLs. `k2 version` keeps the sha.
$fileVer = ($ver -replace '\+.*$', '')
$name = "k2-$fileVer-x86_64-windows"
Write-Host "==> version: $ver  (archive: $name)"

# 3. Assemble the install layout.
$stage = Join-Path $OutDir $name
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force (Join-Path $stage "bin") | Out-Null

Copy-Item (Join-Path $repo "zig-out/bin/k2.exe") (Join-Path $stage "bin")

# Required runtime deps; ld.lld (Linux cross-link) + libclang (bindgen) optional.
$required = @("LLVM-C.dll", "lld-link.exe")
$optional = @("ld.lld.exe", "libclang.dll")
foreach ($f in $required) {
    $src = Join-Path $LlvmPath "bin/$f"
    if (-not (Test-Path $src)) { throw "required dependency not found: $src" }
    Copy-Item $src (Join-Path $stage "bin")
}
foreach ($f in $optional) {
    $src = Join-Path $LlvmPath "bin/$f"
    if (Test-Path $src) { Copy-Item $src (Join-Path $stage "bin") } else { Write-Host "  (skipping optional $f)" }
}

Copy-Item -Recurse (Join-Path $repo "lib") (Join-Path $stage "lib")
foreach ($m in @("LICENSE-APACHE-2.0.txt", "LICENSE-GPLv3.txt", "NOTICE", "README.md")) {
    if (Test-Path (Join-Path $repo $m)) { Copy-Item (Join-Path $repo $m) $stage }
}
$ver | Out-File -Encoding ascii (Join-Path $stage "VERSION.txt")

# 4. Zip.
$zip = Join-Path $OutDir "$name.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $stage -DestinationPath $zip
$size = "{0:N1} MB" -f ((Get-Item $zip).Length / 1MB)
Write-Host "==> packaged: $zip  ($size)"

# 5. Emit outputs for CI.
if ($env:GITHUB_OUTPUT) {
    "archive=$zip"     | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
    "archive_name=$name.zip" | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
    "version=$ver"     | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
    "file_version=$fileVer" | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
}
