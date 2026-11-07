<p align="center">
  <img src="docs/images/logo.svg" width="180" alt="Fels">
</p>
<p align="center"><b>As direct as C. Memory in zones the compiler keeps from escaping. Errors you cannot ignore.</b></p>
<p align="center">
  <a href="https://github.com/fels-lang/fels/releases/latest"><img src="https://img.shields.io/github/v/release/fels-lang/fels?label=release&color=b9532b" alt="latest release"></a>
  <img src="https://img.shields.io/badge/platforms-Windows%20%7C%20Linux-45403b" alt="platforms: Windows, Linux">
  <a href="https://github.com/fels-lang/fels/actions/workflows/ci.yml"><img src="https://github.com/fels-lang/fels/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSING.md"><img src="https://img.shields.io/badge/license-see%20LICENSING.md-45403b" alt="license"></a>
  <a href="https://discord.gg/QBV3XgGhDn"><img src="https://img.shields.io/badge/Discord-join-5865F2?logo=discord&logoColor=white" alt="Discord"></a>
</p>

# The Fels Programming Language

Fels is a small systems language for people who like to know what their code does. It compiles
to native code through LLVM, has no garbage collector and no hidden allocations, and keeps the
safety checks on in release builds. Memory lives in zones that are freed when their block ends,
and the compiler refuses code that would let zone memory escape. Errors are values that every
caller has to handle. Code can run while the program compiles. One tool builds, tests and
fetches packages.

<h3 align="center">
  <a href="https://github.com/fels-lang/fels/releases/latest">Download</a> ·
  <a href="https://fels-lang.github.io/start/install/">Install</a> ·
  <a href="https://fels-lang.github.io/start/first-program/">First program</a> ·
  <a href="https://fels-lang.github.io/docs/overview/">Docs</a> ·
  <a href="https://discord.gg/QBV3XgGhDn">Discord</a>
</h3>

## A taste of Fels

```fels
#import std.fs;
#import std.io.{ println };

// Counts the lines of a file. The file's bytes live in `scratch`, so they are
// freed when the block ends; a number may leave the zone, the bytes may not.
count_lines :: fn(path: []const u8) -> usize ! fs::FsError {
    zone scratch: Arena {
        text := fs::read_all(path, &scratch)?;   // `?` hands a read error to the caller
        n: usize = 0;
        for b in text { if b == '\n' { n += 1; } }
        return n;
    }
}

main :: fn() -> i32 {
    n := count_lines("README.md") catch err {
        println("cannot read README.md: {err}");
        return 1;
    };
    println("{n} lines");
    return 0;
}
```

Save it as `main.fels` and run `fels run main.fels`. If `count_lines` tried to `return text`,
the compiler would stop you: the bytes belong to the zone.

Fels is young and still changes. [Strata](https://fels-lang.github.io/start/showcase/), a portfolio
app with a GUI, is written in it, and so is the compiler's own ELF linker.
[Why Fels](https://fels-lang.github.io/start/why/) says what it is for and where it stands.

## Links

- **Website and docs:** [fels-lang.github.io](https://fels-lang.github.io)
- **Community:** [Discord](https://discord.gg/QBV3XgGhDn) for questions, help and showing what you built
- **Editors:** [VS Code and Zed](https://fels-lang.github.io/docs/tooling/) with an LSP
- **Known issues:** [KNOWN_ISSUES.md](KNOWN_ISSUES.md)
- **Changes:** [CHANGELOG.md](CHANGELOG.md)

If you try Fels, I would love to hear how it went. Open an
[issue](https://github.com/fels-lang/fels/issues) for a bug or an idea, or ask on
[Discord](https://discord.gg/QBV3XgGhDn).

## License

The compiler is under the [GPL v3](LICENSE-GPLv3.txt). The runtime and the standard library are
under [Apache 2.0](LICENSE-APACHE-2.0.txt), so the programs you build are yours.
[LICENSING.md](LICENSING.md) has the details.
