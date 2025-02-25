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

### Linking the C runtime (`link_libc`)

K2 links with `/NODEFAULTLIB` and its own tiny runtime — it does **not** pull in
the C runtime. That's fine for pure K2, but a C library brings its *code* and not
the CRT it depends on. A **static** library (e.g. a `raylib.lib` built against the
CRT) calls `malloc`/`free`/`calloc`/`realloc` and the compiler's stack/security
helpers (`__chkstk`, `__report_rangecheckfailure`), so linking it without the CRT
fails with `undefined symbol: malloc` and friends.

Link the C runtime to fix it:

- **CLI:** `k2 build app.k2 --libc` (or `-lc`)
- **build.k2:** `app.link_libc();`

`link_libc` pulls in the UCRT (`ucrt.lib` — malloc/free/…) and the VC runtime
(`vcruntime.lib` — `__chkstk`, security checks). `k2` adds the UCRT search path
automatically (derived from the configured Windows SDK path). For `vcruntime.lib`
you need your MSVC `lib/x64` directory on the search path — either build `k2` with
`-Dmsvc-lib-path=<…/VC/Tools/MSVC/<ver>/lib/x64>`, or pass `--lib-path <that dir>`.

K2's own functions are **module-private** (internal linkage — the whole program is
one object), so they never clash with the CRT's `exit`/`abort`/etc. when you link
libc. A complete static-raylib build is just:

```sh
k2 build game.k2 --libc --lib-path <raylib-lib-dir> --lib-path <msvc-lib-dir>
```

(or `app.link_libc()` in a build.k2 once `k2` is built with `-Dmsvc-lib-path`).

> A static library also needs *its own* system dependencies. Static raylib, for
> example, also wants `gdi32`, `user32`, `winmm`, `shell32`, and `opengl32` —
> add them with `app.link("gdi32")` etc. The **DLL** distribution of a library
> avoids all of this (the `.dll` already contains its CRT and dependencies), so
> prefer it when available.

### Static vs dynamic — automatic

You don't rename or swap library files to switch link mode, and in the common case
you don't even say which mode you want. **The build peeks inside each `.lib` you
link** (from the artifact's own `lib_path`s) and reacts to what it finds:

- an **import library** (it carries an `__IMPORT_DESCRIPTOR_<dll>` symbol) → the
  build copies the matching `.dll` next to the output exe automatically, and
- a **static archive** → the build links the C runtime automatically.

So this is usually all you write:

```k2
build :: fn(b: Build) {
    game := b.executable("game", "src/main.k2");
    game.link("raylib");
    game.lib_path("vendor/raylib/lib");   // whichever raylib.lib is here decides the mode
    b.default(game);
}
```

If `vendor/raylib/lib/raylib.lib` is the import library, you'll see
`raylib → dynamic (raylib.dll)` and the DLL lands next to the exe; if it's the
static archive, the C runtime is linked for you. The bindings (`#extern("raylib", …)`)
never change — only which `raylib.lib` is on the path.

#### Explicit overrides

The detection only covers the artifact's own libraries (not system libs), and you
can always be explicit:

- **`game.static_link()`** / **`game.link_mode(.static)`** — force linking the C
  runtime (e.g. if you also list the library's system deps yourself).
- **`game.dynamic()`** — force dynamic mode.
- **`game.runtime_file("…/extra.dll")`** — copy an extra DLL the detector can't infer.
- **`game.link_libc()`** — the low-level "link the C runtime" used by `static_link`.

A static C library also needs *its own* system deps (static raylib wants
`opengl32`/`gdi32`/…) — add those with `game.link("opengl32")` etc. A toggle:

```k2
if b.option("static") {
    game.lib_path("vendor/raylib/lib-static");
    game.link("opengl32"); game.link("gdi32"); game.link("user32");
    game.link("winmm"); game.link("shell32");
} else {
    game.lib_path("vendor/raylib/lib-dynamic");
}
```

### Cross-platform (roadmap)

That API is deliberately platform-agnostic, so the same `build.k2` will work
unchanged once K2 grows other targets. The intended mapping:

| build.k2 | Windows (today) | Linux (planned) | macOS (planned) |
|---|---|---|---|
| `link("raylib")` | `raylib.lib` | `-lraylib` → `libraylib.so`/`.a` | `-lraylib` → `libraylib.dylib`/`.a` |
| `link_mode(.dynamic)` | import lib + ship `.dll` | `.so` + rpath | `.dylib` + rpath |
| `link_mode(.static)` | archive + CRT | `.a` + libc | `.a` + libSystem |
| `runtime_file(x)` | copy next to exe | (rpath usually suffices) | (rpath) |
| `link_libc()` | ucrt + vcruntime | the system libc/crt | libSystem |

**K2 only emits and links Windows today** (COFF objects, `lld-link`, a Win64-only
ABI in `backend/llvm/abi.zig`, PE output). Reaching Linux/macOS needs, in order:

1. **Target selection** (`-target x86_64-linux-gnu`, …) — LLVM emits ELF/Mach-O
   for free once the triple is chosen.
2. **ELF / Mach-O linking** via `ld.lld` / `ld64.lld` (lld already ships both).
3. **The SysV / AArch64 aggregate ABI** — the largest piece; SysV's by-value
   struct classification (eightbyte SSE/INTEGER) is more involved than Win64's
   size-based rule, so it's a second ABI backend alongside `abi.zig`.
4. Per-platform runtime + entry conventions (`runtime/linux.k2` exists already).

None of that requires changing a `build.k2` — the link-mode/`runtime_file`/named-
library design above absorbs it.

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
