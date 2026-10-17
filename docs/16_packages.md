# Packages

A Fels project lists the packages it uses in `fels.pkg`, which sits next to `build.fels`.
`fels build` fetches whatever is missing, and your program imports a package by its name:

```fels
// fels.pkg
#package mygame "0.1.0";
#license "MIT";

#use raylib from "github.com/raysan5/raylib" version "^5.0"
    may ffi("opengl32", "gdi32", "winmm");
#use mathlib from "../mathlib";
```

```fels
// src/main.fels
#import raylib.core;
#import mathlib;
```

What sets Fels apart is the `may` part. A package's compile-time code (its `#run`, its
`#compiler` hooks) can only reach the host when `fels.pkg` grants it, and the compiler enforces
that. If a new version of a package wants more, the update stops until you grant it.

## fels.pkg

`fels.pkg` is a list of `#` directives, and each one ends with `;`. Comments start with `//`.

| Directive | Meaning |
| --- | --- |
| `#package name "version";` | the package's name and version |
| `#license "MIT";` · `#description "...";` | shown to the people who use it |
| `#use name from "source" [version "range"] [may caps];` | a package this one uses |
| `#needs caps;` | what this package's compile-time code needs (for packages others use) |
| `#root "src";` | where its imports start (default: `src/` if there is one, else the folder) |

**The source** is either a path or a git location. A path starts with `.`, `/` or a drive like
`C:\`. A git location can be `github.com/user/repo`, a full `https://` URL, `git@...` or
`file:///...`.

**The version** of a git package is a range over its version tags, which look like `v1.2.3` or
`1.2.3`:

| Range | Matches |
| --- | --- |
| `^1.4` or `1.4` | `1.4.0` up to, not including, `2.0.0` |
| `^0.3` | `0.3.0` up to `0.4.0` (below 1.0 the minor version is the breaking one) |
| `~1.4` | `1.4.x` |
| `=1.4.2` | only `1.4.2` |
| `*` or no version | the newest version |

A pre-release (`2.0.0-rc.1`) only matches a range that names one. A version that is not a range,
such as `"main"` or a full commit hash, names a branch or a commit. When a repository has no
version tags and `fels.pkg` gives no version, the repository is used at its default branch.

## Capabilities

Today Fels has one capability, `ffi`, which lets compile-time code call into host libraries.
With library names (`ffi("user32")`) it may call only into those, and without them (`ffi`) it
may call into any.

- A package says what it needs with `#needs ffi("user32");` in its own `fels.pkg`.
- You grant it on the `#use` line with `may ffi("user32")`.
- When a package needs something that its `#use` line does not grant, the build stops and tells
  you which line to change:

  ```text
  fels.pkg:4:1: error: `mathlib` 1.2.0 needs ffi("user32") at compile time, which is not granted to it
    To allow it, add `may ffi("user32")` to this #use line.
  ```

- A package can only pass on what it holds. Say your project grants `helpers` the library
  `gdi32`, and `helpers` grants `ffi("user32", "gdi32")` to a package it uses. That package then
  gets `gdi32` only.
- The VM enforces the grant. A `#run` in a package's folder gets that package's capabilities,
  and a `#run` anywhere else gets none (only `build.fels` has host access). A package that calls
  a library it did not declare is stopped when the call happens.

## fels.lock

`fels.lock` records the exact commit and a content hash of every git package:

```fels
#lock raylib from "github.com/raysan5/raylib" version "5.5.0"
    commit "c1ab645ca298a2801097931d1079b10ff7eb9df8" hash "sha256-9f2c...";
```

The commands write this file, so nobody writes a hash by hand. A build takes the locked commit
as long as the range in `fels.pkg` still allows it. That way a new tag upstream does not change
your build until you run `fels update`. Commit `fels.lock` along with `fels.pkg`.

The hash covers every file of the package, as the sorted paths and their bytes. It is the same
on every machine, because the checkout ignores git's line ending settings. The hash is checked
when a package is fetched and by `fels fetch --verify`, and a mismatch stops the build.

## Commands

```text
fels add <name> <source> [version] [--may <caps>]   add a #use line and fetch the package
fels fetch [--verify]                                 fetch what fels.pkg uses; check the hashes
fels update [name...]                                 newest versions fels.pkg allows, into fels.lock
fels remove <name...>                                 take packages out of fels.pkg and fels.lock
fels why <name>                                       where a package comes from, who uses it, what it may do
fels vendor                                           copy the git packages into vendor/
```

```text
$ fels add raylib github.com/raysan5/raylib ^5.0 --may 'ffi("opengl32")'
  fetching raylib 5.5.0
added raylib 5.5.0
```

`fels add` creates `fels.pkg` when there is none, and it leaves the file as it was when the
package cannot be used. Without a version, it writes the range of the version it found
(`version "^5.5"` for 5.5.0). A later `fels update` then stays within versions that should not
break the project. `fels build` fetches missing packages by itself, and `fels build --list`
shows the packages with their versions and grants.

```text
$ fels why mathlib
mathlib 1.2.0  github.com/ana/mathlib
  in C:\Users\ana\AppData\Local\fels\pkg\mathlib-ae10245599c0
  used by this project: version "^1.0", may ffi("user32")
  used by helpers: version "~1.2"
  its compile-time code may: ffi("user32")
```

**Builds that must not fetch:** `fels build --offline` takes packages only from `fels.lock` and
the cache, and it never runs git. `fels build --frozen` stops when `fels.lock` would change,
which is what CI wants. `fels vendor` copies every git package into `vendor/<name>`. A build then
uses them from there, without git and without the cache, so a project can carry its packages
along (commit `vendor/`). `fels fetch --verify` also checks the files in `vendor/`.

## How packages are resolved

- **One version of each package.** When two packages use the same one, its version has to fit
  both ranges, or the build stops and tells you which ones disagree. A package used from two
  different places is an error too.
- **The packages a package uses come along**, with their own `fels.pkg`.
- **Imports:** a package's name becomes an import root for every artifact of the build.
  `#import mathlib` reads `<root>/mathlib.fels`, and `#import mathlib.ops` reads
  `<root>/ops.fels`. `a.add_module(name, dir)` in `build.fels` can point a name somewhere else.
- **The project's own name** is an import root too. A library with `#package mathx` imports
  itself the way its users do, so its examples and tests can say `#import mathx;`. This works in
  `fels build`, `fels test` and the editor. A `#use` with the project's own name is an error.
- **The cache:** git packages live in `%LOCALAPPDATA%\fels\pkg` on Windows and in
  `~/.cache/fels/pkg` elsewhere. There is one folder per package and commit, without `.git`.
  `FELS_PKG_DIR` sets another folder. Fetching needs `git` on the PATH.

## A package's build.fels

A package is its Fels sources. When it also has a `build.fels`, `fels build` runs that script
for the project that uses the package. It runs with the capabilities that `fels.pkg` grants the
package, not with the host access the project's own `build.fels` has. Its artifacts and steps
are not built there. What counts is what it provides to every artifact of the project, and to
the test programs of `fels test`:

```fels
// the build.fels of a package that wraps a C library
build :: fn(b: Build) {
    b.provide_lib_path("lib/windows");               // where raylib.lib is
    b.provide_link("winmm");                         // what the library itself needs
    b.provide_runtime_file("lib/windows/raylib.dll"); // copied next to the users' programs
}
```

## In the editor

The language server reads `fels.pkg` too, so imports of packages resolve in the editor the same
way they do in `fels build`. It never runs git. A package that is in `fels.pkg` but not fetched
yet shows "run `fels fetch`" at its import.

## Not built yet

- A registry or index of package names. Today you use a package by its location.
- More capabilities than `ffi` (reading files, the network, running programs). These arrive
  with the compile-time features that need them.
- Building a package's C sources. A package brings its C libraries prebuilt.
