# scripts/package.ps1 - build + bundle a relocatable fels release archive.
#
# Produces  dist/fels-<version>-x86_64-windows.zip  laid out as:
#   fels-<version>-x86_64-windows/
#     bin/   fels.exe, LLVM-C.dll, felslld.dll (in-process linker)
#     lib/   std/...
#     LICENSE-*.txt, NOTICE, README.md, VERSION.txt
# which the relocatable runtime (Phase 0) finds with no flags: std via ../lib,
# the linker beside fels.exe, the DLLs via the OS loader.
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
# Resolve a relative output dir against the repo, not the caller's cwd — so the
# script works run from anywhere (e.g. C:\Windows\System32), not only repo root.
if (-not [System.IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $repo $OutDir }

# 1. Build the compiler (release), injecting the version when given.
# -Din-process-lld builds felslld.dll (the LLD fallback) so the release never spawns
# a 69 MB lld-link.exe. -Dembed-linker bakes the self-hosted felsld INTO fels.exe, so
# the common link path needs no separate felsld.dll (single-binary linker).
# The target is pinned to the baseline x86-64-v2 (SSE4.2) CPU. Without it zig builds for the CPU of
# the build machine, and 0.2.0 shipped with AVX-512 code that crashed ("illegal instruction",
# 0xC000001D) on CPUs without it.
$buildArgs = @("build", "-Dllvm-path=$LlvmPath", "-Doptimize=$Optimize", "-Dcpu=x86_64_v2", "-Din-process-lld", "-Dembed-linker")
if ($Version) { $buildArgs += "-Dversion=$Version" }
Write-Host "==> zig $($buildArgs -join ' ')"
Push-Location $repo
try { & zig @buildArgs; if ($LASTEXITCODE -ne 0) { throw "zig build failed ($LASTEXITCODE)" } }
finally { Pop-Location }
# felsld is embedded in fels.exe by -Dembed-linker above — no separate felsld.dll.

# 2. The version is whatever the binary reports - the single source of truth.
# (`fels version` prints to stderr; route through cmd so PowerShell doesn't treat
# native stderr as a terminating error under ErrorActionPreference=Stop.)
$felsexe = Join-Path $repo "zig-out/bin/fels.exe"
$reported = (& cmd /c "`"$felsexe`" version 2>&1") | Select-Object -First 1
$ver = ($reported -replace '^fels\s+', '').Trim()
if (-not $ver) { throw "could not read version from fels.exe" }
# The archive filename drops SemVer build metadata (`+sha`) - the tag/version
# already identifies it, and `+` is awkward in URLs. `fels version` keeps the sha.
$fileVer = ($ver -replace '\+.*$', '')
$name = "fels-$fileVer-x86_64-windows"
Write-Host "==> version: $ver  (archive: $name)"

# 3. Assemble the install layout.
$stage = Join-Path $OutDir $name
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force (Join-Path $stage "bin") | Out-Null

Copy-Item (Join-Path $repo "zig-out/bin/fels.exe") (Join-Path $stage "bin")

# In-process linker: felslld.dll (built above) replaces a spawned 69 MB lld-link.exe.
# fels LoadLibrary's it at link time; no standalone linker exe in the core.
$felslld = Join-Path $repo "zig-out/bin/felslld.dll"
if (-not (Test-Path $felslld)) { throw "felslld.dll missing - build must use -Din-process-lld" }
Copy-Item $felslld (Join-Path $stage "bin")
# (felsld is baked into fels.exe via -Dembed-linker — nothing to copy.)

# LLVM-C.dll (codegen) is the only LLVM DLL the core needs. libclang (bindgen)
# and ld.lld.exe (Linux cross-link) are separate opt-in components below.
$llvmc = Join-Path $LlvmPath "bin/LLVM-C.dll"
if (-not (Test-Path $llvmc)) { throw "required dependency not found: $llvmc" }
Copy-Item $llvmc (Join-Path $stage "bin")

Copy-Item -Recurse (Join-Path $repo "lib") (Join-Path $stage "lib")
foreach ($m in @("LICENSE-APACHE-2.0.txt", "LICENSE-GPLv3.txt", "LICENSE-LLVM.txt", "NOTICE", "README.md")) {
    if (Test-Path (Join-Path $repo $m)) { Copy-Item (Join-Path $repo $m) $stage }
}
# The platform installer (adds bin/ to PATH, sets FELS_HOME). Each OS's archive
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
# `bindgen/` folder you drop next to fels.exe (in bin/) to enable `fels bindgen`.
# Kept out of the core archive so the 81 MB libclang only ships if you want it.
$bgZip = ""
$libclang = Join-Path $LlvmPath "bin/libclang.dll"
if (Test-Path $libclang) {
    $bgRoot = Join-Path $OutDir "bindgen-stage"
    $bgDir = Join-Path $bgRoot "bindgen"
    if (Test-Path $bgRoot) { Remove-Item -Recurse -Force $bgRoot }
    New-Item -ItemType Directory -Force $bgDir | Out-Null
    Copy-Item $libclang $bgDir
    Copy-Item (Join-Path $repo "LICENSE-LLVM.txt") $bgDir
    # clang resource headers: <llvm>/lib/clang/<highest>/include -> bindgen/clang-headers
    $res = Get-ChildItem (Join-Path $LlvmPath "lib/clang") -Directory -ErrorAction SilentlyContinue |
        Sort-Object { [int]($_.Name) } -Descending | Select-Object -First 1
    if ($res) { Copy-Item -Recurse (Join-Path $res.FullName "include") (Join-Path $bgDir "clang-headers") }
    @"
fels bindgen component (libclang $ver).

Extract the 'bindgen' folder into the directory that contains fels.exe (fels's bin/).
Then C-header binding generation is available:

    fels bindgen <header.h> [-o out.fels]

fels finds libclang here on demand; the core compiler never loads it.
"@ | Out-File -Encoding ascii (Join-Path $bgDir "README.txt")
    $bgZip = Join-Path $OutDir "fels-bindgen-$fileVer-x86_64-windows.zip"
    if (Test-Path $bgZip) { Remove-Item -Force $bgZip }
    Compress-Archive -Path $bgDir -DestinationPath $bgZip
    $bgSize = "{0:N1} MB" -f ((Get-Item $bgZip).Length / 1MB)
    Write-Host "==> bindgen component: $bgZip  ($bgSize)"
} else {
    Write-Host "  (no libclang.dll in $LlvmPath/bin - skipping bindgen component)"
}

# 5b. Optional linux cross-compile component - ld.lld (the ELF linker for
# `fels build --target linux`). Windows linking is in-process (felslld.dll); only
# cross-compiling to Linux needs this, so it ships separately. Drop ld.lld.exe
# into bin/ next to fels.exe; the runtime resolves it there (LLVM-C.dll marker).
$xZip = ""
$ldlld = Join-Path $LlvmPath "bin/ld.lld.exe"
if (Test-Path $ldlld) {
    $xRoot = Join-Path $OutDir "linux-cross-stage"
    if (Test-Path $xRoot) { Remove-Item -Recurse -Force $xRoot }
    New-Item -ItemType Directory -Force $xRoot | Out-Null
    Copy-Item $ldlld $xRoot
    Copy-Item (Join-Path $repo "LICENSE-LLVM.txt") $xRoot
    @"
fels linux cross-compile component (ld.lld).

Put ld.lld.exe into fels's bin/ (next to fels.exe). Then you can cross-compile to
Linux from Windows:

    fels build <file.fels> --target linux              # static, no-libc ELF
    fels build <file.fels> --target linux-gnu --sysroot <dir>   # glibc ELF
"@ | Out-File -Encoding ascii (Join-Path $xRoot "README.txt")
    $xZip = Join-Path $OutDir "fels-linux-cross-$fileVer-x86_64-windows.zip"
    if (Test-Path $xZip) { Remove-Item -Force $xZip }
    Compress-Archive -Path (Join-Path $xRoot "*") -DestinationPath $xZip
    Write-Host ("==> linux-cross component: $xZip  ({0:N1} MB)" -f ((Get-Item $xZip).Length / 1MB))
}

# 6. Emit outputs for CI.
if ($env:GITHUB_OUTPUT) {
    "archive=$zip"     | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
    "archive_name=$name.zip" | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
    "version=$ver"     | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
    "file_version=$fileVer" | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
    if ($bgZip) {
        "bindgen_archive=$bgZip" | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
        "bindgen_archive_name=fels-bindgen-$fileVer-x86_64-windows.zip" | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
    }
    if ($xZip) {
        "linux_cross_archive=$xZip" | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
        "linux_cross_archive_name=fels-linux-cross-$fileVer-x86_64-windows.zip" | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
    }
}
