# Type System

Fels is statically typed and infers types throughout. It is strict where that catches bugs,
which is why it has distinct types and optionals and never narrows a value implicitly.
Everywhere else, inference and compound literals keep it out of your way.

## Primitive Types

### Integer Types

Fels has signed and unsigned integer types of fixed width:

| Signed | Unsigned | Size |
|--------|----------|------|
| `i8` | `u8` | 8-bit |
| `i16` | `u16` | 16-bit |
| `i32` | `u32` | 32-bit |
| `i64` | `u64` | 64-bit |
| `isize` | `usize` | pointer-width |

`isize` and `usize` are as wide as a pointer, so they have 64 bits on 64-bit platforms. Use
`usize` for array indices and lengths, and `isize` when you need a signed offset.

#### Integer Literals

An integer literal can carry a suffix that names its type:

```fels
a := 42i32;       // i32
b := 255u8;        // u8
c := 1000u64;      // u64
d := 0usize;       // usize
```

Without a suffix, the literal takes its type from the context. When nothing in the context
decides it, the literal is an `i32`. Either way the value has to fit, so `b: u8 = 300;` is a
compile error. So is `x := 5000000000;` when nothing gives `x` a wider type (see below, or
write `5000000000i64`).

A literal is computed at the type it takes, and the same goes for a minus sign in front of it
and for arithmetic on literals. So `k: i64 = -5;` is the 64-bit -5, `big: u64 = 1 << 40;` is
computed in 64 bits, and so is `(1 << 40) as u64`. Next to a typed operand, a literal takes
that operand's type, on either side: with `big: i64`, both `big + 5` and `5 + big` are `i64`.
A shift has the type of the value being shifted, never the type of the amount. With `b: u8`,
`x := 1 << b;` is an `i32`, and `1 << 10` is 1024.

A local inferred from an unsuffixed integer literal gets its type from the first use that
asks for one. With `prices: []i64`, `total := 0; for p in prices { total += p; }` makes
`total` an `i64`. In a function returning `usize`, `n := 0; … return n;` makes `n` a `usize`,
and `i := 0; … v.get(i)` makes `i` a `usize`.

The uses that count are an assignment to or from the local, a typed local or field it
initializes, an argument, a `return`, and a pointer it is given to (`p: *i64 = &n;`). And
`m := n;` gives `m` the same type. Being an operand next to a typed one (`i < xs.len`,
`n + w`) does not count, because the operators take operands of mixed widths. A later use
that asks for another type is an error, and the literal has to fit the type
(`x := 300; b: u8 = x;` is an error).

When no use asks for a type, the local is an `i32`, so `&x` is a `*i32`. A cast reads it as
another type (`w: i64 = x as i64;`), or you can give it its type up front (`x := 42i64` or
`x: i64 = 42`).

A local from a float literal takes `f32` or `f64` the same way. After `w := 0.0;`, the
assignment `w = size.x;` with an `f32` makes `w` an `f32`. When nothing asks, the local is an
`f64`. So for a `y := 1.5` that no use gives a type, `&y` is a `*f64`.

A constant is different. `N :: 300;` has no width of its own and is checked like the literal
wherever it is used, so `b: u8 = N;` is an error.

A suffix has the final word. It fixes the literal's width even through inference, so
`x := 0i64` gives `x` a 64-bit slot, and the `i64` is not narrowed back to the `i32` default.
This matters for values that exceed 32 bits (e.g. addresses built with `usize`/`i64`),
because a narrowed slot would silently truncate the value.

Only the widths in the table above are valid suffixes (`i8`/`i16`/`i32`/`i64`/`isize`, their
`u` twins, and `byte`). An unsupported or malformed width is a compile error, so a suffix is
never dropped silently:

```fels
x := 0u128;   // error: unsupported integer width `u128`: fels integers are at most 64-bit — use `u64` or `usize`
y := 0u9;     // error: unsupported integer width `u9`: ...
z := 3.0f16;  // error: unsupported float width `f16`: fels floats are `f32` or `f64`
```

A hex literal that ends in letters (`0xABC`, `0xFF`) is *not* a bad suffix. The suffix is
split off only after the digits of the radix, so hex digits are never mistaken for a width.
Float literals accept only `f32`/`f64`.

#### Overflow policy

What plain `+`, `-` and `*` do on overflow is fixed, and it is never undefined behavior:

| Build | Plain `+` `-` `*` on overflow |
| --- | --- |
| `debug`, `release_safe`, `release_small` (`fels build`, `--release`, `-O0` to `-O3`) | **traps**: aborts at the operation, so the bug is caught at its source |
| `release_fast` (`--release-fast`, `--unchecked`) | **wraps** (two's complement) |

So overflow is a loud crash in the builds you develop and ship by default. In the one mode
that asks for no checks, it is a well-defined wraparound, so there is no overflow UB to
exploit. (`release_fast` also drops the checks on indexing, null pointers, division by zero
and shift amounts, and those faults are undefined behavior there.)

When you *want* wraparound in every build, for hashing, PRNGs, checksums or fixed-width
counters, use the explicit wrapping operators `+%`, `-%` and `*%`. They never trap:

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

The wrapping operators work on integers only. They behave the same at compile time, so a
hash like the one above can be evaluated in a `#run` constant and matches its runtime value.

#### Sub-Byte Integer Types

For the fields of `#packed` structs, Fels has the sub-byte integer types `u1` through `u7`:

```fels
#packed
StatusBits :: struct {
    enabled: u1,
    priority: u3,
    mode: u4,
}
```

In a `#packed` struct each of them takes only its bits, so `StatusBits` is one byte (see
[Packed structs](#packed-structs) below). Anywhere else, such as in a local, a parameter or a
field of a plain struct, a sub-byte value takes a whole byte.

### Float Types

| Type  | Size   | Precision        |
|-------|--------|------------------|
| `f32` | 32-bit | IEEE 754 single  |
| `f64` | 64-bit | IEEE 754 double  |

Float arithmetic and comparisons lower to the matching LLVM floating-point instructions.

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

You use booleans in conditions, in logical expressions and as flags. Fels never converts an
integer or a pointer to `bool` implicitly.

### Void

`void` is the unit type. It carries no data, and you use it as the return type of a function
that produces no value:

```fels
log :: fn(msg: []const u8) -> void {
    // ...
}
```

You never construct a `void` value yourself. A function with a `void` return ends without a
return expression, or it uses a bare `return;`.

## Composite Types

### Structs

Structs are the main way to group related data into a single type:

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

A named literal can only name fields the struct really has, and it must supply every field
that has no default. Otherwise you get a compile error (`no field …` / `missing field …`).

#### Default field values

A field can declare a default with `= expr`. When a named literal leaves the field out, or a
positional/`.{}` literal stops short of it, the field is filled from its default. Defaults
work like trailing default arguments, so put the defaulted fields last, where a positional
literal can reach them:

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
> Use `.{}` zero initialization to make sure every field starts at a known value. It helps
> most with large structs where you only need to override a few fields afterward.

### Packed Structs

The `#packed` attribute gives you a struct with no padding between its fields. You need that
for hardware registers, binary protocols and memory-mapped I/O:

```fels
#packed
Flags :: struct {
    readable: bool,
    writable: bool,
    executable: bool,
}
```

A packed struct with a sub-byte field (`u1`–`u7`, `i1`–`i7`) is laid out bit by bit. Each
integer field takes exactly its width and starts at the bit where the field before it ended,
counting up from the lowest bit of the first byte. `PixelFormat` below is 16 bits, or two
bytes, with `red` in bits 0–4, `green` in bits 5–10 and `blue` in bits 11–15. `StatusBits`
above is one byte. A wider integer can start inside a byte too (`a: u3, b: u8` puts `b` in
bits 3–10). The struct takes as many bytes as its bits need, and in a literal the bits after
the last field are zero.

```fels
#packed
PixelFormat :: struct {
    red: u5,
    green: u6,
    blue: u5,
}

p: PixelFormat = .{ 31, 0, 31 };   // the bits 0b11111_000000_11111
p.green = 63;                      // the other fields keep their bits
```

A field that is not an integer (a `bool`, a float, a pointer, a struct, an array) takes whole
bytes and starts at a whole byte. If the integers before it end inside a byte, you get an
error that says how many bits are missing. That way the filler is written out
(`reserved: u5`) instead of being added without a word. A `bool` is a byte, so use `u1` when
you want a bit. `core::offset_of` gives the byte that holds a field's first bit. A packed
struct without sub-byte fields is laid out byte by byte, as C's `#pragma pack(1)` does.

> [!IMPORTANT]
> Taking the address of a packed struct field (`&p.b`, `&p.arr[i]`, a field of a nested
> packed struct) is a compile error, because the field may not be byte-aligned. You read and
> write packed fields by value, including through a `*Packed` pointer. To hand a field's bytes
> to something else, take the address of the whole struct and use `core::unaligned_read` or
> `core::memcpy` at the field's offset.

### Unions

A `union` is a struct whose fields share their storage. Every field starts at offset 0, and
the union is as large as its largest field, rounded up to the strictest alignment among them.
It is C's untagged union, and you use it for the bytes a C API overlays and for viewing a
value's bits as another type.

```fels
Halves :: struct { low: u32, high: u32 }
LargeInteger :: union { quad: u64, parts: Halves }   // 8 bytes

li: LargeInteger = .{ .quad = 0x0000000500000007 };
low := unsafe (li.parts.low);                          // 7
li.parts.high = 1;                                     // writes the upper four bytes
```

Nothing records which field was written last, so reading a field reinterprets the bytes as
that field's type, whatever they hold. That is what a pointer cast does, and like a pointer
cast it is done in `unsafe`. Writing a field (the place of a plain `=`) is not unsafe. But
`u.f += 1` reads `u.f` first, so it is unsafe. Taking `&u.f` hands out a pointer that reads
the same way, so that is `unsafe` too.

A union literal sets one field and zeroes the rest of the bytes. `.{ v }` sets the first
field, `.{ .name = v }` sets another, and `.{}` leaves the whole union zero. A union in static
storage (a global, a constant) starts as `.{}`, and you write its field at run time.

`core::sizeof`, `core::align_of` and `core::offset_of` (always 0) work on a union. A union can
be generic (`Cell :: union($T: type) { value: T, raw: [8]u8 }`). `core::type_info` reports
one as `.union_`, so a reflective reader does not take its fields for separate values. The
comptime VM does not run code that reads or writes a union's fields.

When a value is one of several things and knows which, use a payload enum (below).

### Generic Structs

A struct can take types (and compile-time values) as parameters, written with a `$` prefix:

```fels
Pair :: struct($T: type, $U: type) {
    first: T,
    second: U,
}

p: Pair(i32, bool) = .{ 42, true };
```

Generic structs are **monomorphized**. Each unique combination of type arguments produces its
own specialized type at compile time, so `Pair(i32, bool)` and `Pair(f64, f64)` are
completely separate types.

```fels
// A dynamically-growable array parameterized by element type
ArrayList :: struct($T: type) {
    items: []T,
    capacity: usize,
}

list: ArrayList(u8) = .{};
```

### Methods

You can declare functions **inside** a struct body. There, `Self` is the struct type and the
struct's type parameters are in scope, so methods on a generic struct never have to spell
out `$T` again:

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

There are two call forms, and they follow Fels's `::` / `.` split:

- **`Type::name(...)`** calls an *associated* function, one with no `self`, such as a
  constructor, a factory or a type-level helper. It mirrors module member access.
- **`value.name(...)`** calls a *method*, one whose first parameter is `self: *Self`
  (or `Self`). It uses the same UFCS machinery as free-function extension methods.

A method declared inside a type **shadows** a free function of the same name when you call
it on that type. So a type can own a `load`/`add`/… without colliding with an unrelated free
function. The other way round, you can still add methods to a type you don't own by writing
a free function that takes `self` first (see *Extension Methods* in the modules chapter).
In-struct declarations are for a type's own API, and free functions are for extension.

> In-struct methods are sugar. Each one is lowered to a top-level function named
> `<Struct>.<method>`, with `Self` resolved and the struct's type parameters inherited. So
> they cost nothing beyond what the existing generic/UFCS machinery already pays. To
> constrain an inherited type parameter (e.g. "integers only"), give the method a
> `where { … }` clause.

### Enums

An enum is a type that holds one of a fixed set of variants:

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

When the context tells the compiler which type to expect, you can use the dot shorthand:

```fels
d2: Direction = .north;

move :: fn(dir: Direction) -> void { /* ... */ }
move(.east);
```

The context can be a typed local, an assignment, a call argument, the declared return type,
or a field of a struct literal (positional or named):

```fels
Robot :: struct { id: i32, facing: Direction }

heading :: fn() -> Direction { return .south; }

r1: Robot = .{ 1, .north };                   // positional field
r2: Robot = .{ .id = 2, .facing = .east };    // named field
spawn :: fn() -> Robot { return .{ 3, .west }; }
```

It can also be an element of an array or slice literal, a field's default value, or the other
operand of `==` and `!=`, on either side. Using a name the enum does not have is an error.

```fels
route: [3]Direction = .{ .north, .north, .east };
Turtle :: struct { facing: Direction = .north }

if d == .north { /* ... */ }
if .west != heading() { /* ... */ }
```

#### Enums with Payloads

An enum variant can carry data of its own:

```fels
Rect :: struct { width: f64, height: f64 }

Shape :: enum {
    circle: f64,             // radius
    rectangle: Rect,         // struct payload
    none,                    // no payload
}

s := Shape.circle(3.14);     // construct a variant with its payload
```

To construct a variant with a payload, call the variant: `EnumType.variant(payload)`. A
variant without a payload is written `EnumType.variant`. Where the type is known, the dot
shorthand takes the payload the same way, in every place where `.variant` works:

```fels
s: Shape = .circle(2.0);
shapes: [2]Shape = .{ .rectangle(.{ 1.0, 2.0 }), .none };
unit :: fn() -> Shape { return .circle(1.0); }
```

You get the payload back by pattern matching:

```fels
area :: fn(s: Shape) -> f64 {
    match s {
        .circle |r|    => { return 3.14159 * r * r; },
        .rectangle |b| => { return b.width * b.height; },
        else           => { return 0.0; },
    }
}
```

Enums with payloads are how Fels does tagged unions (a `union` is untagged). Construction and
matching both work at compile time too, so comptime code can build and inspect them. This is
the basis for constructing `ast.*` values programmatically in metaprogramming.

### Error Types

You declare an error type with the `errors` keyword. It looks a lot like an enum, but it is
made for use with Fels's fallible functions:

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

Error types work with the `!` operator in a function's return type, which marks the function
as fallible:

```fels
read_file :: fn(path: []const u8) -> []u8 ! IoError {
    // ...
}
```

> [!NOTE]
> The [Error Handling](04_error_handling.md) chapter covers `?`, `catch` and error
> propagation in full.

## Pointer Types

Fels has several kinds of pointer, each for a different use.

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

`&` of a variable, a field or an element points at it in place. `&` of any other value (a
literal, a call result, arithmetic, an enum variant) stores the value in a temporary and
points at that. The temporary lives until the end of the enclosing block, like a local
declared there, so you must not keep the pointer past that point. The temporary for an
unsuffixed literal has the literal's default type:

```fels
p := &5;               // *i32, pointing at a temporary holding 5
q := &2.5;             // *f64
r := &5i64;            // a suffix picks another width: *i64
s := &f();             // a temporary holding the call's result
```

A function cannot return an address in its own frame. That covers the address of a local, of
a parameter (a pointer parameter's own address too, `&p`), of a field or an element stored in
one, and of a temporary (`&5`, `&f()`, `&(x + 1)`). The frame is gone once the function
returns, so the pointer would dangle.

The compiler follows the address through a local that a declaration or a plain assignment
gave it (`q := &x; return q;`) and into a returned struct or array literal. This is the same
way it keeps a zone's memory inside its zone ([Memory & Zones](05_memory_zones.md)). It does
not follow the address through a call.

An address that outlives the function can be returned. That is the case for a global, for a
pointer parameter or what it points at (`&p.field`), for an element of a slice, and for
memory from an allocator or from a zone the caller passes in. A slice of a local array is
not checked yet, because a function that `#run` calls returns the bytes it built that way.

```fels
bad :: fn() -> *i32 { x := 5; return &x; }   // error: the address of local `x` cannot be returned
ok :: fn(p: *Point) -> *i32 { return &p.y; } // points into the caller's `Point`
```

- `*const T` prevents modification through the pointer. The underlying data may still be
  mutable through another path.
- `*volatile T` makes every read and write go to memory, so the compiler cannot optimize the
  accesses away. Use it for memory-mapped hardware registers.

### Many Pointers

A many-pointer points to an array of values, but it does not track their length:

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
> Many pointers perform **no bounds checking**, and indexing past the actual allocation is
> undefined behavior. Prefer slices (`[]T`) whenever you know the length.

## Slice Types

A slice is a **pointer + length** pair. It gives you bounds-checked access to a contiguous
sequence of elements:

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

`==` and `!=` on `[]const u8` (and `[]u8`) compare **contents**, not slice identity. The
comparison checks the length first and then the bytes, so it never reads past either slice:

```fels
a: []const u8 = "abc";
b: []const u8 = "abc";

a == b        // true  — same contents
a == "abc"    // true  — either side may be a literal
a != "abd"    // true
"ab" == "abc" // false — different length
```

This is the same byte-wise lowering that `match` string patterns use. It runs in the
compile-time VM too, so string comparisons fold at comptime. That comes in handy in `#run`
constants and `#compiler` hooks, e.g. `if d.derives == "Sum"`.

> [!NOTE]
> Slices of other element types (e.g. `[]i32`) do not get content comparison, since `==` is
> defined for byte slices (strings). Compare those element by element.

> [!TIP]
> Slices are the preferred way to pass a sequence of data. They are lightweight (only two
> machine words) and safe, because they are bounds-checked at runtime in every build except
> `release_fast`.

## Array Types

An array is a fixed-size sequence, allocated on the stack:

```fels
[N]T    // array of N elements of type T
```

```fels
data: [4]u8 = .{ 1u8, 2u8, 3u8, 4u8 };
zeros: [256]u8 = .{};                    // zero-initialized
len := data.len;                          // compile-time known: 4
```

The length `N` is an integer literal or a constant, and that includes a constant that
compile-time code computes (`N :: #run count();` or `N :: count();`, see
[09_comptime](09_comptime.md)). An array literal may stop short, and the rest is then zero.
It may not have more elements than the array, so `a: [3]i32 = .{ 1, 2, 3, 4 };` is a compile
error.

Unlike a slice, an array has its length as part of its type, so `[4]u8` and `[8]u8` are
different types. To pass an array to a function that expects a slice, use the slice operator:

```fels
process :: fn(items: []const u8) -> void { /* ... */ }

buf: [16]u8 = .{};
process(buf[:]);    // convert array to slice
```

## Optional Types

An optional holds a value that may or may not be present:

```fels
?T    // either a value of type T, or null
```

```fels
maybe: ?i32 = 42;
none: ?i32 = null;
```

### Unwrapping Optionals

#### Force Unwrap (`!!`)

`!!` extracts the value and **panics at runtime** if the optional is `null`:

```fels
val := maybe!!;    // 42 — or panic if null
```

#### Nil Coalesce (`??`)

`??` gives you a default value for when the optional is `null`:

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
> Avoid `!!` in production code paths unless you are certain the value cannot be `null`.
> Prefer `??` or an explicit null check, so that you handle the `null` case gracefully.

## Function Types

A function type describes a function's signature, and it is a first-class type:

```fels
fn(i32, i32) -> i32                        // two i32 params, returns i32
fn(*Self, []const u8) -> usize ! IoError   // fallible method
fn() -> void                               // no params, no return value
```

With function types you can store functions and pass them around as values:

```fels
apply :: fn(f: fn(i32) -> i32, x: i32) -> i32 {
    return f(x);
}

double :: fn(n: i32) -> i32 { return n * 2; }

result := apply(double, 21);    // 42
```

A `fn(...)` value is a closure, `{ fn, env }`, wherever it is. That holds for a local, a
parameter, an array element and a struct field, so a lambda that captures can be stored in
any of them. A C function pointer is one bare code address, and you write it as
`extern fn(...)`. You meet it in a C struct's callback field, in a COM vtable's methods and
as an argument of a C function.

```fels
Button :: struct { on_click: fn(i32) -> i32 }           // a closure
WNDCLASS :: struct { style: u32, proc: extern fn(usize, u32, usize, isize) -> isize }  // C
```

## Distinct Types

A distinct type creates a **newtype**. It shares the representation of its underlying type,
but the compiler treats it as a separate type:

```fels
UserId :: distinct u64;
Pixels :: distinct i32;
```

That keeps you from mixing up values that mean different things:

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
> Distinct types are zero-cost. At runtime `UserId` and `u64` have the same representation,
> and the distinction exists only at compile time, for type safety.

## Type Aliases

A type alias gives an existing type a second name. Unlike `distinct`, an alias is
**transparent**, so the alias and its underlying type are fully interchangeable:

```fels
MyInt :: i32;
Bytes :: []u8;
Trio  :: [3]i32;
CStr  :: [*]const u8;

add :: fn(a: MyInt, b: MyInt) -> i32 { return a + b; }  // MyInt == i32
```

`Name :: <right-hand side>;` declares an alias when the right-hand side is a type, and a
value constant when it is not. A primitive type keyword (`i32`, `bool`, …) or a type
constructor (`[`, `*`, `[*`, `?`, `borrow`, `atomic`) is a type on sight. A bare identifier
is a type when it **names** one: a built-in such as `f32`, `byte` or `Text`, a struct, enum or
other declared type, or another alias, in this module or another (`lib::Node`). Any other
bare identifier is a constant:

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

You can use an alias wherever its type can be written: in annotations, parameters, returns,
fields, pointers, slices, casts, generic type arguments and `core::sizeof`. A `pub` alias can
be imported without importing the type it names.

An alias stands for its type in a path as well. That covers `P::new(…)`, `Hue.red` through an
enum alias, `! ErrorAlias`, and paths from another module (`lib::P::new(…)`), which is how a
module re-exports a type. An interface is implemented on the type itself
(`Point as Shape { … }`), not on an alias of it.

The standard library uses aliases for C ABI types (see [`std.c`](11_c_interop.md)):

```fels
#import std.c.{ c_int, c_string };
#extern("kernel32", "lstrlenA")
lstrlenA :: fn(s: c_string) -> c_int;
```

## Opaque Types

An opaque type is a type with no visible definition, so you can only use it behind a pointer:

```fels
Foo :: opaque;
```

```fels
// Only *Foo is usable — you cannot create or inspect a Foo value directly
get_handle :: fn() -> *Foo { /* ... */ }
use_handle :: fn(h: *Foo) -> void { /* ... */ }
```

Opaque types are useful for:
- **FFI boundaries**: wrapping C `void*` handles in a named type.
- **Abstraction**: giving callers a handle without revealing the implementation.

## Atomic Types

The `atomic` qualifier marks a struct field that threads share:

```fels
Counter :: struct {
    value: atomic u32,
}
```

The qualifier documents the intent, but it does not change how the field may be used. Access
the field atomically through [`std.atomics`](07_stdlib.md#stdatomics), whose operations are
sequentially consistent:

```fels
#import std.atomics as atomics;

c: Counter = .{ .value = 0 };
old := atomics::fetch_add(&c.value, 1);   // returns the previous value
now := atomics::load(&c.value);
```

The `core::atomic_*` builtins underneath take the memory ordering as their last argument
(`core::atomic_load(&c.value, 4)`, see [Builtins](08_attributes_builtins.md)). The atomic
wrapper type `Atomic(T)` in `std.atomics` keeps the value inside it instead.

> [!NOTE]
> The compiler does not yet check how an `atomic` field is used. A plain `c.value = 3`
> compiles, and so does the qualifier on a local, so use `std.atomics` for every access.

## Borrow Types

The `borrow` qualifier creates a temporary reference to zone-allocated data, one that does
not own it:

```fels
borrow *T       // borrowed pointer
borrow []T      // borrowed slice
```

With a borrowed reference you can pass a zone-owned value to a function without transferring
ownership:

```fels
print_name :: fn(name: borrow []const u8) -> void {
    // Can read `name` but cannot store it or return it
}
```

### Borrow Rules

| Allowed | Not Allowed |
|---------|-------------|
| Read through the reference | Store through a pointer or into a global |
| Pass to another `borrow` parameter | Return from a function |
| Use in expressions | Forward to a non-`borrow` parameter |
| Hold in a local struct or array, which is then borrowed too | |

> [!IMPORTANT]
> Borrowed references are a safety mechanism that works at compile time. They make sure that
> zone-owned data is not captured by accident beyond its intended scope. See the
> [Memory Management](05_memory_zones.md) chapter for the details on zones and ownership.

## Type Casting

You convert a value to another type explicitly with the `as` operator:

```fels
x := 42i32;
y := x as i64;          // integer widening (lossless)
z := x as u32;          // signed to unsigned
f := x as f64;          // integer to float
i := 3.14 as i32;       // float to integer (truncates toward zero)
d := id as u64;         // distinct type to underlying type
```

Every cast in Fels is explicit and visible in the source code. The compiler rejects `as`
casts that make no sense (e.g., casting a struct to an integer).

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

Fels has a small, well-defined set of **implicit coercions**. They are the only cases where a
value of one type is silently accepted as another:

| Source | Target | Description |
|--------|--------|-------------|
| Integer literal | Any integer type | Only if the literal's value fits in the target type |
| Array (`[N]T`) | Slice (`[]T`) | Via the `[:]` slice operator |
| Concrete type | `*Interface` pointer | When the type implements the interface (checked at compile time) |
| Non-null value | Optional (`?T`) | A value of type `T` is accepted where `?T` is expected |

Every other conversion needs an explicit `as` cast. Fels keeps implicit coercions to a
minimum on purpose, to prevent subtle type errors.

> [!NOTE]
> Integer literals are special. The literal `42` can become a `u8`, an `i64`, a `usize` or
> any other integer type, as long as the value fits. Once it is bound to a variable with a
> concrete type, no further implicit conversion happens.
