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

## Builtins

Builtin functions are implicitly available. Some require an `unsafe` block.

| Builtin | Signature | Unsafe? | Description |
|---------|-----------|---------|-------------|
| `sizeof` | `sizeof($T: type) -> usize` | No | Returns the size of `T` in bytes. |
| `truncate_to` | `truncate_to($T: type, val: any) -> T` | No | Truncates a wider integer into a narrower integer type `T`. |
| `type_name` | `type_name($T: type) -> []const u8` | No | Returns the name of the type as a string. |
| `type_info` | `type_info($T: type) -> TypeInfo` | No | Returns compile-time reflection data about the type (fields, variants, etc.). |
| `atomic_load` | `atomic_load(ptr: *atomic T, order: Enum) -> T` | No | Performs an atomic load (e.g. `.acquire`). |
| `atomic_store`| `atomic_store(ptr: *atomic T, val: T, order: Enum)` | No | Performs an atomic store. |
| `ptr_from_int`| `ptr_from_int($T: type, addr: usize) -> T` | **Yes** | Casts an integer address into a pointer type `T`. |
| `volatile_store`| `volatile_store(ptr: *T, val: T)` | **Yes** | Bypasses compiler optimization to perform a volatile memory write. |
| `unaligned_read`| `unaligned_read($T: type, ptr: any) -> T` | **Yes** | Reads type `T` from a potentially unaligned memory location. |
| `asm` | `asm(...)` | **Yes** | Executes inline assembly. Syntax: `asm(volatile, "inst", inputs: {}, outputs: {}, clobbers: {})` |

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
