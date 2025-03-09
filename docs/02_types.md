# Type System

K2 is statically typed with full type inference. Every value has a known type at compile time, and the compiler will reject programs where types do not align. K2's type system is designed to be explicit where it matters — preventing subtle bugs through distinct types, optional types, and strict casting rules — while staying lightweight through inference and compound literals.

---

## Primitive Types

### Integer Types

K2 provides fixed-width signed and unsigned integer types:

| Signed | Unsigned | Size |
|--------|----------|------|
| `i8` | `u8` | 8-bit |
| `i16` | `u16` | 16-bit |
| `i32` | `u32` | 32-bit |
| `i64` | `u64` | 64-bit |
| `isize` | `usize` | pointer-width |

`isize` and `usize` are pointer-sized integers — 64 bits on 64-bit platforms. Use `usize` for array indices and lengths; use `isize` when you need a signed offset.

#### Integer Literals

Integer literals can carry a type suffix to specify their type explicitly:

```k2
a := 42i32;       // i32
b := 255u8;        // u8
c := 1000u64;      // u64
d := 0usize;       // usize
```

Without a suffix, an integer literal's type is inferred from context. If no context constrains it, the literal defaults to `i32`.

A suffix is authoritative: it fixes the literal's width even through inference. `x := 0i64` gives `x` a 64-bit slot — the `i64` is not narrowed back to the `i32` default. This matters for values that exceed 32 bits (e.g. addresses built with `usize`/`i64`), where a narrowed slot would silently truncate the value.

#### Wrapping Arithmetic

Plain `+`, `-`, `*` trap on signed/unsigned overflow in debug builds (catching bugs
close to their source). When you *want* two's-complement wraparound — hashing, PRNGs,
checksums, fixed-width counters — use the wrapping operators `+%`, `-%`, `*%`:

```k2
a := 250u8 +% 10u8;   // 4   — wraps at 256, never traps
h := h *% 16777619u32; // FNV-style hash step

fnv1a :: fn(s: []const u8) -> u32 {
    h := 2166136261u32;
    i := 0usize;
    while i < s.len { h = (h ^ (s[i] as u32)) *% 16777619u32; i = i + 1usize; }
    return h;
}
```

Wrapping operators are integer-only and behave identically at compile time, so a hash
like the above can be evaluated in a `#run` constant and matches its runtime value.

#### Sub-Byte Integer Types

Within packed structs, K2 supports sub-byte integer types from `u1` through `u7`. These types cannot be used outside of packed struct fields:

```k2
#packed
StatusBits :: struct {
    enabled: u1,
    priority: u3,
    mode: u4,
}
```

> [!NOTE]
> Sub-byte types are only valid as fields inside `#packed` structs. They cannot appear in function signatures, local variables, or non-packed struct fields.

---

### Float Types

| Type  | Size   | Precision        |
|-------|--------|------------------|
| `f32` | 32-bit | IEEE 754 single  |
| `f64` | 64-bit | IEEE 754 double  |

Float arithmetic and comparisons lower to the correct LLVM floating-point instructions.

```k2
pi := 3.14159f64;
half := 0.5f32;
result := pi * 2.0;
```

---

### Boolean

`bool` holds one of two values: `true` or `false`.

```k2
flag := true;
done: bool = false;
```

Booleans are used in conditions, logical expressions, and as flags. K2 does not implicitly convert integers or pointers to `bool`.

---

### Void

`void` is the unit type. It carries no data and is used as the return type for functions that produce no value:

```k2
log :: fn(msg: []const u8) -> void {
    // ...
}
```

You never construct a `void` value directly. A function with a `void` return simply ends without a return expression, or uses a bare `return;`.

---

## Composite Types

### Structs

Structs are the primary way to group related data into a single type:

```k2
Point :: struct {
    x: i32,
    y: i32,
}
```

#### Construction

```k2
// Named field construction
p := Point { x = 10, y = 20 };

// Positional compound literal (fields filled in declaration order)
p2: Point = .{ 10, 20 };

// Zero-initialized (all fields set to their zero value)
p3: Point = .{};
```

#### Field Access

```k2
val := p.x;
p.y = 30;
```

> [!TIP]
> Use `.{}` zero initialization to ensure all fields start at known values. This is especially useful for large structs where you only need to override a few fields afterward.

---

### Packed Structs

The `#packed` attribute creates a struct with no padding between fields. This is essential for hardware registers, binary protocols, and memory-mapped I/O:

```k2
#packed
Flags :: struct {
    readable: bool,
    writable: bool,
    executable: bool,
}
```

Packed structs support sub-byte field types (`u1` through `u7`), allowing precise bit-level layout:

```k2
#packed
PixelFormat :: struct {
    red: u5,
    green: u6,
    blue: u5,
}
```

> [!IMPORTANT]
> Taking the address of a packed struct field is not allowed, because the field may not be byte-aligned. Access packed fields by value only.

---

### Generic Structs

Structs can be parameterized by types (and compile-time values) using `$`-prefixed parameters:

```k2
Pair :: struct($T: type, $U: type) {
    first: T,
    second: U,
}

p: Pair(i32, bool) = .{ 42, true };
```

Generic structs are **monomorphized** — each unique combination of type arguments produces a distinct, specialized type at compile time. `Pair(i32, bool)` and `Pair(f64, f64)` are completely separate types.

```k2
// A dynamically-growable array parameterized by element type
ArrayList :: struct($T: type) {
    items: []T,
    capacity: usize,
}

list: ArrayList(u8) = .{};
```

---

### Enums

Enums define a type that holds one of a fixed set of variants:

```k2
Direction :: enum {
    north,
    south,
    east,
    west,
}

d := Direction.north;
```

#### Dot Shorthand

When the expected type is known from context, you can use the dot shorthand:

```k2
d2: Direction = .north;

move :: fn(dir: Direction) -> void { /* ... */ }
move(.east);
```

#### Enums with Payloads

Enum variants can carry associated data:

```k2
Shape :: enum {
    circle: f64,             // radius
    rectangle: struct {      // inline struct payload
        width: f64,
        height: f64,
    },
    none,                    // no payload
}

s := Shape.circle(3.14);     // construct a variant with its payload
```

Construct a payload-carrying variant by calling the variant as `EnumType.variant(payload)`
(payload-less variants are just `EnumType.variant`). Recover the payload by pattern
matching:

```k2
area :: fn(s: Shape) -> f64 {
    match s {
        .circle |r|    => return 3.14159 * r * r;
        .rectangle |b| => return b.width * b.height;
        else           => return 0.0;
    }
}
```

Enums with payloads are K2's approach to tagged unions. Construction and matching
both work at compile time too, so comptime code can build and inspect them — the
basis for constructing `ast.*` values programmatically in metaprogramming.

---

### Error Types

Error types are declared with the `errors` keyword. They look similar to enums but are specifically designed for use with K2's fallible function system:

```k2
IoError :: errors {
    not_found,
    permission_denied,
    timeout,
}

ParseError :: errors {
    invalid_input,
    overflow: i64,    // error variant with a payload
}
```

Error types integrate with the `!` operator in function return types to indicate fallible operations:

```k2
read_file :: fn(path: []const u8) -> []u8 ! IoError {
    // ...
}
```

> [!NOTE]
> See the [Error Handling](05_error_handling.md) chapter for full details on `try`, `catch`, and error propagation.

---

## Pointer Types

K2 provides several pointer kinds for different use cases.

### Single Pointers

A single pointer points to exactly one value:

| Syntax          | Description                          |
|-----------------|--------------------------------------|
| `*T`            | Mutable pointer to `T`              |
| `*const T`      | Immutable (const) pointer to `T`    |
| `*volatile T`   | Volatile pointer to `T`             |

```k2
x := 42;
ptr: *i32 = &x;       // take address of x
val := *ptr;           // dereference: read the value (42)
*ptr = 100;            // dereference: write a new value
```

- `*const T` prevents modification through the pointer. The underlying data may still be mutable through another path.
- `*volatile T` ensures every read and write goes to memory, preventing the compiler from optimizing accesses away. Use this for memory-mapped hardware registers.

---

### Many Pointers

A many-pointer points to an array of values whose length is not tracked:

| Syntax          | Description                              |
|-----------------|------------------------------------------|
| `[*]T`          | Mutable many-pointer to `T`             |
| `[*]const T`    | Const many-pointer to `T`               |

```k2
buffer: [*]u8 = get_raw_buffer();
first := buffer[0];
buffer[3] = 0xFF;
```

> [!WARNING]
> Many pointers perform **no bounds checking**. Indexing past the actual allocation is undefined behavior. Prefer slices (`[]T`) whenever you know the length.

---

## Slice Types

Slices are a **pointer + length** pair, providing bounds-checked access to a contiguous sequence of elements:

| Syntax        | Description                    |
|---------------|--------------------------------|
| `[]T`         | Mutable slice of `T`          |
| `[]const T`   | Const slice of `T`            |

```k2
arr: [4]i32 = .{ 1, 2, 3, 4 };

slice := arr[:];          // full slice of the array
sub := arr[1..3];         // elements at indices 1 and 2
first := slice[0];        // bounds-checked index access
len := slice.len;         // number of elements
raw := slice.ptr;         // underlying pointer ([*]T)
```

String literals in K2 have the type `[]const u8`:

```k2
greeting: []const u8 = "hello, world";
```

> [!TIP]
> Slices are the preferred way to pass sequences of data. They are lightweight (just two machine words) and safe (bounds-checked at runtime).

---

## Array Types

Arrays are fixed-size, stack-allocated sequences:

```k2
[N]T    // array of N elements of type T
```

```k2
data: [4]u8 = .{ 1u8, 2u8, 3u8, 4u8 };
zeros: [256]u8 = .{};                    // zero-initialized
len := data.len;                          // compile-time known: 4
```

Arrays differ from slices in that their length is part of the type. `[4]u8` and `[8]u8` are different types. To pass an array to a function expecting a slice, use the slice operator:

```k2
process :: fn(items: []const u8) -> void { /* ... */ }

buf: [16]u8 = .{};
process(buf[:]);    // convert array to slice
```

---

## Optional Types

An optional wraps a value that may or may not be present:

```k2
?T    // either a value of type T, or null
```

```k2
maybe: ?i32 = 42;
none: ?i32 = null;
```

### Unwrapping Optionals

#### Force Unwrap (`!!`)

Extracts the value, **panicking at runtime** if the optional is `null`:

```k2
val := maybe!!;    // 42 — or panic if null
```

#### Nil Coalesce (`??`)

Provides a default value when the optional is `null`:

```k2
val := maybe ?? 0;    // 42, or 0 if maybe were null
```

#### Conditional Checks

```k2
if maybe != null {
    // maybe is guaranteed non-null in this branch
}
```

> [!CAUTION]
> Avoid `!!` in production code paths unless you are certain the value cannot be `null`. Prefer `??` or explicit null checks to handle the `null` case gracefully.

---

## Function Types

Function types describe a function's signature as a first-class type:

```k2
fn(i32, i32) -> i32                        // two i32 params, returns i32
fn(*Self, []const u8) -> usize ! IoError   // fallible method
fn() -> void                               // no params, no return value
```

Function types allow storing and passing functions as values:

```k2
apply :: fn(f: fn(i32) -> i32, x: i32) -> i32 {
    return f(x);
}

double :: fn(n: i32) -> i32 { return n * 2; }

result := apply(double, 21);    // 42
```

---

## Distinct Types

Distinct types create **newtypes** — types that share the underlying representation but are treated as separate types by the compiler:

```k2
UserId :: distinct u64;
Pixels :: distinct i32;
```

This prevents accidental mixing of semantically different values:

```k2
user: UserId = 42u64 as UserId;
offset: Pixels = 100i32 as Pixels;

// ERROR: cannot pass Pixels where UserId is expected
// lookup(offset);
```

Convert between a distinct type and its underlying type with `as`:

```k2
id: UserId = 42u64 as UserId;
raw := id as u64;              // back to plain u64
```

> [!TIP]
> Distinct types are zero-cost. At runtime, `UserId` and `u64` have identical representation. The distinction exists only at compile time for type safety.

---

## Type Aliases

A type alias gives an existing type a second name. Unlike `distinct`, an alias is
**transparent** — the alias and its underlying type are fully interchangeable:

```k2
MyInt :: i32;
Bytes :: []u8;
Trio  :: [3]i32;
CStr  :: [*]const u8;

add :: fn(a: MyInt, b: MyInt) -> i32 { return a + b; }  // MyInt == i32
```

An alias is recognized when the right-hand side **begins with a type** — a
primitive type keyword (`i32`, `bool`, …) or a type constructor (`[`, `*`, `[*`,
`?`, `borrow`, `atomic`). A bare-identifier right-hand side stays a value
constant, so `Foo :: Bar` is a constant, not an alias (alias-to-named-type is not
supported yet).

The standard library uses aliases for C ABI types — see [`std.c`](07_stdlib.md):

```k2
#import std.c.{ c_int, c_size_t };
#extern("msvcrt", "strlen")
strlen :: fn(s: [*]const c_char) -> c_size_t;
```

---

## Opaque Types

Opaque types declare a type with no visible definition. They can only be used behind a pointer:

```k2
Foo :: opaque;
```

```k2
// Only *Foo is usable — you cannot create or inspect a Foo value directly
get_handle :: fn() -> *Foo { /* ... */ }
use_handle :: fn(h: *Foo) -> void { /* ... */ }
```

Opaque types are useful for:
- **FFI boundaries** — wrapping C `void*` handles with a named type.
- **Abstraction** — exposing a handle to callers without revealing the implementation.

---

## Atomic Types

The `atomic` qualifier is applied to struct fields to enable atomic memory operations:

```k2
Counter :: struct {
    value: atomic u32,
}
```

Atomic fields must be accessed through the `atomic_load` and `atomic_store` builtins rather than through regular field access:

```k2
c := Counter { value = 0 };
current := atomic_load(&c.value);
atomic_store(&c.value, current + 1);
```

> [!NOTE]
> The `atomic` qualifier is only valid on struct fields. See the [Builtins](08_builtins.md) chapter for the full set of atomic operations available.

---

## Borrow Types

The `borrow` qualifier creates a temporary, non-owning reference to zone-allocated data:

```k2
borrow *T       // borrowed pointer
borrow []T      // borrowed slice
```

Borrowed references allow you to pass zone-owned values to functions without transferring ownership:

```k2
print_name :: fn(name: borrow []const u8) -> void {
    // Can read `name` but cannot store it or return it
}
```

### Borrow Rules

| Allowed | Not Allowed |
|---------|-------------|
| Read through the reference | Store in a struct field |
| Pass to another `borrow` parameter | Return from a function |
| Use in expressions | Forward to a non-`borrow` parameter |

> [!IMPORTANT]
> Borrowed references are a compile-time safety mechanism. They guarantee that zone-owned data is not accidentally captured beyond its intended scope. See the [Memory Management](06_memory.md) chapter for details on zones and ownership.

---

## Type Casting

The `as` operator performs explicit type conversions:

```k2
x := 42i32;
y := x as i64;          // integer widening (lossless)
z := x as u32;          // signed to unsigned
f := x as f64;          // integer to float
i := 3.14 as i32;       // float to integer (truncates toward zero)
d := id as u64;         // distinct type to underlying type
```

All casts in K2 are explicit and visible in the source code. The compiler will reject `as` casts that are nonsensical (e.g., casting a struct to an integer).

### Cast Summary

| From | To | Behavior |
|------|----|----------|
| Small int | Larger int | Zero/sign extension |
| Large int | Smaller int | Truncation |
| Signed int | Unsigned int | Bit reinterpretation |
| Integer | Float | Nearest representable value |
| Float | Integer | Truncation toward zero |
| Distinct type | Underlying type | Identity (no-op at runtime) |
| Underlying type | Distinct type | Identity (no-op at runtime) |

---

## Type Coercion Rules

K2 performs a small, well-defined set of **implicit coercions**. These are the only cases where a value of one type is silently accepted as another:

| Source | Target | Description |
|--------|--------|-------------|
| Integer literal | Any integer type | Only if the literal's value fits in the target type |
| Array (`[N]T`) | Slice (`[]T`) | Via the `[:]` slice operator |
| Concrete type | `*Interface` pointer | When the type implements the interface (checked at compile time) |
| Non-null value | Optional (`?T`) | A value of type `T` is accepted where `?T` is expected |

All other conversions require an explicit `as` cast. K2 intentionally keeps implicit coercions to a minimum to prevent subtle type errors.

> [!NOTE]
> Integer literals are special: the literal `42` can become `u8`, `i64`, `usize`, or any integer type — as long as the value fits. Once bound to a variable with a concrete type, no further implicit conversion occurs.
