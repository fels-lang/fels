# 11. C interoperability

Fels talks to C libraries directly: declare the functions you need with `#extern`,
link the import library, and call them. Structs cross the boundary **by value**
with the correct platform ABI, and an automated generator turns C headers into
Fels bindings so you don't hand-write hundreds of declarations.

## Declaring C functions

`#extern("<lib>", "<symbol>")` binds an external C function. The body is omitted
(it lives in the C library), and the `<lib>` is pulled into the link automatically.

```fels
#extern("raylib", "InitWindow")
InitWindow :: fn(width: i32, height: i32, title: [*]const u8);

#extern("raylib", "WindowShouldClose")
WindowShouldClose :: fn() -> bool;
```

`#foreign(...)` is an alias for `#extern(...)`. `#system_library("name");` is a
standalone linking directive (no symbols introduced) for a library you depend on
but don't declare functions from directly.

## C types: `std.c`

`std.c` provides C-ABI type aliases (`c_int`, `c_long`, `c_size_t`, `c_string`, …)
sized for 64-bit Windows (LLP64), so signatures can read like their C originals:

```fels
#import std.c.{ c_int, c_string };

#extern("kernel32", "lstrlenA")
lstrlenA :: fn(s: c_string) -> c_int;       // int lstrlenA(const char *s)
```

They are [transparent aliases](02_types.md#type-aliases): a `c_int` *is* an `i32`, so
values flow between the two with no cast, and `core::sizeof(c_int)` is 4.

| alias                                 | Fels        | C                                    |
|---------------------------------------|---------------|--------------------------------------|
| `c_char`, `c_schar`, `c_uchar`        | `i8`, `i8`, `u8` | `char`, `signed char`, `unsigned char` |
| `c_short`, `c_ushort`                 | `i16`, `u16`  | `short`, `unsigned short`            |
| `c_int`, `c_uint`                     | `i32`, `u32`  | `int`, `unsigned int`                |
| `c_long`, `c_ulong`                   | `i32`, `u32`  | `long`, `unsigned long` (LLP64)      |
| `c_longlong`, `c_ulonglong`           | `i64`, `u64`  | `long long`, `unsigned long long`    |
| `c_size_t`, `c_ssize_t`               | `usize`, `isize` | `size_t`, `ssize_t`/`ptrdiff_t`   |
| `c_intptr`, `c_uintptr`, `c_voidptr`  | `isize`, `usize`, `usize` | `intptr_t`, `uintptr_t`, `void*` |
| `c_float`, `c_double`                 | `f32`, `f64`  | `float`, `double`                    |
| `c_bool`                              | `bool`        | `_Bool`                              |
| `c_string`                            | `[*]const u8` | `const char*` (NUL-terminated)       |

`c_char` is the signed `i8`, so a pointer to it does not accept a Fels string
(`[*]const u8`); use `c_string` for `const char*` parameters.

A string literal ends in a NUL that its length leaves out, so `"title".ptr` is a C string and
can be passed as it is. Other text is not: a slice of a literal, text read from a file or built
at run time has no NUL after it. Copy such text into a buffer and add the NUL before you give
it to C.

### Naming a binding

The Fels name of a binding is yours. It may be the name of a function the runtime or
another module already declares — `CloseHandle`, `GetStdHandle`, `WriteFile` — and your
declaration then shadows it inside your own file. Several bindings can also share one C
symbol with different signatures; each call is compiled with the signature of the
binding it names, so a `BOOL` can be `i32` in one module and `bool` in another.

```fels
#extern("kernel32", "CloseHandle")
CloseHandle :: fn(handle: usize) -> i32;      // the C header's BOOL
```

## Passing structs by value (the raylib pattern)

C UI/graphics libraries pass small aggregates by value everywhere. Declare the
struct on the Fels side to match the C layout and pass it directly — the compiler
applies the Win64 C ABI at the boundary:

```fels
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

## Struct layout and C unions

Struct fields keep their declaration order at their natural alignment, so a struct that
mirrors a C struct has C's size and field offsets. `#packed` removes the padding
(`#pragma pack(1)`), and `#align(N)` is `alignas(N)`: it raises the struct's alignment and
rounds its size up, including when the struct is a field of another struct or an array
element.

### Checking a layout

`core::sizeof`, `core::align_of` and `core::offset_of` report the layout at compile time,
and `#assert` turns an assumption about it into a build error:

```fels
WNDCLASSEXA :: struct {
    cbSize: u32,
    style: u32,
    lpfnWndProc: extern fn(usize, u32, usize, isize) -> isize,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: usize,
    hIcon: usize,
    hCursor: usize,
    hbrBackground: usize,
    lpszMenuName: ?*const u8,
    lpszClassName: ?*const u8,
    hIconSm: usize,
}

#assert(core::sizeof(WNDCLASSEXA) == 80, "WNDCLASSEXA is 80 bytes");
#assert(core::offset_of(WNDCLASSEXA, "lpfnWndProc") == 8, "lpfnWndProc sits at offset 8");
#assert(core::offset_of(WNDCLASSEXA, "lpszClassName") == 64);
```

The numbers in that example are those of `windows.h` (checked with clang against the
Windows SDK headers). More generally, the compiler's answers were compared with clang's
layout for `x86_64-pc-windows-msvc` on structs mixing `u8`–`u64`, `f64`, `bool`, pointers,
arrays, nesting, `#packed` and `#align`; slice and `fn` fields were compared with the layout
LLVM emits for them.

What is **guaranteed**, on the supported targets (Windows and Linux, x86-64):

| Property | Guarantee |
|---|---|
| Field order | Declaration order; never reordered. |
| Field alignment | Natural: `u8`/`i8`/`bool` 1, `u16`/`i16` 2, `u32`/`i32`/`f32` 4, `u64`/`i64`/`f64`, pointers and `usize` 8. |
| Struct alignment and size | The largest field alignment; the size is a multiple of it. |
| `#packed` | No padding; alignment 1. Takes no argument: there is no equivalent of `#pragma pack(2)` or `pack(4)` (`#packed(2)` is an error). Sub-byte fields (`u1`–`u7`) are bit-packed, from the lowest bit up; that is not C's bitfield layout, which groups bitfields into units of their declared type, so a C bitfield struct is matched with explicit filler fields. |
| `#align(N)` | Alignment at least `N`, size rounded up to a multiple of `N`. |
| `[]T`, `string` | 16 bytes: pointer then length. |
| `extern fn(...)` | A thin 8-byte code pointer, a C function pointer, in a field as anywhere. A plain `fn(...)` is a 16-byte `{fn, env}` closure, in a field too. |
| `?*T` | An 8-byte nullable pointer. |
| `union` | Every field at offset 0; the size of the largest field, rounded up to the strictest field alignment. |

What is **not** guaranteed, and so is not offered:

- The layout of an enum, an error set or an `interface` value. A payload enum happens to be
  a 4-byte tag followed by a byte array, but that is an implementation detail;
  `core::align_of` and `core::offset_of` reject these types, and a struct that contains one
  has no `offset_of` for the fields after it.
- Opaque (`Name :: opaque;`) and other incomplete types: they have no size.
- Anything on a 32-bit target: the table assumes 8-byte pointers and 8-byte alignment for
  64-bit integers, which Fels's current targets have.

`core::offset_of` takes the field as a string literal and reports the offset of a
top-level field; for a nested one, add the offsets (`offset_of(Outer, "inner") +
offset_of(Inner, "x")`).

A C union is a Fels `union` (see [02_types](02_types.md)): every field at offset 0, the
size of the largest rounded up to the strictest alignment, which is C's rule. Reading a
field is `unsafe`, as it reinterprets the bytes; writing one is not.

```fels
// typedef union { struct { DWORD LowPart; LONG HighPart; }; LONGLONG QuadPart; } LARGE_INTEGER;
LowHigh      :: struct { low: u32, high: i32 }
LargeInteger :: union { quad: i64, parts: LowHigh }

li: LargeInteger = .{ -2i64 };
low := unsafe (li.parts.low);                 // 4294967294; li.parts.high is -1

// typedef struct { DWORD type; union { MOUSEINPUT mi; KEYBDINPUT ki; HARDWAREINPUT hi; }; } INPUT;
InputData :: union { mi: MouseInput, ki: KeybdInput, hi: HardwareInput }
Input :: struct { kind: u32, u: InputData }   // 40 bytes, the union at offset 8

key: Input = .{ 1, .{ .ki = .{ vk, 0, 0, 0, 0 } } };
```

A payload enum is a *tagged* union, a tag in front of the payload, so it does not overlay
C's bytes; use it for Fels's own sum types.

## Exporting data

`#export` makes a function visible to a C host; it does the same for a global. A C host finds
a plugin's entry point by name, and what it finds is data — CLAP's is
`extern const clap_plugin_entry_t clap_entry;`, a struct of version numbers and function
pointers. A global's initializer is laid out in the image at build time (see "Static
aggregates" in [01_syntax](01_syntax.md)), so the same declaration works here:

```fels
Version :: struct { major: u32, minor: u32, revision: u32 }
PluginEntry :: struct {
    version: Version,
    init:    extern fn(u32) -> u32,
    scale:   extern fn(i32) -> i32,
    deinit:  extern fn(),
}

#export("gab_entry")
ENTRY: PluginEntry = .{ .{ 1u32, 2u32, 0u32 }, plugin_init, plugin_scale, plugin_deinit };

#export("gab_calls")
calls: i32 = 0;            // a plain exported global; the host reads it, the library writes it
```

`#export("name")` exports the global under `name`; a bare `#export` uses its own name. An
immutable constant (`#export("limit") LIMIT :: 42;`) is exported too, in read-only memory. The
`extern fn(...)` fields of `PluginEntry` are bare code addresses, so a C declaration with function
pointers of the same signatures has the same layout; check that with `#assert(core::sizeof(...))`
and `core::offset_of` (see "Checking a layout").

On Windows the symbol goes in the DLL's export table, where `GetProcAddress` (or Python's
`ctypes.c_int32.in_dll`) finds it, and the address is the global's own storage — the host and
the library see each other's writes. [`examples/dll`](../examples/dll/README.md) is a working
plugin-shaped library, loaded from Python. A DLL that holds addresses in its data (the function
pointers above) carries a base-relocation table, so it works wherever the loader maps it; two
of them can be loaded into one process. A C program can also link against the import library
LLD writes beside the DLL and declare the data `__declspec(dllimport) extern` — `int`, an array,
a struct of function pointers and a string all read and write correctly, and the library sees
the program's writes (tested with a freestanding C program compiled by clang). A DLL that felsld
links has no import library, and felsld links only DLLs that hold no address; for those, and for
any host that prefers it, resolve the export by name.

On Linux the target is a static executable, so there is no shared object to export from; `#export`
gives the global a global symbol under its exported name, visible to a debugger or `nm`.

## COM and the Windows Runtime

A COM interface is a pointer to an object whose first word points to a table of function pointers,
and every method takes the interface pointer first — which is exactly a struct with a `*Vtbl` field
and a vtable struct of `extern fn(...)` fields, called as `p.vtbl.method(p, ...)`. The standard library
supplies the shared pieces — [`std.com`](07_stdlib.md#stdcom--com-and-windows-runtime-types) for
`Guid`, `HRESULT`, `IUnknown` and `IInspectable`, and
[`std.winrt`](07_stdlib.md#stdwinrt--calling-com-and-the-windows-runtime-windows-only) for starting
COM / the Runtime, creating objects and `HSTRING` — and you declare the interfaces you call, listing
the vtable in header order and `#assert`ing its `core::offset_of` values against the header (the
way to get them is to compile the header with clang and print `offsetof`). An object you implement
is a struct with the vtable pointer first and a static vtable (see "Static aggregates" in
[01_syntax](01_syntax.md)), which the operating system can call back.

## Linking

The library named in `#extern`/`#system_library` is resolved at link time. Point
the linker at it:

- **CLI:** `fels build app.fels -o app.exe --lib-path <dir> [--lib <name>]`
- **build.fels:** `app.link("raylib"); app.lib_path("vendor/raylib/lib");`

Linking a non-system import library currently routes through LLD (the self-hosted
`felsld` doesn't read `.lib` archives yet); `fels` configures `lld-link` for you.

### Linking the C runtime (`link_libc`)

Fels links with `/NODEFAULTLIB` and its own tiny runtime — it does **not** pull in
the C runtime. That's fine for pure Fels, but a C library brings its *code* and not
the CRT it depends on. A **static** library (e.g. a `raylib.lib` built against the
CRT) calls `malloc`/`free`/`calloc`/`realloc` and the compiler's stack/security
helpers (`__chkstk`, `__report_rangecheckfailure`), so linking it without the CRT
fails with `undefined symbol: malloc` and friends.

Link the C runtime to fix it:

- **CLI:** `fels build app.fels --libc` (or `-lc`)
- **build.fels:** `app.link_libc();`

`link_libc` pulls in the UCRT (`ucrt.lib` — malloc/free/…) and the VC runtime
(`vcruntime.lib` — `__chkstk`, security checks). Both search paths are found for
you: the UCRT path is derived from the configured Windows SDK path, and the MSVC
`lib/x64` directory (where `vcruntime.lib` lives) is **auto-discovered** — `fels`
scans the standard `…/Microsoft Visual Studio/<year>/<edition>/VC/Tools/MSVC/<ver>/lib/x64`
locations and uses the newest toolset it finds. So you normally don't configure
anything. If your toolchain is on a non-default drive, override the discovery by
building `fels` with `-Dmsvc-lib-path=<…/VC/Tools/MSVC/<ver>/lib/x64>`, or pass
`--lib-path <that dir>` on the command line.

Fels's own functions are **module-private** (internal linkage — the whole program is
one object), so they never clash with the CRT's `exit`/`abort`/etc. when you link
libc. A complete static-raylib build is just:

```sh
fels build game.fels --libc --lib-path <raylib-lib-dir>
```

(or `app.link_libc()` in a build.fels — the MSVC path is discovered automatically).

> A static library also needs *its own* system dependencies. Static raylib, for
> example, also wants `gdi32`, `user32`, `winmm`, `shell32`, and `opengl32` —
> add them with `app.link("gdi32")` etc. The **DLL** distribution of a library
> avoids all of this (the `.dll` already contains its CRT and dependencies), so
> prefer it when available.

### Static vs dynamic — automatic

You don't rename or swap library files to switch link mode, and in the common case
you don't even say which mode you want. **The build peeks inside each `.lib` you
link** (in the artifact's own `lib_path`s *and* the directory containing
`build.fels`, so a `raylib.lib` sitting next to your build script is detected even
with no `lib_path` call) and reacts to what it finds:

- an **import library** (it carries an `__IMPORT_DESCRIPTOR_<dll>` symbol) → the
  build copies the matching `.dll` next to the output exe automatically, and
- a **static archive** → the build links the C runtime automatically.

So this is usually all you write:

```fels
build :: fn(b: Build) {
    game := b.executable("game", "src/main.fels");
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

#### System dependencies — pulled in automatically

A static C library also needs *its own* system deps (static raylib wants
`opengl32`/`gdi32`/…). You normally **don't list them** — when a static C library
is linked, Fels honors that library's own embedded `/DEFAULTLIB` directives, exactly
like a C compiler does, so its system dependencies flow in automatically:

```fels
build :: fn(b: Build) {
    game := b.executable("game", "src/main.fels");
    game.link("raylib");
    game.lib_path("vendor/raylib/lib-static");   // raylib.lib (static archive)
    b.default(game);                              // opengl32/gdi32/winmm pulled in for you
}
```

Fels stays minimal-runtime by default: it links `/NODEFAULTLIB` and provides its own
tiny runtime, so a plain Fels program pulls in nothing. The honoring kicks in **only**
when a static C library is involved — and even then Fels suppresses just the CRT-startup
*umbrella* libs (`libcmt`/`msvcrt`/…), whose `mainCRTStartup` would clash with Fels's
entry, while letting the real system deps (`opengl32`, `gdi32`, …) through. The C
runtime itself (`malloc`, `__chkstk`, …) comes from `ucrt`+`vcruntime`, which the
static auto-detection already links.

> **Caveat — libraries that don't self-declare their deps.** Honoring only pulls
> in what the `.lib` *records*. A library that uses Win32 APIs without
> `#pragma comment(lib, …)` won't list them, so you still link those yourself. The
> prebuilt **static raylib** is the classic case: it embeds `winmm` but not the
> GUI/GL libraries glfw uses, so a complete static-raylib build is:
>
> ```fels
> app := b.executable("app", "main.fels");
> app.link("raylib");                 // raylib.lib detected → CRT auto-linked
> app.link("opengl32"); app.link("gdi32"); app.link("user32");
> app.link("shell32"); app.link("winmm");   // raylib's GUI deps it doesn't declare
> b.default(app);
> ```
>
> Run it from the folder that holds `raylib.lib` (or add `app.lib_path("…")`). The
> **DLL** distribution avoids the whole list — its `.dll` already carries the CRT
> and these dependencies, so prefer it when you can.

**Opting out — `game.no_default_libs()`.** If you'd rather keep the strict, minimal
linking and control every dependency yourself, call `no_default_libs()`; then the
library's `/DEFAULTLIB` directives are ignored and you list system deps explicitly:

```fels
game.lib_path("vendor/raylib/lib-static");
game.no_default_libs();
game.link("opengl32"); game.link("gdi32"); game.link("user32");
game.link("winmm"); game.link("shell32");
```

A static/dynamic toggle then needs nothing extra in the default path:

```fels
if b.option("static") {
    game.lib_path("vendor/raylib/lib-static");   // static archive → CRT + its deps auto
} else {
    game.lib_path("vendor/raylib/lib-dynamic");  // import lib → DLL auto-copied
}
```

#### Forcing static when both libraries exist

You can't make an import library link statically — it has no code in it, only a
pointer to the DLL. So "forcing static" means **making the linker pick the static
archive**, which you control by what's on the search path:

- If the static and import `raylib.lib` live in **different folders**, only add the
  static folder to `lib_path` (or list it first — the first `raylib.lib` found
  wins). The build sees a static archive → static link.
- If the two have **different names** (`raylib.lib` static, `raylibdll.lib`
  import), just `link("raylib")` vs `link("raylibdll")` — the name picks the file.

To make the intent safe, call **`game.static_link()`**: if the `raylib.lib` actually
resolved on your path turns out to be an *import* library, you get a clear warning
(`requested static linking, but '…/raylib.lib' is an import library — the link will
be DYNAMIC`) instead of silently shipping a dynamic build.

### Cross-platform

That API is deliberately platform-agnostic, so the same `build.fels` will work
unchanged once Fels grows other targets. The intended mapping:

| build.fels | Windows (today) | Linux (planned) | macOS (planned) |
|---|---|---|---|
| `link("raylib")` | `raylib.lib` | `-lraylib` → `libraylib.so`/`.a` | `-lraylib` → `libraylib.dylib`/`.a` |
| `link_mode(.dynamic)` | import lib + ship `.dll` | `.so` + rpath | `.dylib` + rpath |
| `link_mode(.static)` | archive + CRT | `.a` + libc | `.a` + libSystem |
| `runtime_file(x)` | copy next to exe | (rpath usually suffices) | (rpath) |
| `link_libc()` | ucrt + vcruntime | the system libc/crt | libSystem |

**Fels emits and links Windows and Linux on x86-64**: PE through felsld or `lld-link` with
the Win64 ABI, and ELF through `ld.lld` with the SysV ABI, either static without libc
(`--target linux`, `a.target(.linux)`) or against glibc (`--target linux-gnu`,
`a.target(.linux_gnu)`); see [the Linux backend](14_linux_elf_backend.md) and
[targets and tiers](18_targets_and_tiers.md). macOS is not there yet: it needs Mach-O
linking (`ld64.lld`), the AArch64 aggregate ABI and its own runtime and entry. None of
that requires changing a `build.fels` — the link-mode/`runtime_file`/named-library design
above absorbs it.

## Generating bindings from a C header

`fels bindgen` parses an arbitrary C header with libclang and emits a Fels module:

```sh
fels bindgen raylib.h --lib raylib -o raylib.fels
```

It maps:

- C functions → `#extern("<lib>", "<name>") pub name :: fn(...) -> ...;`
- C structs   → `pub Name :: struct { ... }`
- C enums     → `pub CONST :: <value>;` (plus a `pub Name :: i32` alias)
- C typedefs  → `pub Name :: <type>;`
- and a leading `#system_library("<lib>")`

Then use it like any module:

```fels
#import raylib.*;

main :: fn() -> i32 {
    InitWindow(800, 450, "fels + raylib".ptr);
    // ...
    return 0;
}
```

Options: `--lib <name>` sets the import-library name (default: the header stem),
`-o <file>` sets the output path, `-I<dir>` / `-D<sym>` are forwarded to clang,
and anything after `--` is passed to clang verbatim (e.g. extra `-isystem` paths
for libraries that include system headers). `fels bindgen` requires an
LLVM-enabled build (libclang ships in the same SDK).

It also maps **object-like `#define` constants**: a plain numeric/string macro
becomes `pub NAME :: <value>;`, and a compound-literal macro (e.g. raylib's
`#define RAYWHITE CLITERAL(Color){ 245,245,245,255 }`) becomes a comptime-folded
typed constant, so colors and flags Just Work:

```fels
__lit_RAYWHITE :: fn() -> Color { return .{ 245, 245, 245, 255 }; }
pub RAYWHITE :: #run __lit_RAYWHITE();
```

### Harder constructs

bindgen handles the awkward parts of real headers too:

- **Function pointers / callbacks** become a real Fels function type, expanded
  inline at the use site (Fels has no `Name :: fn(...)` type-alias form):
  `void set_logger(LogCallback)` → `pub set_logger :: fn(cb: extern fn(i32, [*]const u8) -> void);`.
  You can pass a Fels function as the callback and C will call back into it.
- **Unions** become a Fels `union` with the same fields.
- **Bitfield structs** (and unions with a bitfield) become a size- and alignment-correct
  opaque blob (`#align(A) struct { _bytes: [N]u8 }`) so by-value passing stays ABI-correct
  (you read the contents via casts).
- **Opaque / forward-declared types** (`typedef struct Foo Foo;` handles) become
  `pub Foo :: opaque;`, so `*Foo` resolves and the module always compiles.
- **Variadic** functions bind their fixed parameters and carry a `// note:` flag
  (the `...` itself isn't representable).
- `long double` maps to `f64` (they're identical on Win64).

**Still not handled:** function-like / expression `#define` macros (e.g.
`#define DEG2RAD (PI/180.0)`), and the variadic `...`. Skim generated bindings
for an unusually complex header before relying on them.
