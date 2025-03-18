# Attributes and Builtins

## Attributes

Attributes modify the behavior or layout of declarations. They are prefixed with `#`.

### Layout Attributes

- `#packed`: applied to a `struct`. Packs the fields tightly without padding. Required for structs containing sub-byte fields (like `u4`).
- `#align(N)`: custom alignment for a `struct`. Example: `#align(64)`.

### Function Attributes

- `#inline`: hints the compiler to inline the function.
- `#noinline`: prevents the compiler from inlining the function.
- `#noreturn`: specifies that the function never returns (e.g., exit or panic).
- `#naked`: produces a function without standard prologue or epilogue. Typically used for raw inline assembly entry points.
- `#entry`: designates the function as the program entry point (an alternative to naming it `main`).

### FFI & Linkage

- `#export("name")`: exports the symbol with external linkage. If no string is provided, exports it using its K2 name.
- `#extern("library_name", "symbol_name")`: declares an external function binding (FFI). 
  ```k2
  #extern("kernel32", "WriteFile")
  WriteFile :: fn(...) -> bool;
  ```
- `#foreign`: Alias for `#extern`.
- `#system_library("libname")`: A top-level directive that tells the linker to link against the specified system library.

### Diagnostics

- `#deprecated("message")`: Triggers a deprecation warning at the call site.

---

## Builtins — the `core::` namespace

Builtins live in the reserved **`core::`** namespace — compiler-provided operations,
always in scope (no import). The `core::` prefix makes a builtin call visually
distinct from an ordinary function call:

```k2
n   := core::sizeof(Point);          // a builtin — you can see the compiler is involved
name := core::type_name(Point);      // "Point"
buf := unsafe core::slice_from_raw_parts(u8, p, len);
if bad { core::panic("invalid state"); }   // no-return
```

`core` is reserved: a user module/import may not be named `core`. Some builtins
require an `unsafe` block (last column).

> **Migration note:** the bare forms (`sizeof(T)`, `ptr_from_int(...)`, …) still work
> while the standard library is migrated to `core::`, but they are deprecated — write
> `core::sizeof(T)`. (A few names are being tidied at the same time, e.g.
> `typeid_of` → `core::type_id`, `truncate_to` → `core::narrow`,
> `slice_from_raw_parts` → `core::slice_raw`; see the tracking issue.)

| Builtin | Signature | Unsafe? | Description |
|---------|-----------|---------|-------------|
| `core::sizeof` | `core::sizeof($T: type) -> usize` | No | Size of `T` in bytes. |
| `core::truncate_to` | `core::truncate_to($T: type, val) -> T` | No | Truncate a wider integer into a narrower `T`. |
| `core::type_name` | `core::type_name($T: type) -> []const u8` | No | The type's name as a string. |
| `core::type_info` | `core::type_info($T: type) -> TypeInfo` | No | Compile-time reflection data (fields, variants, …). |
| `core::typeid_of` | `core::typeid_of($T: type) -> usize` | No | Stable runtime type id. |
| `core::any` | `core::any(x) -> Any` | No | Wrap a value into a type-erased `Any`. |
| `core::panic` | `core::panic(msg: []const u8) -> never` | No | Abort with a message; never returns. |
| `core::atomic_load` | `core::atomic_load(ptr, order) -> T` | No | Atomic load (e.g. `.acquire`). |
| `core::atomic_store`| `core::atomic_store(ptr, val, order)` | No | Atomic store. |
| `core::ptr_from_int`| `core::ptr_from_int($T: type, addr: usize) -> T` | **Yes** | Integer address → pointer `T`. |
| `core::slice_from_raw_parts`| `core::slice_from_raw_parts($T, ptr, len) -> []T` | **Yes** | Build a slice from a raw pointer + length. |
| `core::volatile_store`| `core::volatile_store(ptr: *T, val: T)` | **Yes** | Volatile memory write. |
| `core::unaligned_read`| `core::unaligned_read($T: type, ptr) -> T` | **Yes** | Read `T` from a possibly-unaligned address. |
| `core::asm` | `core::asm(...)` | **Yes** | Inline assembly: `core::asm(volatile, "inst", inputs: {}, outputs: {}, clobbers: {})` |

More families (source-location constants like `core::file`/`core::line`, math, bit
ops, and memory primitives) are being added — see the tracking issue / docs roadmap.

---

## Compile-Time Directives

### Compile-time If (`#if`)

Evaluates a condition at compile time and includes only the active branch in the IR.

```k2
#if sizeof(usize) == 8 {
    // 64-bit code
} else {
    // 32-bit code
}
```

### Compile-time Run (`#run`)

Executes K2 code during compilation via the AST interpreter.

```k2
// As a block
#run {
    compute_lookup_tables();
}

// As an expression
size := #run compute_size();
```
*Note: The compile-time interpreter supports many standard language features but may be limited when interfacing with external or deeply complex types.*

### The `TARGET` Pseudo-module

The compiler provides compile-time target information via the virtual `TARGET` identifier.

- `TARGET.os`: Returns `.windows`, `.linux`, `.macos`, or `.unknown`.
- `TARGET.arch`: Returns `.x86_64`, `.aarch64`, or `.unknown`.
- `TARGET.debug`: Returns `true` if compiling in debug mode, `false` otherwise.

```k2
#if TARGET.os == .windows {
    #extern("kernel32", "ExitProcess")
    ExitProcess :: fn(code: u32);
}
```
