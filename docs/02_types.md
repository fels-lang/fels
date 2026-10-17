# Type System

Fels is statically typed with full inference. It's strict where that catches bugs — distinct types, optionals, no implicit narrowing — and stays out of your way otherwise, through inference and compound literals.

## Primitive Types

### Integer Types

Fels provides fixed-width signed and unsigned integer types:

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

```fels
a := 42i32;       // i32
b := 255u8;        // u8
c := 1000u64;      // u64
d := 0usize;       // usize
```

Without a suffix, an integer literal's type is inferred from context. If no context constrains it, the literal defaults to `i32`. Either way the value has to fit: `b: u8 = 300;` is a compile error, and so is `x := 5000000000;` when nothing gives `x` a wider type (see below; or write `5000000000i64`).

The literal is computed at the type it takes, and so are a minus sign and arithmetic on literals: `k: i64 = -5;` is the 64-bit -5, `big: u64 = 1 << 40;` is computed in 64 bits, and so is `(1 << 40) as u64`. Next to a typed operand a literal takes that operand's type, on either side: with `big: i64`, both `big + 5` and `5 + big` are `i64`. A shift has the type of the value shifted, never that of the amount: with `b: u8`, `x := 1 << b;` is an `i32` and `1 << 10` is 1024.

A local inferred from an unsuffixed integer literal has the type of its first use that asks for one. With `prices: []i64`, `total := 0; for p in prices { total += p; }` makes `total` an `i64`; in a function returning `usize`, `n := 0; … return n;` makes `n` a `usize`; `i := 0; … v.get(i)` makes `i` a `usize`. The uses that count are an assignment to or from the local, a typed local or field it initializes, an argument, a `return`, and a pointer it is given to (`p: *i64 = &n;`); `m := n;` gives `m` the same type. An operand next to a typed one (`i < xs.len`, `n + w`) does not, as the operators take operands of mixed widths. A later use asking for another type is an error, and the literal has to fit the type (`x := 300; b: u8 = x;` is an error). With no such use the local is an `i32`, so `&x` is a `*i32`; a cast reads it as another type (`w: i64 = x as i64;`), or give it its type up front (`x := 42i64` or `x: i64 = 42`). A local from a float literal takes `f32` or `f64` the same way (`w := 0.0;` then `w = size.x;` with an `f32` makes `w` an `f32`) and is an `f64` when nothing asks, so `&y` is a `*f64` for a `y := 1.5` no use gives a type. A constant is different: `N :: 300;` has no width of its own and is checked like the literal wherever it is used, so `b: u8 = N;` is an error.

A suffix is authoritative: it fixes the literal's width even through inference. `x := 0i64` gives `x` a 64-bit slot — the `i64` is not narrowed back to the `i32` default. This matters for values that exceed 32 bits (e.g. addresses built with `usize`/`i64`), where a narrowed slot would silently truncate the value.

Only the widths in the table above are valid suffixes (`i8`/`i16`/`i32`/`i64`/`isize`, their `u` twins, and `byte`). An unsupported or malformed width is a compile error rather than a silently-dropped suffix:

```fels
x := 0u128;   // error: unsupported integer width `u128`: fels integers are at most 64-bit — use `u64` or `usize`
y := 0u9;     // error: unsupported integer width `u9`: ...
z := 3.0f16;  // error: unsupported float width `f16`: fels floats are `f32` or `f64`
```

A hex literal that legitimately ends in letters (`0xABC`, `0xFF`) is *not* a bad suffix — the suffix is split off only after the radix's digits, so hex digits are never mistaken for a width. Float literals accept only `f32`/`f64`.

#### Overflow policy

Fels's policy for plain `+`, `-`, `*` is fixed and never undefined behavior:

| Build | Plain `+` `-` `*` on overflow |
| --- | --- |
| `debug`, `release_safe`, `release_small` (`fels build`, `--release`, `-O0` to `-O3`) | **traps** — aborts at the operation, catching the bug at its source |
| `release_fast` (`--release-fast`, `--unchecked`) | **wraps** (two's complement) |

So overflow is a loud crash in the builds you develop and ship by default, and well-defined
wraparound in the one mode that asks for no checks; there is no overflow UB to exploit.
(`release_fast` also drops the checks on indexing, null pointers, division by zero and shift
amounts, which are undefined behavior there.) When you specifically *want* wraparound in
every build (hashing, PRNGs, checksums, fixed-width counters), use the explicit wrapping
operators `+%`, `-%`, `*%`, which never trap:

```fels
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

Fels has the sub-byte integer types `u1` through `u7`, meant for the fields of `#packed` structs:

```fels
#packed
StatusBits :: struct {
    enabled: u1,
    priority: u3,
    mode: u4,
}
```

> [!NOTE]
> Each sub-byte value takes one whole byte, in a `#packed` struct too: fields are not
> bit-packed yet (see [Packed structs](#packed-structs) below), so `StatusBits` is 3 bytes and
> does not describe a C bitfield or a hardware register. The compiler accepts the types
> elsewhere as well (a local, a parameter, a field of a plain struct), one byte each.

### Float Types

| Type  | Size   | Precision        |
|-------|--------|------------------|
| `f32` | 32-bit | IEEE 754 single  |
| `f64` | 64-bit | IEEE 754 double  |

Float arithmetic and comparisons lower to the correct LLVM floating-point instructions.

```fels
pi := 3.14159f64;
half := 0.5f32;
result := pi * 2.0;
```

### Boolean

`bool` holds one of two values: `true` or `false`.

```fels
flag := true;
done: bool = false;
```

Booleans are used in conditions, logical expressions, and as flags. Fels does not implicitly convert integers or pointers to `bool`.

### Void

`void` is the unit type. It carries no data and is used as the return type for functions that produce no value:

```fels
log :: fn(msg: []const u8) -> void {
    // ...
}
```

You never construct a `void` value directly. A function with a `void` return ends without a return expression, or uses a bare `return;`.

## Composite Types

### Structs

Structs are the primary way to group related data into a single type:

```fels
Point :: struct {
    x: i32,
    y: i32,
}
```

#### Construction

```fels
// Named-field literal — order doesn't matter
p: Point = .{ .x = 10, .y = 20 };

// Positional compound literal (fields filled in declaration order)
p2: Point = .{ 10, 20 };

// Zero-initialized (all fields set to their zero value)
p3: Point = .{};
```

A named literal must name a real field of the struct, and every field without a
default must be supplied — otherwise it's a compile error (`no field …` /
`missing field …`).

#### Default field values

A field may declare a default with `= expr`. A named literal that omits the
field, or a positional/`.{}` literal that stops short of it, fills it from the
default. Defaults work like trailing default arguments — put defaulted fields
last so a positional literal can reach them:

```fels
Config :: struct {
    name: []const u8,
    retries: i32 = 3,
    verbose: bool = false,
}

a: Config = .{ .name = "build" };               // retries = 3, verbose = false
b: Config = .{ .name = "ci", .verbose = true }; // retries = 3
c: Config = .{ "deploy", 5 };                   // verbose = false (default)
```

#### Field Access

```fels
val := p.x;
p.y = 30;
```

> [!TIP]
> Use `.{}` zero initialization to ensure all fields start at known values. This is especially useful for large structs where you only need to override a few fields afterward.

### Packed Structs

The `#packed` attribute creates a struct with no padding between fields. This is essential for hardware registers, binary protocols, and memory-mapped I/O:

```fels
#packed
Flags :: struct {
    readable: bool,
    writable: bool,
    executable: bool,
}
```

Packed structs accept sub-byte field types (`u1` through `u7`), but they are **not bit-packed**: each such field occupies one whole byte. `PixelFormat` below is 3 bytes (not 16 bits), and `StatusBits` above is 3 bytes (not 8 bits). Bit-level packing is not implemented (see the roadmap's known gaps), so these types do not describe a C bitfield.

```fels
#packed
PixelFormat :: struct {
    red: u5,
    green: u6,
    blue: u5,
}
```

> [!IMPORTANT]
> Taking the address of a packed struct field (`&p.b`, `&p.arr[i]`, a field of a nested packed struct) is a compile error, because the field may not be byte-aligned. Read and write packed fields by value, including through a `*Packed` pointer. To hand a field's bytes to something else, take the address of the whole struct and use `core::unaligned_read` or `core::memcpy` at the field's offset.

### Generic Structs

Structs can be parameterized by types (and compile-time values) using `$`-prefixed parameters:

```fels
Pair :: struct($T: type, $U: type) {
    first: T,
    second: U,
}

p: Pair(i32, bool) = .{ 42, true };
```

Generic structs are **monomorphized** — each unique combination of type arguments produces a distinct, specialized type at compile time. `Pair(i32, bool)` and `Pair(f64, f64)` are completely separate types.

```fels
// A dynamically-growable array parameterized by element type
ArrayList :: struct($T: type) {
    items: []T,
    capacity: usize,
}

list: ArrayList(u8) = .{};
```

### Methods

Functions can be declared **inside** a struct body. Within the body, `Self` is the
struct type and the struct's type parameters are in scope, so methods on a generic
struct never re-spell `$T`:

```fels
Vec2 :: struct {
    x: i32, y: i32

    // Associated function (no receiver) — called `Vec2::new(...)`:
    new :: fn(a: i32, b: i32) -> Self { return .{ a, b }; }

    // Methods (receiver `self: *Self`) — called `v.method(...)` via UFCS:
    dot  :: fn(self: *Self, o: *Self) -> i32 { return self.x * o.x + self.y * o.y; }
    len2 :: fn(self: *Self) -> i32 { return self.dot(self); }
}

p := Vec2::new(3, 4);   // associated function: `::`, no receiver
n := p.len2();          // method: `.`, receiver auto-passed (25)
```

```fels
Box :: struct($T: type) {
    value: T
    make :: fn(v: T) -> Self { return .{ v }; }       // T inferred from the arg
    get  :: fn(self: *Self) -> T { return self.value; } // T inferred from the receiver
}

b := Box::make(10);     // Box(i32)
v := b.get();           // 10
```

Two call forms, matching Fels's `::` / `.` split:

- **`Type::name(...)`** for an *associated* function — one with no `self` (a
  constructor, factory, or type-level helper). Mirrors module member access.
- **`value.name(...)`** for a *method* — one whose first parameter is `self: *Self`
  (or `Self`). Uses the same UFCS machinery as free-function extension methods.

A method declared inside a type **shadows** a free function of the same name when
called on that type, so a type can own a `load`/`add`/… without colliding with an
unrelated free function. Conversely, you can still add methods to a type you don't
own by writing a free `self`-first function (see *Extension Methods* in the modules
chapter) — in-struct declarations are for a type's own API, free functions for
extension.

> In-struct methods are sugar: each is lowered to a top-level function named
> `<Struct>.<method>` with `Self` resolved and the struct's type parameters
> inherited, so they cost nothing the existing generic/UFCS machinery doesn't
> already pay. To constrain an inherited type parameter (e.g. "integers only"),
> give the method a `where { … }` clause.

### Enums

Enums define a type that holds one of a fixed set of variants:

```fels
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

```fels
d2: Direction = .north;

move :: fn(dir: Direction) -> void { /* ... */ }
move(.east);
```

The context can be a typed local, an assignment, a call argument, the declared
return type, or a field of a struct literal (positional or named):

```fels
Robot :: struct { id: i32, facing: Direction }

heading :: fn() -> Direction { return .south; }

r1: Robot = .{ 1, .north };                   // positional field
r2: Robot = .{ .id = 2, .facing = .east };    // named field
spawn :: fn() -> Robot { return .{ 3, .west }; }
```

It can also be an element of an array or slice literal, a field's default value, or the other
operand of `==` and `!=`, on either side. A name the enum does not have is an error.

```fels
route: [3]Direction = .{ .north, .north, .east };
Turtle :: struct { facing: Direction = .north }

if d == .north { /* ... */ }
if .west != heading() { /* ... */ }
```

#### Enums with Payloads

Enum variants can carry associated data:

```fels
Rect :: struct { width: f64, height: f64 }

Shape :: enum {
    circle: f64,             // radius
    rectangle: Rect,         // struct payload
    none,                    // no payload
}

s := Shape.circle(3.14);     // construct a variant with its payload
```

Construct a payload-carrying variant by calling the variant as `EnumType.variant(payload)`
(payload-less variants are just `EnumType.variant`). Recover the payload by pattern
matching:

```fels
area :: fn(s: Shape) -> f64 {
    match s {
        .circle |r|    => return 3.14159 * r * r;
        .rectangle |b| => return b.width * b.height;
        else           => return 0.0;
    }
}
```

Enums with payloads are Fels's approach to tagged unions. Construction and matching
both work at compile time too, so comptime code can build and inspect them — the
basis for constructing `ast.*` values programmatically in metaprogramming.

### Error Types

Error types are declared with the `errors` keyword. They look similar to enums but are specifically designed for use with Fels's fallible function system:

```fels
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

```fels
read_file :: fn(path: []const u8) -> []u8 ! IoError {
    // ...
}
```

> [!NOTE]
> See the [Error Handling](04_error_handling.md) chapter for full details on `?`, `catch`, and error propagation.

## Pointer Types

Fels provides several pointer kinds for different use cases.

### Single Pointers

A single pointer points to exactly one value:

| Syntax          | Description                          |
|-----------------|--------------------------------------|
| `*T`            | Mutable pointer to `T`              |
| `*const T`      | Immutable (const) pointer to `T`    |
| `*volatile T`   | Volatile pointer to `T`             |

```fels
x: i32 = 42;
ptr: *i32 = &x;       // take address of x
val := *ptr;           // dereference: read the value (42)
*ptr = 100;            // dereference: write a new value
```

`&` of a variable, a field or an element points at it in place. `&` of any other value (a literal, a call result, arithmetic, an enum variant) stores the value in a temporary and points at that. The temporary lives until the end of the enclosing block, like a local declared there, so the pointer must not be kept past it. An unsuffixed literal's temporary has the literal's default type:

```fels
p := &5;               // *i32, pointing at a temporary holding 5
q := &2.5;             // *f64
r := &5i64;            // a suffix picks another width: *i64
s := &f();             // a temporary holding the call's result
```

A function cannot return an address in its own frame: the address of a local, of a parameter
(a pointer parameter's own address too, `&p`), of a field or an element stored in one, or of a
temporary (`&5`, `&f()`, `&(x + 1)`). The frame is gone once the function returns, so the pointer
would dangle. The compiler follows the address through a local that a declaration or a plain
assignment gave it (`q := &x; return q;`) and into a returned struct or array literal, the way it
keeps a zone's memory inside its zone ([Memory & Zones](05_memory_zones.md)); it does not follow
it through a call. An address that outlives the function can be returned: of a global, a pointer
parameter or what it points at (`&p.field`), an element of a slice, memory from an allocator or
from a zone the caller passes in. A slice of a local array is not checked yet, since a function
that `#run` calls returns the bytes it built that way.

```fels
bad :: fn() -> *i32 { x := 5; return &x; }   // error: the address of local `x` cannot be returned
ok :: fn(p: *Point) -> *i32 { return &p.y; } // points into the caller's `Point`
```

- `*const T` prevents modification through the pointer. The underlying data may still be mutable through another path.
- `*volatile T` ensures every read and write goes to memory, preventing the compiler from optimizing accesses away. Use this for memory-mapped hardware registers.

### Many Pointers

A many-pointer points to an array of values whose length is not tracked:

| Syntax          | Description                              |
|-----------------|------------------------------------------|
| `[*]T`          | Mutable many-pointer to `T`             |
| `[*]const T`    | Const many-pointer to `T`               |

```fels
buffer: [*]u8 = get_raw_buffer();
first := buffer[0];
buffer[3] = 0xFF;
```

> [!WARNING]
> Many pointers perform **no bounds checking**. Indexing past the actual allocation is undefined behavior. Prefer slices (`[]T`) whenever you know the length.

## Slice Types

Slices are a **pointer + length** pair, providing bounds-checked access to a contiguous sequence of elements:

| Syntax        | Description                    |
|---------------|--------------------------------|
| `[]T`         | Mutable slice of `T`          |
| `[]const T`   | Const slice of `T`            |

```fels
arr: [4]i32 = .{ 1, 2, 3, 4 };

slice := arr[:];          // full slice of the array
sub := arr[1..3];         // elements at indices 1 and 2
first := slice[0];        // bounds-checked index access
len := slice.len;         // number of elements
raw := slice.ptr;         // underlying pointer ([*]T)
```

String literals in Fels have the type `[]const u8`:

```fels
greeting: []const u8 = "hello, world";
```

### Comparing strings

`==` and `!=` on `[]const u8` (and `[]u8`) compare **contents**, not slice
identity. The comparison checks the length first, then the bytes, so it never
reads past either slice:

```fels
a: []const u8 = "abc";
b: []const u8 = "abc";

a == b        // true  — same contents
a == "abc"    // true  — either side may be a literal
a != "abd"    // true
"ab" == "abc" // false — different length
```

This is the same byte-wise lowering used by `match` string patterns, and it
runs in the compile-time VM too, so string comparisons fold at comptime (handy
in `#run` constants and `#compiler` hooks, e.g. `if d.derives == "Sum"`).

> [!NOTE]
> Other slice element types (e.g. `[]i32`) do not get content comparison —
> `==` is defined for byte slices (strings). Compare those element-by-element.

> [!TIP]
> Slices are the preferred way to pass sequences of data. They are lightweight (just two machine words) and safe (bounds-checked at runtime, in every build but `release_fast`).

## Array Types

Arrays are fixed-size, stack-allocated sequences:

```fels
[N]T    // array of N elements of type T
```

```fels
data: [4]u8 = .{ 1u8, 2u8, 3u8, 4u8 };
zeros: [256]u8 = .{};                    // zero-initialized
len := data.len;                          // compile-time known: 4
```

The length `N` is an integer literal or a constant, also one that compile-time code computes (`N :: #run count();` or `N :: count();`, see [09_comptime](09_comptime.md)). An array literal may stop short, and the rest is zero, but it may not have more elements than the array: `a: [3]i32 = .{ 1, 2, 3, 4 };` is a compile error.

Arrays differ from slices in that their length is part of the type. `[4]u8` and `[8]u8` are different types. To pass an array to a function expecting a slice, use the slice operator:

```fels
process :: fn(items: []const u8) -> void { /* ... */ }

buf: [16]u8 = .{};
process(buf[:]);    // convert array to slice
```

## Optional Types

An optional wraps a value that may or may not be present:

```fels
?T    // either a value of type T, or null
```

```fels
maybe: ?i32 = 42;
none: ?i32 = null;
```

### Unwrapping Optionals

#### Force Unwrap (`!!`)

Extracts the value, **panicking at runtime** if the optional is `null`:

```fels
val := maybe!!;    // 42 — or panic if null
```

#### Nil Coalesce (`??`)

Provides a default value when the optional is `null`:

```fels
val := maybe ?? 0;    // 42, or 0 if maybe were null
```

#### Conditional Checks

```fels
if maybe != null {
    // maybe is guaranteed non-null in this branch
}
```

> [!CAUTION]
> Avoid `!!` in production code paths unless you are certain the value cannot be `null`. Prefer `??` or explicit null checks to handle the `null` case gracefully.

## Function Types

Function types describe a function's signature as a first-class type:

```fels
fn(i32, i32) -> i32                        // two i32 params, returns i32
fn(*Self, []const u8) -> usize ! IoError   // fallible method
fn() -> void                               // no params, no return value
```

Function types allow storing and passing functions as values:

```fels
apply :: fn(f: fn(i32) -> i32, x: i32) -> i32 {
    return f(x);
}

double :: fn(n: i32) -> i32 { return n * 2; }

result := apply(double, 21);    // 42
```

## Distinct Types

Distinct types create **newtypes** — types that share the underlying representation but are treated as separate types by the compiler:

```fels
UserId :: distinct u64;
Pixels :: distinct i32;
```

This prevents accidental mixing of semantically different values:

```fels
user: UserId = 42u64 as UserId;
offset: Pixels = 100i32 as Pixels;

// ERROR: cannot pass Pixels where UserId is expected
// lookup(offset);
```

Convert between a distinct type and its underlying type with `as`:

```fels
id: UserId = 42u64 as UserId;
raw := id as u64;              // back to plain u64
```

> [!TIP]
> Distinct types are zero-cost. At runtime, `UserId` and `u64` have identical representation. The distinction exists only at compile time for type safety.

## Type Aliases

A type alias gives an existing type a second name. Unlike `distinct`, an alias is
**transparent** — the alias and its underlying type are fully interchangeable:

```fels
MyInt :: i32;
Bytes :: []u8;
Trio  :: [3]i32;
CStr  :: [*]const u8;

add :: fn(a: MyInt, b: MyInt) -> i32 { return a + b; }  // MyInt == i32
```

`Name :: <right-hand side>;` declares an alias when the right-hand side is a type
and a value constant when it is not. A primitive type keyword (`i32`, `bool`, …) or
a type constructor (`[`, `*`, `[*`, `?`, `borrow`, `atomic`) is a type on sight. A
bare identifier is a type when it **names** one — a built-in such as `f32`, `byte`
or `Text`, a struct, enum or other declared type, or another alias, in this module
or another (`lib::Node`) — and a constant otherwise:

```fels
Real  :: f32;           // an alias of a built-in
Node  :: struct { v: i32 }
Point :: Node;          // an alias of a struct (declared before or after `Node`)
Money :: Real;          // an alias of an alias

Pair    :: struct($T: type) { a: T, b: T }
IntPair :: Pair(i32);   // an alias of a generic type's instance

LIMIT :: 8;
MAX   :: LIMIT;         // names a constant, so a constant — not an alias
```

An alias is accepted wherever its type can be written: annotations, parameters,
returns, fields, pointers, slices, casts, generic type arguments and `core::sizeof`. A
`pub` alias can be imported without importing the type it names.

An alias stands for its type in a path as well: `P::new(…)`, `Hue.red` through an enum
alias, `! ErrorAlias`, and from another module (`lib::P::new(…)`), which is how a module
re-exports a type. An interface is implemented on the type itself (`Point as Shape { … }`),
not on an alias of it.

The standard library uses aliases for C ABI types — see [`std.c`](11_c_interop.md):

```fels
#import std.c.{ c_int, c_string };
#extern("kernel32", "lstrlenA")
lstrlenA :: fn(s: c_string) -> c_int;
```

## Opaque Types

Opaque types declare a type with no visible definition. They can only be used behind a pointer:

```fels
Foo :: opaque;
```

```fels
// Only *Foo is usable — you cannot create or inspect a Foo value directly
get_handle :: fn() -> *Foo { /* ... */ }
use_handle :: fn(h: *Foo) -> void { /* ... */ }
```

Opaque types are useful for:
- **FFI boundaries** — wrapping C `void*` handles with a named type.
- **Abstraction** — exposing a handle to callers without revealing the implementation.

## Atomic Types

The `atomic` qualifier marks a struct field that threads share:

```fels
Counter :: struct {
    value: atomic u32,
}
```

The qualifier documents the intent; it does not change how the field may be used. Access it
atomically through [`std.atomics`](07_stdlib.md#stdatomics), whose operations are sequentially
consistent:

```fels
#import std.atomics as atomics;

c: Counter = .{ .value = 0 };
old := atomics::fetch_add(&c.value, 1);   // returns the previous value
now := atomics::load(&c.value);
```

The `core::atomic_*` builtins under them take the memory ordering as their last argument
(`core::atomic_load(&c.value, 4)`; see [Builtins](08_attributes_builtins.md)). The atomic
wrapper type `Atomic(T)` in `std.atomics` keeps the value inside it instead.

> [!NOTE]
> The compiler does not yet check how an `atomic` field is used: a plain `c.value = 3` compiles,
> and so does the qualifier on a local. Use `std.atomics` for every access.

## Borrow Types

The `borrow` qualifier creates a temporary, non-owning reference to zone-allocated data:

```fels
borrow *T       // borrowed pointer
borrow []T      // borrowed slice
```

Borrowed references allow you to pass zone-owned values to functions without transferring ownership:

```fels
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
> Borrowed references are a compile-time safety mechanism. They guarantee that zone-owned data is not accidentally captured beyond its intended scope. See the [Memory Management](05_memory_zones.md) chapter for details on zones and ownership.

## Type Casting

The `as` operator performs explicit type conversions:

```fels
x := 42i32;
y := x as i64;          // integer widening (lossless)
z := x as u32;          // signed to unsigned
f := x as f64;          // integer to float
i := 3.14 as i32;       // float to integer (truncates toward zero)
d := id as u64;         // distinct type to underlying type
```

All casts in Fels are explicit and visible in the source code. The compiler will reject `as` casts that are nonsensical (e.g., casting a struct to an integer).

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

## Type Coercion Rules

Fels performs a small, well-defined set of **implicit coercions**. These are the only cases where a value of one type is silently accepted as another:

| Source | Target | Description |
|--------|--------|-------------|
| Integer literal | Any integer type | Only if the literal's value fits in the target type |
| Array (`[N]T`) | Slice (`[]T`) | Via the `[:]` slice operator |
| Concrete type | `*Interface` pointer | When the type implements the interface (checked at compile time) |
| Non-null value | Optional (`?T`) | A value of type `T` is accepted where `?T` is expected |

All other conversions require an explicit `as` cast. Fels intentionally keeps implicit coercions to a minimum to prevent subtle type errors.

> [!NOTE]
> Integer literals are special: the literal `42` can become `u8`, `i64`, `usize`, or any integer type — as long as the value fits. Once bound to a variable with a concrete type, no further implicit conversion occurs.
