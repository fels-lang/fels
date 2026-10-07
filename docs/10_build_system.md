# The Fels Build System (`build.fels`)

In Fels, your build is a Fels program that runs inside the compiler. There are no Makefiles,
no CMake and no second language. The build system sits on top of two pieces the compiler
already has: the comptime VM that executes the compiler's IR, and the `#compiler` message
loop that inspects and generates the program.

More is planned on the same base. Dependency builds are to run in a capability sandbox, which
is the structural fix for the `build.rs` problem. A content-hashed parallel build graph,
typed-AST codegen, a macOS target and `--watch` on the `felsld` linker are planned as well.

This page is the design. The VM and metaprogramming foundation it builds on is described in
[09_comptime.md](09_comptime.md).

## 1. The file and the execution model

A project keeps a **`build.fels`** at its root, and that file defines a `build` procedure:

```fels
#import std.build.{ Build };

build :: fn(b: Build) {
    exe := b.executable("hello", "src/main.fels");
    b.default(exe);
}
```

When you run `fels build` without a file argument, it finds `./build.fels` and **runs
`build(b)` inside the comptime VM**. That is the same engine behind `#run` and `#compiler`.
There is no separate "build binary": the build script never touches the disk to compile
itself, because it executes as compile-time Fels. While it runs, each builder method records
its call in the compiler's build plan through a `__build_*` intrinsic (see section 9). After
`build(b)` returns, the compiler executes that plan.

This is Jai's model (`#run build()`) without the boilerplate. If you come from Jai,
`#run build();` is also accepted, but the idiom in Fels is a bare `fels build`.

**Four layers:**

| Layer | Audience | Surface |
| --- | --- | --- |
| **0 — default** | `fels build main.fels` | No `build.fels`, CLI flags become options. (Exists today.) |
| **1 — declarative builder** | 90% of projects | `Build`/`Artifact`/`Step` + methods. Pure data. |
| **2 — workspaces & options** | power users | Jai-parity `Workspace`, full `Options` struct, `add_file`/`add_source`/`add_quote`. |
| **3 — compiler intercept** | tooling, codegen | the message loop: `wait_message`, typed `Message`, `set_status`. |

## 2. Layer 1 — the declarative builder

Layer 1 is the everyday API. It is a set of methods on `Build` and `Artifact` (UFCS) that
only populate data, while the compiler performs the effects. That split is what makes the
build deterministic and sandboxable.

```fels
#import std.build.{ Build };

build :: fn(b: Build) {
    // the game
    game := b.executable("game", "src/main.fels");
    game.release();                      // optimized, with the safety checks
    game.link("raylib");                 // raylib.lib
    game.link("user32");
    game.lib_path("vendor/raylib/lib");
    game.output("bin/game.exe");
    game.define("MAX_ENTITIES", "4096"); // comptime const injected into this build

    // a build-time dependency, sandboxed by default
    rl := b.require_path("raylib", "vendor/raylib");
    game.depend(rl);

    // a codegen step that feeds a second artifact (planned: `codegen` and `needs` are not built yet)
    bind := b.codegen("bindings", gen_raylib_bindings);  // fn(*Gen)
    tool := b.executable("packer", "tools/packer.fels");
    tool.needs(bind);                    // ordering + declared inputs

    // run / test steps
    b.run_step("run", game);             // `fels build run [-- args]`
    b.test_dir("test", "tests/");        // `fels build test`

    b.default(game);                     // what bare `fels build` produces
}
```

### Core types

These are the types of `lib/std/build.fels` as built. The five structs are handles that carry
an id, and the state they name lives in the compiler:

```fels
pub Build    :: struct { id: i32 }
pub Artifact :: struct { id: i32 }
pub Step     :: struct { id: i32 }   // its methods: see Steps below
pub Command  :: struct { id: i32 }   // its methods: arg, arg_output, cwd, env
pub Tests    :: struct { id: i32 }   // its methods: see Test steps below

pub Optimize  :: enum { debug, release_safe, release_fast, release_small }
pub Subsystem :: enum { console, windows }
pub LinkMode  :: enum { dynamic, static }
pub Target    :: enum { windows, linux, linux_gnu }
pub Os        :: enum { windows, linux, macos, other }
```

Two more enums are planned, for `use_backend` and the Layer 2 `Options`: `Backend` (`llvm`,
`native`) and `OutputKind` (`executable`, `shared_library`, `static_library`, `object`, `none`).

### Builder methods (selection)

| Method | Effect |
| --- | --- |
| `b.executable(name, root) -> Artifact` | declare an exe |
| `b.shared(name, root)` / `b.static(name, root)` / `b.object(name, root)` | other output kinds |
| `e.release()` · `e.debug()` · `e.release_small()` | optimization shorthands |
| `e.optimize(Optimize.release_fast)` · `e.use_backend(Backend.llvm)` | full optimization / backend (`use_backend` is planned) |
| `e.link(lib)` · `e.lib_path(dir)` | system libraries + search dirs |
| `e.output(path)` | explicit output path |
| `e.define(key, value)` | inject a comptime constant into that build |
| `e.depend(dep)` · `e.needs(step)` | edges in the build graph (`needs` is planned, and `depend` is accepted but ignored for now) |
| `b.run_step(name, exe)` · `b.test_dir(name, dir)` | run/test steps |
| `b.codegen(name, fn)` · `b.custom(name, fn)` | codegen / arbitrary steps (planned: neither is built yet) |
| `b.require_path(name, dir)` · `b.require_git(name, url)` | dependencies |
| `b.default(artifact)` | the default target |
| `b.option(key) -> bool` · `b.option_str(key, default) -> []const u8` | read a `-Dkey` / `-Dkey=value` CLI override |

## 3. Layer 2 — workspaces & build options (Jai parity)

A workspace is an isolated compilation environment, as in Jai. Layer 1 makes one for each
artifact, and in Layer 2 you drive them yourself.

> Planned: Layer 2 is not built yet (see the plan in section 9). Today
> `b.workspace(name)` only names the build. A `#quote { … }` holds statements, so quoting
> a top-level declaration such as `build_id :: 0xC0FFEE;` is part of this plan too.

```fels
build :: fn(b: Build) {
    w := b.workspace("Main program");
    o := w.options();
    o.kind        = .executable;
    o.output_name = "example";
    o.output_path = "./.build";
    o.backend     = .llvm;
    o.optimize    = .debug;
    o.bounds_check    = .on;
    o.null_check      = .on;
    o.dead_code_elim  = .all;
    o.emit_debug_info = true;
    w.set_options(o);

    w.add_file("main.fels");
    // add generated code as text …
    w.add_source("VERSION :: 3;");
    // … or as TYPED AST (validated at the generation site — better than a string)
    w.add_quote(#quote { build_id :: 0xC0FFEE; });
}
```

### `Options` — the full knob set (Jai's `Build_Options`, modernized)

```fels
pub Options :: struct {
    kind:            OutputKind,   // executable | shared_library | static_library | object | none
    output_name:     []const u8,
    output_path:     []const u8,
    backend:         Backend,      // llvm | native
    optimize:        Optimize,

    // safety checks (debug on; release off)  — values: off | on | always/fatal
    bounds_check:    Check,
    cast_check:      Check,
    null_check:      Check,
    overflow_check:  Check,        // Fels's overflow policy lives here

    // codegen / artifacts
    emit_debug_info: bool,         // .pdb / DWARF
    dead_code_elim:  DeadCode,     // none | used | all
    strip:           bool,
    llvm_opt_level:  u8,           // 0..3, overrides `optimize`'s LLVM level

    // inputs
    import_paths:    [MAX_PATHS][]const u8, n_import_paths: usize,

    // target (cross-compile)
    target:          Target,

    // hermetic / reproducible
    frozen:          bool,         // fail if the lockfile would change
    text_output:     bool,         // compiler chatter (Jai's text_output_flags)
}

pub Check    :: enum { off, on, always }
pub DeadCode :: enum { none, used, all }
```

`set_optimization(o, .release_fast)` is sugar that flips the whole safety and codegen block
at once, like Jai's `set_optimization`.

## 4. Layer 3 — the compiler intercept (message loop)

This is the Jai message loop, built on Fels's `#compiler` hook and `core::compiler_decls()`,
which are already implemented. You register interest in a workspace and then pull typed
messages as each phase finishes a unit. That lets you **inspect or alter the program** before
it lowers.

> Planned: the Layer 3 surface below is not built yet (see the plan in section 9).

```fels
build :: fn(b: Build) {
    w := b.workspace("Main");
    w.add_file("main.fels");
    w.intercept();                       // begin

    had_error := false;
    while true {
        m := w.wait_message();
        match m.kind {
            .file_parsed => {},
            .typechecked => {
                // m carries the typed declaration: name, kind, type info,
                // and (Fels extension) the decl's AST for rewriting.
                if !check_decl(b, m) { had_error = true; }
            },
            .phase => {},
            .complete => { break; },
            else => {},
        }
    }

    w.end_intercept();
    if had_error { w.set_status(.failed); }
}
```

```fels
pub MessageKind :: enum { file_parsed, typechecked, phase, complete, error }

pub Message :: struct {
    kind:      MessageKind,
    workspace: u32,
    // typechecked payload (Jai gives you syntax trees + types here; Fels too):
    decl_name: []const u8,
    decl_kind: []const u8,   // "fn" | "struct" | ...  (from core::compiler_decls())
    // …typed AST handle + type_info handle (Layer-3 extensions)
}
```

Today `core::compiler_decls()` already gives a hook the program's declarations (name and
kind) at compile time. Layer 3 generalizes that into the streamed message form and adds the
typed-AST and type-info handles.

## 5. The distinctive parts

> Planned: this section is design. Three parts of it are built so far: the gating of
> comptime FFI, the ordering and up-to-date check described in 5.2, and the target loop of
> 5.4 (see the plan in section 9). `*Caps`, `#provided`, `add_quote`, `--watch` and
> `b.codegen` do not exist yet.

### 5.1 Capability-sandboxed dependency builds — the supply-chain fix
In Jai, the build is arbitrary code with full access to the host, and the same is true of
`build.rs`. **Fels hands every build hook a capability set.** A dependency's `build.fels`
receives a `*Caps` that it cannot forge or widen:

```fels
// vendor/raylib/build.fels  — runs sandboxed
build :: fn(b: Build, caps: *Caps) {
    lib := b.static("raylib", "src/raylib.fels");
    lib.optimize(.release_fast);

    caps.read_dir(".");          // ALLOWED — granted its own folder
    // caps.shell("curl ...");   // DENIED at the VM — no ambient OS authority
    b.default(lib);
}
```

The root build grants capabilities explicitly, as in
`b.require_path("raylib", "vendor/raylib").allow(.read_self)`. A dependency that never
received `shell`, `net` or `write` *physically cannot* reach them. The VM's capability table
enforces this, so it does not rest on policy. This is the structural answer to the
build-script supply-chain hole.

### 5.2 Content-hashed, parallel build graph
Steps and artifacts form a DAG. Each step declares its inputs and outputs and is
**content-hashed**, so unchanged steps are skipped and independent steps run in parallel.
Jai's build is largely linear, while the one in Fels is incremental by construction.
`fels build --explain` prints the graph and tells you why each step ran or was cached.

What is built today is smaller. Steps and artifacts run in the order of their edges, and a
cycle is an error. Each artifact keeps an input stamp, so an unchanged one prints "up to
date" (see [Up to date](#up-to-date)), and `--rebuild` builds it anyway. A step runs its
actions every time, and nothing runs in parallel yet. There is no `--explain` or `--watch`
either, and `e.depend(dep)` is accepted but ignored.

### 5.3 Typed-AST codegen + `#provided`
Generated code goes in as **typed AST** (`w.add_quote(#quote { … })`) and is validated at
the generation site. It is not a raw string that would only fail at splice time. The
`#provided NAME;` directive is Fels's typed `#placeholder`. It promises a symbol that the
build will generate, and the type-checker trusts it until the build supplies it.

```fels
// main.fels
#provided GIT_REV: []const u8;       // build will define this
println(GIT_REV);
```

### 5.4 Targets as values → build matrices
`Target` is an ordinary value, so cross-compilation becomes a loop:

```fels
targets: [2]Target = .{ Target.windows, Target.linux };
for t in targets {
    e := b.executable(name_for(t), "src/main.fels");   // one name per target
    e.target(t);
    e.output(out_for(t));
}
```

This loop works today, with `name_for` and `out_for` as functions of your own build.fels.
Each artifact needs its own name, because its up-to-date stamp is kept under that name. A
`.linux_gnu` target also needs `e.sysroot(dir)`, and a macOS target is planned.

### 5.5 `--watch`, hermetic builds, asset pipelines
- **`fels build --watch`** re-runs only the affected steps when a file changes. The
  microsecond-class `felsld` linker makes that loop feel instant.
- **Hermetic/reproducible:** pin the toolchain and record input hashes, and `--frozen`
  fails on lockfile drift.
- **Asset/codegen steps** (shader compile, embed-file, bindings) are first-class graph nodes
  with declared inputs and outputs, so they cache and parallelize too.

### 5.6 Bindings generation, on typed AST
A `b.codegen` step can read C/C++ headers, or introspect Fels natively through
`core::compiler_decls()` and `core::type_info`. From either it emits **typed AST** bindings
into a workspace, which makes it the safer, faster cousin of Jai's `generate_bindings`.

## 6. CLI surface

```text
fels build                  run ./build.fels, build the default artifact
fels build <name>           build a named artifact or step
fels build run [-- args]    build the default exe, then run it
fels build test             build + run the test step
fels build --list           list artifacts and steps
fels build --release        shorthand override (debug → release_safe)
fels build --release-fast   the same, without the safety checks (debug → release_fast)
fels build -Dkey=value      set an option the script reads via b.option(...)
fels build --watch          rebuild affected steps on change (planned)
fels build --explain        print the build graph + cache decisions (planned)
fels build --frozen         fail if the lockfile would change
fels build --offline        use only fels.lock and the package cache, never git
fels build --rebuild        build every artifact, also the ones that are up to date
fels build --prefix <dir>   the install prefix for `fels build install` (default: dist)
fels build -q, --quiet      print no progress: no live tree, no ✓ and up-to-date lines
fels build <file.fels>        direct single-file build (back-compat, today's behavior)
fels run <file.fels> [-- args]  build one file into .fels-cache/run and run it
```

The path without a `build.fels` is the built-in default metaprogram, as in Jai
(`-- meta Build`) with its Default_Metaprogram. All it does is turn flags into `Options`.

## 7. Source locations

For asserts, logging and codegen, the `core::` constants below fold to a literal right where
you write them (see [Builtins](08_attributes_builtins.md#source-location--target-constants)):

| Constant | Meaning |
| --- | --- |
| `core::file` | the current file's path, as the compiler was given it |
| `core::module` | the module's name |
| `core::func` | the enclosing function's name |
| `core::line` | the line it is written on |
| `core::column` | the column |

Compared with Jai, three things are not there yet: the folder of the file (`#filepath`), the
location of a piece of code (`#location(x)`), and the caller's location as a default argument
(`#caller_location`).

## 8. Jai → Fels mapping (and the extensions)

| Jai | Fels |
| --- | --- |
| `build.jai` / `first.jai`, `#run build()` | `build.fels`, bare `fels build` (or `#run build()`) |
| module `Compiler`, `#compiler` proc | `std.build`, `#compiler` hook (built) |
| `compiler_create_workspace()` | `b.workspace(name)` |
| `get_build_options` / `set_build_options` | `w.options()` / `w.set_options(o)` |
| `set_optimization(*o, .OPTIMIZED)` | `set_optimization(o, .release_fast)` |
| `add_build_file` / `add_build_string` | `w.add_file` / `w.add_source` **+ `w.add_quote` (typed)** |
| `#placeholder` | `#provided` (typed) |
| `compiler_begin_intercept` / `wait_for_message` / `end_intercept` | `w.intercept()` / `w.wait_message()` / `w.end_intercept()` |
| `compiler_set_workspace_status(.FAILED)` | `w.set_status(.failed)` |
| `set_build_options_dc(.{do_output=false})` | implicit: the build script never self-compiles to an exe |
| Default_Metaprogram | `fels build` with no `build.fels` |
| `generate_bindings` | `b.codegen` step emitting typed AST |
| — | **capabilities/sandbox, content-hashed parallel graph, `--watch`, target matrix, hermetic/`--frozen`** |

## 9. Implementation plan

Here is what the build system needs, set against what already exists:

| Piece | Status |
| --- | --- |
| Comptime VM that runs IR | ✅ done |
| `#compiler` hook + `core::compiler_decls()` (program introspection) | ✅ done |
| Driver `compileFileWithLlvm` (exe/dll/obj) + `felsld` linker | ✅ done |
| **`fels build` dir-mode**: find `build.fels`, run `build(b)` in the VM | ✅ done |
| **Config capture**: `host_call` opcode → `__build_*` intrinsics → host `BuildPlan` | ✅ done |
| **Plan executor**: per-artifact `compileFileWithLlvm`, wired outputs/libs/opt | ✅ done |
| Layer 1 surface: `executable`/`shared`/`static`/`object`, `link`/`lib_path`/`output`/`optimize`/`define`, `require_*`/`depend`, `run_step`/`test_dir`/`default` | ✅ done |
| CLI: `fels build` / `run` / `<name>` / `--list` / `--release` / `-q` | ✅ done |
| `test_dir` step execution | ✅ done |
| Build order: steps and artifacts run in the order of their edges (`after`, `depends_on`, `link_artifact`), with cycle detection | ✅ done |
| Incremental builds: an input stamp per artifact (settings key + a hash of every file it read), "up to date", `--rebuild` | ✅ done |
| Parallel builds, `--explain`, `--watch` | later |
| `e.depend(dep)` edges (accepted, but ignored for now) | later |
| Capabilities / `*Caps` sandbox + VM capability table | ⏳ slices 1–2 done: comptime FFI is gated in `src/vm/engine.zig`, and the grant is per-library with conservative narrowing. The `*Caps` surface in `build.fels` is open |
| `define` injection: `define`/`define_int`/`define_bool` write a `build_options` module | ✅ done |
| `add_quote` typed codegen / `#provided` | later (extends `#quote`/`#insert`) |
| Layer 2 (`workspace`/`Options`) + Layer 3 (intercept) surface | later |
| Cross-compile targets | ✅ Linux x86-64 (`a.target(.linux)`, `.linux_gnu`), macOS later |

**Execution mechanism (as built):** the compiler does not read the `Build` struct back out
of VM memory. Instead, the builder methods call `__build_*` compiler intrinsics, which lower
(in the VM) to a new `host_call` opcode. The VM's `Vm.host` bridge forwards each call to the
build driver, and the driver records it into a `BuildPlan`. So the config is captured
imperatively while the script runs. That is robust, needs no fragile offset math, and is the
model Jai itself uses. `Build`/`Artifact` are tiny value handles that carry an id, and all
the state lives in the driver.

**Build order from here:** first the rest of the build graph (`e.depend` edges, parallel
builds, `--explain` and `--watch`), then the rest of the capability system, and then the
surface of Layers 2–3. Cross-compiling to Linux x86-64 is done, and macOS comes last.

## 10. Minimal end-to-end (the target for v1)

```fels
// build.fels
#import std.build.{ Build };

build :: fn(b: Build) {
    app := b.executable("app", "src/main.fels");
    app.release();
    app.link("user32");
    b.run_step("run", app);
    b.default(app);
}
```

```text
$ fels build            # → bin/app.exe via felsld
$ fels build run        # → builds, then runs app.exe
$ fels build --release  # → release_safe override
```

## API reference (expanded)

This is the full `std.build` surface. Below, `b` is the `Build` handle and `a` is an
`Artifact`.

**Declare artifacts** (on `Build`): `b.executable(name, root)`, `b.shared(name, root)` (.dll),
`b.static(name, root)` (.lib) and `b.object(name, root)` (.o). All of them return an
`Artifact`.

A static library is an archive of the compiled object. The program that links it sees only
its `#export`ed functions and globals. The runtime it carries stays private, so it does not
clash with the program's own. The libraries that its `#extern` functions come from travel
with it as `/DEFAULTLIB` directives, so the program does not have to name them.

**Optimization** (on `Artifact`): `a.optimize(.debug|.release_safe|.release_fast|.release_small)`,
or one of the shorthands `a.debug()`, `a.release_safe()`, `a.release_fast()`, `a.release()`
(= release_safe) and `a.release_small()`.

Every mode except `release_fast` keeps the runtime safety checks. Index bounds, null
pointers, integer overflow, division by zero and shift amounts are all checked, and each one
stops the program with a message where it fails. `release_safe` is optimized as fully as
`release_fast`. `release_fast` is the opt-out. In it, an index past the end, a null pointer,
a division by zero or a shift past the width is undefined behavior, and overflow wraps. When
you build a single file, you can pass `--release-fast` (`-O2` without the checks) or
`--unchecked` (no checks at any `-O`).

**Linking**: `a.link_artifact(lib)` links a library that this build makes (`b.static` or
`b.shared`). The library is built first, each artifact is built once, and a shared library's
DLL is copied next to the program:

```fels
util := b.static("util", "src/util.fels");
app := b.executable("app", "src/main.fels");
app.link_artifact(util);
```

The other linking calls:

- `a.link(lib)` links a library, with one call per library. `a.system_library(name)` is an
  alias for it.
- `a.lib_path(dir)` adds a folder to search for libraries.
- `a.link_flag(raw)` passes a raw flag straight to the linker.
- `a.link_libc()` links the C runtime, for C libraries built against it.
- `a.link_mode(.dynamic|.static)`, `a.dynamic()` and `a.static_link()` choose how C
  libraries link (`.static` also links the C runtime).
- `a.runtime_file(path)` copies a runtime dependency (e.g. a `.dll`) next to the output.
- `a.no_default_libs()` keeps strict `/NODEFAULTLIB` instead of honoring a static C
  library's own `/DEFAULTLIB` directives.

**Usually you need none of these.** The build inspects each linked `.lib`. For an import
library it copies the DLL automatically. For a static archive it links the C runtime
automatically and pulls in the archive's system deps through its `/DEFAULTLIB` directives.
See [docs/11 → Linking](11_c_interop.md) for the static-vs-dynamic workflow and
cross-platform linking.

**Executable settings**: `a.subsystem(.console|.windows)`, `a.console()`, `a.windowed()`
(GUI, without a console window), `a.entry(symbol)` and `a.stack_size(bytes)`. These force the
LLD path, because the fast felsld linker can't apply them.

**Target**: `a.target(.windows | .linux | .linux_gnu)` builds the artifact for another OS,
and this works from Windows too. `.linux` is a static ELF without libc, `.linux_gnu` links
glibc dynamically, and `a.sysroot(dir)` says where glibc is. A Linux output has no `.exe`.
`a.strip()` leaves the symbol table out of a Linux output (a Windows output has none).
`b.host_os()` returns the OS that `fels build` runs on (`.windows`, `.linux`, `.macos`,
`.other`), so a script can choose per platform. Libraries for Linux are not supported yet,
and the output does not carry debug information (DWARF/CodeView) yet.

**Output**: `a.output(path)` sets an explicit path, and `a.out_dir(dir)` sets a directory and
derives the name. There is also the workspace-wide `b.out_root(dir)`, but a per-artifact
`out_dir` wins over it.

**Metadata**: `a.version(semver)` and `a.description(text)` are shown by `--list` and in the
summary.

**Install**: `fels build install` builds every artifact marked with `a.install()` and copies
it into the install prefix. Programs and DLLs go to `bin/` (with the DLLs copied next to
them), and static and import libraries go to `lib/`. `b.install_file(src, dest)` and
`b.install_dir(src, dest)` add files and folders, with `dest` relative to the prefix.
`b.install_prefix(dir)` sets the prefix (default `dist`, relative to build.fels), and
`fels build install --prefix <dir>` overrides it. If the script names a step or artifact
`install`, that one takes the place of the built-in step.

**Constants for the program**: `a.define(name, text)`, `a.define_int(name, value)` and
`a.define_bool(name, value)` write a `build_options` module that the program imports:

```fels
// build.fels
app.define("GIT_REV", b.option_string("rev", "dev", "the commit"));
app.define_int("MAX_PLAYERS", 8);

// src/main.fels
#import build_options;
limit := build_options::MAX_PLAYERS;
```

`#import build_options` works for every artifact. Without a define, the module is empty.

**Modules**: `a.add_module(name, dir)` maps an import name to a folder. With
`app.add_module("mathlib", "deps/mathlib")`, `#import mathlib.ops` reads
`deps/mathlib/ops.fels`, and a bare `#import mathlib` reads `deps/mathlib/mathlib.fels`.

**Dependencies**: `b.require_path(name, dir)` and `b.require_git(name, url)` return a dep id,
which you pass to `a.depend(dep_id)`. The build accepts that call, but it has no effect yet.

**Workspace**: `b.workspace(name)` names the build, and `b.summary()` prints a summary after
the build.

**Build options** come from the command line (`fels build -Dname` or `-Dname=value`). The
script declares each one at the place where it reads it, with a default and a help text:

| Call | Command line | Returns |
| --- | --- | --- |
| `b.option_bool(name, default, help)` | `-Dname`, `-Dname=true` or `false` (also `yes`/`no`, `on`/`off`, `1`/`0`) | `bool` |
| `b.option_int(name, default, help)` | `-Dname=42`, also `0x`, `0o` and `0b` | `i64` |
| `b.option_string(name, default, help)` | `-Dname=text` | `[]const u8` |
| `b.option_choice(name, "a\|b\|c", default, help)` | `-Dname=b` | `[]const u8`, one of the words |

`b.option(name) -> bool` and `b.option_str(name, default)` are the short forms without help
text. When the same `-D` option is given twice, the last one wins.

`fels build` stops with an error when it gets a `-D` option the script does not declare
(usually a typo) or a value of the wrong kind. It then lists the options the script has:

```text
$ fels build -Dthread=8
fels build: unknown build option -Dthread
build options of this build.fels:
  -Dthreads=<int>              worker threads (default: 4)
  -Dbackend=gl|vulkan|d3d      renderer (default: gl)
```

An option that is read only inside an `if` is declared only when that branch runs, so read
your options at the top of `build`.

**Steps & default**: `b.run_step(name, artifact)`, `b.test_dir(name, dir)`, `b.step(name,
description)`, `b.command(name, program)`, `b.default(artifact)` and `b.default_step(step)`.
See [Steps](#steps) below.

For a build.fels that uses most of these, see `examples/build_showcase/`.

## Steps

A step is a named piece of work. `fels build <name>` first builds the artifacts the step
depends on and runs the steps it comes after, and then it runs the step's actions in order.
Paths are relative to build.fels.

```fels
gen_tool := b.executable("gen", "tools/gen.fels");

gen := b.step("gen", "generate the tables");
gen.run(gen_tool);                     // build the tool, then run it
game := b.executable("game", "src/main.fels");
game.after(gen);                       // the tables exist before the game compiles

assets := b.step("assets", "copy the assets next to the game");
assets.copy_dir("assets", "bin/assets");
assets.copy_file("config.ini", "bin/config.ini");
assets.write_file("bin/version.txt", "1.0");
assets.print("assets copied");

clean := b.step("clean", "remove the output");
clean.remove("bin");

all := b.step("all", "the game and its assets");
all.depends_on(game);
all.after(assets);
b.default_step(all);                   // a bare `fels build` runs `all`
```

| On a `Step` | Does |
| --- | --- |
| `s.depends_on(artifact)` | build the artifact first |
| `s.after(other)` | run the other step first |
| `s.command(program) -> Command` | run a program: a name found on PATH, or a path relative to build.fels |
| `s.run(artifact) -> Command` | build an artifact of this build and run it |
| `s.copy_file(src, dest)` · `s.copy_dir(src, dest)` | copy a file, or a folder with everything in it |
| `s.write_file(path, text)` | write a file, creating its folders |
| `s.remove(path)` | remove a file or a folder |
| `s.print(text)` | print a line when the step runs (`print` from `std.io` prints while the script runs) |

A `Command` takes `c.arg(text)`, `c.arg_output(artifact)` (the absolute path of an artifact's
output), `c.cwd(dir)` (default: build.fels's folder) and `c.env(key, value)` (added to the
environment that `fels build` runs in). When a command exits with a code other than 0, the
build stops. `b.command(name, program)` is a step with one command.

`a.after(step)` runs the step before the artifact is built, which is what you want for
generated code. In one `fels build`, each artifact is built once and each step runs once. A
step that comes after itself is an error.

`b.run_step(name, artifact)` returns its `Command` too, so you can give a run arguments, a
working directory and environment variables. It also gets the arguments after `--`
(`fels build run -- --verbose`). An exit code other than 0 is reported, but it does not fail
the build.

## Test steps

`b.test_dir(name, dir)` declares a test step. When you run it, it compiles and runs every
`*.fels` file directly under `dir` as a standalone program, and each one **passes when it
exits 0**:

```sh
fels build test          # the step named "test"
```

```text
tests/
  ✓ lexer_test.fels  212ms
  ✓ parser_test.fels  240ms
  ✗ sema_test.fels: exited with 1

Test Summary: 2 passed, 1 failed · 0.71s
```

A test is a `.fels` file with a `main :: fn() -> i32` that returns `0` on success and
non-zero on failure. If any test fails, the step itself fails (non-zero `fels build` exit),
so it drops cleanly into CI. A failing test shows its exit code and what it printed. Tests
can import the project's packages.

`b.test_dir` returns a `Tests` handle:

| Call | Does |
| --- | --- |
| `t.recursive()` | also the tests in the folders below |
| `t.filter(text)` | only the test files whose path contains `text` |
| `t.optimize(.release_fast)` | the optimization level (default `.debug`; every mode but `.release_fast` keeps the checks) |
| `t.link(lib)` | a library the tests link |
| `t.link_artifact(lib)` | a library this build makes, built before the tests run |

`fels build test -- parser` runs only the test files whose path contains `parser`.

## Up to date

`fels build` does not build an artifact again when nothing it depends on has changed. For
each artifact it keeps a stamp in `.fels-cache/build/<name>/inputs`. The stamp holds a hash
of the artifact's settings, the import roots, the capabilities of the packages and the
compiler itself. It also holds the hash of every file the last build read: the sources and
what they import, `std`, `build_options` and the libraries it linked. When all of them match
and the output exists, the artifact is "up to date". A changed option reaches the program
through `build_options`, so the program is built again.

```text
$ fels build
· mathutil up to date
✓ app → bin/app.exe  412 KB  1.84s  (check 210ms · lower 520ms · optimise 12ms · codegen 60ms · emit 1.02s · link 9ms)
  because src/main.fels changed
· plugin up to date

Build Summary: 1 built, 2 up to date · 1.91s
```

`fels build --rebuild` builds every artifact anyway. Compile-time code that reads other
files through `#extern` calls is not tracked, so rebuild after you change such a file.

## What a build prints

On a terminal, `fels build` shows what it is doing as a live tree, as `zig build` does: the
artifact being built and the stage it is in (checking, lowering, optimising, generating code,
emitting the object, linking). Inside a stage it counts the functions and names the one it is
at, and it shows a `#run` while it runs, with its file and line:

```text
[1] fels build
└─ [1/6] app
   └─ [1414/2168] lowering
      └─ menu (app.fels)
         ├─ #run (app.fels:1153)
         └─ preparing the comptime VM
```

The tree goes away when the build is done. What stays is one line for each artifact: `✓` with
its output, its size, the time it took and the time of each stage, `·` when it was up to date,
or `✗` when it does not compile (the errors are printed above it). Under a `✓` a dim line says
why the artifact was built again: a file that changed (and how many more did), its settings,
another fels, or an output that was missing. A first build and `--rebuild` have no such line.
A build of more than one artifact ends with a `Build Summary` line. Before a `run` step starts
the program, its line shows with `▸`.

When the output goes to a file or a pipe there is no tree and no color, and the lines are the
same. `NO_COLOR` turns the colors off on a terminal too, and `FELS_COLOR` turns them on when
the output is piped. `-q` prints only errors.

## Printing from build.fels

`print` and `println` from `std.io` work in a build script and in `#run` code. At compile
time their output goes to the compiler's output, next to `fels build`'s own lines.

## Inspecting the plan

`fels build --list` prints the resolved plan without building anything. It shows every
artifact with its kind, optimization level, version, install flag and linked libraries.
After the artifacts come the declared steps with their targets, and then the build options:

```text
workspace: my-app
artifacts:
  game             executable     release-fast (default) v2.1.0 [install]  links: raylib user32
    the main game binary
  util             static_library debug
steps:
  run              run        game
  test             test_dir   tests
options:
  -Dfast                       build with optimizations (default: false)
  -Dthreads=<int>              worker threads (default: 4)
```
