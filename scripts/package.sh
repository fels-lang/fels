#!/bin/sh
# scripts/package.sh - build + bundle a relocatable fels release archive for Linux.
#
# Produces  dist/fels-<version>-x86_64-linux.tar.gz  laid out as:
#   fels-<version>-x86_64-linux/
#     bin/   fels, ld.lld (the linker Linux programs are linked with)
#     lib/   std/...
#     LICENSE-*.txt, NOTICE, README.md, VERSION.txt, install.sh
# which fels finds with no flags: std via ../lib, the linker beside fels. LLVM is linked into
# fels; it needs the system's C++ runtime (libstdc++.so.6), zlib and zstd, which every
# desktop and server distribution has.
#
# Also  dist/fels-bindgen-<version>-x86_64-linux.tar.gz : a `bindgen/` folder with libclang
# and the clang headers, to drop into bin/ for `fels bindgen`.
#
# Usage:  scripts/package.sh <llvm-dir> [version] [optimize]
set -eu

llvm="${1:?usage: scripts/package.sh <llvm-dir> [version] [optimize]}"
version="${2:-}"
optimize="${3:-ReleaseSafe}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
out="$repo/dist"
cd "$repo"

# 1. Build the compiler. The CPU is pinned to the x86-64-v2 baseline, as for Windows: zig
#    otherwise builds for the CPU of the build machine.
set -- build "-Dllvm-path=$llvm" "-Doptimize=$optimize" "-Dcpu=x86_64_v2"
[ -n "$version" ] && set -- "$@" "-Dversion=$version"
echo "==> zig $*"
zig "$@"

# 2. The version is whatever the binary reports. The archive name drops SemVer build
#    metadata (`+sha`).
ver="$(./zig-out/bin/fels version 2>&1 | head -n 1 | sed 's/^fels[[:space:]]*//')"
[ -n "$ver" ] || { echo "error: could not read the version from fels" >&2; exit 1; }
filever="${ver%%+*}"
name="fels-$filever-x86_64-linux"
echo "==> version: $ver  (archive: $name)"

# 3. Assemble the install layout. Both binaries go without their debug information (as the
#    Windows archive ships no .pdb); lld's is most of its 190 MB.
stage="$out/$name"
rm -rf "$stage"
mkdir -p "$stage/bin"
cp zig-out/bin/fels "$stage/bin/fels"
strip --strip-debug "$stage/bin/fels"
# lld picks the linker it is by its name: as `ld.lld` it links ELF.
cp "$llvm/bin/lld" "$stage/bin/ld.lld"
strip "$stage/bin/ld.lld"
cp -R lib "$stage/lib"
for m in LICENSE-APACHE-2.0.txt LICENSE-GPLv3.txt NOTICE README.md; do
    if [ -f "$m" ]; then cp "$m" "$stage/"; fi
done
cp scripts/install.sh "$stage/install.sh"
chmod +x "$stage/install.sh" "$stage/bin/fels" "$stage/bin/ld.lld"
echo "$ver" > "$stage/VERSION.txt"

# 4. Archive.
tar -C "$out" -czf "$out/$name.tar.gz" "$name"
echo "==> packaged: $out/$name.tar.gz ($(du -h "$out/$name.tar.gz" | cut -f1))"

# 5. The optional bindgen component: libclang and the clang resource headers.
libclang="$(ls "$llvm"/lib/libclang.so.[0-9]* 2>/dev/null | sort -V | tail -n 1 || true)"
if [ -n "$libclang" ]; then
    bg="$out/bindgen-stage/bindgen"
    rm -rf "$out/bindgen-stage"
    mkdir -p "$bg"
    cp "$libclang" "$bg/libclang.so"
    strip "$bg/libclang.so"
    res="$(ls -d "$llvm"/lib/clang/[0-9]* 2>/dev/null | sort -V | tail -n 1 || true)"
    if [ -n "$res" ]; then cp -R "$res/include" "$bg/clang-headers"; fi
    cat > "$bg/README.txt" <<EOF
fels bindgen component (libclang $ver).

Extract the 'bindgen' folder into the directory that contains fels (fels's bin/).
Then C-header binding generation is available:

    fels bindgen <header.h> [-o out.fels]

fels finds libclang here on demand; the core compiler never loads it.
EOF
    tar -C "$out/bindgen-stage" -czf "$out/fels-bindgen-$filever-x86_64-linux.tar.gz" bindgen
    echo "==> bindgen component: $out/fels-bindgen-$filever-x86_64-linux.tar.gz"
else
    echo "  (no libclang.so in $llvm/lib - skipping the bindgen component)"
fi

# For the release workflow: the archives it uploads.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "archive=$out/$name.tar.gz"
        echo "file_version=$filever"
        if [ -n "$libclang" ]; then echo "bindgen_archive=$out/fels-bindgen-$filever-x86_64-linux.tar.gz"; fi
    } >> "$GITHUB_OUTPUT"
fi
