# Attributes and Builtins

## Attributes

Attributes change the behavior or the layout of a declaration, and each one starts with `#`.

### Layout Attributes

- `#packed`: for a `struct`. It packs the fields tightly with no padding, so the alignment is 1.
  Sub-byte fields (`u1`–`u7`, `i1`–`i7`) take only their bits, and so does every integer field
  after them. Any other field starts at a whole byte (see
  [Packed structs](02_types.md#packed-structs)).
- `#align(N)`: C's `alignas(N)` for a `struct`. `N` is an integer literal and a power of two,
  from 1 to 4096. The struct is aligned to at least `N`, and its size is rounded up to a
  multiple of `N`. That holds wherever the struct lives: as a local or a global, as a field of
  another struct (placed at an `N`-aligned offset), or as an array element. Example:
  `#align(64)`. On a `#packed` struct only the size is rounded up, and the fields stay back to
  back. `core::sizeof` agrees with this at compile time and at run time.

### Function Attributes

- `#inline`: hints to the compiler that it should inline the function.
- `#noinline`: keeps the compiler from inlining the function.
- `#noreturn`: says that the function never returns, as with exit or panic.
- `#naked`: produces a function without the standard prologue or epilogue. You will mostly use
  it for raw inline assembly entry points.
- `#entry`: makes the function the program's entry point, as an alternative to naming it `main`.
- `#cold`: marks a function that is rarely called, so the optimizer moves it off the hot path.
  It becomes a real LLVM `cold` attribute.
- `#section("name")`: places the function in a specific section of the object file.
- `#keep`: never strips the function, even when nothing uses it. It forces non-internal linkage.

### FFI & Linkage

- `#export("name")`: exports the symbol with external linkage. Without a string, it exports the
  symbol under its Fels name. It works on a function and on a top-level global
  (`#export("plugin_entry") ENTRY: PluginEntry = .{ ... };`), see
  [11_c_interop](11_c_interop.md#exporting-data).
- `#extern("library_name", "symbol_name")`: declares a binding to an external function (FFI).
  The second argument is the **real link symbol**. The Fels declaration name does not have to
  match the C symbol, so a binding can take an idiomatic Fels name:
  ```fels
  #extern("kernel32", "WriteFile")
  WriteFile :: fn(...) -> bool;          // Fels name == C symbol

  #extern("ws2_32", "connect")
  sys_connect :: fn(...) -> i32;         // Fels name `sys_connect`, links `connect`
  ```
  Two externs may bind the same C symbol under different Fels names, and the one external
  declaration is deduplicated at link time. A plain Fels function may even share its name with
  a renamed extern's C symbol, for example a `connect` wrapper over `sys_connect`. The wrapper
  keeps internal linkage under a module-private symbol, so the two don't clash.
- `#foreign`: an alias for `#extern`.
- `#system_library("libname")`: a top-level directive that tells the linker to link against the
  named system library.
- `#link_name("name")`: sets the function's external symbol name **without** exporting it, which
  is what sets it apart from `#export`.
- `#weak`: emits a weak symbol, which another definition can override at link time.

### Diagnostics

- `#deprecated("message")`: triggers a deprecation warning at the call site.
- `#must_use`: the caller may not discard the function's return value. `f();` as a statement is
  an error, so write `x := f()` or `_ := f()`.
- `#maybe_unused`: marks a declaration as possibly unused. The compiler accepts it, and it
  suppresses any future unused-declaration warning.

### Threads

- `#spawns` on a function: the closures it takes run on other threads while the caller goes on
  (`thread::Scope.spawn`, `thread::Pool.range`). What such a closure captures is checked where
  the function is called: a value, a `*const T` or `[]const T`, a pointer to a `#sync` type, or a
  struct of such. A `*T` or `[]T` is an error, since two threads could write through it at once,
  and so is a closure held in a variable, whose captures are not known there. Inside
  `unsafe { }` nothing is checked. See [std.thread](07_stdlib.md#stdthread).
- `#sync` on a type: threads may use one at once through a pointer to it, as its methods
  synchronize (`sync::Mutex`, `sync::Channel(T)`, `atomics::Atomic(T)`). A closure that runs on
  another thread may capture a `*` to it.

## Builtins — the `core::` namespace

Builtins live in the reserved **`core::`** namespace. They are operations the compiler
provides, and they are always in scope, with no import. The `core::` prefix makes a builtin
call look different from an ordinary function call:

```fels
n   := core::sizeof(Point);          // a builtin — you can see the compiler is involved
name := core::type_name(Point);      // "Point"
buf := unsafe core::slice_raw(u8, p, len);
if bad { core::panic("invalid state"); }   // no-return
```

`core` is reserved, so a module or import of your own may not be named `core` (that is a
compile error). Some builtins need an `unsafe` block, as the last column of the table shows.

> **Bare names are rejected.** If you call a builtin by its bare name (`sizeof(T)`,
> `ptr_from_int(...)`, …), you get a hard error that points you to the `core::` form. A few
> names were tidied up in the move: `typeid_of` → `core::type_id`, `truncate_to` →
> `core::narrow`, `slice_from_raw_parts` → `core::slice_raw`. The old names still work behind
> `core::` (`core::typeid_of`), but these docs use the new ones. (`@panic` keeps its sigil and
> also works as `core::panic`.)

| Builtin | Signature | Unsafe? | Description |
|---------|-----------|---------|-------------|
| `core::sizeof` | `core::sizeof($T: type) -> usize` | No | Size of `T` in bytes, padding included. |
| `core::align_of` | `core::align_of($T: type) -> usize` | No | Alignment `T` requires, in bytes. Folds at compile time. |
| `core::offset_of` | `core::offset_of($T: type, "field") -> usize` | No | Byte offset of `field` in struct `T`, with the field as a string literal. Folds at compile time. |
| `core::has_padding` | `core::has_padding($T: type) -> bool` | No | Whether a `T` has bytes that no value sets: padding between or after struct fields (nested ones too), an optional's flag byte, the bytes a smaller enum or error payload leaves. Folds at compile time. |
| `core::narrow` | `core::narrow($T: type, val) -> T` | No | Truncate a wider integer into a narrower `T`. |
| `core::type_name` | `core::type_name($T: type) -> []const u8` | No | The type's name as a string. |
| `core::type_info` | `core::type_info($T: type) -> TypeInfo` | No | Compile-time reflection data (fields, variants, …). |
| `core::type_id` | `core::type_id($T: type) -> usize` | No | Stable runtime type id. |
| `core::any` | `core::any(x) -> Any` | No | Wrap a value into a type-erased `Any`. |
| `core::panic` | `core::panic(msg: []const u8) -> never` | No | Abort with a message. Never returns. |
| `core::atomic_load` | `core::atomic_load(ptr, ord) -> T` | No | Atomic load with ordering `ord`. |
| `core::atomic_store`| `core::atomic_store(ptr, val, ord)` | No | Atomic store. |
| `core::atomic_add`/`_sub`/`_and`/`_or`/`_xor` | `core::atomic_add(ptr, v, ord) -> T` | No | Read-modify-write that returns the **previous** value. |
| `core::atomic_max`/`_min` | `core::atomic_max(ptr, v, ord) -> T` | No | Atomic max/min (signed or unsigned, chosen from `T`). |
| `core::atomic_exchange` | `core::atomic_exchange(ptr, v, ord) -> T` | No | Swap that returns the previous value. |
| `core::atomic_cas` | `core::atomic_cas(ptr, expected, desired, ord) -> T` | No | Compare-and-swap that returns the value it saw (`== expected` on success). |
| `core::atomic_fence` | `core::atomic_fence(ord)` | No | Memory fence. |
| `core::ptr_from_int`| `core::ptr_from_int($T: type, addr: usize) -> T` | **Yes** | Integer address → pointer `T`. |
| `core::fn_ptr`| `core::fn_ptr(f) -> *void` | **Yes** | Raw thin pointer to a top-level function, for a C callback or a thread entry. An ordinary Fels fn value is a fat closure, which a C ABI can't call. |
| `core::slice_raw`| `core::slice_raw($T, ptr, len) -> []T` | **Yes** | Build a slice from a raw pointer and a length. |
| `core::volatile_store`| `core::volatile_store(ptr: *T, val: T)` | **Yes** | Volatile memory write. |
| `core::unaligned_read`| `core::unaligned_read($T: type, ptr) -> T` | **Yes** | Read `T` from a possibly-unaligned address. |
| `core::asm` | `core::asm(...)` | **Yes** | Inline assembly: `core::asm(volatile, "inst", inputs: {}, outputs: {}, clobbers: {})` |

The trailing `ord` is an integer ordering constant: `0` relaxed, `1` acquire, `2` release,
`3` acq_rel and `4` seq_cst. It **must be known at compile time**. Prefer the
[`std.atomics`](07_stdlib.md#stdatomics) wrappers, which default to seq_cst.

### Source-location & target constants

These are compile-time constants, written without parentheses. Each one folds to a literal
where you use it:

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
log :: fn(msg: []const u8) { println("{core::file}:{core::line}: {msg}"); }
```

### Math

For ints and floats there are `core::min(a,b)`, `core::max(a,b)`, `core::abs(x)` and
`core::clamp(x, lo, hi)`. The float functions are `core::sqrt`, `core::floor`, `core::ceil`,
`core::round`, `core::trunc`, `core::sin`, `core::cos`, `core::pow(x, y)` and
`core::fma(a, b, c)`. Each one returns the type of its first argument and maps to a fast CPU
instruction. All of them except `fma` also **fold at compile time**, so you can use them in
`#run`.

### Bit operations

These work on any integer: `core::count_ones(x)`, `core::count_zeros(x)`,
`core::leading_zeros(x)`, `core::trailing_zeros(x)`, `core::swap_bytes(x)`,
`core::reverse_bits(x)`, `core::rotate_left(x, n)` and `core::rotate_right(x, n)`. Each one
returns the type of `x`. Only `core::count_ones` folds at compile time. The others depend on the
width of `x`, and the comptime VM cannot run them yet. A `#run` expression inside a function
that uses one is compiled as ordinary code and computed at run time. A top-level `#run`
constant or an `#assert` that needs one is a compile error.

### Memory & control

`core::memcpy(dst, src, n)`, `core::memset(dst, byte, n)`, `core::trap()`,
`core::unreachable()`, `core::prefetch(ptr)` and `core::cycle_count() -> u64` are the low-level
primitives that the standard library wraps.

## Compile-Time Directives

### Compile-time If (`#if`)

`#if` evaluates a condition at compile time and keeps only the branch that is active. In a
function body it chooses between pieces of code, and the condition can be any constant
expression:

```fels
width :: fn() -> i32 {
    #if core::sizeof(usize) == 8 {
        return 64;
    } else #if core::sizeof(usize) == 4 {
        return 32;
    } else {
        return 16;
    }
}
```

At the top level it chooses between declarations: an `#extern`, an `#import`, a constant or a
struct layout that differs from one platform to the next.

```fels
#if TARGET.os == .windows {
    #extern("kernel32", "GetCurrentProcessId") pid :: fn() -> u32;
    PATH_SEP :: 92;      // '\\'
} else #if TARGET.os == .linux {
    #extern("c", "getpid") pid :: fn() -> i32;
    PATH_SEP :: 47;      // '/'
}
```

A top-level `#if` is decided while the file is read, before any constant has a value. That is
why its condition can only ask about the build. It may use `TARGET.os` or `TARGET.arch`
compared with a variant (`==`, `!=`), `TARGET.debug`, `true` and `false`, joined with `!`, `&&`
and `||`. Anything else in the condition is a compile error, and so is a platform that `TARGET`
does not know. The declarations in the branches not taken are parsed, but they are not part of
the program.

### Embedding a file (`#embed`)

`#embed("path")` is the bytes of a file, a `[]const u8` in the program's static data. The path is
relative to the folder of the file that names it, and the file is read as the program is
compiled, so a change to it builds the program again.

```fels
GREETING :: #embed("data/greeting.txt");
LINES :: #run count_lines(#embed("data/greeting.txt"));
```

What compile-time code may read is a capability ([09](09_comptime.md#capabilities)): the
project's own code reads the files below the project's folder, and a package's code what its
`#use` line grants it (`may read("data")`). The bytes are text, never a format: printing them
shows their braces as they are.

### Compile-time Run (`#run`)

`#run` executes Fels code on the comptime VM while the program compiles, and folds the result
to a constant. `#run expr` is an expression, and it may initialise a top-level constant or a
local. As a statement (`#run { … }` or `#run f();`) it is an error: a statement run while
compiling would have nothing to give the function, and it used to run with the program
instead. To check something while compiling, use `#assert`.

```fels
compute_size :: fn() -> i32 { return 16 * 4; }

make_crc_table :: fn() -> [256]u32 {
    table: [256]u32 = .{};
    for i in 0..256 {
        c := i as u32;
        for k in 0..8 { c = if c & 1 != 0 { 0xEDB88320 ^ (c >> 1) } else { c >> 1 }; }
        table[i] = c;
    }
    return table;
}

// As an expression, including at the top level
SIZE :: #run compute_size();

// A whole table or struct: the result becomes the global's initial value, as data in the image
CRC: [256]u32 = #run make_crc_table();

// And in a function, for a value
main :: fn() -> i32 {
    n := #run compute_size();
    return SIZE + n + (CRC[1] & 0) as i32;
}
```

What a `#run` can return, what it can read (static data, read-only) and what gets refused is
explained in [09_comptime](09_comptime.md#data-at-compile-time).
*Note: the comptime VM supports many of the standard language features, but it may be limited
when it works with external or deeply complex types.*

### Compile-time assertions (`#assert`)

```fels
#assert(condition);
#assert(condition, "message");
```

`#assert` is a standalone top-level directive, like `#system_library`, and it fails the build
when `condition` is `false`. The condition is evaluated on the comptime VM, so it can use
constants, `core::sizeof`, `core::align_of`, `core::offset_of` and calls the VM can run. This is
how you pin down a layout that something outside Fels depends on:

```fels
Header :: struct { kind: u8, len: u32, id: u64 }

#assert(core::sizeof(Header) == 16, "Header is sent as-is over the wire");
#assert(core::offset_of(Header, "len") == 4);
#assert(core::align_of(Header) == 8);
```

When an assertion fails, it reports the message and the condition as you wrote it:

```
header.fels:3:9: error: static assertion failed: Header is sent as-is over the wire (`core::sizeof(Header) == 16`)
```

- The condition must be a `bool`, or you get a type error, and it must fold at compile time. A
  condition that needs the host, such as a call into a DLL, is an error, not a pass.
- `#assert` is evaluated when the program is lowered, that is by `fels build`, `object` and
  `ir`. `fels check` only type-checks, so it does not run assertions.
- It works at the top level only. Inside a function, use `#if` with `core::trap()` or an
  ordinary check.

### The `TARGET` constant

`TARGET` describes the platform and the mode that the program is built for. It is a constant,
`TARGET : TargetInfo`. Its `os` and `arch` fields are enums, and `debug` is a `bool`:

- `TARGET.os`: a `TargetOs`, which is `.windows`, `.linux`, `.macos` or `.unknown`.
- `TARGET.arch`: a `TargetArch`, which is `.x86_64`, `.aarch64` or `.unknown`.
- `TARGET.debug`: `true` in a debug build (`-O0`, the `debug` mode), and `false` when the build
  is optimized.

```fels
describe :: fn() -> i32 {
    #if TARGET.os == .windows {
        return 1;
    } else {
        return 2;
    }
}
```

`TARGET` belongs to the build, not to the compiler, so a `--target linux` build made on Windows
sees `.linux`. A misspelt platform is a compile error (`TARGET.os == .windos`: "enum `TargetOs`
has no variant `.windos`"). In `#if` the comparison folds, and only the branch that holds is
compiled. In a plain `if` it is an ordinary comparison of constants. A build script and
`fels check` see the machine they run on.
