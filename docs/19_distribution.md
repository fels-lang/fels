# Distribution, packaging & install

How k2 ships: a **slim, relocatable core** plus **optional components** loaded on
demand. The model is deliberately close to Jai's (a lean compiler with a separate
`Bindings_Generator` module) rather than a single monolith.

## 1. What the core depends on

The compiler links exactly what it needs to *compile and link your code*:

| Dependency | Why | Shipped in core |
| --- | --- | --- |
| `LLVM-C.dll` | code generation | yes (~69 MB) |
| `lld-link.exe` / `ld.lld.exe` | linking (Windows / Linux) | yes |
| `lib/std` | the standard library (k2 source) | yes |
| `libclang.dll` | **only** `k2 bindgen` (C-header → bindings) | **no** — see §3 |

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

## 3. The bindgen component

`k2 bindgen` ships as a **separate download**, `k2-bindgen-<ver>-<target>.zip`,
containing a single `bindgen/` folder:

```
bindgen/
  libclang.dll
  clang-headers/        # clang's builtin headers (stddef.h, stdint.h, …)
  README.txt
```

Drop that `bindgen/` folder next to `k2.exe` (in `bin/`) and binding generation
"just works" — `k2` finds both libclang and the headers there, with no LLVM
install and no environment variables. Without it, the core is fully functional;
only `k2 bindgen` is unavailable.

## 4. Packaging (`scripts/package.ps1`)

Builds k2 (ReleaseSafe) and emits, into `dist/`:

- **`k2-<ver>-<target>.zip`** — the relocatable core: `bin/` (k2.exe + LLVM-C +
  the lld linkers), `lib/std`, the licenses, `VERSION.txt`, and the platform
  installer. The Phase 0 runtime finds the stdlib + linker relative to `k2.exe`,
  so it runs from anywhere with no flags.
- **`k2-bindgen-<ver>-<target>.zip`** — the optional component above (§3).

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

Dropping `libclang` from the core takes the Windows archive from **110 MB → 78 MB**
(~30 % smaller) while keeping `k2 bindgen` available as a 31 MB opt-in. The next
size lever is **static-linking `LLVM-C`** into `k2.exe` (à la C3's single
`c3c.exe`), which removes `LLVM-C.dll` as a separate file; the static LLVM libs
are already wired for `-Din-process-lld`.
