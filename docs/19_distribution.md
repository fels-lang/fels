# Distribution, packaging, install

Small core, optional components dropped in next to the binary. The core is one
relocatable folder: `fels.exe`, `LLVM-C.dll`, `felslld.dll`, `lib/std`.

## Core dependencies

| Dependency | For | In core |
| --- | --- | --- |
| `LLVM-C.dll` | codegen | yes (~69 MB) |
| `felslld.dll` | in-process COFF linker (Windows) | yes (~65 MB) |
| `lib/std` | standard library (Fels source) | yes |
| `lld-link.exe` | spawned COFF linker | no — superseded by `felslld.dll` |
| `ld.lld.exe` | ELF linker (Linux target) | no — cross component |
| `libclang.dll` | `fels bindgen` | no — bindgen component |

libclang is 81 MB and exactly one subcommand touches it. Linking it would put it
in every `fels.exe` import table, paid at process start — Windows resolves imports
at load. So it's not linked.

## libclang, loaded on demand

`fels.exe`'s import table is `KERNEL32`, `LLVM-C.dll`, the CRT shims, `ntdll`. No
libclang. `fels bindgen` does a runtime `LoadLibraryW` on first use.

`src/clang_c.zig`:

- clang-c header is `@cImport`ed for types/enums only.
- The ~48 functions are a fn-pointer table; each field is typed
  `*const @TypeOf(c.clang_…)`, so signatures track the header — no manual prototypes
  to drift.
- `load(path)` resolves symbols by field name. `bindgen.zig` calls through it.

Resolution order for the DLL:

1. `$FELS_LIBCLANG` (file or dir)
2. next to `fels.exe`, then `<exe>/bindgen/`
3. `$FELS_LLVM/bin`
4. build-time LLVM dir
5. bare name — OS loader search

Miss → `fels bindgen` prints that list.

## In-process linking

Object, then a linker for the exe. The LLD COFF driver is compiled into
`felslld.dll` (`-Din-process-lld`, `src/backend/llvm/lld_shim.cpp`) and called
in-process; `lld-link.exe` is never spawned. Spawn path stays as a fallback.

## felsld — the native linker

`felsld.dll` is a PE/COFF linker written in Fels (`linker/felsld.fels`). Default
for programs it can handle, LLD for the rest.

Why it's fast: no `.lib` import-archive parsing, which is LLD's dominant cost. The
compiler emits a `.skimp` section mapping every `#extern("dll","sym")` import to
its DLL. felsld reads that and writes one PE import descriptor per DLL.

Single-object COFF. Reads AMD64, merges sections by class (`.text`, `.rdata`,
`.data`, `.pdata`, `.bss`) at their required alignment — the 32/64-byte SIMD
constant pools at -O2 are the reason that matters. Builds the import tables,
applies REL32 / ADDR64 / ADDR32NB, keeps `.pdata`/`.xdata` and the exception
directory, writes a PE32+ with the subsystem, entry, and stack from the build.
Emits DLLs too (`.edata` from a `.skexp` map) — which is how `felsld.dll` links
itself.

Hands off to LLD on multi-object links, raw linker flags, a static-CRT
`/DEFAULTLIB` pull-in, and a DLL whose data holds an absolute address (a vtable, a static
table of function pointers). felsld writes no base-relocation table, and a DLL is rebased
whenever its preferred address is taken, so such a DLL needs the table LLD emits. An
executable is always loaded at felsld's fixed base and keeps the address as written.

### Dev: DLL. Release: embedded.

- `zig build` → `fels.exe` + `felsld.dll`, loaded on demand.
- `zig build -Dembed-linker` → two-stage. `felsld.fels` compiles to a freestanding
  object, links into `fels.exe`, which exports `fels_link_mem`. One binary that
  is its own linker.

`link.zig` is one path either way: `GetProcAddress` on the running module (embed),
else `LoadLibrary("felsld.dll")` (dev). The embedded object is built from source
at release time — no committed blob.

## Optional components

Folders dropped into `bin/`. Resolved by location, no env vars, no LLVM install.

`fels-bindgen-<ver>-<target>.zip`:

```
bindgen/
  libclang.dll
  clang-headers/        # stddef.h, stdint.h, …
  README.txt
```

`fels-linux-cross-<ver>-<target>.zip`:

```
ld.lld.exe
README.txt
```

## Packaging — `scripts/package.ps1`

ReleaseSafe build, `-Din-process-lld`, into `dist/`:

- `fels-<ver>-<target>.zip` — core: `bin/` (fels.exe, LLVM-C, felslld.dll),
  `lib/std`, licenses, `VERSION.txt`, installer. stdlib resolves relative to
  `fels.exe`.
- `fels-bindgen-<ver>-<target>.zip`
- `fels-linux-cross-<ver>-<target>.zip`

Reported version is the source of truth; the asset filename drops the `+<sha>`.

## Install scripts

Per-archive installer, idempotent. Copies the tree to a prefix, wires `PATH` and
`FELS_HOME`.

- `install.ps1` → `%LOCALAPPDATA%\fels`
- `install.sh` → `~/.fels`

Both take a custom prefix and a no-PATH mode.

## Size (Windows core, compressed)

| | |
| --- | --- |
| libclang + both LLD exes in core | 110 MB |
| libclang → bindgen component | 78 MB |
| in-process `felslld.dll` + cross split | 50 MB |
