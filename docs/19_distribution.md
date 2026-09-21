# Distribution, packaging, install

Fels comes as a small core, and optional components are dropped in next to the binary. The
core is one relocatable folder with `fels.exe`, `LLVM-C.dll`, `felslld.dll` and `lib/std`.

## Core dependencies

| Dependency | For | In core |
| --- | --- | --- |
| `LLVM-C.dll` | codegen | yes (~69 MB) |
| `felslld.dll` | in-process COFF linker (Windows) | yes (~65 MB) |
| `lib/std` | standard library (Fels source) | yes |
| `lld-link.exe` | spawned COFF linker | no, superseded by `felslld.dll` |
| `ld.lld.exe` | ELF linker (Linux target) | no, cross component |
| `libclang.dll` | `fels bindgen` | no, bindgen component |

libclang is 81 MB, and exactly one subcommand touches it. Linking it would put it in every
`fels.exe` import table, and you would pay for it at process start, because Windows resolves
imports at load. So it is not linked.

## libclang, loaded on demand

The import table of `fels.exe` holds `KERNEL32`, `LLVM-C.dll`, the CRT shims and `ntdll`, and
no libclang. `fels bindgen` does a runtime `LoadLibraryW` on first use.

This lives in `src/clang_c.zig`:

- The clang-c header is `@cImport`ed for its types and enums only.
- The ~48 functions are a table of fn pointers. Each field is typed
  `*const @TypeOf(c.clang_…)`, so the signatures track the header, and there are no manual
  prototypes to drift.
- `load(path)` resolves symbols by field name. `bindgen.zig` calls through it.

The DLL is looked up in this order:

1. `$FELS_LIBCLANG` (file or dir)
2. next to `fels.exe`, then `<exe>/bindgen/`
3. `$FELS_LLVM/bin`
4. build-time LLVM dir
5. bare name, which leaves the search to the OS loader

When all of them miss, `fels bindgen` prints that list.

## In-process linking

The compiler writes an object, and then a linker makes the exe from it. The LLD COFF driver is
compiled into `felslld.dll` (`-Din-process-lld`, `src/backend/llvm/lld_shim.cpp`) and called
in-process. `link.zig` spawns `lld-link.exe` from the LLVM `bin` folder only when `felslld.dll`
cannot be loaded or lacks its `fels_lld_link_coff` export. When the in-process link runs and
fails, that error is reported, and there is no second try with the exe.

## felsld — the native linker

`felsld.dll` is a PE/COFF linker written in Fels (`linker/felsld.fels`). It is the default for
the programs it can handle, and LLD links the rest.

It is fast because it does no `.lib` import-archive parsing, which is LLD's dominant cost. The
compiler emits a `.skimp` section that maps every `#extern("dll","sym")` import to its DLL.
felsld reads that section and writes one PE import descriptor per DLL.

felsld links a single COFF object. It reads AMD64 and merges sections by class (`.text`,
`.rdata`, `.data`, `.pdata`, `.bss`) at their required alignment. The alignment matters because
of the 32/64-byte SIMD constant pools at -O2. It builds the import tables, applies REL32 /
ADDR64 / ADDR32NB, and keeps `.pdata`/`.xdata` and the exception directory. Then it writes a
PE32+ with the subsystem, entry and stack from the build. It emits DLLs too (`.edata` from a
`.skexp` map), and that is how `felsld.dll` links itself.

It hands off to LLD for multi-object links, raw linker flags, a static-CRT `/DEFAULTLIB`
pull-in, and a DLL whose data holds an absolute address (a vtable, a static table of function
pointers). felsld writes no base-relocation table, and a DLL is rebased whenever its preferred
address is taken, so such a DLL needs the table that LLD emits. An executable is always loaded
at felsld's fixed base and keeps the address as written.

### Dev: DLL. Release: embedded.

- `zig build` → `fels.exe` + `felsld.dll`, loaded on demand.
- `zig build -Dembed-linker` → a two-stage build. `felsld.fels` compiles to a freestanding
  object, which is linked into `fels.exe`, and `fels.exe` exports `fels_link_mem`. The result is
  one binary that is its own linker.

`link.zig` takes one path either way. It uses `GetProcAddress` on the running module when the
linker is embedded, and `LoadLibrary("felsld.dll")` otherwise (dev). The embedded object is
built from source at release time, so there is no committed blob.

## Optional components

Optional components are zips that you extract into `bin/`, next to `fels.exe`. They are found
by their location, so they need no LLVM install and no env vars. The variables in the lookup
order above (`$FELS_LIBCLANG`, `$FELS_LLVM`) are optional overrides.

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

These two files sit at the top of the zip, with no folder around them, so `ld.lld.exe` lands
right next to `fels.exe`. The compiler looks for it there when it links for `--target linux`.

`ld.lld` is looked up in this order:

1. the LLVM `bin` folder fels links with (`--llvm-path`; an installed fels uses its own
   folder, where it finds `LLVM-C.dll`)
2. next to `fels.exe`
3. `PATH`

When none has it, the build names the folders it looked in and the ways to give it one.

## Packaging — `scripts/package.ps1`

The script makes a ReleaseSafe build with `-Din-process-lld` and writes these into `dist/`:

- `fels-<ver>-<target>.zip`, the core: `bin/` (fels.exe, LLVM-C, felslld.dll), `lib/std`,
  licenses, `VERSION.txt` and the installer. The stdlib resolves relative to `fels.exe`.
- `fels-bindgen-<ver>-<target>.zip`
- `fels-linux-cross-<ver>-<target>.zip`

The reported version is the source of truth, and the asset filename drops the `+<sha>`.

## Install scripts

Each archive has its own installer, and it is idempotent, so running it again is safe. It
copies the tree to a prefix and wires up `PATH` and `FELS_HOME`.

- `install.ps1` → `%LOCALAPPDATA%\fels`
- `install.sh` → `~/.fels`

Both take a custom prefix, and both have a no-PATH mode.

## Size (Windows core, compressed)

| | |
| --- | --- |
| libclang + both LLD exes in core | 110 MB |
| libclang → bindgen component | 78 MB |
| in-process `felslld.dll` + cross split | 50 MB |
