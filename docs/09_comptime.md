# Compile-time execution

`#run`, and everything built on it, executes on a register bytecode VM (`src/vm/`). The VM runs
the same IR (`src/ir.zig`) that the native backend lowers. Because there is only one lowering,
comptime and runtime share their semantics. They don't drift apart, because there is no second
implementation to drift from.

Memory at compile time follows the zone/arena model too. The arenas are host-backed bump arenas,
and they free their memory as zones exit. A `zone` block's memory is gone when the block ends,
so comptime RAM stays bounded instead of growing until the build finishes.

A `std.heap` arena's memory is real memory at compile time too, so code that uses it runs as it
would in a compiled program. That covers slices of it and of string constants, a `Vec` of
slices, a pointer cast (`p as *T`) and a pointer as a number (`p as usize`).

## The surface

- `#run expr`: evaluates at compile time and folds to a constant.
- `#insert <code>`: splices generated code at a site. The subtree is resolved and type-checked
  again, like hand-written code.
- `#quote { … }` / `#quote(expr)`: typed AST quotations with `$`-splices. Each one is an
  `ast.Block` or an `ast.Expr` value, parsed once at the definition site.
- `#parse(string)`: parses comptime text into code. This is the escape hatch.
- Template macros: `name :: macro(p) { return #quote { … }; }`. They are hygienic, they splice
  through every construct, and they support `#for` unrolling. See
  [13_metaprogramming.md](13_metaprogramming.md).
- First-class `ast.*` values: build a program in the VM, then `#insert #run gen()`.

Reflection (`core::type_info(T)`, `core::type_id`, `core::type_name`, constraints and the
runtime `Any`) has its own page, [12_reflection_and_constraints.md](12_reflection_and_constraints.md).

## #compiler hooks

A `#compiler` function runs at comptime and reads the program through `core::compiler_decls()`.
Each `Decl` carries its shape: a struct's fields, an enum's variants, a fn's params and return,
and the decl's body source. The function returns new top-level declarations as source, and these
are spliced in and checked again. A generated decl whose name matches an existing one replaces
it, and `core::compiler_remove(name)` drops one. `core::compiler_error("msg")` halts the build
with a diagnostic. A bare `#compiler` runs before typecheck, and `#compiler(final)` runs after
generation, over the augmented program.

`#derive`-style codegen is built on this: you walk `core::type_info(T)` and emit the impl.

## Comptime FFI and build

Comptime code can call host DLLs when it has the capability for it (see below). `src/vm/ffi.zig`
does `LoadLibraryA`/`GetProcAddress` and marshals `Value` against the C ABI. `fels build` uses
the same machinery. `build.fels` runs in the VM, and its builder calls are lowered to
`__build_*` intrinsics that produce the build plan. See [10_build_system.md](10_build_system.md).

## Capabilities

Host FFI needs the `ffi` capability. A bare `#run` has none. It is pure, and a call into a host
function halts the build:

    comptime FFI to `MulDiv` (in `kernel32`) is not allowed here: this ran as a
    pure `#run`, which has no `ffi` capability.

`build.fels` runs with `ffi` granted, because it is the script you wrote and so the trusted
root. The comptime heap reserves its pages through two primitives, `VirtualAlloc` and
`VirtualFree`. These stay open to everyone, since they hand back memory and nothing else.

All of this is about the supply chain. A dependency's compile-time code, such as a `#run` or a
`#compiler` hook, can't reach the host unless it was handed the capability to. That shuts the
`build.rs` hole: pulling in a package can't read your keys or spawn a process while you compile.
`unsafe` is the next effect to gate. Granular caps (`fs`, `net`) arrive with the package manager
that gives them something to guard. In the code, this is `Vm.caps` in `src/vm/engine.zig`, and
it is checked at the FFI opcode.

## Data at compile time

**Arithmetic is the machine's.** The VM computes in 128 bits, and then it does to the result what
the operand's type would have done. So `+%`, `-%`, `*%`, `<<`, `~` and `as` drop the bits that
the type cannot hold. `0xFFFFFFFFu32 +% 1` is `0`, `300u32 as u8` is `44`, and the usual
`x ^= x << 13; x ^= x >> 17; x ^= x << 5` gives the numbers the machine gives. So a hash or a
generator run at compile time agrees with the same one run at run time. A plain `+`, `-` or
`*` that overflows traps in most builds and wraps in a `release_fast` one
([02_types](02_types.md#overflow-policy)), so there is no single answer to match. The VM keeps
the exact result, and a `#run` result that the type cannot hold is refused (see below).

**Static data can be read.** A global that is a struct, an array, an enum value or a function
pointer (see [01_syntax](01_syntax.md#static-aggregates)) is there for compile-time code to use.
You can write `TABLE[i]`, `ORIGIN.x`, `VT.add(1, 2)`, `&TABLE[2]` or `match MODES[i] { … }`, or
copy the global into a local. What the code sees is the global's *initial value*. The image is
what runs, not this. The value is built the first time a run reads it, once per run however often
it is read, and it is **read-only**. A write through an element, a field, a pointer, or a copy
that still points at the table stops the build with "compile-time code cannot modify a global".
So does an assignment to a scalar global (`counter = counter + 1` in a `#run`). When a test does
this, `fels test` runs that test at run time instead.

Two kinds of global cannot be read yet: one that holds the address of another
(`A: Node = .{ 1, &B }`), and one that a `#run` computes. Reading one of them stops that run and
names the global, but the program itself is unaffected.

**A computed constant can be an array length.** With `N :: #run count();` (or `N :: count();`),
`[N]i32` has `N` elements, whether it is a local, a global, a parameter or a struct field. The
type check finds that it cannot fold `N`, so the VM computes it and the check runs again with the
value. A literal with too many elements is then an error against that length. A value that is not
an integer, or is negative, is an error at the constant.

**`#run` can return data.** Whatever type the call has, what it returns becomes the initial
value of the global. It is laid out like a literal and placed in the image, so nothing runs at
startup:

```fels
CRC: [256]u32 = #run make_crc_table();       // the standard CRC-32 table, built by the compiler
SQUARES :: #run make_squares();              // an untyped constant takes the type of the call
CFG: Config = #run load_defaults();          // a struct, with strings, arrays, enum values inside
W: Wrap = .{ #run origin(), #run primes(), 5 };   // and as a field or an element of a literal
```

Only data survives the trip. A struct can, and so can an array, an enum value without a payload,
a number, a string (a `[]const u8` literal or a byte slice the code built), `null` and the name of
a plain function. In an array, an element that nothing wrote is zero, and trailing zeros are not
stored, in the same way that an array literal is zero past its last element.

These are refused, with a message that says where in the value the problem is:

- a pointer into compile-time memory, because the program will not have that memory
- a variant that carries a payload
- a lambda, because it has no plain code address (name a function instead)
- a slice of anything but bytes
- a number the type cannot hold (`the value 300 does not fit in u8`)

A global that a `#run` computes cannot be read by another `#run`, since the VM is built before
any `#run` has a value.

## Caching

This is where purity pays off. A pure `#run` is a deterministic function of its bytecode, so its
result is content-addressable. The cache hashes the thunk together with its call closure, names a
file after that hash, and skips the run when the file already exists. `FELS_CACHE=1` turns it on.
It is opt-in while it is young.

    grind(5_000_000) at comptime:  ~600 ms cold  →  ~6 ms warm

The key covers the thunk's bytecode, every function it calls transitively, their constant pools,
and a format/host salt. If you change any of it (the input, a helper three calls down, a single
literal), the key moves and the value is computed again. A stale read isn't possible, because
whatever changed is part of the key.

Sometimes the closure can't be pinned from bytecode alone, because it reaches FFI, a global, an
indirect call or a print. Then there is no key, and the `#run` runs as usual. Slice 1 stores
scalar results. Aggregates (tables, structs) wait on `Value` serialization, so a `#run` that
returns one is always evaluated. Entries live under `.fels-cache/`, and the code is in
`src/vm/run_cache.zig`.

## Limits

`#quote` reflects range, string, guard and binding match patterns as the catch-all `anything`.
Quoting them still works, but reflecting on those specific patterns is lossy.
