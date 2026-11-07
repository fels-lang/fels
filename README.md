<p align="center">
  <img src="docs/images/logo.svg" width="180" alt="Fels">
</p>
<p align="center">A small systems language for people who like to know what their code does.</p>
<p align="center">
  <a href="https://github.com/fels-lang/fels/releases/latest"><img src="https://img.shields.io/github/v/release/fels-lang/fels?label=release&color=b9532b" alt="latest release"></a>
  <img src="https://img.shields.io/badge/platforms-Windows%20%7C%20Linux-45403b" alt="platforms: Windows, Linux">
  <a href="https://github.com/fels-lang/fels/actions/workflows/ci.yml"><img src="https://github.com/fels-lang/fels/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSING.md"><img src="https://img.shields.io/badge/license-see%20LICENSING.md-45403b" alt="license"></a>
</p>

# The Fels Programming Language

Fels compiles to native code through LLVM and has no garbage collector. Memory lives in zones,
errors are values, and code can run while the program compiles. One tool builds, tests and
fetches packages.

- **Website and docs:** [fels-lang.github.io](https://fels-lang.github.io)
- **Install:** [latest release](https://github.com/fels-lang/fels/releases/latest), then
  [these steps](https://fels-lang.github.io/start/install/)
- **Known issues:** [KNOWN_ISSUES.md](KNOWN_ISSUES.md)
- **Changes:** [CHANGELOG.md](CHANGELOG.md)

If you try Fels, I would love to hear how it went. Open an
[issue](https://github.com/fels-lang/fels/issues) for a bug, a question or an idea.

## License

The compiler is under the [GPL v3](LICENSE-GPLv3.txt). The runtime and the standard library are
under [Apache 2.0](LICENSE-APACHE-2.0.txt), so the programs you build are yours.
[LICENSING.md](LICENSING.md) has the details.
