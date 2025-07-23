# scripts/package.ps1 - build + bundle a relocatable k2 release archive.
#
# Produces  dist/k2-<version>-x86_64-windows.zip  laid out as:
#   k2-<version>-x86_64-windows/
#     bin/   k2.exe, LLVM-C.dll, lld-link.exe, ld.lld.exe
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

# 2. The version is whatever the binary reports - the single source of truth.
# (`k2 version` prints to stderr; route through cmd so PowerShell doesn't treat
# native stderr as a terminating error under ErrorActionPreference=Stop.)
$k2exe = Join-Path $repo "zig-out/bin/k2.exe"
$reported = (& cmd /c "`"$k2exe`" version 2>&1") | Select-Object -First 1
$ver = ($reported -replace '^k2\s+', '').Trim()
if (-not $ver) { throw "could not read version from k2.exe" }
# The archive filename drops SemVer build metadata (`+sha`) - the tag/version
# already identifies it, and `+` is awkward in URLs. `k2 version` keeps the sha.
$fileVer = ($ver -replace '\+.*$', '')
$name = "k2-$fileVer-x86_64-windows"
Write-Host "==> version: $ver  (archive: $name)"

# 3. Assemble the install layout.
$stage = Join-Path $OutDir $name
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force (Join-Path $stage "bin") | Out-Null

Copy-Item (Join-Path $repo "zig-out/bin/k2.exe") (Join-Path $stage "bin")

# Required runtime deps; ld.lld (Linux cross-link) optional. libclang is NOT
# here - k2 loads it on demand only for `k2 bindgen`, so it ships as the separate
# bindgen component below (keeps the core archive ~81 MB lighter).
$required = @("LLVM-C.dll", "lld-link.exe")
$optional = @("ld.lld.exe")
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
# The platform installer (adds bin/ to PATH, sets K2_HOME). Each OS's archive
# carries its own: install.ps1 here; install.sh ships with the Linux/macOS archive.
Copy-Item (Join-Path $repo "scripts/install.ps1") $stage
$ver | Out-File -Encoding ascii (Join-Path $stage "VERSION.txt")

# 4. Zip.
$zip = Join-Path $OutDir "$name.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $stage -DestinationPath $zip
$size = "{0:N1} MB" -f ((Get-Item $zip).Length / 1MB)
Write-Host "==> packaged: $zip  ($size)"

# 5. Optional bindgen component - libclang + the clang resource headers, as a
# `bindgen/` folder you drop next to k2.exe (in bin/) to enable `k2 bindgen`.
# Kept out of the core archive so the 81 MB libclang only ships if you want it.
$bgZip = ""
$libclang = Join-Path $LlvmPath "bin/libclang.dll"
if (Test-Path $libclang) {
    $bgRoot = Join-Path $OutDir "bindgen-stage"
    $bgDir = Join-Path $bgRoot "bindgen"
    if (Test-Path $bgRoot) { Remove-Item -Recurse -Force $bgRoot }
    New-Item -ItemType Directory -Force $bgDir | Out-Null
    Copy-Item $libclang $bgDir
    # clang resource headers: <llvm>/lib/clang/<highest>/include -> bindgen/clang-headers
    $res = Get-ChildItem (Join-Path $LlvmPath "lib/clang") -Directory -ErrorAction SilentlyContinue |
        Sort-Object { [int]($_.Name) } -Descending | Select-Object -First 1
    if ($res) { Copy-Item -Recurse (Join-Path $res.FullName "include") (Join-Path $bgDir "clang-headers") }
    @"
k2 bindgen component (libclang $ver).

Extract the 'bindgen' folder into the directory that contains k2.exe (k2's bin/).
Then C-header binding generation is available:

    k2 bindgen <header.h> [-o out.k2]

k2 finds libclang here on demand; the core compiler never loads it.
"@ | Out-File -Encoding ascii (Join-Path $bgDir "README.txt")
    $bgZip = Join-Path $OutDir "k2-bindgen-$fileVer-x86_64-windows.zip"
    if (Test-Path $bgZip) { Remove-Item -Force $bgZip }
    Compress-Archive -Path $bgDir -DestinationPath $bgZip
    $bgSize = "{0:N1} MB" -f ((Get-Item $bgZip).Length / 1MB)
    Write-Host "==> bindgen component: $bgZip  ($bgSize)"
} else {
    Write-Host "  (no libclang.dll in $LlvmPath/bin - skipping bindgen component)"
}

# 6. Emit outputs for CI.
if ($env:GITHUB_OUTPUT) {
    "archive=$zip"     | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
    "archive_name=$name.zip" | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
    "version=$ver"     | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
    "file_version=$fileVer" | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
    if ($bgZip) {
        "bindgen_archive=$bgZip" | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
        "bindgen_archive_name=k2-bindgen-$fileVer-x86_64-windows.zip" | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
    }
}
