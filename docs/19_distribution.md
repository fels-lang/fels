# Distribution, packaging & install

How k2 ships: a **slim, relocatable core** plus **optional components** loaded on
demand. The model is deliberately close to Jai's (a lean compiler with a separate
`Bindings_Generator` module) rather than a single monolith.

## 1. What the core depends on

The compiler links exactly what it needs to *compile and link your code*:

| Dependency | Why | Shipped in core |
| --- | --- | --- |
| `LLVM-C.dll` | code generation | yes (~69 MB) |
| `k2lld.dll` | **in-process** COFF linker (Windows) | yes (~65 MB) |
| `lib/std` | the standard library (k2 source) | yes |
| `lld-link.exe` | spawned COFF linker | **no** — replaced by `k2lld.dll` (§2.5) |
| `ld.lld.exe` | ELF linker, `--target linux` only | **no** — cross component (§3) |
| `libclang.dll` | **only** `k2 bindgen` (C-header → bindings) | **no** — bindgen component (§3) |

`libclang` is **81 MB** and is used by a single, optional subcommand most users
never run. Linking it would force every `k2.exe` to load it just to *start*
(Windows resolves all imports at launch). So the core does not link it at all.

## 2. On-demand libclang (the slim core)

`k2.exe` carries **no dependency** on `libclang.dll` — confirmed in its import
table (`KERNEL32`, `LLVM-C.dll`, the CRT shims, `ntdll`; no `libclang`). The
binding generator instead **loads libclang at runtime** the first time
`k2 bindgen` runs, exactly like Jai's module loads it on demand.

Mechanics (`src/clang_c.zig`):

- The clang-c header is still `@cImport`ed, but **only for its types/enums** —
  `CXCursor`, `CXType`, the `CXType_*` tags, etc.
- The ~48 libclang *functions* live in a `Lib` table of function pointers. Each
  field's type is derived from the `@cImport` declaration via
  `*const @TypeOf(c.clang_…)`, so a signature can never drift from the header.
- `load(path)` opens the library (Windows: `LoadLibraryW`/`GetProcAddress`;
  POSIX: `std.DynLib`) and `@typeInfo`-iterates the table, resolving each symbol
  by its field name. `bindgen.zig` calls through it as `lib.clang_…(…)`.

The core compiler never touches any of this; it is reached only by `k2 bindgen`.

### Where libclang is resolved (CLI), in order

1. `$K2_LIBCLANG` — a full path to the library, or a directory containing it
2. next to `k2.exe`, then `<exe>/bindgen/` (the component layout)
3. `$K2_LLVM/bin`
4. the build-time LLVM dir (dev/CI fallback)
5. the bare name — the OS loader's own search (exe dir, system dirs, `PATH`)

If none resolve, `k2 bindgen` prints exactly how to provide it. The clang
*resource headers* (`stddef.h`, …) resolve in parallel: `<exe>/bindgen/clang-headers`
first, then the build-time LLVM tree.

## 2.5 In-process linking (no spawned linker exe)

k2 compiles to a `.o`, then needs a linker to make the final `.exe`. Rather than
ship and *spawn* the 69 MB `lld-link.exe`, the LLD COFF driver is built into
**`k2lld.dll`** (`-Din-process-lld` → `src/backend/llvm/lld_shim.cpp`), which k2
`LoadLibrary`s and calls in-process — no subprocess, faster, and no standalone
linker executable in the distribution. The spawn path (`lld-link.exe`) remains a
fallback only if `k2lld.dll` is somehow absent. LLD is ~65 MB either way (it
carries its own LLVM object-handling code), so this is an *architecture* win, not
a raw-size one — the size win comes from no longer shipping **two** 69 MB LLD
exes (`lld-link` + `ld.lld`).

## 2.6 The self-hosted native linker (k2lnk)

The release also ships **`k2lnk.dll`** — a PE/COFF linker **written in k2 itself**
(`linker/k2lnk.k2`). k2 prefers it for eligible programs and falls back to
`k2lld.dll`/LLD for the rest. Its defining trick, and why it's fast and
*k2-specific*: it never parses a `.lib` import archive (LLD's single biggest
cost). The compiler already knows every import's DLL from `#extern("dll","sym")`
and emits a `.k2imp` map section; k2lnk reads that and synthesizes one PE import
descriptor per DLL directly.

It is a **full single-object COFF linker**: it reads the AMD64 COFF, classifies
and **merges sections by class** (`.text`/`.rdata`+`.xdata`/`.data`/`.pdata`/
`.bss`) honoring each section's required alignment (16/32/64-byte SIMD pools at
-O2), builds **multi-DLL** import tables from the `.k2imp` map, applies the
REL32 / ADDR64 / ADDR32NB relocations, keeps `.pdata`/`.xdata` and wires the
exception directory, and writes a PE32+ image with the requested **subsystem**
(console/GUI), **entry**, and **stack**. It also produces **DLLs** — building an
export table (`.edata`) from the compiler's `.k2exp` map — which means **k2lnk
builds itself**: the shipped `k2lnk.dll` is linked by `k2lnk`.

The whole exe-integration suite links through it at `-O2`. It bails to LLD only on
the genuinely hard cases (multiple objects, raw linker flags, a C library's
`/DEFAULTLIB` static-CRT objects), always safely. The first DLL-capable
`k2lnk.dll` is bootstrapped via LLD (the prior one couldn't emit a DLL); after
that it self-hosts. `package.ps1` builds it with the just-built compiler.

## 3. Optional components

Two features ship as **separate downloads** instead of bloating the core. Each is
a folder you drop next to `k2.exe` (in `bin/`); the runtime finds it there with no
LLVM install and no environment variables.

**`k2-bindgen-<ver>-<target>.zip`** — `k2 bindgen` (C-header → bindings):

```
bindgen/
  libclang.dll
  clang-headers/        # clang's builtin headers (stddef.h, stdint.h, …)
  README.txt
```

**`k2-linux-cross-<ver>-<target>.zip`** — `k2 build --target linux`:

```
ld.lld.exe              # the ELF linker; drop into bin/ next to k2.exe
README.txt
```

(`ld.lld.exe` is resolved from k2's `bin/` via the `LLVM-C.dll` marker — see
`resolveLlvmBin`.) Without either component the core is fully functional; only
that one feature is unavailable.

## 4. Packaging (`scripts/package.ps1`)

Builds k2 (ReleaseSafe) and emits, into `dist/`:

- **`k2-<ver>-<target>.zip`** — the relocatable core: `bin/` (k2.exe + LLVM-C +
  `k2lld.dll`), `lib/std`, the licenses, `VERSION.txt`, and the platform
  installer. The Phase 0 runtime finds the stdlib relative to `k2.exe`, so it
  runs from anywhere with no flags.
- **`k2-bindgen-<ver>-<target>.zip`** — the bindgen component (§3).
- **`k2-linux-cross-<ver>-<target>.zip`** — the Linux cross-compile component (§3).

It builds with `-Din-process-lld` so the core ships `k2lld.dll` instead of a
spawned `lld-link.exe`.

The binary-reported version is the single source of truth; the asset filename
drops the `+<sha>` build metadata for URL-friendliness.

## 5. Install scripts

Each platform's core archive carries its own installer, which copies the layout
to a stable prefix and wires up `PATH` + `K2_HOME` (idempotent):

- **`install.ps1`** (Windows) → `%LOCALAPPDATA%\k2`, user `PATH`.
- **`install.sh`** (Linux/macOS) → `~/.k2`, via the shell rc.

Run it from inside the extracted archive; both accept a custom prefix and a
"copy only, don't touch PATH" mode. The standard library is OS-agnostic k2
source — only the *binaries* differ per platform, and the per-OS archive already
carries the right ones, so the installer just keeps `bin/` and `lib/` together.

## 6. Size

The Windows core archive, compressed:

| Step | Size |
| --- | --- |
| Original (libclang + both LLD exes in core) | 110 MB |
| − `libclang` → bindgen component | 78 MB |
| − `lld-link.exe`/`ld.lld.exe` → in-process `k2lld.dll` + cross component | **50 MB** |

So ~**55 % smaller** than where we started, with `k2 bindgen` (31 MB) and Linux
cross-compile (26 MB) available as opt-ins. The next size lever is
**static-linking `LLVM-C`** into `k2.exe` (à la C3's single `c3c.exe`), which
removes `LLVM-C.dll` as a separate file; the static LLVM libs are already wired
for `-Din-process-lld`.
