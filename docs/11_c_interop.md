# 11. C interoperability

Fels talks to C libraries directly. You declare the functions you need with `#extern`, link the
import library, and call them. Structs cross the boundary **by value** with the correct platform
ABI. And because nobody wants to write hundreds of declarations by hand, an automated generator
turns C headers into Fels bindings for you.

## Declaring C functions

`#extern("<lib>", "<symbol>")` binds an external C function. You leave out the body, because it
lives in the C library, and the `<lib>` is pulled into the link automatically.

```fels
#extern("raylib", "InitWindow")
InitWindow :: fn(width: i32, height: i32, title: [*]const u8);

#extern("raylib", "WindowShouldClose")
WindowShouldClose :: fn() -> bool;
```

`#foreign(...)` is an alias for `#extern(...)`. For a library you depend on but don't declare any
functions from directly, use `#system_library("name");`. It is a standalone linking directive and
introduces no symbols.

## C types: `std.c`

`std.c` provides C-ABI type aliases (`c_int`, `c_long`, `c_size_t`, `c_string`, …). They are
sized for 64-bit Windows (LLP64), and they let your signatures read like their C originals:

```fels
#import std.c.{ c_int, c_string };

#extern("kernel32", "lstrlenA")
lstrlenA :: fn(s: c_string) -> c_int;       // int lstrlenA(const char *s)
```

They are [transparent aliases](02_types.md#type-aliases). A `c_int` *is* an `i32`, so values flow
between the two without a cast, and `core::sizeof(c_int)` is 4.

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

These sizes don't change on Linux x86-64, where C `long` is 64 bits, so use `c_longlong` and
`c_ulonglong` for `long` and `unsigned long` there.

`c_char` is the signed `i8`, so a pointer to it does not accept a Fels string (`[*]const u8`).
For `const char*` parameters, use `c_string` instead.

A string literal ends in a NUL that its length leaves out. That makes `"title".ptr` a C string,
and you can pass it as it is. Other text has no NUL after it: a slice of a literal, text read
from a file, or text built at run time. Copy such text into a buffer and add the NUL before you
give it to C.

### Naming a binding

You choose the Fels name of a binding. It may even be the name of a function that the runtime or
another module already declares, such as `CloseHandle`, `GetStdHandle` or `WriteFile`, and your
declaration then shadows it inside your own file. Several bindings can also share one C symbol
with different signatures. Each call is compiled with the signature of the binding it names, so
a `BOOL` can be `i32` in one module and `bool` in another.

```fels
#extern("kernel32", "CloseHandle")
CloseHandle :: fn(handle: usize) -> i32;      // the C header's BOOL
```

### Variadic functions

A C function that takes `...` is declared with `...` after its parameters:

```fels
#extern("c", "printf")
printf :: fn(fmt: [*]const u8, ...) -> i32;

main :: fn() -> i32 {
    count: u8 = 3;
    printf("%s: %d at %.2f\n".ptr, "apples".ptr, count, 0.5);
    return 0;
}
```

A call can pass any number of arguments after the parameters. Each one goes the way a C caller
passes it:

| argument                                          | C receives it as                              |
|---------------------------------------------------|-----------------------------------------------|
| `i8`, `i16`, `u8`, `u16`, `i1`–`i7`, `u1`–`u7`, `bool` | an `int`                                 |
| an integer literal                                | an `int`, or a `long long` if it does not fit |
| `i32`, `u32`, `i64`, `u64`, `isize`, `usize`      | itself                                        |
| `f32`, `f64`, a float literal                     | a `double`                                    |
| a pointer (`*T`, `[*]T`, `?*T`)                   | itself                                        |

Any other argument is an error: a slice, a struct, or a Fels function. Pass a C string as its
`.ptr`. The compiler doesn't read the format string, so its `%` codes have to match these
types: `%d` for an `int`, `%lld` for an `i64`, `%zu` for a `usize`, `%f` for a `double`.

Only an `#extern` function can take `...`. A Fels function takes any number of values as a
slice. You can only call a variadic function. Taking one as a value is an error, because a
Fels function value has a fixed number of parameters.

## Passing structs by value (the raylib pattern)

C UI and graphics libraries pass small aggregates by value everywhere. Declare the struct on the
Fels side so it matches the C layout, and pass it directly. The compiler applies the Win64 C ABI
at the boundary:

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

This matches what a C compiler (clang or MSVC) does, so the bits arrive intact. Win64 does not
treat floating-point *struct members* specially. Only naked `float`/`double` scalar arguments
use XMM registers, so `Vector2` correctly travels as a 64-bit integer. For a runnable round-trip,
see `examples/c_interop/`.

## Struct layout and C unions

Struct fields keep their declaration order at their natural alignment. A struct that mirrors a
C struct therefore has C's size and field offsets. `#packed` removes the padding, like
`#pragma pack(1)`. `#align(N)` works like `alignas(N)`: it raises the struct's alignment and
rounds its size up. That also holds when the struct is a field of another struct or an array
element.

### Checking a layout

`core::sizeof`, `core::align_of` and `core::offset_of` report the layout at compile time. With
`#assert` you can write down an assumption about it, and the build fails when the assumption is
wrong:

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

The numbers in that example are those of `windows.h`, checked with clang against the Windows SDK
headers. Beyond this one struct, the compiler's answers were compared with clang's layout for
`x86_64-pc-windows-msvc`. The test structs mixed `u8`–`u64`, `f64`, `bool`, pointers, arrays,
nesting, `#packed` and `#align`. Slice and `fn` fields were compared with the layout LLVM emits
for them.

Here is what is **guaranteed** on the supported targets (Windows and Linux, x86-64):

| Property | Guarantee |
|---|---|
| Field order | Declaration order, never reordered. |
| Field alignment | Natural: `u8`/`i8`/`bool` 1, `u16`/`i16` 2, `u32`/`i32`/`f32` 4, `u64`/`i64`/`f64`, pointers and `usize` 8. |
| Struct alignment and size | The largest field alignment, and the size is a multiple of it. |
| `#packed` | No padding, alignment 1. It takes no argument, so there is no equivalent of `#pragma pack(2)` or `pack(4)` (`#packed(2)` is an error). Sub-byte fields (`u1`–`u7`) are bit-packed from the lowest bit up. That is not C's bitfield layout, which groups bitfields into units of their declared type, so you match a C bitfield struct with explicit filler fields. |
| `#align(N)` | Alignment at least `N`, size rounded up to a multiple of `N`. |
| `[]T`, `string` | 16 bytes: pointer then length. |
| `extern fn(...)` | A thin 8-byte code pointer (a C function pointer), in a field as anywhere else. A plain `fn(...)` is a 16-byte `{fn, env}` closure, in a field too. |
| `?*T` | An 8-byte nullable pointer. |
| `union` | Every field at offset 0. The size is that of the largest field, rounded up to the strictest field alignment. |

And here is what is **not** guaranteed, and so not offered:

- The layout of an enum, an error set or an `interface` value. A payload enum happens to be a
  4-byte tag followed by a byte array, but that is an implementation detail. `core::align_of`
  and `core::offset_of` reject these types, and a struct that contains one has no `offset_of`
  for the fields after it.
- Opaque types (`Name :: opaque;`) and other incomplete types, which have no size.
- Anything on a 32-bit target. The table assumes 8-byte pointers and 8-byte alignment for
  64-bit integers, which is what Fels's current targets have.

`core::offset_of` takes the field name as a string literal and reports the offset of a top-level
field. For a nested field, add up the offsets: `offset_of(Outer, "inner") +
offset_of(Inner, "x")`.

A C union is a Fels `union` (see [02_types](02_types.md)). Every field sits at offset 0, and the
size is that of the largest field, rounded up to the strictest alignment. That is C's rule too.
Reading a field is `unsafe`, because it reinterprets the bytes, but writing one is not.

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

A payload enum is a *tagged* union, with a tag in front of the payload, so it does not overlay
C's bytes. Use it for Fels's own sum types.

## Exporting data

`#export` makes a function visible to a C host, and it does the same for a global. A C host finds
a plugin's entry point by name, and what it finds is data. CLAP's, for example, is
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

`#export("name")` exports the global under `name`, and a bare `#export` uses the global's own
name. An immutable constant (`#export("limit") LIMIT :: 42;`) is exported too, in read-only
memory. The `extern fn(...)` fields of `PluginEntry` are bare code addresses, so a C declaration
with function pointers of the same signatures has the same layout. You can check that with
`#assert(core::sizeof(...))` and `core::offset_of` (see "Checking a layout").

On Windows the symbol goes into the DLL's export table, where `GetProcAddress` (or Python's
`ctypes.c_int32.in_dll`) finds it. The address is the global's own storage, so the host and the
library see each other's writes. [`examples/dll`](../examples/dll/README.md) is a working
plugin-shaped library, loaded from Python.

A DLL that holds addresses in its data (like the function pointers above) carries a
base-relocation table. It works wherever the loader maps it, and two of them can be loaded into
one process. A C program can also link against the import library that LLD writes beside the
DLL, and declare the data `__declspec(dllimport) extern`. An `int`, an array, a struct of
function pointers and a string all read and write correctly that way, and the library sees the
program's writes. (This was tested with a freestanding C program compiled by clang.) A DLL that
felsld links has no import library, and felsld links only DLLs that hold no address. For those
DLLs, and for any host that prefers it, resolve the export by name.

On Linux the target is a static executable, so there is no shared object to export from. There,
`#export` gives the global a global symbol under its exported name, which a debugger or `nm` can
see.

## COM and the Windows Runtime

A COM interface is a pointer to an object whose first word points to a table of function
pointers, and every method takes the interface pointer first. In Fels that is exactly a struct
with a `*Vtbl` field and a vtable struct of `extern fn(...)` fields, called as
`p.vtbl.method(p, ...)`.

The standard library supplies the shared pieces.
[`std.com`](07_stdlib.md#stdcom--com-and-windows-runtime-types) has `Guid`, `HRESULT`,
`IUnknown` and `IInspectable`, and
[`std.winrt`](07_stdlib.md#stdwinrt--calling-com-and-the-windows-runtime-windows-only) covers
starting COM and the Runtime, creating objects and `HSTRING`. You declare the interfaces you call
yourself. List the vtable in header order and `#assert` its `core::offset_of` values against the
header. To get those values, compile the header with clang and print `offsetof`. An object you
implement is a struct with the vtable pointer first and a static vtable (see "Static aggregates"
in [01_syntax](01_syntax.md)), and the operating system can call back into it.

## Linking

The library named in `#extern`/`#system_library` is resolved at link time, so you point the
linker at it:

- **CLI:** `fels build app.fels -o app.exe --lib-path <dir> [--lib <name>]`
- **build.fels:** `app.link("raylib"); app.lib_path("vendor/raylib/lib");`

Linking a non-system import library currently goes through LLD, because the self-hosted `felsld`
doesn't read `.lib` archives yet. `fels` configures `lld-link` for you.

### Linking the C runtime (`link_libc`)

Fels links with `/NODEFAULTLIB` and its own tiny runtime, and it does **not** pull in the C
runtime. That's fine for pure Fels, but a C library brings its *code* and not the CRT it depends
on. A **static** library (for example a `raylib.lib` built against the CRT) calls
`malloc`/`free`/`calloc`/`realloc` and the compiler's stack and security helpers (`__chkstk`,
`__report_rangecheckfailure`). Linking it without the CRT therefore fails with
`undefined symbol: malloc` and friends.

To fix that, link the C runtime:

- **CLI:** `fels build app.fels --libc` (or `-lc`)
- **build.fels:** `app.link_libc();`

`link_libc` pulls in the UCRT (`ucrt.lib`, for malloc/free/…) and the VC runtime
(`vcruntime.lib`, for `__chkstk` and the security checks). Both search paths are found for you.
The UCRT path is derived from the configured Windows SDK path. The MSVC `lib/x64` directory,
where `vcruntime.lib` lives, is **auto-discovered**: `fels` scans the standard
`…/Microsoft Visual Studio/<year>/<edition>/VC/Tools/MSVC/<ver>/lib/x64` locations and uses the
newest toolset it finds. So you normally don't configure anything. If your toolchain is on a
non-default drive, override the discovery by building `fels` with
`-Dmsvc-lib-path=<…/VC/Tools/MSVC/<ver>/lib/x64>`, or pass `--lib-path <that dir>` on the
command line.

Fels's own functions are **module-private**: they have internal linkage, and the whole program
is one object. So they never clash with the CRT's `exit`/`abort`/etc. when you link libc. One
command then covers the C runtime of a static-raylib build. Its system libraries come on top,
as the note below explains:

```sh
fels build game.fels --libc --lib-path <raylib-lib-dir>
```

(Or call `app.link_libc()` in a build.fels, and the MSVC path is discovered automatically.)

> A static library also needs *its own* system dependencies. Static raylib, for example, also
> wants `gdi32`, `user32`, `winmm`, `shell32`, and `opengl32`, and you add them with
> `app.link("gdi32")` and so on. The **DLL** distribution of a library avoids all of this,
> because the `.dll` already contains its CRT and dependencies. Prefer it when it is available.

### Static or dynamic, chosen automatically

You don't rename or swap library files to switch the link mode, and in the common case you don't
even say which mode you want. **The build peeks inside each `.lib` you link** and reacts to what
it finds. It looks in the artifact's own `lib_path`s *and* in the directory containing
`build.fels`, so a `raylib.lib` sitting next to your build script is detected even with no
`lib_path` call. There are two cases:

- an **import library** (it carries an `__IMPORT_DESCRIPTOR_<dll>` symbol) → the
  build copies the matching `.dll` next to the output exe automatically, and
- a **static archive** → the build links the C runtime automatically.

So this is usually all you write:

```fels
#import std.build.{ Build };

build :: fn(b: Build) {
    game := b.executable("game", "src/main.fels");
    game.link("raylib");
    game.lib_path("vendor/raylib/lib");   // whichever raylib.lib is here decides the mode
    b.default(game);
}
```

If `vendor/raylib/lib/raylib.lib` is the import library, you'll see
`raylib → dynamic (raylib.dll)` and the DLL lands next to the exe. If it's the static archive,
the C runtime is linked for you. The bindings (`#extern("raylib", …)`) never change. Only the
`raylib.lib` on the path does.

#### Explicit overrides

The detection only covers the artifact's own libraries, not system libs. You can always be
explicit instead:

- **`game.static_link()`** / **`game.link_mode(.static)`**: force linking the C runtime (for
  example if you also list the library's system deps yourself).
- **`game.dynamic()`**: force dynamic mode.
- **`game.runtime_file("…/extra.dll")`**: copy an extra DLL that the detector can't infer.
- **`game.link_libc()`**: the low-level "link the C runtime" that `static_link` uses.

#### System dependencies, pulled in automatically

A static C library also needs *its own* system deps (static raylib wants
`opengl32`/`gdi32`/…). You normally **don't list them**. When a static C library is linked, Fels
honors that library's own embedded `/DEFAULTLIB` directives, exactly like a C compiler does, so
its system dependencies flow in automatically:

```fels
#import std.build.{ Build };

build :: fn(b: Build) {
    game := b.executable("game", "src/main.fels");
    game.link("raylib");
    game.lib_path("vendor/raylib/lib-static");   // raylib.lib (static archive)
    b.default(game);                              // opengl32/gdi32/winmm pulled in for you
}
```

Fels keeps a minimal runtime by default. It links `/NODEFAULTLIB` and provides its own tiny
runtime, so a plain Fels program pulls in nothing. The honoring kicks in **only** when a static C
library is involved. Even then, Fels suppresses only the CRT-startup *umbrella* libs
(`libcmt`/`msvcrt`/…), because their `mainCRTStartup` would clash with Fels's entry. The real
system deps (`opengl32`, `gdi32`, …) still get through. The C runtime itself (`malloc`,
`__chkstk`, …) comes from `ucrt`+`vcruntime`, which the static auto-detection already links.

> **Caveat: libraries that don't self-declare their deps.** Honoring only pulls in what the
> `.lib` *records*. A library that uses Win32 APIs without `#pragma comment(lib, …)` won't list
> them, so you still link those yourself. The prebuilt **static raylib** is the classic case. It
> embeds `winmm` but not the GUI/GL libraries glfw uses, so a complete static-raylib build is:
>
> ```fels
> app := b.executable("app", "main.fels");
> app.link("raylib");                 // raylib.lib detected → CRT auto-linked
> app.link("opengl32"); app.link("gdi32"); app.link("user32");
> app.link("shell32"); app.link("winmm");   // raylib's GUI deps it doesn't declare
> b.default(app);
> ```
>
> Run it from the folder that holds `raylib.lib` (or add `app.lib_path("…")`). The **DLL**
> distribution avoids the whole list, because its `.dll` already carries the CRT and these
> dependencies. Prefer it when you can.

**Opting out: `game.no_default_libs()`.** If you'd rather keep the strict, minimal linking and
control every dependency yourself, call `no_default_libs()`. The library's `/DEFAULTLIB`
directives are then ignored, and you list the system deps explicitly:

```fels
game.lib_path("vendor/raylib/lib-static");
game.no_default_libs();
game.link("opengl32"); game.link("gdi32"); game.link("user32");
game.link("winmm"); game.link("shell32");
```

In the default path, a static/dynamic toggle then needs nothing extra:

```fels
if b.option("static") {
    game.lib_path("vendor/raylib/lib-static");   // static archive → CRT + its deps auto
} else {
    game.lib_path("vendor/raylib/lib-dynamic");  // import lib → DLL auto-copied
}
```

#### Forcing static when both libraries exist

You can't make an import library link statically, because it has no code in it, only a pointer
to the DLL. So "forcing static" means **making the linker pick the static archive**, and you
control that by what's on the search path:

- If the static and import `raylib.lib` live in **different folders**, add only the static
  folder to `lib_path`, or list it first, because the first `raylib.lib` found wins. The build
  sees a static archive → static link.
- If the two have **different names** (`raylib.lib` static, `raylibdll.lib` import), choose
  with `link("raylib")` or `link("raylibdll")`. The name picks the file.

To make the intent safe, call **`game.static_link()`**. If the `raylib.lib` actually resolved on
your path turns out to be an *import* library, you get a clear warning
(`requested static linking, but '…/raylib.lib' is an import library — the link will
be DYNAMIC`) instead of silently shipping a dynamic build.

### Cross-platform

That API is deliberately platform-agnostic, so the same `build.fels` calls work for Linux
today and are meant to carry over to macOS. This is how each call maps:

| build.fels | Windows | Linux | macOS (planned) |
|---|---|---|---|
| `link("raylib")` | `raylib.lib` | `-lraylib` → `libraylib.so`/`.a` | `-lraylib` → `libraylib.dylib`/`.a` |
| `link_mode(.dynamic)` | import lib + ship `.dll` | `.so` only in a glibc build, no rpath | `.dylib` + rpath |
| `link_mode(.static)` | archive + CRT | links glibc, as `link_libc()` does | `.a` + libSystem |
| `runtime_file(x)` | copy next to exe | copy next to exe | (rpath) |
| `link_libc()` | ucrt + vcruntime | glibc (`libc.so.6`) | libSystem |

**Fels emits and links Windows and Linux on x86-64.** Windows gets PE through felsld or
`lld-link` with the Win64 ABI. Linux gets ELF through `ld.lld` with the SysV ABI, either static
without libc (`--target linux`, `a.target(.linux)`) or against glibc (`--target linux-gnu`,
`a.target(.linux_gnu)`). For the details, see [the Linux backend](14_linux_elf_backend.md) and
[targets and tiers](18_targets_and_tiers.md). macOS is not there yet. It needs Mach-O linking
(`ld64.lld`), the AArch64 aggregate ABI, and its own runtime and entry. None of that requires
changing a `build.fels`, because the link-mode/`runtime_file`/named-library design above absorbs
it.

## Generating bindings from a C header

`fels bindgen` parses an arbitrary C header with libclang and emits a Fels module:

```sh
fels bindgen raylib.h --lib raylib -o raylib.fels
```

It maps these constructs:

- C functions → `#extern("<lib>", "<name>") pub name :: fn(...) -> ...;`
- C structs   → `pub Name :: struct { ... }`
- C enums     → `pub CONST :: <value>;` (plus a `pub Name :: i32` alias)
- C typedefs  → `pub Name :: <type>;`
- and a leading `#system_library("<lib>")`

Then you use it like any other module:

```fels
#import raylib.*;

main :: fn() -> i32 {
    InitWindow(800, 450, "fels + raylib".ptr);
    // ...
    return 0;
}
```

A few options control it. `--lib <name>` sets the import-library name (the default is the header
stem), and `-o <file>` sets the output path. `-I<dir>` / `-D<sym>` are forwarded to clang, and
anything after `--` is passed to clang verbatim, for example extra `-isystem` paths for libraries
that include system headers. `fels bindgen` requires an LLVM-enabled build (libclang ships in the
same SDK).

It also maps **object-like `#define` constants**. A plain numeric or string macro becomes
`pub NAME :: <value>;`. A compound-literal macro, such as raylib's
`#define RAYWHITE CLITERAL(Color){ 245,245,245,255 }`, becomes a comptime-folded typed constant,
so colors and flags work with no extra effort:

```fels
__lit_RAYWHITE :: fn() -> Color { return .{ 245, 245, 245, 255 }; }
pub RAYWHITE :: #run __lit_RAYWHITE();
```

### Harder constructs

bindgen handles the awkward parts of real headers too:

- **Function pointers / callbacks** become a real Fels function type. It is expanded inline at
  the use site, because Fels has no `Name :: fn(...)` type-alias form:
  `void set_logger(LogCallback)` → `pub set_logger :: fn(cb: extern fn(i32, [*]const u8) -> void);`.
  You can pass a Fels function as the callback, and C will call back into it.
- **Unions** become a Fels `union` with the same fields.
- **Bitfield structs** (and unions with a bitfield) become a size- and alignment-correct
  opaque blob (`#align(A) struct { _bytes: [N]u8 }`). That way by-value passing stays
  ABI-correct, and you read the contents via casts.
- **Opaque / forward-declared types** (`typedef struct Foo Foo;` handles) become
  `pub Foo :: opaque;`, so `*Foo` resolves and the module always compiles.
- **Variadic** functions keep their `...` (see "Variadic functions" above):
  `int log_msg(int level, const char *fmt, ...)` → `pub log_msg :: fn(level: i32, fmt: [*]const u8, ...) -> i32;`.
- `long double` maps to `f64` (they're identical on Win64).

**Still not handled:** function-like / expression `#define` macros (such as
`#define DEG2RAD (PI/180.0)`). If a header is unusually complex, skim the generated bindings
before you rely on them.
