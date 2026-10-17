# Attributes and Builtins

## Attributes

Attributes modify the behavior or layout of declarations. They are prefixed with `#`.

### Layout Attributes

- `#packed`: applied to a `struct`. Packs the fields tightly without padding (alignment 1). Sub-byte fields (`u1`–`u7`) still take a whole byte each: there is no bit packing yet (see [Packed structs](02_types.md#packed-structs)).
- `#align(N)`: C's `alignas(N)` for a `struct`. `N` is an integer literal and a power of
  two (1 to 4096). The struct is aligned to at least `N` and its size is rounded up to a
  multiple of `N`, wherever it lives: as a local or global, as a field of another struct
  (placed at an `N`-aligned offset), or as an array element. Example: `#align(64)`.
  On a `#packed` struct only the size is rounded up; the fields stay back to back.
  `core::sizeof` agrees at compile time and at run time.

### Function Attributes

- `#inline`: hints the compiler to inline the function.
- `#noinline`: prevents the compiler from inlining the function.
- `#noreturn`: specifies that the function never returns (e.g., exit or panic).
- `#naked`: produces a function without standard prologue or epilogue. Typically used for raw inline assembly entry points.
- `#entry`: designates the function as the program entry point (an alternative to naming it `main`).
- `#cold`: marks a rarely-called function so the optimizer moves it off the hot path (a real LLVM `cold` attribute).
- `#section("name")`: places the function in a specific object-file section.
- `#keep`: never strip the function, even if it's unused (forces non-internal linkage).

### FFI & Linkage

- `#export("name")`: exports the symbol with external linkage. If no string is provided, exports it using its Fels name. It applies to a function and to a top-level global (`#export("gab_entry") ENTRY: PluginEntry = .{ ... };`) — see [11_c_interop](11_c_interop.md#exporting-data).
- `#extern("library_name", "symbol_name")`: declares an external function binding (FFI).
  The second argument is the **real link symbol** — the Fels declaration name is free to
  differ from the C symbol — a binding can take an idiomatic Fels name:
  ```fels
  #extern("kernel32", "WriteFile")
  WriteFile :: fn(...) -> bool;          // Fels name == C symbol

  #extern("ws2_32", "connect")
  sys_connect :: fn(...) -> i32;         // Fels name `sys_connect`, links `connect`
  ```
  Two externs may bind the same C symbol under different Fels names (the one external
  declaration is deduplicated at link time). A plain Fels function may even share a name
  with a renamed extern's C symbol (e.g. a `connect` wrapper over `sys_connect`); the
  wrapper keeps internal linkage under a module-private symbol so the two don't clash.
- `#foreign`: Alias for `#extern`.
- `#system_library("libname")`: A top-level directive that tells the linker to link against the specified system library.
- `#link_name("name")`: sets the function's external symbol name **without** exporting it (distinct from `#export`).
- `#weak`: emits a weak symbol that another definition can override at link time.

### Diagnostics

- `#deprecated("message")`: Triggers a deprecation warning at the call site.
- `#must_use`: the caller may not discard the function's return value — `f();` as a statement is an error; use `x := f()` or `_ := f()`.
- `#maybe_unused`: marks a declaration as possibly unused (accepted; suppresses any future unused-declaration warning).

## Builtins — the `core::` namespace

Builtins live in the reserved **`core::`** namespace — compiler-provided operations,
always in scope (no import). The `core::` prefix makes a builtin call visually
distinct from an ordinary function call:

```fels
n   := core::sizeof(Point);          // a builtin — you can see the compiler is involved
name := core::type_name(Point);      // "Point"
buf := unsafe core::slice_raw(u8, p, len);
if bad { core::panic("invalid state"); }   // no-return
```

`core` is reserved: a user module/import may not be named `core` (it's a compile
error). Some builtins require an `unsafe` block (last column).

> **Bare names are rejected.** Calling a builtin by its bare name (`sizeof(T)`,
> `ptr_from_int(...)`, …) is a hard error pointing you at the `core::` form. A few
> names were tidied in the move: `typeid_of` → `core::type_id`, `truncate_to` →
> `core::narrow`, `slice_from_raw_parts` → `core::slice_raw`. The old names still work
> behind `core::` (`core::typeid_of`), but these docs use the new ones. (`@panic` keeps its
> sigil and also works as `core::panic`.)

| Builtin | Signature | Unsafe? | Description |
|---------|-----------|---------|-------------|
| `core::sizeof` | `core::sizeof($T: type) -> usize` | No | Size of `T` in bytes, padding included. |
| `core::align_of` | `core::align_of($T: type) -> usize` | No | Alignment `T` requires, in bytes. Folds at compile time. |
| `core::offset_of` | `core::offset_of($T: type, "field") -> usize` | No | Byte offset of `field` in struct `T`; the field is a string literal. Folds at compile time. |
| `core::narrow` | `core::narrow($T: type, val) -> T` | No | Truncate a wider integer into a narrower `T`. |
| `core::type_name` | `core::type_name($T: type) -> []const u8` | No | The type's name as a string. |
| `core::type_info` | `core::type_info($T: type) -> TypeInfo` | No | Compile-time reflection data (fields, variants, …). |
| `core::type_id` | `core::type_id($T: type) -> usize` | No | Stable runtime type id. |
| `core::any` | `core::any(x) -> Any` | No | Wrap a value into a type-erased `Any`. |
| `core::panic` | `core::panic(msg: []const u8) -> never` | No | Abort with a message; never returns. |
| `core::atomic_load` | `core::atomic_load(ptr, ord) -> T` | No | Atomic load with ordering `ord`. |
| `core::atomic_store`| `core::atomic_store(ptr, val, ord)` | No | Atomic store. |
| `core::atomic_add`/`_sub`/`_and`/`_or`/`_xor` | `core::atomic_add(ptr, v, ord) -> T` | No | Read-modify-write; returns the **previous** value. |
| `core::atomic_max`/`_min` | `core::atomic_max(ptr, v, ord) -> T` | No | Atomic max/min (signed vs unsigned chosen from `T`). |
| `core::atomic_exchange` | `core::atomic_exchange(ptr, v, ord) -> T` | No | Swap; returns the previous value. |
| `core::atomic_cas` | `core::atomic_cas(ptr, expected, desired, ord) -> T` | No | Compare-and-swap; returns the value seen (`== expected` on success). |
| `core::atomic_fence` | `core::atomic_fence(ord)` | No | Memory fence. |
| `core::ptr_from_int`| `core::ptr_from_int($T: type, addr: usize) -> T` | **Yes** | Integer address → pointer `T`. |
| `core::fn_ptr`| `core::fn_ptr(f) -> *void` | **Yes** | Raw thin pointer of a top-level function, for a C callback / thread entry (fels's ordinary fn value is a fat closure a C ABI can't call). |
| `core::slice_raw`| `core::slice_raw($T, ptr, len) -> []T` | **Yes** | Build a slice from a raw pointer + length. |
| `core::volatile_store`| `core::volatile_store(ptr: *T, val: T)` | **Yes** | Volatile memory write. |
| `core::unaligned_read`| `core::unaligned_read($T: type, ptr) -> T` | **Yes** | Read `T` from a possibly-unaligned address. |
| `core::asm` | `core::asm(...)` | **Yes** | Inline assembly: `core::asm(volatile, "inst", inputs: {}, outputs: {}, clobbers: {})` |

The trailing `ord` is an integer ordering constant — `0` relaxed, `1` acquire, `2` release,
`3` acq_rel, `4` seq_cst — and **must be compile-time known**. Prefer the
[`std.atomics`](07_stdlib.md#stdatomics) wrappers, which default to seq_cst.

### Source-location & target constants

Compile-time constants (no parens) that fold to a literal at the use site:

| Constant | Type | Value |
|---|---|---|
| `core::file` | `[]const u8` | the current source file path |
| `core::module` | `[]const u8` | the module name (file basename, no `.fels`) |
| `core::func` | `[]const u8` | the enclosing function's name |
| `core::line` | `i32` | the line of the `core::line` reference |
| `core::column` | `i32` | the column |
| `core::os` | `[]const u8` | the OS the program is built for (`"windows"`, `"linux"`), as `TARGET.os` |
| `core::arch` | `[]const u8` | the architecture the program is built for (`"x86_64"`), as `TARGET.arch` |

```fels
log :: fn(msg: []const u8) { print(core::file); print_i64(core::line as i64); print(msg); }
```

### Math

`core::min(a,b)`, `core::max(a,b)`, `core::abs(x)`, `core::clamp(x, lo, hi)` (int or
float), and the float functions `core::sqrt`, `core::floor`, `core::ceil`,
`core::round`, `core::trunc`, `core::sin`, `core::cos`, `core::pow(x, y)`,
`core::fma(a, b, c)`. Each returns its first argument's type and maps to a fast CPU
instruction. All except `fma` also **fold at compile time** (usable in `#run`).

### Bit operations

On any integer: `core::count_ones(x)`, `core::count_zeros(x)`,
`core::leading_zeros(x)`, `core::trailing_zeros(x)`, `core::swap_bytes(x)`,
`core::reverse_bits(x)`, `core::rotate_left(x, n)`, `core::rotate_right(x, n)`.
Each returns `x`'s type. `core::count_ones` folds at compile time; the
width-dependent ones currently fall back to runtime inside `#run`.

### Memory & control

`core::memcpy(dst, src, n)`, `core::memset(dst, byte, n)`, `core::trap()`,
`core::unreachable()`, `core::prefetch(ptr)`, `core::cycle_count() -> u64`. These are
the low-level primitives the standard library wraps.

## Compile-Time Directives

### Compile-time If (`#if`)

Evaluates a condition at compile time and includes only the active branch in the IR.
`#if` is a **statement**: it appears inside a function body, not at the top level, so it
chooses code, not declarations.

```fels
width :: fn() -> i32 {
    #if core::sizeof(usize) == 8 {
        return 64;
    } else {
        return 32;
    }
}
```

### Compile-time Run (`#run`)

Executes Fels code during compilation on the comptime VM and folds the result to a
constant. `#run expr` is an expression and may initialise a top-level constant; the
block form `#run { … }` is a statement and, like `#if`, only appears inside a function.

```fels
// As an expression, including at the top level
SIZE :: #run compute_size();

// A whole table or struct: the result becomes the global's initial value, as data in the image
CRC: [256]u32 = #run make_crc_table();

// As a block statement, inside a function
main :: fn() -> i32 {
    #run {
        compute_lookup_tables();
    }
    return 0;
}
```
What a `#run` can return, what it can read (static data, read-only) and what is refused is in
[09_comptime](09_comptime.md#data-at-compile-time).
*Note: the comptime VM supports many standard language features but may be limited when interfacing with external or deeply complex types.*

### Compile-time assertions (`#assert`)

```fels
#assert(condition);
#assert(condition, "message");
```

A standalone top-level directive (like `#system_library`) that fails the build when
`condition` is `false`. The condition is evaluated on the comptime VM, so it can use
constants, `core::sizeof`, `core::align_of`, `core::offset_of` and calls the VM can run.
It is the way to pin down a layout that something outside Fels depends on:

```fels
Header :: struct { kind: u8, len: u32, id: u64 }

#assert(core::sizeof(Header) == 16, "Header is sent as-is over the wire");
#assert(core::offset_of(Header, "len") == 4);
#assert(core::align_of(Header) == 8);
```

A failing assertion reports the message and the condition as written:

```
header.fels:3:9: error: static assertion failed: Header is sent as-is over the wire (`core::sizeof(Header) == 16`)
```

- The condition must be a `bool` (a type error otherwise) and must fold at compile time;
  one that needs the host, such as a call into a DLL, is an error, not a pass.
- `#assert` is evaluated when the program is lowered, i.e. by `fels build`, `object` and
  `ir`. `fels check` only type-checks, so it does not run assertions.
- Top level only. Inside a function, use `#if` with `core::trap()` or an ordinary check.

### The `TARGET` constant

`TARGET` describes the platform and mode the program is built for. It is a constant,
`TARGET : TargetInfo`, whose fields are enums:

- `TARGET.os`: a `TargetOs`, `.windows`, `.linux`, `.macos` or `.unknown`.
- `TARGET.arch`: a `TargetArch`, `.x86_64`, `.aarch64` or `.unknown`.
- `TARGET.debug`: `true` in a debug build (`-O0`, the `debug` mode), `false` when optimized.

```fels
describe :: fn() -> i32 {
    #if TARGET.os == .windows {
        return 1;
    } else {
        return 2;
    }
}
```

It is the build's, not the compiler's: a `--target linux` build made on Windows sees
`.linux`. A misspelt platform is a compile error (`TARGET.os == .windos`: "enum `TargetOs`
has no variant `.windos`"). In `#if` the comparison folds and only the branch that holds is
compiled; in a plain `if` it is an ordinary comparison of constants. A build script and
`fels check` see the machine they run on. `#if` is a statement, so it goes in a function
body.
