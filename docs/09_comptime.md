# Compile-time execution

`#run` and everything built on it execute on a register bytecode VM (`src/vm/`).
The VM runs the same IR (`src/ir.zig`) the native backend lowers. One lowering, so
comptime and runtime share semantics — they don't drift, because there's no second
implementation to drift from.

Memory is the zone/arena model, at compile time: host-backed bump arenas that free
as zones exit. A `zone` block's memory is gone when the block ends, so comptime RAM
stays bounded instead of growing until the build finishes.

## The surface

- `#run expr` — evaluate at compile time, fold to a constant.
- `#insert <code>` — splice generated code at a site. The subtree is re-resolved and
  type-checked like hand-written code.
- `#quote { … }` / `#quote(expr)` — typed AST quotations (an `ast.Block` / `ast.Expr`
  value, parsed once at the definition site), with `$`-splices.
- `#parse(string)` — parse comptime text into code. The escape hatch.
- Template macros — `name :: macro(p) { return #quote { … }; }`, hygienic, splicing
  through every construct, with `#for` unrolling. See
  [13_metaprogramming.md](13_metaprogramming.md).
- First-class `ast.*` values — build a program in the VM, then `#insert #run gen()`.

Reflection — `type_info(T)`, `typeid_of`, `type_name`, constraints, runtime `Any` —
lives in [12_reflection_and_constraints.md](12_reflection_and_constraints.md).

## #compiler hooks

A `#compiler` function runs at comptime. It reads the program through
`compiler_decls()` — each `Decl` carries its shape: a struct's fields, an enum's
variants, a fn's params and return, and the decl's body source. It returns new
top-level declarations as source, which get spliced and re-checked. A generated
decl whose name matches an existing one replaces it. `compiler_remove(name)` drops
one. `compiler_error("msg")` halts the build with a diagnostic. Bare `#compiler`
runs before typecheck; `#compiler(final)` runs after generation, over the augmented
program.

`#derive`-style codegen is built on this — walk `type_info(T)`, emit the impl.

## Comptime FFI and build

Comptime code can call host DLLs, given the capability (below): `src/vm/ffi.zig` does
`LoadLibraryA`/`GetProcAddress` and marshals `Value` against the C ABI. `fels build`
is the same machinery — `build.fels` runs in the VM, lowering builder calls to
`__build_*` intrinsics that produce the build plan. See
[10_build_system.md](10_build_system.md).

## Capabilities

Host FFI needs the `ffi` capability. A bare `#run` has none — it's pure, and a call
into a host function halts the build:

    comptime FFI to `MulDiv` (in `kernel32`) is not allowed here: this ran as a
    pure `#run`, which has no `ffi` capability.

`build.fels` runs with `ffi` granted; it's the script you wrote, the trusted root. The
two primitives the comptime heap reserves pages through, `VirtualAlloc` and
`VirtualFree`, stay open to everyone — they hand back memory and nothing else.

The point is the supply chain. A dependency's compile-time code — a `#run`, a
`#compiler` hook — can't reach the host unless it was handed the capability to. That
shuts the `build.rs` hole: pulling in a package can't read your keys or spawn a
process while you compile. `unsafe` is the next effect to gate; granular caps
(`fs`, `net`) arrive with the package manager that gives them something to guard.
Code: `Vm.caps` in `src/vm/engine.zig`, checked at the FFI opcode.

## Data at compile time

**Arithmetic is the machine's.** The VM computes in 128 bits, then does to the result what the
operand's type would have done: `+%`, `-%`, `*%`, `<<`, `~` and `as` drop the bits the type
cannot hold. `0xFFFFFFFFu32 +% 1` is `0`, `300u32 as u8` is `44`, and the usual
`x ^= x << 13; x ^= x >> 17; x ^= x << 5` gives the numbers the machine gives — a hash or a
generator run at compile time and at run time agree. A plain `+`, `-`, `*` that overflows
traps in a debug build and wraps in a release build ([02_types](02_types.md#overflow-policy)),
so there is no single answer to match; the VM keeps the exact result, and a `#run` result the
type cannot hold is refused (below).

**Static data can be read.** A global that is a struct, an array, an enum value or a function
pointer (see [01_syntax](01_syntax.md#static-aggregates)) is there for compile-time code to
use: `TABLE[i]`, `ORIGIN.x`, `VT.add(1, 2)`, `&TABLE[2]`, `match MODES[i] { … }`, a copy
into a local. What the code sees is the global's *initial value* — the image is what runs, not
this. It is built the first time a run reads it, once per run however often it is read, and
it is **read-only**: a write through an element, a field, a pointer, or a copy that still
points at the table stops the build with "compile-time code cannot modify a global". A scalar
global is not assignable at compile time either.

Not readable yet: a global that holds the address of another (`A: Node = .{ 1, &B }`) and a
global that a `#run` computes. Reading one stops that run and names the global; the program
itself is unaffected.

**A computed constant can be an array length.** With `N :: #run count();` (or `N :: count();`),
`[N]i32` has `N` elements, as a local, a global, a parameter or a struct field. The type check
finds that it cannot fold `N`, the VM computes it, and the check runs again with the value, so a
literal with too many elements is an error against that length. A value that is not an integer,
or is negative, is an error at the constant.

**`#run` can return data.** Whatever type the call has, what it returns becomes the initial
value of the global, laid out like a literal and placed in the image — nothing runs at
startup:

```fels
CRC: [256]u32 = #run make_crc_table();       // the standard CRC-32 table, built by the compiler
SQUARES :: #run make_squares();              // an untyped constant takes the type of the call
CFG: Config = #run load_defaults();          // a struct, with strings, arrays, enum values inside
W: Wrap = .{ #run origin(), #run primes(), 5 };   // and as a field or an element of a literal
```

Only data survives the trip. A struct, an array (an element nothing wrote is zero, and trailing
zeros are not stored, as an array literal is zero past its last element), an enum value without
a payload, a number, a string (a `[]const u8` literal or a byte slice the code built), `null`
and the name of a plain function can. These are
refused with a message that says where in the value the problem is: a pointer into
compile-time memory (the program will not have that memory), a variant that carries a payload,
a lambda (it has no plain code address; name a function instead), a slice of anything but
bytes, a number the type cannot hold
(`the value 300 does not fit in u8`). A global that a `#run` computes cannot be read by another
`#run`, since the VM is built before any `#run` has a value.

## Caching

Purity pays off here. A pure `#run` is a deterministic function of its bytecode, so
its result is content-addressable: hash the thunk plus its call closure, name a file
by that hash, skip the run when the file already exists. `FELS_CACHE=1` turns it on
(opt-in while it's young).

    grind(5_000_000) at comptime:  ~600 ms cold  →  ~6 ms warm

The key covers the thunk's bytecode, every function it transitively calls, their
constant pools, and a format/host salt. Change any of it — the input, a helper three
calls down, a single literal — and the key moves and the value recomputes. A stale
read isn't possible, because whatever changed is part of the key.

When the closure can't be pinned from bytecode alone — it reaches FFI, a global, an
indirect call, a print — there's no key and the `#run` just runs. Slice 1 stores
scalar results; aggregates (tables, structs) wait on `Value` serialization, and a
`#run` that returns one is always evaluated. Entries live under `.fels-cache/`.
Code: `src/vm/run_cache.zig`.

## Limits

`#quote` reflects range/string/guard/binding match patterns as the catch-all
`anything`. Quoting still works; reflecting on those specific patterns is lossy.
