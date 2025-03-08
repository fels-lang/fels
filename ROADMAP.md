# K2 Roadmap

This file tracks where the language and compiler are headed. For the design of
the comptime VM and metaprogramming layer specifically, see
[`docs/09_comptime_vm_roadmap.md`](docs/09_comptime_vm_roadmap.md).

Status legend: **done** · **in progress** · **next** · **later**.

---

## Recently landed

The comptime engine and the first metaprogramming layer are in and tested:

- **Comptime bytecode VM** — a register-based VM that executes the compiler's own
  IR, so compile-time and runtime share one lowering and behave identically. It
  replaced the old AST tree-walker entirely (the tree-walker is deleted; the VM
  is the sole comptime engine).
- **Full comptime data-type coverage** — scalars, floats, structs (nested),
  arrays, slices, enums + `match`, optionals, errors/fallible + payloads,
  interfaces with dynamic dispatch, recursion, loops.
- **Reflection** — `sizeof`, `type_name`, and nested `type_info`
  (`.fields[i].name`, `.elem_info`, `.bits`, `.signed`, `.kind`, …).
- **Metaprogramming** — `#quote` / `#insert` (splice + re-check), template
  `macro`s with `$`-splices and hygiene, `#for` comptime unrolling, a faithful
  `ast.*` value surface you can `match` on, and `#insert #run gen()` — running
  arbitrary comptime code that *builds* AST and splices it back in, type-checked
  like hand-written code.

---

## Now: fix what blocks real programs

- **Interface-through-interface dispatch** — a method on `*InterfaceA` that calls
  a method on a `*InterfaceB` argument causes an LLVM verification error. Top
  compiler bug; blocks `std.fmt.Display`.
- **Symbol mangling / package namespaces** — top-level names must be globally
  unique, which prevents multi-package projects and third-party code.
- **Wrapping arithmetic** — decide and implement `+%` / `-%` / `*%` and the
  release-build overflow policy.

## Soon: complete the language

- Static interface constraints (`where T: Writer`-style).
- Const-correct interface values and receiver mutability rules.
- `#test` runner and test attribute.
- `#callconv`, `#link`, `#section` attributes.
- Linux native entry-point generation and linking; macOS runtime.
- Continue bootstrapping `std.*` (string slicing, sorting, hash maps).

## Soon: widen metaprogramming

- More `ast.*` node kinds (calls, field/index access, `if`/`while`/`return`, …)
  in materialization, reification, and the prelude — so generators are more
  expressive.
- Building `ast.*` values programmatically without `#quote` (needs growable
  comptime lists / array construction).
- `#parse("…")` — the marked string escape hatch.
- Bare-call macros (`name(args)` without an explicit `#insert`).
- Typed macro parameters (real `ast.Expr` / `ast.Block` instead of a `Code`
  marker) and an auto-generated, complete `std.ast`.

## Later: tooling and ergonomics

- Formatter.
- Language server (LSP).
- Package manifest and dependency management.
- Improved diagnostics for generic instantiation and interface conformance.

## Later: the metaprogramming endgame

These are designed in [`docs/09_comptime_vm_roadmap.md`](docs/09_comptime_vm_roadmap.md):

- Gated comptime FFI (`#extern`) and a host stdlib (`std.io`/`std.fs`) exposed as
  capabilities.
- A `std.compiler` module and a Jai-style compile-time message loop, so user code
  can inspect and modify the program as it compiles.
- `k2 build` scripts — the entry point runs entirely in the VM.
- **Capability-sandboxed metaprogramming** — the structural answer to the
  `build.rs` / supply-chain problem: a dependency's build hook receives only the
  capabilities it was granted and physically cannot reach the host OS.

## Future language expansion (after a stable foundation)

- Runtime type identity, reflection, `Any`.
- SIMD and vector operations.
- Contracts (`#require`, `#ensure`).
- Interface composition, owned dynamic objects, downcasting.
- User-defined attributes.

---

## Open language decisions

| Decision | Question |
| --- | --- |
| Plain arithmetic | Does overflow trap, wrap, or become UB in release builds? |
| Debug safety | Which checks are mandatory vs. disabled inside `unsafe`? |
| Error ABI | How are fallible returns propagated across modules and FFI? |
| Borrow scope | Should `borrow` expand to fields, returns, or extern contracts? |
| Static constraints | What is the `where T: Trait` syntax? Coherence rules? |
| Mutability | How do `const`, receiver mutability, pointers, and interface coercions interact? |
| `Any` / reflection | Borrowed or owned? What defines stable runtime type identity? |
| Packages | How are packages named, versioned, and represented in symbols? |
