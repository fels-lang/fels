# Syntax Reference

This page covers every lexical element of Fels, from comments and identifiers to literals,
operators and punctuation.

## Comments

Fels has **line comments only** and no block comments. A line comment starts with `//` and
runs to the end of the line:

```fels
// This is a comment
x := 42; // inline comment
```

> [!NOTE]
> Fels leaves out block comments (`/* ... */`) on purpose. For a longer comment, write several
> line comments in a row.

## Identifiers

Identifiers are the names you give to variables, functions, types and other declarations.

**Rules:**
- Must start with a letter (`a`–`z`, `A`–`Z`) or underscore (`_`)
- May continue with letters, digits (`0`–`9`) or underscores
- Are **case-sensitive**, so `foo`, `Foo` and `FOO` are three different identifiers

```fels
x := 1;
my_variable := 2;
_private := 3;
Point2D :: struct { x: f64, y: f64 }
```

### Escaped Identifiers

Put `@` in front of an identifier to use a keyword as an ordinary name. The same prefix lets
you define special names (like the runtime's `@panic`) that cannot clash with the names in
user code:

```fels
@if := 42;          // uses the keyword 'if' as a variable name
@panic("oh no");    // the runtime's panic function
```

## Keywords

The tables below list every keyword in Fels, grouped by category.

### Declaration Keywords

| Keyword | Purpose |
|---------|---------|
| `fn` | Function declaration |
| `struct` | Struct type definition |
| `union` | Union type definition (fields share their storage) |
| `interface` | Interface (trait) type definition |
| `enum` | Enum type definition |
| `errors` | Error set type definition |
| `distinct` | Distinct (newtype) wrapper |
| `opaque` | Opaque type (forward declaration) |
| `pub` | Public visibility modifier |

### Qualifier Keywords

| Keyword | Purpose |
|---------|---------|
| `atomic` | Atomic type qualifier |
| `borrow` | Borrow qualifier for zone-owned values |
| `const` | Const qualifier |
| `volatile` | Volatile qualifier |

### Control Flow Keywords

| Keyword | Purpose |
|---------|---------|
| `if`, `else` | Conditional branching |
| `while` | While loop |
| `for`, `in` | For loops (range and slice iteration) |
| `match` | Pattern matching |
| `return` | Return from function |
| `break` | Break from loop |
| `continue` | Continue to next loop iteration |
| `defer` | Deferred execution (runs at scope exit) |

### Other Keywords

| Keyword | Purpose |
|---------|---------|
| `zone` | Memory allocation zone |
| `as` | Type cast / interface implementation |
| `unsafe` | Unsafe block or expression |
| `import` | Module import (used as `#import`) |
| `type` | Type keyword (used in generic parameters: `$T: type`) |
| `fail` | Fail with error |
| `catch` | Catch errors |
| `yield` | End a `catch` handler with the value to use in place of the call's |

### Literal Keywords

| Keyword | Purpose |
|---------|---------|
| `null` | Null literal (for optionals) |
| `true` | Boolean true |
| `false` | Boolean false |

### Words that are not reserved

Some words only mean something in one position, and everywhere else you can use them as
ordinary names. These are `macro` and `constraint` after `::` (a macro or constraint
declaration) and `where` after a signature. The same goes for `ok` and `err` after `defer.`
and for the names after `#`, such as `extern`, `run` and `quote`. So `macro := 5;` is a valid
declaration.

## Primitive Type Keywords

Fels has a fixed set of primitive types:

| Type | Description |
|------|-------------|
| `bool` | Boolean (`true` or `false`) |
| `void` | Void / unit type |
| `i8` | 8-bit signed integer |
| `i16` | 16-bit signed integer |
| `i32` | 32-bit signed integer |
| `i64` | 64-bit signed integer |
| `isize` | Pointer-sized signed integer |
| `u8` | 8-bit unsigned integer |
| `u16` | 16-bit unsigned integer |
| `u32` | 32-bit unsigned integer |
| `u64` | 64-bit unsigned integer |
| `usize` | Pointer-sized unsigned integer |
| `f32` | 32-bit IEEE 754 float |
| `f64` | 64-bit IEEE 754 float |

> [!NOTE]
> The lexer sees `f32` and `f64` as identifiers, not keywords. They are recognized as
> primitive types later, during semantic analysis.

## Literals

### Integer Literals

You can write integer literals in decimal, hexadecimal or binary. Underscores may go anywhere
in the digits to make long numbers easier to read.

```fels
42            // decimal, type inferred
42i32         // explicit i32 suffix
255u8         // explicit u8 suffix
1000u64       // explicit u64 suffix
0xFF          // hexadecimal
0xff          // hex (case insensitive)
0b1010        // binary
1_000_000     // underscores for readability
0xDEAD_BEEF   // hex with underscores
```

**Base prefixes:**

| Prefix | Base | Digits |
|--------|------|--------|
| *(none)* | 10 (decimal) | `0`–`9` |
| `0x` / `0X` | 16 (hexadecimal) | `0`–`9`, `a`–`f`, `A`–`F` |
| `0b` / `0B` | 2 (binary) | `0`, `1` |

**Type suffixes:**
An integer literal may end with a type suffix that sets its exact type: `i8`, `i16`, `i32`,
`i64`, `isize`, `u8`, `u16`, `u32`, `u64`, `usize`. Without a suffix, the type is inferred
from the context.

### Float Literals

A float literal has a decimal point with digits after it, an exponent (`e` or `E`, an optional
sign, then digits), or both.

```fels
3.14      // f64 by default
1.0       // decimal with fractional part required
0.5       // leading zero
2.5f32    // explicit f32 suffix (f32 and f64 are the only float suffixes)
1e5       // 100000.0: an exponent makes a float, with or without the point
1.5e-3    // 0.0015
6.02E23f32
```

> [!NOTE]
> A bare integer like `1` is never treated as a float on its own. When you mean a
> floating-point value, write `1.0` (or `1e0`).

### String Literals

String literals go in double quotes, and their type is `[]const u8`.

```fels
"hello world"      // simple string
"line1\nline2"     // escape sequences
"tab\there"        // tab character
"quote\"inside"    // escaped double-quote
"backslash\\"      // escaped backslash
```

**Escape sequences:**

| Sequence | Meaning |
|----------|---------|
| `\\` | Backslash |
| `\"` | Double quote |
| `\n` | Newline (LF) |
| `\t` | Horizontal tab |
| `\r` | Carriage return |
| `\'` | Single quote |
| `\0` | Null byte |
| `\xHH` | The byte with hex value `HH`, two hex digits (`\x41` is `A`) |
| `\u{H…}` | The UTF-8 bytes of a Unicode code point, 1 to 6 hex digits (`\u{e9}` is `é`, two bytes) |

A `\u{…}` names a code point up to `10FFFF` that is no surrogate (`D800` to `DFFF`). Any other
backslash in a literal is an error that lists these escapes.

#### Raw Strings

A raw string, `r"…"`, is its bytes as written: a backslash in it is a backslash. It is for
Windows paths and regular expressions. It ends at the next `"` on its line, so it cannot hold a
`"`.

```fels
dir := r"C:\Users\fels\new";      // the same as "C:\\Users\\fels\\new"
number := r"\d+\.\d+";
```

#### Multi-line Strings

A string of several lines goes between `"""` delimiters. Its lines start on the line after the
opening `"""`, and the closing `"""` is on a line of its own. The indentation in front of the
closing `"""` is taken off every line, so the text can be indented with the code around it.
The newline before the closing line is no part of the string.

```fels
usage :: fn() -> []const u8 {
    return """
        usage: tool [options] <file>

          -o <out>   write to "out"
        """;
}
```

That string is `"usage: tool [options] <file>\n\n  -o <out>   write to \"out\""`. A `"` needs
no backslash in it. The escapes are those of any string, and a `{name}` in a `"""` string
passed to `println` is printed as in any other string. A line that does not start with the
closing delimiter's indentation is an error, unless it is blank.

### Character Literals

A character literal is written in single quotes and is **sugar for its integer
code point**. It is an untyped integer literal (like `65`), so it coerces to `u8`,
`i32`, a `rune` and so on from the context. There is no dedicated `char` type.

```fels
'A'        // 65
'.'        // 46
'\n'       // 10  — same escapes as strings
'\\'       // 92
'\''       // 39
'\x41'     // 65  — hex escape
'\u{20ac}' // 8364, the code point of €
```

Because it is an ordinary integer literal, it works anywhere a number does:

```fels
nl: u8 = '\n';
if name[i] == '.' { dots = dots + 1; }   // coerces to u8 in the comparison
```

A bare multi-byte UTF-8 character, such as `'é'`, decodes to its Unicode code point.

### Boolean Literals

```fels
true
false
```

### Null Literal

You use the `null` literal with optional types:

```fels
null  // for optionals
```

## Operators

### Arithmetic Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `+` | Addition | `a + b` |
| `-` | Subtraction | `a - b` |
| `-` | Unary negation (prefix) | `-x` |
| `*` | Multiplication | `a * b` |
| `/` | Division | `a / b` |
| `%` | Remainder (modulo) | `a % b` |

### Comparison Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `==` | Equal | `a == b` |
| `!=` | Not equal | `a != b` |
| `<` | Less than | `a < b` |
| `<=` | Less than or equal | `a <= b` |
| `>` | Greater than | `a > b` |
| `>=` | Greater than or equal | `a >= b` |

> [!NOTE]
> Comparison operators do not chain, so an expression like `a < b < c` is a compile error.
> Write `a < b && b < c` instead.

### Logical Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `&&` | Logical AND (short-circuiting) | `a && b` |
| `\|\|` | Logical OR (short-circuiting) | `a \|\| b` |
| `!` | Logical NOT (prefix) | `!flag` |

### Bitwise Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `&` | Bitwise AND | `a & b` |
| `\|` | Bitwise OR | `a \| b` |
| `^` | Bitwise XOR | `a ^ b` |
| `~` | Bitwise NOT (prefix) | `~mask` |
| `<<` | Left shift | `a << 4` |
| `>>` | Right shift | `a >> 2` |

> [!NOTE]
> Used as a prefix, the `&` symbol is also the **address-of** operator: `&my_var`.

### Assignment Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `=` | Assignment | `x = 10` |
| `+=` | Add and assign | `x += 1` |
| `-=` | Subtract and assign | `x -= 1` |
| `*=` | Multiply and assign | `x *= 2` |
| `/=` | Divide and assign | `x /= 2` |
| `%=` | Remainder and assign | `x %= 3` |
| `&=` | Bitwise AND and assign | `x &= mask` |
| `\|=` | Bitwise OR and assign | `x \|= bits` |
| `^=` | Bitwise XOR and assign | `x ^= bits` |
| `<<=` | Left shift and assign | `x <<= 1` |
| `>>=` | Right shift and assign | `x >>= 1` |

### Special Operators

| Operator | Kind | Description |
|----------|------|-------------|
| `?` | Postfix | Error propagation: returns early on error |
| `??` | Infix | Nil coalesce: gives a default for optional/error values |
| `!!` | Postfix | Force unwrap: panics on `null` or error |
| `as` | Infix | Type cast |
| `&` | Prefix | Address-of |
| `*` | Prefix | Pointer dereference |
| `.` | Infix | Field access / method call |
| `::` | Infix | Constant or declaration binding |
| `:=` | Infix | Variable binding (type-inferred) |
| `->` | — | Return type arrow (in function signatures) |
| `=>` | — | Match arm arrow |
| `..` | Infix | Exclusive range (e.g., `0..10`) |
| `..=` | Infix | Inclusive range (e.g., `0..=9`) |
| `$` | Prefix | Type parameter prefix (e.g., `$T`) |

### Operator Precedence

The table lists operators from **highest** to **lowest** precedence:

| Precedence | Operators | Associativity |
|:----------:|-----------|:-------------:|
| 1 (highest) | `?`, `!!`, `as`, `catch` (postfix), calls, `.` field access, indexing | Left-to-right |
| 2 | `!`, `~`, `&`, `*`, `-` (prefix) | Right-to-left |
| 3 | `*`, `/`, `%`, `*%` | Left-to-right |
| 4 | `+`, `-`, `+%`, `-%` | Left-to-right |
| 5 | `<<`, `>>` | Left-to-right |
| 6 | `&` (bitwise) | Left-to-right |
| 7 | `^` | Left-to-right |
| 8 | `\|` | Left-to-right |
| 9 | `==`, `!=`, `<`, `<=`, `>`, `>=` | Left-to-right |
| 10 | `&&` | Left-to-right |
| 11 (lowest) | `\|\|` | Left-to-right |

The postfix operators bind tighter than everything else, the prefix operators included. So
`-x as u8` is `-(x as u8)`, `*p as i32` is `*(p as i32)`, and `a == b as i64` is
`a == (b as i64)`. Write `(*p) as i32` when you want to cast the value that `*p` loads.

`??` has no single row, because it binds tightly on its left and loosely on its right. Its left
operand is only the operand just before it, so `x + o ?? 0` is `x + (o ?? 0)`. Its right operand
runs to the end of the expression, so `o ?? 0 + 1` is `o ?? (0 + 1)`. A chain groups from the
right, so `a ?? b ?? c` is `a ?? (b ?? c)`.

> [!TIP]
> When in doubt, add parentheses to make the precedence explicit. The code is easier to read
> that way, and you avoid subtle bugs.

## Declarations

### Constants (Compile-Time)

You bind a constant with `::`, and its value must be computable at compile time. By
convention, constant names are written in `UPPER_SNAKE_CASE`:

```fels
MAX :: 100;
PI :: 3.14159;
GREETING :: "hello";
```

The initializer does not have to be a literal. Arithmetic over constants that are already
declared is folded to a value at build time, and constants can build on each other to any
depth:

```fels
W      :: 800;
STRIDE :: W * 3;         // 2400, folded during the build
SIZE   :: STRIDE * 450;  // 1080000, folded through STRIDE
```

A constant has to be declared before the constants that use it.

A string constant is a real `[]const u8` slice, so slice operations work on it directly.
`GREETING.len` is `5`, and `GREETING[0]` is the first byte. (More generally, field and index
access work on any top-level constant, not only on locals.)

You can write a constant's type between the two colons, `NAME : T : value`, much as a
variable has one (`name: T = value`). The value then takes that type. It can be a struct or
an array, which gives you a table the program reads but cannot change:

```fels
LIMIT  : i64      : 5000000000;
ORIGIN : Point    : .{ 0.0, 0.0 };
DIGITS : [10]u8   : .{ 48, 49, 50, 51, 52, 53, 54, 55, 56, 57 };
```

A constant is read-only data. Assigning to it, to one of its fields or to one of its
elements is a compile error. `&ORIGIN` is a `*const Point`, so nothing can write to it
through a pointer either. (A pointer that a constant holds may still point at something
writable.)

A constant can also be declared in a function body. It belongs to its block, from the
declaration to the end of the block. Its value is computed while compiling, as any
constant's is, so it can be the length of an array:

```fels
draw :: fn() {
    CELLS :: 16;
    WIDTH : u16 : CELLS * 8;
    grid: [CELLS]u8 = .{};
    // ...
}
```

Its value can use literals and other constants. It cannot use the function's locals or
parameters, because those have no value until the function runs: for that, use a local
(`width := cells * 8;`). A local in the same block, or in a block inside it, cannot reuse the
constant's name.

Constants can also bind functions, types, and other compile-time constructs:

```fels
add :: fn(a: i32, b: i32) -> i32 {
    return a + b;
}

Point :: struct {
    x: f64,
    y: f64,
}
```

### Mutable globals

A top-level binding written with `: T =` (instead of `::`) is a **mutable
global**. It is exactly the form of a local variable, lifted to module scope. The
operator makes the whole difference. `::` gives an immutable compile-time constant,
and `: T =` (like a local's `=`) gives a variable you can change at runtime. There
is no `mut`, `var` or `static` keyword.

```fels
counter: i64 = 0;          // mutable global, explicit type required
flags:   u32 = 0u32;

bump :: fn() { counter += 1; }   // read + write from anywhere
```

The initializer lives in static storage, like a C `static`. It is data in the image,
laid out by the compiler and placed by the linker, and nothing runs at startup to
put it there. You always write a global's type, while an immutable `::` constant
infers its type from the initializer (or has it written, `NAME : T : value`). Reading
a global loads its current value, and `=` and the compound assignments (`+=`, …) store to it.

#### Static aggregates

A global can hold more than a scalar. Its initializer can be any of the following, nested
to any depth:

| Initializer | Type of the global (or of the field / element) |
|---|---|
| a constant expression: a literal, other constants, `core::sizeof`, a `#run` call | any integer, `f32`/`f64`, `bool`, `[]const u8` (a string) |
| `.{ ... }`, positional or named | a struct |
| `.{ ... }` | an array |
| `.{}` | anything above: a struct with every field defaulted or zero, an array of zeros, an empty slice (a union only this way) |
| the name of a top-level function | a function value: a `fn(...)` closure, or an `extern fn(...)` C pointer |
| `&OTHER`, the address of another top-level global | a pointer `*T` or `?*T` |
| `null` | a pointer or an optional |
| `.variant` or `Enum.variant`, and `Enum.variant(payload)` for one that carries a payload | an enum, or an error of a set (`.eof`, `HttpError.status(404)`) |
| `#run call()` that returns the whole value | a struct, an array, an enum value, a function pointer, or a string, also as one field or element of a literal |

```fels
Point :: struct { x: i32, y: i32 }
Vtbl  :: struct { add: fn(i32, i32) -> i32, id: u32 }
Node  :: struct { v: i32, next: *Node }
Mode  :: enum { fast, slow }
Shape :: enum { circle: f64, square: f64 }

add :: fn(a: i32, b: i32) -> i32 { return a + b; }
dbl :: fn(x: i32) -> i32 { return x * 2; }

ORIGIN:   Point                    = .{ 3, 4 };
PRIMES:   [5]u32                   = .{ 2u32, 3u32, 5u32, 7u32, 11u32 };
VT:       Vtbl                     = .{ add, 7u32 };
HANDLERS: [2]extern fn(i32) -> i32 = .{ dbl, dbl };
A:        Node                     = .{ 1, &B };      // the two refer to each other;
B:        Node                     = .{ 2, &A };      // the order they are written in does not matter
MODE:     Mode                     = .slow;
FIRST:    Shape                    = Shape.circle(1.5);   // a payload, a string one too

use :: fn() -> i32 { return VT.add(1, 2) + HANDLERS[1](4); }   // calls through the tables
```

A literal is read exactly as the same literal would be for a local variable. A named literal
gives every omitted field its default, and it is an error if one of those fields has none. A
positional (or empty) literal that stops short gives the fields after it their defaults, up to
the first field that has none, and zero from there on. So put defaulted fields last, as you
would for trailing default arguments. An array literal is zero past its last element.

The value is checked against the type, and a mistake is a compile error that points at the
offending value:

- a number that does not fit (`300` for a `u8`)
- a string for an integer
- a field that does not exist or is given twice
- a field with no default left out
- too many initializers
- a function that is generic or a lambda
- a pointer to anything but a top-level global

`fels check` reports these like any type error. A value that only the compile-time evaluator
can compute (a `#run`) is checked when the program is built.

A few things are not supported yet:

- an optional that is not a pointer and holds anything but `null`
- the address of an element or a field (`&TABLE[2]`, `&OBJ.id`). Take `&TABLE` or `&OBJ`
  instead.
- a slice of anything but a string

There is no uninitialised form either. Write `.{}` when you want zeros.

You can also let the compiler build a table instead of typing it out. `#run` runs a function
at compile time, and what it returns is the initial value. Like a literal, it is data in the
image:

```fels
CRC: [256]u32 = #run make_crc_table();    // built once, by the compiler, on the comptime VM
ORIGIN :: #run find_origin();             // `::` takes the type of the call
```

Only data can come back. A pointer into compile-time memory, a payload variant or a lambda is
refused, and the error names the place in the value that is wrong. See
[09_comptime](09_comptime.md#data-at-compile-time) for more.

Code that runs at compile time (`#run`, `#assert`) can read static data. It sees a global's
*initial value*, whether that is a struct, an array, an enum value or a function pointer. It can
index that value, take a field, call through it and take the address of an element. It cannot
change it, though. A write is a compile error, because the image is what runs and a write would
not be in it. Two kinds of global cannot be read yet: one that holds the address of another
global, and one that a `#run` computes. Reading either of them stops that `#run` and names the
global.

The function-pointer forms differ in what they hold. A `fn(...)` *field of a struct* and an
`extern fn(...)` are both the bare code address. That is what a C structure of function pointers
holds, so a `Vtbl` like the one above has the layout a C header gives it. A plain `fn(...)`
global is a closure `{ code, environment }`, and when it is stored statically it is the
function with no environment. You call either one where it stands: `F(x)`, `VT.add(1, 2)`,
`HANDLERS[i](x)`.

An address stored in a global is a number that the linker fixes. An executable linked by
`felsld` is always loaded at its own base address, and it holds the final value. A DLL, and an
executable linked by LLD (which randomizes the base address), carries a base-relocation table
that the loader applies. That way the stored addresses follow the image wherever it lands. For
this reason, `felsld` hands any DLL that holds an address to LLD.

Such a global is **exported** like a function, with `#export`. See
[11_c_interop](11_c_interop.md#exporting-data) for the details.

### Variables (Inferred Type)

You declare a variable with `:=`, and its type is inferred from the right-hand side:

```fels
x := 42;          // inferred as integer
name := "Fels";     // inferred as []const u8
flag := true;     // inferred as bool
```

### Variables (Explicit Type)

When you want to state the type yourself, use the `: Type =` syntax:

```fels
count: i32 = 0;
data: [4]u8 = .{ 1u8, 2u8, 3u8, 4u8 };
buffer: [256]u8 = .{};
```

> [!TIP]
> Prefer `:=` with type inference when the type is obvious from the context. Write the type
> out when the inferred one would be ambiguous, or when you need a specific numeric width.

## Punctuation Reference

| Symbol | Usage |
|--------|-------|
| `;` | Statement terminator, required after every statement |
| `,` | Separator in lists (parameters, fields, arguments) |
| `:` | Type annotation separator |
| `::` | Constant / declaration binding |
| `:=` | Variable binding (type inferred) |
| `( )` | Grouping, function parameters, call arguments |
| `{ }` | Blocks, struct bodies, enum bodies |
| `[ ]` | Array / slice indexing and type syntax |
| `.{ }` | Compound literal (struct, array, or enum initialization) |
| `#` | Directive prefix (`#import`, `#if`, `#run`, attributes) |
| `\|x\|` | Payload capture (in `match` arms and `if` / `while` conditions) |

## Quick Example

To put it all together, here is a small Fels program that uses the core syntax elements:

```fels
#import std.io.{ print, println };

MAX_SIZE :: 1024;

Buffer :: struct {
    data: [MAX_SIZE]u8,
    len: usize,
}

BufferError :: errors {
    overflow,
}

make_buffer :: fn() -> Buffer {
    return .{
        .data = .{},
        .len = 0,
    };
}

append :: fn(buf: *Buffer, byte: u8) -> void ! BufferError {
    if buf.len >= MAX_SIZE {
        fail .overflow;
    }
    buf.data[buf.len] = byte;
    buf.len += 1;
}

main :: fn() -> i32 {
    buf := make_buffer();

    // Fill the buffer with values
    for i in 0..10 {
        append(&buf, i as u8) catch err {
            println("append failed");
            return 1;
        };
    }

    println("buffer has {buf.len} bytes");
    return 0;
}
```
