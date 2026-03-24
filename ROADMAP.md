# Roadmap

Where Fels is headed. For component-by-component status see the table in
[README.md](README.md#project-status); for the design of any single subsystem see the
chapter it links to in [`docs/`](docs/).

This file tracks what is *not* done. Everything else is in the docs.

---

## Where it stands

Fels compiles end-to-end on two targets. Windows x86-64 is the original host: parse →
check → IR → LLVM → object → executable, linked by `felsld` without spawning LLD.
`x86_64-linux-none` (static) cross-compiles from Windows and has a complete standard
library — all 25 modules, backed by 103 runtime functions in
[`src/runtime/linux.fels`](src/runtime/linux.fels) covering file I/O, time, process
control, sockets and threads. `x86_64-linux-gnu` is implemented behind
`--target linux-gnu` + `--sysroot`.

The comptime VM runs the same IR the native backend lowers, and a bare `#run` is now
capability-pure: it cannot reach host DLLs unless granted. `build.fels` is the
privileged root.

---

## Releasing

0.1.0 and 0.1.1 are tagged and published, built locally from a full LLVM install.
What is still not automated or done:

| Item | State |
| --- | --- |
| CI release workflow | Done: a version tag builds, smoke tests and publishes the release (`release.yml`), with LLVM from the official llvm.org archive (`.github/actions/setup-llvm`). |
| Packaging prerequisites | `scripts/package.ps1` needs an LLVM install carrying the LLVM-C headers and the static `LLVM*`/`lld*` libraries. The usual Windows LLVM distributions ship only `Remarks.h` and `lto.h`; the `clang+llvm-*-x86_64-pc-windows-msvc` archive is the one that works. |
| Repository description + topics | the repo is public but has neither, so it is close to unfindable in search |
| Build-from-source path | Zig + LLVM, needs a clean pass and an examples sweep |
| Release testing | 0.1.0 shipped with a broken build system because only `fels build <file>.fels` was tested, not `fels build`. Any release check must extract the archive somewhere neutral and run both. |

---

## Open work

### Capabilities and packages

The single thread with the most leverage, because everything else in this section is
ordinary toolchain work and this is not.

Slice 1 closed the comptime side of the `build.rs` supply-chain hole: a dependency's
compile-time code physically cannot reach the host unless the capability was granted.
Slice 2 made the grant expressive instead of all-or-nothing. A run now holds `.none`,
`.libs` (an allowlist, matched the way `#extern` spells library names) or `.all`, and
`Caps.narrow` hands capabilities to a nested run with no way to widen them, failing
closed when two allowlists are disjoint. Both live in
[`src/vm/engine.zig`](src/vm/engine.zig).

What remains:

- The `*Caps` surface in `build.fels`, so a build script declares the libraries it
  needs and the driver grants exactly those instead of `.all`. This is the first
  slice that changes the Fels-side API rather than compiler internals.
- Capabilities beyond FFI — filesystem, network, environment, process spawn — each
  gated at its call site. Comptime code reaches the host only through FFI today, so
  these arrive alongside the operations that need them.
- The capability-bounded, content-hashed package manager designed in
  [`docs/16`](docs/16_packages.md). A dependency's build hook receives only what it
  was granted. This is the payoff the earlier slices exist for.

### Tooling

None of these exist as subcommands today; `fels help` lists what does.

- More for `fels test`: per-test zones with leak checks, a time limit, a filter, TAP or
  JSON reports. `fels test` itself works. See [`docs/17`](docs/17_testing.md) §6.
- Reflection-driven structural diffs on assertion failure, which also unlocks struct
  equality.
- Property testing and snapshots.
- `fels fmt` — canonical formatter.
- `fels doc` — reflection-driven documentation generation.
- `fels repl`.
- LSP v2/v3 — rename, semantic tokens, code actions. v1 (diagnostics, completion, hover,
  go-to-definition, document symbols) ships behind `fels lsp`.

### Build system

From the table in [`docs/10`](docs/10_build_system.md). Layer 1 and the plan executor
are done.

- Dependency/step DAG with topological order and parallel execution.
- Content hashing, incremental builds, `--watch`.
- `add_quote` typed codegen, `#provided`, `define` injection — extends `#quote`/`#insert`.
- Layer 2 (`workspace`/`Options`) and Layer 3 (intercept) surfaces.
- Cross-compile target selection from `build.fels`.

### Targets

Current tiers are in [`docs/18`](docs/18_targets_and_tiers.md).

| Target | Now | Needs |
| --- | --- | --- |
| `aarch64-linux` | 3 | aarch64 runtime arm + ABI; the clearest next target |
| `riscv64-linux` | 3 | LLVM-ready; runtime/seam unwritten |
| `wasm32-wasi` | 3 | LLVM-ready; runtime/seam unwritten |
| `*-macos` | 3 | Mach-O + Apple ABI; the large one |

An ELF `felsld` is explicitly a much later item. LLD stays the correctness path on Linux.

### Language reach

- Static interface conformance constraints.
- Interface composition, owned dynamic objects, downcasting.
- SIMD.
- Contracts — `#require` / `#ensure`.
- Attributes that need infrastructure first: `#when(cond)`, `#bench`, `#on_start` /
  `#on_exit`.

### Metaprogramming

- More `ast.*` node kinds.
- Building `ast.*` values without `#quote`.
- Bare-call macros and typed macro parameters.
- An auto-generated `std.ast`.
- Scoping user-written generators to a pure subset, so a `#compiler` hook is not a
  proc-macro with ambient power ([`docs/13`](docs/13_metaprogramming.md)).
- Recursing into nested fields for the derives other than `format`.

---

## Known gaps

Accepted constructs whose backend semantics are incomplete, or shapes the compiler
rejects on purpose. Each needs a fix-or-document decision before v0.1.0.

- **`==` on non-scalar enum payloads** — comparing two enum values whose variant carries
  a struct, string or array payload is a clear error; use `match`. Scalar payloads,
  `.variant` comparison, and every other `==` work.
- **Static storage covers the common shapes, not every one.** A top-level global can hold
  structs, arrays, function pointers, addresses of other globals, `null`, strings, enum
  values and errors (with their payloads), and can be exported ([`docs/01`](docs/01_syntax.md)).
  Not yet: an optional that is not a pointer holding a value, the address of an element or
  field (`&TABLE[2]`), a slice of anything but a string, a union holding anything but zeros,
  and an uninitialised global (write `.{}`). A data export is checked by resolving it by name at run
  time and, for a DLL linked by LLD, by a C program that uses it through the import library
  (`__declspec(dllimport)`); a DLL linked by `felsld` has no import library.
- **Compile-time code reads static data, with two exceptions.** A `#run` or `#assert` reads a
  struct, array, enum or function-pointer global (read-only; [`docs/09`](docs/09_comptime.md)).
  It cannot read a global that holds the address of another global, nor a global that another
  `#run` computes: the VM is built before any `#run` has a value, so `#assert(TABLE[3] == 9)` on
  `TABLE: [8]u32 = #run make();` stops with "global `TABLE` cannot be read by compile-time code".
- **What a `#run` can return is data only.** A struct, array, enum value, function pointer,
  string or number becomes the global's initial value, a payload variant too. A pointer into
  compile-time memory, a lambda and a slice of anything but bytes are refused with a message
  ([`docs/09`](docs/09_comptime.md#data-at-compile-time)).
- **Compile-time aggregates alias when copied.** `b := a; b.x = 9;` changes `a` at compile time
  and not at run time, and the same for an array, a field copied out of a struct and a value
  stored into an array element. (Writes to *static* data are refused, so
  there the mistake is loud; for a local it is silent.) In-place writes to a nested aggregate
  fail outright: `pts[1].x = 9`, `o.p.x = 9`, `a.t[1] = 9` and `g[1][0] = 9` are reported as
  "could not be evaluated", and so is the address of an element that is itself an aggregate
  (`p := &pts[1]; p.y`); only whole-element writes (`pts[1] = .{ 9, 8 }`) work. The VM
  addresses an aggregate by a pointer to its block and has no copy; it needs value semantics.
- **Compile-time `+`, `-`, `*` keep the exact result on overflow.** A debug build traps and a
  release build wraps ([`docs/02`](docs/02_types.md#overflow-policy)); `+%`, `-%`, `*%`, `<<`,
  `~` and `as` do match the machine at compile time.
- **`fels check` cannot judge a static value only the comptime VM can compute.** A value that
  does not fit, a missing field, a pointer to something that is not a global are reported by
  `check` and by every build. A `#run` result or a call inside a constant is checked when the
  module is lowered (`build`, `object`, `ir`), as is a failing `#assert`. The language server
  analyses one document without its imports and does not run this check yet.
- **There is no pack-to-N.** `#packed` removes all padding; a C struct under `#pragma pack(2)` or
  `pack(4)` (`BITMAPFILEHEADER`) has no direct spelling. `#packed(N)` was read as plain
  `#packed` without a word, giving a different size than C; it is an error now. The size and
  field offsets can be matched with a `#packed` struct and explicit padding fields (its
  alignment is then 1, where C's is N).
- **A `#packed` bit field is not a C bitfield.** Sub-byte fields are bit-packed from the
  lowest bit with no units, where C groups bitfields into units of their declared type and
  aligns the struct to them; a C bitfield struct is matched with explicit filler fields, and
  bindgen still maps one as a byte blob.
- **The test suite does not run Linux executables.** It cross-compiles and links the portable
  fixtures for Linux and checks the ELF, but running them takes a Linux machine; the Linux paths
  (the futex mutex and condition variable, static data and relocation, `std.com`) were run
  under WSL by hand. A CI job on Linux would close this.
- **`std.sync` and `std.winrt` are deliberately small.** `std.sync` has a mutex, a condition
  variable and a bounded queue: no reader/writer lock, semaphore, barrier, one-shot or unbounded
  channel. `std.winrt` has start-up, activation and `HSTRING`: no events, delegates or async, no
  generated projection of a runtime class, no smart pointer ([`docs/07`](docs/07_stdlib.md)).
- **Returning a capturing closure** needs an `*Arena` parameter, because the captured
  environment must outlive the function. Lambdas otherwise capture freely.
- **A variable named like a type is taken for the variable in a closure or a macro.** A
  closure that has a local of the same name as a type it also writes as `*Type` for a builtin
  or a generic function (`core::sizeof(*Node)` next to a local `Node`) is read as using the
  variable, so returning it is refused as capturing; a macro template renames the type
  along with its own local of that name. The free-variable pass runs before the callee is
  known. Rename the variable.
- **`#quote` pattern fidelity** — range, string, guard and binding match patterns reflect
  as the catch-all `anything`. Quoting works; reflecting on those patterns is lossy.
  This is the only `TODO` in the compiler ([`src/ir.zig`](src/ir.zig)).
- **Overload resolution** — a rejected instantiation is not yet an error
  ([`docs/12`](docs/12_reflection_and_constraints.md)).
- **`bindgen` v1** maps the common scalar/pointer/struct/union/enum/array shapes; a struct
  with bitfields is a byte blob, and the rest is unhandled ([`src/bindgen.zig`](src/bindgen.zig)).
- **The comptime VM's step limit surfaces as the wrong error.** Exhausting
  `step_limit` inside a `#run` feeding `#parse` reports "`#parse` operand did not
  evaluate to a string at compile time", which points at the metaprogram instead of
  the budget. Around ten million loop iterations is where this starts.

---

## Open decisions

Neither has been answered. Both affect the language surface, so they should be settled
before v0.1.0 rather than after.

| Decision | Question |
| --- | --- |
| Debug safety | Which checks are mandatory, and which may `unsafe` disable? |
| Error ABI across FFI | How does a fallible return cross the C boundary? |
