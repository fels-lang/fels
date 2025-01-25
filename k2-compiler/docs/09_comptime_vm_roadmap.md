# K2 Comptime Bytecode VM & Metaprogramming — Design Roadmap

> Status: **design doc** (no implementation yet). This describes the architecture for
> replacing the comptime tree-walker with a bytecode VM and the metaprogramming features
> built on top of it. See `src/vm/` for the in-progress skeleton.

## Context

K2's compile-time execution today runs on a **tree-walking interpreter** (`src/comptime.zig`)
that re-walks the type-checked AST for every `#run`, `#if`, and generic instantiation. It models
values with a `ComptimeValue` union and has no real memory model — `arena.new()` and zones are not
executed, only type-checked. This caps how far metaprogramming can go and means comptime code does
**not** behave identically to runtime code.

The goal is to match and then exceed Jai's metaprogramming by replacing the tree-walker with a
**register-based bytecode VM** that:

- executes the existing K2 **IR** (`src/ir.zig`), so comptime and runtime share one lowering and
  behave identically;
- faithfully models K2's signature **Zone/Arena** memory at compile time, giving zero-leak comptime
  execution that frees as zones exit;
- grows into a full compiler API (AST injection, FFI, message loop) and ultimately
  **capability-sandboxed** metaprogramming — fixing the `build.rs`/Jai supply-chain hole.

Three decisions are locked:

1. **Lower from IR, not AST.** The IR already encodes zones (`zone_push`/`zone_pop`/`alloc` carry
   zone names), basic blocks, and complete types. `src/vm/compiler.zig` already targets
   `ir.IrFunction`. One lowering = comptime ≡ runtime semantics.
2. **Tagged `Value` union** for the register/value model (not raw `u64`). Mirrors the proven
   `ComptimeValue` shape but adds real zone-backed pointers.
3. **The VM replaces the tree-walker.** `src/comptime.zig` is retired once the VM reaches parity;
   `#run` routes only through the VM. (No permanent fallback path — see Phase 1.6 migration.)

---

## Current State (what exists vs. what's needed)

**Exists and usable:**
- IR is a solid lowering target: `IrFunction` → `IrBlock[]` → `Instr[]` + `Terminator`, with
  named registers (`RegId: u32`), `Value` (`reg`/`param`/`local`/`global`/`imm`), full `IrType`,
  and zone-tagged `alloc`/`alloc_slice`/`zone_push`/`zone_pop`/`zone_free`. (`src/ir.zig`)
- VM skeleton: `src/vm/instructions.zig` (62-opcode `Opcode` enum, `Instr`, `BytecodeFunction`),
  `src/vm/engine.zig` (`Vm`, ~10 opcodes), `src/vm/compiler.zig` + `compiler_{math,memory,calls,types}.zig`.
- One passing smoke test: `tests/compiler/vm.zig` (hand-assembled `10 + 32 → 42`).
- Comptime integration point already wired: `ir.zig`'s `run_expr` lowering calls
  `comptime_mod.evalExpr` then `comptimeToValue`. This is the seam the VM plugs into.

**Toy-grade and must be redesigned (not extended):**
- Registers are `[1024]u64` — cannot hold `i128`/`f64`/structs/slices/strings/type values.
- Branch terminators emit `jmp <block_id>` but the engine treats `imm` as an **instruction
  index** → control flow is broken for anything past a single block. Needs a block→offset pass.
- Operand fields `a/b/c` are `u8` (max 256), but `RegId`/`Reg` are `u32`. Width mismatch; the
  `@intCast(id)` calls in `compiler.zig`/`compiler_*.zig` truncate silently.
- No call stack / frames — `execute` returns a single `u64`. No `call`, no locals, no globals.
- Zone opcodes (`zone_push/pop/alloc`) are emitted but do nothing at runtime.
- `num_locals = params.len` only; non-param locals untracked.

---

## Phase 1 — The Virtual Machine & Memory Foundation

**Outcome:** a VM that executes real K2 IR functions (arithmetic, control flow, locals, calls,
structs, slices, strings) and **actually runs zones** (host memory allocated on `arena.new()`,
freed on zone exit), wired into `#run` as the sole comptime engine.

### 1.1 Value model — tagged `Value` union (`src/vm/value.zig`, new)

Replace `[1024]u64` registers with slots of:

```
Value = union(enum) {
    void,
    int:    i128,            // all signed widths; width carried by IrType at the instr
    uint:   u128,            // all unsigned widths
    float:  f64,
    bool:   bool,
    // zone-backed pointer: index of owning zone + byte offset into its arena
    ptr:    struct { zone: ZoneId, offset: u32, elem: *const ir.IrType },
    slice:  struct { zone: ZoneId, offset: u32, len: usize, elem: *const ir.IrType },
    string: []const u8,      // interned in VM string arena
    struct_ref: struct { zone: ZoneId, offset: u32, ty: *const ir.IrType },
    variant: struct { tag: u32, payload_zone: ZoneId, payload_offset: u32 },
    type_val: sema.Ty,       // first-class types ($T), as today's ComptimeValue.type_val
    fn_ref: u32,             // index into VM function table
    null_ptr,
}
```

Aggregates live in **zone-backed memory** (see 1.4), addressed by `(ZoneId, offset)`, not host
pointers — this keeps the VM relocatable and makes zone frees trivially correct. Scalars live
inline in registers. `value.zig` owns conversion helpers `fromImm`, `fromComptime`/`toComptime`
(bridge to the old representation during migration), and `coerce(value, IrType)`.

### 1.2 Instruction format & control flow (`src/vm/instructions.zig`, revise)

- Widen `Instr` operands to `u32` (`a`, `b`, `c`, plus a `u64` or payload index `imm` so wide
  immediates/float bits fit). Keep the `r_r_r` / `r_r_imm` / `r_imm` constructors.
- Add a **block-offset resolution pass** in `compiler.zig`: record each `IrBlock`'s start index in
  the flattened instruction stream, then rewrite `jmp`/`br_if`/`br_if_not` targets from `BlockId`
  to instruction offsets. Fixes the current latent jump bug.
- Large/!-fitting immediates (i128, f64, strings, type values) move into a per-function
  **constant pool** on `BytecodeFunction`; `load_imm` references a pool index.

### 1.3 Frames, locals, and calls (`src/vm/engine.zig`, rewrite)

- Introduce a **call stack** of frames: each frame has its own register window + local slots +
  the active-zone watermark (for unwinding). `BytecodeFunction` gains `num_regs`, `num_locals`,
  `params`, `constant_pool`.
- Implement the remaining opcodes in tiers:
  - **Tier A (scalar core):** all `*_i`/`*_f` arithmetic, comparisons, bitwise, `neg`, casts,
    `copy`, `load_imm`, `load_local`/`store_local`, `ret`/`ret_void`, fixed `jmp`/`br_if`.
  - **Tier B (calls & globals):** `call` (resolve IR `call` → function-table index; push frame,
    bind params, copy return), `call_indirect` via `fn_ref`, `load_global`/`store_global` against
    a VM global table seeded from module constants.
  - **Tier C (aggregates):** `struct_init`/`field_addr`/`load_ptr`/`store_ptr`,
    `index_addr`/`slice_init`, `variant_*`, `opt_*`, `try_*` — all reading/writing zone memory.
- Resolve the lowering TODOs in `compiler_memory.zig` (local name → slot index) and
  `compiler_calls.zig` (callee name → function index) by building name→index maps when assembling
  the `BytecodeFunction` / VM module.

### 1.4 Comptime Zones — the differentiator (`src/vm/zones.zig`, new)

This is what makes comptime ≡ runtime and gives zero-leak metaprogramming.

- A `ZoneStack` of arenas. `zone_push(name, kind)` allocates a host-backed arena (bump allocator
  over a growable buffer) and pushes a `ZoneId`; `zone_pop(name)` frees the entire arena.
- `zone_alloc` / `alloc` / `alloc_slice` bump-allocate inside the **named** zone and return a
  `Value.ptr`/`.slice` carrying that `ZoneId`. `zone_free(zone, ptr)` validates the ptr's `ZoneId`
  matches (sema already guarantees this statically; the VM asserts as defense-in-depth).
- **Unwinding:** on `ret`/`fail`/error propagation the engine pops every zone above the frame's
  entry watermark, in reverse order — mirroring `ir.zig`'s return/fail lowering that already emits
  `zone_pop` for each active zone. Result: comptime RAM footprint stays microscopic; arenas free
  as their blocks exit, no compiler-lifetime growth.
- Defends Phase 5: because all comptime allocation is zone-scoped and host memory never leaks into
  raw pointers the user can hold across zone exit, the VM has a natural boundary to sandbox.

### 1.5 Integration with the pipeline (`src/ir.zig`, `src/root.zig`)

- Replace the `run_expr` hook in `ir.zig` (currently `comptime_mod.evalExpr` + `comptimeToValue`)
  with: lower the operand to a temporary IR function → `vm.Compiler.compileFunction` →
  `vm.Vm.execute` → convert the resulting `Value` back to an IR `Value`/immediate (the
  `comptimeToValue` analogue, now in `value.zig`).
- Generic struct/`#if` evaluation that currently calls into `comptime.zig` re-points to the VM.
- `root.zig` already exports `vm_engine`/`vm_instructions`/`vm_compiler`; add `vm_value`/`vm_zones`.

### 1.6 Migration & retiring the tree-walker

Even though the end state has **no fallback**, retire `comptime.zig` safely:

1. Stand up the VM behind the same entry points, keeping `comptime.zig` callable.
2. Add a differential test mode: run both engines on the comptime corpus, assert equal results.
3. Port each construct (literals → control flow → locals → calls → aggregates → zones → reflection
   `sizeof`/`type_name`/`type_info` → `TARGET.*`) until parity.
4. Delete `src/comptime.zig` and the `ComptimeValue` bridge; `#run` is VM-only.

### 1.7 Tests (`tests/compiler/vm.zig`, expand)

Grow from the single smoke test to: per-opcode unit tests; end-to-end `#run` programs (recursion,
loops, structs, slices, strings); **zone tests** asserting allocation counts and that host memory
is released on zone exit (leak check via a counting allocator); differential tests vs. the
tree-walker during migration; reflection tests (`sizeof`, `type_info`, `TARGET.*`).

---

## Phase 2 — AST Injection & FFI

**Outcome:** K2 can generate K2, and comptime code can call the outside world.

### 2.1 `#insert` directive
- Allow a `#run` expression to yield `[]const u8`. Feed that string back through `src/tokens.zig`
  → `src/parser.zig`, producing AST nodes spliced into the sema queue at the insertion site.
- New AST node `insert_expr`/`insert_stmt` in `src/ast.zig` (sibling of the existing `run_expr`,
  `comptime_run`). Sema re-enters name resolution + type checking on the spliced subtree, inside
  the enclosing scope.
- Pipeline change: `src/pipeline.zig` / `src/sema.zig` gain a re-entrant "splice and re-check"
  path so injected nodes are analyzed like hand-written code.

### 2.2 Comptime FFI (`#extern`)
- A `libffi`-style bridge so `#extern` functions resolve and execute during compilation (load
  `kernel32.dll` / `libc`, make real calls). New `src/vm/ffi.zig`; the VM marshals `Value` ↔ C ABI.
- **Gated** from day one: FFI is a capability the VM only grants to the root workspace (sets up
  Phase 5). Third-party macros cannot reach it.

### 2.3 Host standard library in the VM
- Ensure `std.io` / `std.fs` compile and run inside the VM so comptime code can read config files,
  list directories, and generate code from the filesystem. These are surfaced as **capabilities**
  (`FileSys`, `Writer`, …) — K2 already models these as first-class interface types in `sema.Ty`,
  so the VM provides host-backed implementations behind those interfaces.

---

## Phase 3 — The Compiler API & Message Loop (matching Jai)

**Outcome:** user-space K2 can inspect and modify the program as it compiles.

### 3.1 `std.compiler` module
- Expose internal structures to user code as K2 types mirroring `sema.Ty`, `ast.Expr`, `TypeInfo`,
  `sema.TypeLayout`/`FieldInfo`/`VariantInfo`. The VM bridges between user-space K2 values and the
  compiler's live Zig structures (read-mostly, with controlled mutation in 3.2).

### 3.2 Message-loop hooks
- Architect `src/pipeline.zig` to emit events — `Message_File_Parsed`, `Message_Typechecked`,
  (and a completion message) — as each phase finishes a unit.
- User-space K2 registers callbacks (run in the VM) that intercept messages, inspect/alter types
  of declarations, and add code before lowering. This is the Jai-style compile-time message loop.

### 3.3 Build scripts (`k2 build`)
- A mode where the entry point is **not** compiled to an `.exe` but executed entirely in the VM:
  it configures target arch, adds source files to the workspace, and drives the message loop.
- Driver work in `src/main.zig` / `pipeline.zig`; the build script is "just" comptime K2 with the
  `std.compiler` capability granted.

---

## Phase 4 — Exceeding Jai (K2-unique innovations)

### 4.1 Typed AST quotations (`#quote`)
- Introduce `#quote { ... }` returning a **typed AST node** (`ast.Block`/`ast.Expr`), not a string
  — e.g. `macro :: fn() -> ast.Block { return #quote { x := 42; println("Fast!"); }; }`.
- New AST node + parser support; the quoted body is parsed **once** at definition site (syntax
  validated, optionally pre-typed), then injected directly into sema — no re-lex/re-parse per
  expansion. Orders of magnitude faster than Jai's string `insert`, and generated code is
  guaranteed syntactically correct at the generation site.
- Splicing reuses the Phase 2.1 re-entrant sema path, but starting from AST nodes instead of text.

### 4.2 Zero-leak comptime memory
- Already delivered structurally by Phase 1.4: because comptime allocation is zone-scoped and
  arenas free as blocks exit, heavy code-generation runs with a microscopic, bounded RAM footprint
  — unlike Zig/Jai, whose compile-time memory grows until the build ends. Phase 4 adds the
  stress tests and metrics proving it (peak-RSS assertions over large generators).

---

## Phase 5 — Secure Metaprogramming (the supply-chain fix)

**Outcome:** building a malicious dependency **cannot** run arbitrary host code — K2's structural
answer to the `build.rs` / Jai problem.

### 5.1 Capability-based sandboxing
- The message loop passes **restricted capabilities** to dependency build hooks. A dependency's
  `build_plugin :: fn(ctx: *Compiler, fs: *VirtualFileSys)` receives a `VirtualFileSys` that can
  only read inside its own folder — it physically cannot `#import std.fs` and touch `C:\`.
- Enforced by the VM capability table (Phases 2.2/2.3/3.1): capabilities are unforgeable values
  the VM hands out per-workspace. K2's interface/capability system makes this natural — there is no
  ambient authority to reach the OS except through a granted interface.

### 5.2 Strict comptime auditing
- Restrict `unsafe` blocks and `#extern` FFI to the **root `build.k2` workspace** only. Third-party
  library macros are thereby limited to **pure AST transformations** and cannot compromise the host
  OS. The VM rejects FFI/`unsafe` opcodes when the active workspace lacks the privileged capability.

---

## Critical files

**Phase 1 (core):**
- `src/vm/value.zig` *(new)* — tagged `Value` union + conversions.
- `src/vm/zones.zig` *(new)* — host-backed arena stack, alloc/free/unwind.
- `src/vm/engine.zig` *(rewrite)* — frames, call stack, full opcode set.
- `src/vm/instructions.zig` *(revise)* — u32 operands, constant pool, wide imm.
- `src/vm/compiler.zig` + `compiler_{math,memory,calls,types}.zig` *(complete)* — block→offset
  pass, local/global/callee resolution, finish stubbed lowerings.
- `src/ir.zig` *(edit)* — repoint `run_expr` (and generic/`#if`) hooks to the VM.
- `src/root.zig` *(edit)* — export `vm_value`, `vm_zones`.
- `src/comptime.zig` *(delete at 1.6)*; `tests/compiler/vm.zig` *(expand)*.

**Phases 2–5 (later):**
- `src/ast.zig`, `src/parser.zig`, `src/tokens.zig`, `src/sema.zig`, `src/pipeline.zig`,
  `src/main.zig` — `#insert`/`#quote` nodes, re-entrant splice-and-recheck, message-loop events,
  `k2 build` mode, capability plumbing.
- `src/vm/ffi.zig` *(new)* — gated comptime FFI.

## Verification

- **Phase 1:** `zig build test` with the expanded `tests/compiler/vm.zig` (per-opcode, e2e `#run`,
  zone leak checks via counting allocator, reflection). Differential pass vs. `comptime.zig` until
  it is deleted, then VM-only. Build sample K2 programs that use `#run` and confirm identical
  output to today's tree-walker (and to runtime execution of the same code).
- **Phases 2–5:** golden-file tests for `#insert`/`#quote` expansion; an FFI smoke test calling a
  libc function at comptime (root workspace only); a sandbox test asserting a dependency hook is
  denied filesystem access outside its folder and that `#extern`/`unsafe` are rejected outside the
  root workspace.

## Open questions (resolve before Phase 2+)
- IR is non-SSA (mutable registers). Fine for a tree-walking-style VM; revisit if/when we want
  comptime optimization passes.
- Exact `std.compiler` surface and which compiler structures are user-mutable vs. read-only.
- Whether `#quote` nodes are pre-typed at definition site or only at splice site (perf vs. hygiene).
