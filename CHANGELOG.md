# Changelog

Notable changes, newest first. Versions follow [SemVer](https://semver.org/): while
the major version is `0`, any minor bump may break source compatibility.

## Unreleased

### Fixed

- **A program could not bind a Win32 function the runtime also declares.** Declaring
  `#extern("kernel32", "CloseHandle")` under that name — or a `STD_OUTPUT_HANDLE`
  constant, or the same API in two modules — failed with `duplicate top-level
  declaration` for something the program never wrote. It broke both `examples/diskscan`
  executables. A program's own declarations now shadow the runtime's inside its own
  file. Bindings of one C symbol also keep their own signatures: LLVM holds one function
  per symbol, and every call used to be built with the first declaration's types, so a
  `BOOL` bound as `i32` was truncated to the runtime's `bool`.
- **`expr ?? default` on a fallible (`T ! E`) value returned the wrong thing.** It was
  lowered as if the value were an optional, so a failure yielded stale data or the raw
  error tag instead of the default. `expr!!` on a fallible had the same mistake and
  returned the wrong value on success. Two further faults in `??` are fixed: every `??`
  in a function shared one temporary, so a later one of a different type (a slice, then
  a struct) misread it, and a bare literal default such as `.{ 9, 9 }` was lowered with
  no type.
- **`#align(N)` only aligned the variable holding the struct.** Its size stayed natural
  and a struct field of that type was not moved, so `#align(8)` over `[8]u8` — what
  `gabbro bindgen` emits for a C union — sat at offset 4 inside its parent, not 8. It is
  now `alignas(N)`: the struct is aligned and its size rounded up wherever it appears,
  including generic structs and `#packed` structs. `N` must be a power of two.
- **Comptime `core::sizeof` ignored padding.** The VM summed field sizes, so
  `#run core::sizeof(S)` gave 15 for a struct the program measured at 24. It now uses
  the layout the native backend produces.
- **The address of a `#packed` field was accepted.** `docs/02_types.md` always said it
  is an error; `&p.b` and `&p.arr[i]` now are. Field access through a `*Packed` pointer
  is emitted with alignment 1 instead of the field type's natural alignment.

### Changed

- The README no longer claims `i128`/`u128`; the compiler rejects integers wider than 64
  bits.

## 0.1.1 — 2026-09-08

A bug-fix release. **If you have 0.1.0, replace it:** its build system does not work
outside the machine that built it.

### Fixed

- **`gabbro build` could not find the standard library.** Running it in an extracted
  0.1.0 release failed with `cannot read imported module: FileNotFound` naming a path
  from the build machine. `gabbro build` with no source file dispatches to the build
  system early in `main` and returned before the relocatable path resolution ran, so
  `std.build` was looked up at the absolute path the compiler was built at. A direct
  `gabbro build <file>.gab` was unaffected, which is why it survived release testing.
  Setting `GABBRO_HOME` was the only way through on 0.1.0.

### Added

- `examples/mandel` — a Mandelbrot set drawn entirely by the comptime VM. `render`
  runs at compile time and returns Gabbro source, which `#insert #parse` splices into
  `main`; raising the resolution slows the build and leaves the run flat.
- `examples/raycaster` — a twelve-line text map walked in 3D in the terminal at
  roughly 22 fps.

## 0.1.0 — 2026-09-08

First tagged release. Gabbro compiles end-to-end on two targets, ships a standard
library and its own linker, and installs by unzipping.

**The project was previously called Skarn.** The language, the toolchain and the file
extension were all renamed in this release: `skarn` → `gabbro`, `skarnld` → `gabld`,
`.sk` → `.gab`, and the `SKARN_*` environment variables to `GABBRO_*`. The old
repository, `skarn-lang/skarn`, is superseded by `gabbro-lang/gabbro`.

### Language

- Structs, packed structs with sub-byte fields, enums with payloads, and exhaustive
  `match` with range, string and guard patterns.
- Integers `i8`–`i128` and `u1`–`u128`, `f32`/`f64`, pointers, arrays, slices and
  optionals. Arithmetic overflow traps in debug and wraps in release; `+%`/`-%`/`*%`
  always wrap.
- Errors as values: `T ! E`, `?` to propagate, `catch` to handle, `fail` to raise. An
  error is a small integer tag, not a stack unwind.
- Lexical `Arena` zones with compiler-enforced non-escape and deterministic cleanup.
  `borrow` parameters may take a zone-owned value but cannot store or forward it.
- Monomorphized generics with `$T:` constraints, `where {}` predicates and named
  constraints. Interfaces with explicit dynamic dispatch.
- Distinct/newtype and opaque types, UFCS extension methods, lambdas and iterators.
- Debug traps for overflow, divide-by-zero, bad shifts, out-of-bounds indexing, null
  deref and invalid optional unwraps.

### Compile-time execution

- `#run` on a register bytecode VM that executes the same IR the native backend
  lowers, so comptime and runtime cannot drift.
- `#quote`/`#insert` with re-checking and hygiene, template `macro`s with `$`-splices,
  `#for` unrolling, `#parse`, and first-class `ast.*` values you can `match` on.
- `#compiler` hooks with `compiler_decls()` introspection, and `#derive`.
- Reflection: `sizeof`, `type_name`, `type_info(T)`, `typeid` and `Any`, driving
  `std.serde` with no per-type code.
- A bare `#run` is capability-pure: it cannot call host DLLs at compile time, which
  closes the comptime side of the `build.rs` supply-chain surface. The grant is
  per-library rather than all-or-nothing — a run holds `.none`, an allowlist of
  libraries, or `.all` — and capabilities handed to a nested run can only narrow,
  failing closed when two allowlists are disjoint. The comptime heap's page
  primitives stay available to a pure run, so allocation still works.
- Content-addressed caching for pure `#run` results, behind `GABBRO_CACHE`.

### Toolchain

- `gabld`, a single-object PE/COFF linker written in Gabbro that links itself and is
  baked into the release binary. It skips LLD's largest cost by never parsing `.lib`
  import archives: the compiler already knows every import and emits a `.skimp`
  section for the linker to read. LLD remains the fallback for multi-object links,
  raw linker flags and static-CRT pull-in.
- The build system is Gabbro. `build.gab` runs inside the comptime VM; there is no
  second language and no Makefile.
- `gabbro bindgen` generates FFI declarations from a C header via libclang.

### Targets

- `x86_64-windows-msvc` — the original host target, full standard library.
- `x86_64-linux-none` (static) — cross-compiles from Windows, no libc, no crt1.o.
  Full standard library parity with Windows.
- `x86_64-linux-gnu` — behind `--target linux-gnu` with a `--sysroot`.
- No macOS backend.

### Standard library

25 modules: `io`, `fmt`, `mem`, `strings`, `slice`, `vec`, `map`, `list`, `heap`,
`math`, `rand`, `color`, `bits`, `ptr`, `path`, `time`, `crypto`, `serde`, `net`,
`atomics`, `thread`, `fs`, `process`, `c`, `build`.

### Tooling

- `gabbro lsp` with diagnostics, completion, hover, go-to-definition and document
  symbols.
- A tree-sitter grammar with highlight queries, and a Zed extension.
- The `#test` comptime lane: a failed assertion fails the build like a type error.

### Known limitations

Gabbro is experimental. Some accepted constructs still have incomplete backend
semantics. The full list, with file references, is in
[ROADMAP.md](ROADMAP.md#known-gaps); the headlines:

- No runtime test lane, formatter, doc generator, REPL or package manager.
- No external packages; projects are single-tree.
- `==` on enum payloads that are not scalars is rejected; use `match`.
- Struct and aggregate equality is not lowered.
- A `#run` producing a struct, slice or enum cannot become a top-level constant.
- Returning a capturing closure needs an `*Arena` parameter.
- `#quote` reflects range, string, guard and binding match patterns as the catch-all
  `anything`.
