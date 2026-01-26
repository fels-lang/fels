# Fels

Fels is a systems programming language. It compiles to native code through LLVM. It has no garbage
collector. It brings its own linker, build system, test runner and package manager.

<p align="center">
  <img src="docs/images/waves.png" width="760" alt="A window with two moving waves, drawn by a Fels program">
</p>
<p align="center"><sub>A window with a live chart, in about 40 lines of Fels.
The code is <a href="https://github.com/fels-lang/imgui/blob/main/examples/waves.fels">here</a>.</sub></p>

## Why I made it

I wanted a systems language that stays small and clear. So Fels has:

- memory in zones, freed when a block ends
- errors as values, not exceptions
- code that runs while the program compiles
- one tool for building, testing and packages

Fels is young. The language still changes. But I use it for real programs. The biggest one is
Strata, a portfolio app. Writing it showed me a lot of bugs in the compiler. I fixed them.

## Install

Fels runs on 64-bit Windows. It builds programs for Windows and Linux.

1. Download `fels-0.7.0-x86_64-windows.zip` from the
   [latest release](https://github.com/fels-lang/fels/releases/latest).
2. Unpack it. Run `install.ps1` in the folder. It copies Fels to `%LOCALAPPDATA%\fels` and adds
   it to your PATH.
3. Open a new terminal and type `fels version`.

## Your first program

```text
fels new hello
cd hello
fels build run
```

```fels
#import std.io.{ println };

main :: fn() -> i32 {
    println("Hello from Fels");
    return 0;
}
```

## Memory in zones

A zone is an arena. Everything you allocate in it lives until its block ends. Then the zone is
freed in one step. You never call free, and there is no garbage collector.

<p align="center"><img src="docs/images/zones.png" width="560" alt="A function that counts the different bytes of a text, with a table in a zone"></p>

The compiler checks that nothing leaves its zone. This does not compile:

<p align="center"><img src="docs/images/escape-error.png" width="620" alt="The error: zone-owned value from scratch cannot be returned"></p>

## Errors are values

A function that can fail returns `T ! E`. `fail` raises an error. `?` passes it up. `catch`
handles it. An error is a small number. Nothing unwinds the stack.

<p align="center"><img src="docs/images/errors.png" width="660" alt="A parser of digits with an error type, ? and catch"></p>

## Code that runs while it compiles

`#run` calls a function while the program compiles. The result goes into the binary as a
constant. A macro writes code from a template, and the compiler checks it like code you typed.

<p align="center"><img src="docs/images/comptime.png" width="620" alt="fib(30) computed at compile time, and a macro that repeats a block"></p>

Compile time code runs on a virtual machine over the same IR as the native code. So it behaves
the same way. The build file and the tests can run there too.

## One tool

The build file is a Fels program. The compiler runs it at compile time.

<p align="center"><img src="docs/images/build.png" width="560" alt="A build.fels that makes a windowed executable"></p>

- `fels build` builds, `fels build run` runs.
- `fels test` runs every `#test` function.
- `fels add imgui github.com/fels-lang/imgui` adds a package from a Git repository. A lock file
  keeps its version.
- `fels lsp` gives your editor errors, completion, hover and go to definition. There is an extension
  for [Zed](https://github.com/fels-lang/zed-fels) and a
  [tree-sitter grammar](https://github.com/fels-lang/tree-sitter-fels).
- `fels bindgen` turns a C header into Fels bindings.

The linker is mine too. `felsld` is written in Fels and writes Windows executables and DLLs.
It links itself. The release has it built into `fels.exe`, so a link needs no LLD.

## A GUI in Fels

The [imgui package](https://github.com/fels-lang/imgui) brings Dear ImGui with docking and ImPlot
for charts. This is the code of the window at the top:

<p align="center"><img src="docs/images/waves-code.png" width="720" alt="The code of the waves example"></p>

## What I build with it

**Strata** is a desktop app for my investments. It keeps accounts, depots and transactions in
SQLite. It shows performance, risk, allocation and reports, imports bank exports and loads
prices from the web. It is written in Fels with the imgui, sqlite, http and decimal packages.
It is not public yet. The screen is in German for now.

<p align="center"><img src="docs/images/strata.png" width="860" alt="Strata showing the return of a portfolio over time"></p>

The [examples](examples/) folder has more:

- `raytracer` renders spheres with glass and metal into a BMP file
- `mandel` draws a Mandelbrot set, all of it computed at compile time
- `raycaster` walks a 3D maze in the terminal
- `diskscan` is a disk analyzer with a Win32 GUI and threads
- `ecs_game`, `bf` (a Brainfuck interpreter), `dll`, `capability` and more

<p align="center"><img src="docs/images/raytracer.png" width="560" alt="Three spheres of glass, plastic and gold, rendered by the raytracer example"></p>

## Packages

| Package | What it does |
| --- | --- |
| [imgui](https://github.com/fels-lang/imgui) | Dear ImGui with docking, a ready window and ImPlot charts |
| [sqlite](https://github.com/fels-lang/sqlite) | SQLite 3 |
| [http](https://github.com/fels-lang/http) | HTTP and HTTPS through WinHTTP |
| [decimal](https://github.com/fels-lang/decimal) | Exact decimal numbers for money |

The standard library is in [`lib/std`](lib/std/). It has collections, files, processes, threads,
sockets, JSON, CSV, dates and more. [docs/07_stdlib.md](docs/07_stdlib.md) lists it.

## Status

- Windows x64 works end to end.
- Linux x64 works as a target. I build Linux programs from Windows.
- There is no macOS support yet.
- There is no formatter yet.
- The compiler has 661 tests.

## Documentation

The language reference is in [docs](docs/). Good places to start:

- [Overview](docs/00_overview.md)
- [Syntax](docs/01_syntax.md)
- [Memory and zones](docs/05_memory_zones.md)
- [Compile time](docs/09_comptime.md) and [metaprogramming](docs/13_metaprogramming.md)
- [Packages](docs/16_packages.md)

## Building Fels

The compiler is written in Zig 0.16. You need an LLVM with its C headers.

```text
zig build -Dllvm-path=path/to/llvm
zig build test -Dllvm-path=path/to/llvm
```

## License

The compiler is under the [GPL v3](LICENSE-GPLv3.txt). The runtime and the standard library are
under [Apache 2.0](LICENSE-APACHE-2.0.txt). Your programs contain only the second part, so they
are yours. You can license and ship them as you like. [LICENSING.md](LICENSING.md) has the
details.
