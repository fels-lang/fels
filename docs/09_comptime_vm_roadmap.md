# K2 Comptime VM & Metaprogramming — Status & Roadmap

> Status: **Phases 1–4 substantially IMPLEMENTED.** The bytecode VM is the sole
> comptime engine (the tree-walker is deleted), and the metaprogramming surface
> (`#run`/`#insert`/`#quote`/`#parse`/macros/reflection/`#compiler` hooks/comptime
> FFI/comptime zones/`k2 build`) works end-to-end. What remains is the **iterative
> message loop**, a **richer `std.compiler` surface**, and **Phase 5 capability
> sandboxing** — plus the K2-unique innovations at the end of this doc.

## Context

K2's compile-time execution runs on a **register bytecode VM** (`src/vm/`) that
executes the same **IR** (`src/ir.zig`) the native backend lowers, so **comptime ≡
runtime**: one lowering, identical semantics. The VM faithfully models K2's
signature **Zone/Arena** memory at compile time (host arenas that free as zones
exit), giving zero-leak comptime execution. The original tree-walker
(`src/comptime.zig`) has been **deleted**; `#run` routes only through the VM.

The north star is to match and then exceed Jai's metaprogramming, and to close the
`build.rs`/Jai **supply-chain hole** with capability-sandboxed comptime.

---

## What's implemented

### The VM (Phase 1 — done)
- `src/vm/value.zig` — tagged `Value` union (ints/floats/bool, zone-backed
  ptr/slice/struct/variant, strings, first-class `type` values, fn refs).
- `src/vm/zones.zig` — a `ZoneStack` of host-backed bump arenas; `zone_push/pop`
  allocate/free real memory; allocations carry their `ZoneId`; **unwinding frees
  every zone above a frame's watermark** on `ret`/`fail`. Comptime RAM stays
  bounded (frees as blocks exit) — unlike Zig/Jai, whose comptime memory grows
  until the build ends.
- `src/vm/engine.zig` — call stack, frames, locals/globals, **63 opcodes**
  (scalar core, calls, aggregates, slices, strings, variants, optionals, zones,
  `host_call`, FFI). `src/vm/compiler.zig` lowers `ir.IrFunction` → bytecode with a
  block→offset pass and a per-function constant pool.
- Wired as the sole comptime engine: `#run`, generic/`#if` evaluation, and the
  resolution rail for `where` constraints all execute here. **comptime ≡ runtime**
  is verified by the corpus tests.

### Metaprogramming surface (Phases 2 & 4 — done)
- **`#run expr`** — evaluate an expression at compile time, fold to a constant.
- **`#insert <code>`** — splice generated code at a site; the spliced subtree is
  re-resolved and type-checked like hand-written code (re-entrant sema).
- **`#quote { … }` / `#quote(expr)`** — **typed** AST quotations (an `ast.Block` /
  `ast.Expr` *value*, parsed once at the definition site — no re-lex per
  expansion), with `$`-splices.
- **`#parse(string)`** — the string escape hatch (parse comptime text → code).
- **Template macros** — `name :: macro(p) { return #quote { … }; }`, hygienic,
  substituting splices through **every** construct, with `#for` comptime
  unrolling. (See [13_metaprogramming.md](13_metaprogramming.md).)
- **First-class `ast.*` values** — programmatic AST construction (build a program
  in the VM, then `#insert #run gen()`).

### Reflection (done) — see [12_reflection_and_constraints.md](12_reflection_and_constraints.md)
- Comptime: matchable `type_info(T)`, `typeid_of`, `type_name`, `sizeof`.
- Resolve-time generics: built-in + user `constraint`/`where` with `reject`,
  output type params `-> $Acc`.
- Runtime: `Any` (type-erased value), safe downcast, recursive field/slice/pointer
  navigation, `info_of(id)`.

### Compiler API & build (Phase 3 — partially done)
- **`#compiler` hooks** — a function the compiler runs at comptime that can
  introspect the program via **`compiler_decls()`** and **generate new top-level
  declarations** (returns source, spliced + re-checked). `src/pipeline.zig:
  runCompilerHookPass`, `src/ir.zig:runCompilerHooks`. **Introspection is now
  *rich* (R1a):** each `Decl` carries its structure — a `struct`'s `fields`, an
  `enum`'s variants, a `fn`'s params (all `[]CField{name, type_name}`), and a fn's
  `ret` — so a hook can generate code driven by a type's real shape.
- **Comptime FFI** — `src/vm/ffi.zig` loads host DLLs (`LoadLibraryA`/
  `GetProcAddress`) and marshals `Value` ↔ C ABI, callable from `#run`.
- **`k2 build`** — `build.k2` runs entirely in the VM (`host_call` → `__build_*`
  intrinsics → `BuildPlan` → real exes/DLLs). See
  [10_build_system.md](10_build_system.md).

---

## What's partial or not yet built

| Area | State | Gap |
|---|---|---|
| **Message loop** | single-shot | `#compiler` hooks run **once** and can only *introspect + append*. No per-phase events (`File_Parsed`, `Typechecked`), no callback registration, **no modifying existing declarations** (changing a type, rewriting a body). |
| **`std.compiler` surface** | **rich introspection done (R1a)**; mutation/events pending | `Decl` now exposes `fields`/params/variants + `ret` (read-only). Still missing: declaration **bodies**, per-phase **events**, and **mutating** existing decls. |
| **Dynamic code generation in hooks** | **done (R1c)** | A hook builds generated source with the **real `std.strings.StringBuilder`** (`#import std.strings`) or the no-import prelude `CodeBuf`/`emit`, then returns it. `#derive`-style codegen works end-to-end. |
| **`std.heap`/byte-addressed memory at comptime** | **done** | The comptime VM now models **real host memory** (`host_ptr`/`host_buf` values; `ptr_from_int`/`slice_from_raw_parts` + host load/store/index do real `@ptrFromInt` access; `VirtualAlloc` via the existing FFI). So `std.heap.Arena` (and `StringBuilder`, …) **run at comptime exactly as at runtime** — comptime ≡ runtime for memory. (`compiler_decls()` is scoped to the user's own declarations so a hook that imports std for codegen doesn't see std's types.) |
| **Capability sandboxing (Phase 5)** | not started | Comptime FFI/`unsafe` are **unconditionally available** (`ffi.zig`: "for now it is unconditionally available"). A malicious dependency macro can reach the host — the `build.rs` hole is **not** yet closed. |
| **Host stdlib in the VM** | partial | `build.k2` uses `host_call` intrinsics; general `std.fs`/`std.io` at comptime behind capability interfaces is not generalized. |
| **`#quote` fidelity for new match patterns** | lossy | range/string/guard/binding patterns reflect as the catch-all `anything`. |

---

## Roadmap — and K2-unique innovations

The first two items finish the "match Jai" story; the rest are **genuinely novel**
and only sound *because* of K2's design (capability interfaces + zone purity +
typed AST + IR-shared comptime).

### R1. The iterative message loop (`std.compiler`)
- **R1a — rich introspection (DONE).** `compiler_decls()` now returns `Decl{name,
  kind, fields:[]CField, ret}` — a hook reads a struct's fields, an enum's
  variants, and a fn's params/return. (`src/ir.zig:lowerCompilerDecls` +
  `astTypeName`; `src/ast_prelude.zig:compiler_source`.) This is the load-bearing
  foundation for `#derive` (R4) and `#require` (R6).
- **R1b — affect compilation (in progress).** First capability **done**:
  **`compiler_error("msg")`** lets a `#compiler` hook **halt the build with a
  custom diagnostic** after introspecting the program — whole-program validation
  (e.g. "every `Component` must be `#packed`"), the basis for `#require` (R6).
  Wiring: a `halt_msg` VM opcode records the message on the engine; `evalToString`
  surfaces it; `runCompilerHooks` reports it and fails. Still to do: per-phase
  events (`File_Parsed`/`Typechecked`/`Done`), callbacks that **mutate** existing
  declarations (change a type, rewrite a body), and exposing declaration **bodies**
  in `std.compiler`.
- **R1c — dynamic code generation (DONE).** A hook builds generated source with
  the compiler prelude's `CodeBuf`: `cb := gen_buf(); emit(&cb, "..."); emit(&cb,
  d.name); … return rendered(&cb);`. `CodeBuf` is backed by **`__str_cat`**, a
  VM-native string-concat builtin (`str_concat` opcode in the engine, operating on
  the VM's interned strings) — so it needs **no `Arena`, no raw pointers, no
  imports**, and runs cleanly in the comptime VM. `evalToString` accepts the
  resulting `[]const u8`. The `#derive(sum)` demo (emit a `sum_<T>` for every
  struct, summing its fields) works end-to-end. *Why not `StringBuilder`:*
  `std.heap.Arena` uses `VirtualAlloc` + raw `slice_from_raw_parts`, which the
  cell-based comptime VM can't model (it's `Unsupported` → trap-stub); `#run` hides
  this by falling back to runtime, but a hook can't fall back. `CodeBuf` sidesteps
  the heap entirely. (Bonus robustness shipped alongside: the hook-pass sema is now
  continue-on-error, and an unknown-typed slice lowering is graceful, not an ICE.)
  Minor known limit: K2 string literals don't process `\n` escapes, so use a space
  separator between generated decls.

### R2. Capability-sandboxed metaprogramming — *the flagship*
**The structural fix to the `build.rs`/Jai supply-chain hole.** K2 already has no
ambient authority: the only way to touch the OS is through a granted **interface**.
So a dependency's compile-time hook receives a `*Compiler` carrying only an
`AstTransform` capability — it can rewrite ASTs but **physically cannot** open a
file, call FFI, or run `unsafe`. The root `build.k2` workspace gets the privileged
capabilities; third-party macros are limited to **pure AST transforms**. Enforced
by the VM capability table + restricting FFI/`unsafe` opcodes to the root
workspace. *No other systems language can offer "install this dependency, its
macros cannot harm your machine" as a structural guarantee.*

### R3. Content-addressed comptime caching — *sound only in K2*
Because R2 makes third-party comptime **pure** (no hidden I/O — all effects flow
through capabilities the compiler can observe or deny), a `#run f(args)` result
can be **cached by the content hash of (function IR + argument values)**. Re-builds
hit the cache; heavy generators (serializers, parser tables) compute once and are
reused across builds and machines. Zig/Jai can't safely cache comptime because it
may perform arbitrary, unobservable I/O. K2 *can*, because purity is enforced, not
hoped for. (We already have a stable content-hash primitive: `typeid_of`/FNV.)

### R4. `#derive` — reflective, capability-scoped generators
A first-class derive mechanism layered on R1+reflection: `#derive(Serialize, Eq)`
on a type invokes registered comptime plugins that walk `type_info(T)` and emit
impls. Plugins are **capability-scoped** (pure AST transforms, R2), so deriving
from an untrusted crate is safe. This is the practical killer app — automatic
serialization / equality / hashing / debug-printing with no per-type boilerplate
and no `build.rs` risk.

### R5. Zone-budgeted comptime
Leverage the comptime zone model (R-side already done): give each macro/hook a
**memory and step budget** drawn from its zone. A generator that blows its budget
(runaway recursion, pathological expansion) is killed with a diagnostic instead of
OOM-ing the compiler. Turns "zero-leak comptime" into "**bounded, fair** comptime"
— a denial-of-service guard for build-time code, again unique to the zone model.

### R6. Whole-program comptime invariants (`#require`)
After typecheck, a `#compiler` predicate runs over the **entire** typed program and
can assert global properties — "every `Component` struct is `#packed`", "no public
fn returns a zone-owned pointer", "this enum's variants form a closed protocol".
Program-wide, machine-checked design rules expressed in plain K2, enforced at build
time. Distinct from per-decl attributes: these are *cross-cutting* invariants.

### R7. Finish `#quote` reflection fidelity
Round-trip the new match patterns (range/string/guard/binding) through `AstPattern`
so quoted/reflected matches are faithful — needed before R4 derive plugins emit
matches.

---

## Critical files
- VM: `src/vm/{value,zones,engine,instructions,compiler,ffi}.zig`.
- Comptime ↔ pipeline: `src/ir.zig` (`run_expr`, `runCompilerHooks`,
  materialize/reify), `src/pipeline.zig` (`runCompilerHookPass`, prelude
  injection), `src/macroexpand.zig` (template macros).
- Surface: `src/ast_prelude.zig` (`std.compiler` `Decl`, `Any`, `TypeInfo`),
  `src/build.zig` (`k2 build`), `src/parser.zig`/`src/ast.zig` (`#quote`/`#insert`).

## Verification
- `zig build test` — VM opcode/e2e `#run`, zones (leak checks), reflection,
  macros, `#compiler` hooks, `k2 build`. comptime ≡ runtime is asserted by running
  the same programs at comptime and natively.
- Next (R1–R6): message-loop golden tests; a sandbox test proving a dependency
  hook is denied FFI/fs and that `unsafe`/`#extern` are rejected outside the root
  workspace; a cache hit/miss test; a `#derive(Serialize)` round-trip.
