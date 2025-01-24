# Functions & Control Flow

## Function Declarations

Functions are declared with `::` and `fn`:

```k2
// Named function
add :: fn(a: i32, b: i32) -> i32 {
    return a + b;
}

// Public function (exported from module)
pub multiply :: fn(a: i32, b: i32) -> i32 {
    return a * b;
}

// Function with no return value
greet :: fn() {
    println("hello");
}

// Function returning void explicitly
process :: fn(data: []const u8) -> void {
    // ...
}
```

> [!NOTE]
> Functions without an explicit return type implicitly return `void`. Writing `-> void` is optional but permitted for clarity.

---

## Parameters

```k2
// Value parameters
add :: fn(a: i32, b: i32) -> i32 { ... }

// Pointer parameters (allows mutation)
increment :: fn(value: *i32) {
    *value += 1;
}

// Slice parameters
sum :: fn(values: []const i32) -> i32 { ... }

// Borrow parameters (for zone-owned values)
fill :: fn(data: borrow []u8) {
    data[0] = 42u8;
}

// Self parameter (enables dot-call syntax)
pub doubled :: fn(self: i32) -> i32 {
    return self * 2;
}
// Called as: x.doubled() or doubled(x)
```

| Parameter Style | Syntax            | Semantics                                      |
|-----------------|-------------------|-------------------------------------------------|
| Value           | `a: i32`          | Passed by value (copy)                          |
| Pointer         | `p: *i32`         | Mutable pointer to a value                      |
| Const pointer   | `p: *const i32`   | Read-only pointer to a value                    |
| Slice           | `s: []const u8`   | Read-only view into contiguous memory            |
| Borrow          | `b: borrow []u8`  | Zone-aware borrowed reference                   |
| Self            | `self: T`         | Enables dot-call syntax on type `T`             |

---

## Self and Methods

Any top-level function whose first parameter is named `self` can be called using **dot-call syntax**:

```k2
// In module point.k2:
pub distance :: fn(self: *Point) -> f64 { ... }

// Calling:
p := Point { x = 3, y = 4 };
d := (&p).distance();   // or: distance(&p)
```

> [!IMPORTANT]
> For struct pointer receivers, you must take the address explicitly with `&`. K2 does not auto-reference.

---

## Generic Functions

K2 uses the `$` prefix to introduce type parameters. The first occurrence of `$T` binds the type; subsequent uses of `T` refer to the bound type.

```k2
// Type parameter with $
identity :: fn(value: $T) -> T {
    return value;
}

// Multiple type params
swap :: fn(a: $T, b: $U) -> U { ... }

// Explicit type param
max :: fn($T: type, a: T, b: T) -> T {
    if a > b { return a; }
    return b;
}
// Called as: max(i32, 10, 20)

// Constrained type param (must implement interface)
print_to :: fn($W: Writer, writer: *W, data: []const u8) -> usize ! IoError {
    return writer.write(data)?;
}
```

> [!NOTE]
> Generics are **monomorphized** — each unique type argument produces a specialized version at compile time. There is no runtime dispatch overhead.

---

## Fallible Functions

Functions that can fail use `!` after the return type to declare an error channel:

```k2
// Named error type
read :: fn(buf: []u8) -> usize ! IoError { ... }

// Inline error set
parse :: fn(s: []const u8) -> i32 ! { invalid, overflow } { ... }

// Inferred error type
combine :: fn() -> i32 ! { ... }
```

> [!TIP]
> See the [Error Handling](05_error_handling.md) chapter for full details on error propagation, `try`, `catch`, and the `?` operator.

---

## External Functions

FFI declarations for calling C or system functions use the `#extern` attribute:

```k2
#extern("kernel32", "GetStdHandle")
GetStdHandle :: fn(id: i32) -> usize;

#extern("kernel32", "WriteFile")
WriteFile :: fn(
    handle: usize,
    buf: *const u8,
    len: u32,
    written: *u32,
    overlapped: ?*void,
) -> bool;
```

> [!WARNING]
> External function calls are inherently unsafe. The compiler cannot verify the correctness of the foreign function's signature or behavior.

---

## Function Attributes

Attributes are placed before the function declaration to modify compilation behavior:

```k2
#inline
pub fast_add :: fn(a: i32, b: i32) -> i32 { return a + b; }

#noinline
slow_path :: fn() { ... }

#noreturn
abort :: fn() { ... }

#naked
asm_entry :: fn() { ... }

#entry
custom_entry :: fn() { ... }

#export
exported_fn :: fn() { ... }
```

| Attribute    | Effect                                                        |
|--------------|---------------------------------------------------------------|
| `#inline`    | Hint to always inline the function at call sites              |
| `#noinline`  | Prevent the function from being inlined                       |
| `#noreturn`  | Declares the function never returns (e.g., `abort`, `exit`)   |
| `#naked`     | Omit the function prologue/epilogue (for raw assembly)        |
| `#entry`     | Mark as the program entry point                               |
| `#export`    | Export the symbol for external linkage                         |

---

## Control Flow

### If / Else

```k2
if x > 0 {
    println("positive");
} else {
    println("non-positive");
}

// Without else
if flag {
    do_something();
}

// With binding (if-let style)
if result := try_parse(input) {
    // result is available here
}

// With error payload capture
if result := try_parse(input) |err| {
    // err is bound to the captured error payload
} else {
    // success path
}
```

> [!IMPORTANT]
> K2 does **not** have `else if`. Nest `if` statements inside `else` blocks instead:

```k2
if x > 0 {
    // positive
} else {
    if x == 0 {
        // zero
    } else {
        // negative
    }
}
```

---

### While Loop

```k2
i := 0;
while i < 10 {
    println("loop");
    i += 1;
}
```

An infinite loop uses `while true`:

```k2
while true {
    // runs forever until break
    if should_stop() { break; }
}
```

---

### For Range Loop

```k2
// Exclusive range: 0, 1, 2, ..., 9
for i in 0..10 {
    print_u64(i as u64);
}

// Inclusive range: 0, 1, 2, ..., 10
for i in 0..=10 {
    print_u64(i as u64);
}
```

| Syntax     | Range            | Example values        |
|------------|------------------|-----------------------|
| `0..10`    | Exclusive end    | 0, 1, 2, …, 9        |
| `0..=10`   | Inclusive end     | 0, 1, 2, …, 10       |

---

### For Slice Loop

```k2
data: [4]i32 = .{ 10, 20, 30, 40 };

// By value
for val in data[:] {
    print_i64(val as i64);
}

// With index
for val, idx in data[:] {
    // val is the element, idx is the index
}

// By reference
for &val in data[:] {
    *val += 1; // modify in-place
}
```

> [!TIP]
> Use `data[:]` to create a slice from a fixed-size array. See the [Types & Values](02_types_values.md) chapter for more on slices and arrays.

---

### Match

Pattern matching on enums and integers:

```k2
// Enum matching
match direction {
    .north => { println("going north"); }
    .south => { println("going south"); }
    .east  => { println("going east"); }
    .west  => { println("going west"); }
}

// Enum with payload capture
match shape {
    .circle    |radius| => { /* use radius */ }
    .rectangle |corner| => { /* use corner */ }
    .none               => { /* nothing */ }
}

// Integer matching
match code {
    0       => { println("ok"); }
    1, 2, 3 => { println("warning"); }  // grouped cases
    else    => { println("error"); }
}

// Single-statement arms (no braces needed)
match value {
    .a   => return 1,
    .b   => return 2,
    else => return 0,
}
```

> [!IMPORTANT]
> Match is **exhaustiveness-checked**. All enum variants must be handled, or an `else` arm must be present. The compiler will error on non-exhaustive matches.

---

### Break and Continue

`break` exits the innermost loop. `continue` skips to the next iteration:

```k2
while true {
    if done() { break; }
    if skip() { continue; }
    process();
}
```

---

### Defer

`defer` schedules code to execute when the current scope exits. This guarantees cleanup regardless of how the scope is exited (normal return, error, break, etc.):

```k2
// Always defer
defer { cleanup(); }

// Single expression defer
defer close(handle);

// Defer only on success
defer.ok { commit(); }

// Defer only on error
defer.err { rollback(); }
```

> [!NOTE]
> Multiple defers execute in **reverse order** (LIFO). The last defer registered runs first.

```k2
// Example: LIFO order
defer { println("first registered, last to run"); }
defer { println("second registered, first to run"); }
// Output on scope exit:
//   second registered, first to run
//   first registered, last to run
```

---

### Unsafe Blocks

`unsafe` blocks disable certain safety checks. They are required for raw pointer operations, inline assembly, and other low-level operations:

```k2
unsafe {
    raw_ptr := 0x1000 as *u8;
    *raw_ptr = 0;
}

// Unsafe expression
val := unsafe unaligned_read(u64, &x);
```

> [!CAUTION]
> Unsafe code bypasses the compiler's safety guarantees. Use sparingly and audit carefully. Incorrect unsafe code can cause undefined behavior, memory corruption, or security vulnerabilities.

---

### Compile-time Directives

K2 supports compile-time evaluation through special directives:

```k2
// Compile-time if
#if sizeof(usize) == 8 {
    // 64-bit platform code
} else {
    // 32-bit platform code
}

// Compile-time execution
#run {
    // Code executed at compile time
}

// Compile-time expression
size := #run compute_size();
```

| Directive | Purpose                                                        |
|-----------|----------------------------------------------------------------|
| `#if`     | Conditional compilation based on compile-time constants        |
| `#run`    | Execute code or expressions at compile time                    |

---

### Zone Blocks

Zone blocks provide scoped memory management. See the [Memory & Zones](06_memory_zones.md) chapter for full details:

```k2
zone scratch: Arena {
    buf := scratch.new_slice(u8, 64);
    // arena freed at end of zone
}
```
