# 11. C interoperability

K2 talks to C libraries directly: declare the functions you need with `#extern`,
link the import library, and call them. Structs cross the boundary **by value**
with the correct platform ABI, and an automated generator turns C headers into
K2 bindings so you don't hand-write hundreds of declarations.

## Declaring C functions

`#extern("<lib>", "<symbol>")` binds an external C function. The body is omitted
(it lives in the C library), and the `<lib>` is pulled into the link automatically.

```k2
#extern("raylib", "InitWindow")
InitWindow :: fn(width: i32, height: i32, title: [*]const u8);

#extern("raylib", "WindowShouldClose")
WindowShouldClose :: fn() -> bool;
```

`#foreign(...)` is an alias for `#extern(...)`. `#system_library("name");` is a
standalone linking directive (no symbols introduced) for a library you depend on
but don't declare functions from directly.

`std.c` provides C-ABI type aliases (`c_int`, `c_long`, `c_size_t`, `c_string`, …)
sized for 64-bit Windows (LLP64), so signatures can read like their C originals.

## Passing structs by value (the raylib pattern)

C UI/graphics libraries pass small aggregates by value everywhere. Declare the
struct on the K2 side to match the C layout and pass it directly — the compiler
applies the Win64 C ABI at the boundary:

```k2
Color   :: struct { r: u8, g: u8, b: u8, a: u8 }   // 4 bytes
Vector2 :: struct { x: f32, y: f32 }               // 8 bytes
Rect    :: struct { x: f32, y: f32, w: f32, h: f32 } // 16 bytes

#extern("raylib", "DrawCircleV")
DrawCircleV :: fn(center: Vector2, radius: f32, color: Color);
```

| aggregate size | how it is passed/returned                  |
|----------------|--------------------------------------------|
| 1, 2, 4, 8 B   | coerced into an integer register           |
| any other size | by pointer (`byval` argument / `sret` return) |

This matches what a C compiler (clang/MSVC) does, so the bits arrive intact.
Floating-point *struct members* are not special-cased on Win64 (only naked
`float`/`double` scalar arguments use XMM), so `Vector2` correctly travels as a
64-bit integer. See `examples/c_interop/` for a runnable round-trip.

## Linking

The library named in `#extern`/`#system_library` is resolved at link time. Point
the linker at it:

- **CLI:** `k2 build app.k2 -o app.exe --lib-path <dir> [--lib <name>]`
- **build.k2:** `app.link("raylib"); app.lib_path("vendor/raylib/lib");`

Linking a non-system import library currently routes through LLD (the self-hosted
`k2lnk` doesn't read `.lib` archives yet); `k2` configures `lld-link` for you.

## Generating bindings from a C header

`k2 bindgen` parses an arbitrary C header with libclang and emits a K2 module:

```sh
k2 bindgen raylib.h --lib raylib -o raylib.k2
```

It maps:

- C functions → `#extern("<lib>", "<name>") pub name :: fn(...) -> ...;`
- C structs   → `pub Name :: struct { ... }`
- C enums     → `pub CONST :: <value>;` (plus a `pub Name :: i32` alias)
- C typedefs  → `pub Name :: <type>;`
- and a leading `#system_library("<lib>")`

Then use it like any module:

```k2
#import raylib.*;

main :: fn() -> i32 {
    InitWindow(800, 450, "k2 + raylib".ptr);
    // ...
    return 0;
}
```

Options: `--lib <name>` sets the import-library name (default: the header stem),
`-o <file>` sets the output path, `-I<dir>` / `-D<sym>` are forwarded to clang,
and anything after `--` is passed to clang verbatim (e.g. extra `-isystem` paths
for libraries that include system headers). `k2 bindgen` requires an
LLVM-enabled build (libclang ships in the same SDK).

It also maps **object-like `#define` constants**: a plain numeric/string macro
becomes `pub NAME :: <value>;`, and a compound-literal macro (e.g. raylib's
`#define RAYWHITE CLITERAL(Color){ 245,245,245,255 }`) becomes a comptime-folded
typed constant, so colors and flags Just Work:

```k2
__lit_RAYWHITE :: fn() -> Color { return .{ 245, 245, 245, 255 }; }
pub RAYWHITE :: #run __lit_RAYWHITE();
```

### Harder constructs

bindgen handles the awkward parts of real headers too:

- **Function pointers / callbacks** become a real K2 function type, expanded
  inline at the use site (K2 has no `Name :: fn(...)` type-alias form):
  `void set_logger(LogCallback)` → `pub set_logger :: fn(cb: fn(i32, [*]const u8) -> void);`.
  You can pass a K2 function as the callback and C will call back into it.
- **Unions** and **bitfield structs** become a size- and alignment-correct opaque
  blob (`#align(A) struct { _bytes: [N]u8 }`) so by-value passing stays ABI-correct
  (you read the contents via casts).
- **Opaque / forward-declared types** (`typedef struct Foo Foo;` handles) become
  `pub Foo :: opaque;`, so `*Foo` resolves and the module always compiles.
- **Variadic** functions bind their fixed parameters and carry a `// note:` flag
  (the `...` itself isn't representable).
- `long double` maps to `f64` (they're identical on Win64).

**Still not handled:** function-like / expression `#define` macros (e.g.
`#define DEG2RAD (PI/180.0)`), and the variadic `...`. Skim generated bindings
for an unusually complex header before relying on them.
