# The K2 Build System (`build.k2`)

> **Thesis.** Your build *is* a K2 program that runs inside the compiler. No
> Makefiles, no CMake, no second language. K2 already has the two pieces Jai's
> build system is made of — a **comptime VM** that executes the compiler's own IR
> and a **`#compiler` message loop** that can inspect and generate the program —
> so the build system is the ergonomic surface on top of them.
>
> Where Jai stops, K2 keeps going: **capability-sandboxed dependency builds**
> (the structural fix for the `build.rs` supply-chain problem), a **content-
> hashed parallel build graph**, **typed-AST codegen** instead of string
> splicing, **targets as values** for cross-compile matrices, and **`--watch`**
> backed by the fast `k2lnk` linker.

This document is the design. See [09_comptime_vm_roadmap.md](09_comptime_vm_roadmap.md)
for the VM/metaprogramming foundation it sits on.

---

## 1. The file and the execution model

A project has a **`build.k2`** at its root. It defines a `build` procedure:

```k2
#import std.build;

build :: fn(b: *Build) {
    exe := b.executable("hello", "src/main.k2");
    b.default(exe);
}
```

`k2 build` (no file argument) finds `./build.k2` and **runs `build(&b)` inside the
comptime VM** — the same engine behind `#run` and `#compiler`. There is no
separate "build binary": the build script never touches the disk to compile
itself; it executes as compile-time K2. After it returns, the compiler reads the
populated `Build` value back out of VM memory and executes the plan.

This is Jai's model (`#run build()`), minus the boilerplate. For Jai familiarity
`#run build();` is also accepted, but bare `k2 build` is the idiom.

**Three layers, increasing power:**

| Layer | Audience | Surface |
| --- | --- | --- |
| **0 — default** | `k2 build main.k2` | No `build.k2`; CLI flags → options. (Exists today.) |
| **1 — declarative builder** | 90% of projects | `Build`/`Artifact`/`Step` + methods. Pure data. |
| **2 — workspaces & options** | power users | Jai-parity `Workspace`, full `Options` struct, `add_file`/`add_source`/`add_quote`. |
| **3 — compiler intercept** | tooling, codegen | the message loop: `wait_message`, typed `Message`, `set_status`. |

---

## 2. Layer 1 — the declarative builder

The everyday API. Everything is a method on `*Build` or `*Artifact` (UFCS), so it
reads as a fluent pipeline. Methods only *populate data* — the compiler performs
the effects — which keeps the build deterministic and sandboxable.

```k2
#import std.build;

build :: fn(b: *Build) {
    // ── the game ──────────────────────────────────────────────
    game := b.executable("game", "src/main.k2");
    game.release();                      // or .optimize(.release_fast)
    game.link("raylib");                 // raylib.lib
    game.link("user32");
    game.lib_path("vendor/raylib/lib");
    game.output("bin/game.exe");
    game.define("MAX_ENTITIES", "4096"); // comptime const injected into this build

    // ── a build-time dependency, sandboxed by default ─────────
    rl := b.require_path("raylib", "vendor/raylib");
    game.depend(rl);

    // ── a codegen step that feeds a second artifact ───────────
    bind := b.codegen("bindings", gen_raylib_bindings);  // fn(*Gen)
    tool := b.executable("packer", "tools/packer.k2");
    tool.needs(bind);                    // ordering + declared inputs

    // ── run / test steps ──────────────────────────────────────
    b.run_step("run", game);             // `k2 build run [-- args]`
    b.test_dir("test", "tests/");        // `k2 build test`

    b.default(game);                     // what bare `k2 build` produces
}
```

### Core types

```k2
pub Optimize   :: enum { debug, release_safe, release_fast, release_small }
pub OutputKind :: enum { executable, shared_library, static_library, object, none }
pub Backend    :: enum { llvm, native }   // native = k2's own backend (future)

pub Artifact :: struct {
    name:    []const u8,
    root:    []const u8,        // entry .k2 source
    kind:    OutputKind,
    opt:     Optimize,
    backend: Backend,
    output:  []const u8,        // "" → derived from name
    // fixed-capacity pools (VM-readable; no growable lists needed at build time)
    libs:       [MAX_LIBS][]const u8,    n_libs: usize,
    lib_paths:  [MAX_PATHS][]const u8,   n_lib_paths: usize,
    defines:    [MAX_DEFS]Define,        n_defs: usize,
    deps:       [MAX_DEPS]u32,           n_deps: usize,   // indices into Build.deps
}
```

### Builder methods (selection)

| Method | Effect |
| --- | --- |
| `b.executable(name, root) -> *Artifact` | declare an exe |
| `b.shared(name, root)` / `b.static(name, root)` / `b.object(name, root)` | other output kinds |
| `e.release()` · `e.debug()` · `e.release_small()` | optimization shorthands |
| `e.optimize(Optimize.release_fast)` · `e.use_backend(Backend.llvm)` | full optimization / backend |
| `e.link(lib)` · `e.lib_path(dir)` | system libraries + search dirs |
| `e.output(path)` | explicit output path |
| `e.define(key, value)` | inject a comptime constant into that build |
| `e.depend(dep)` · `e.needs(step)` | edges in the build graph |
| `b.run_step(name, exe)` · `b.test_dir(name, dir)` | run/test steps |
| `b.codegen(name, fn)` · `b.custom(name, fn)` | codegen / arbitrary steps |
| `b.require_path(name, dir)` · `b.require_git(name, url, rev)` | dependencies |
| `b.default(artifact)` | the default target |
| `b.option(key, default) -> []const u8` | read a `-Dkey=value` CLI override |

---

## 3. Layer 2 — workspaces & build options (Jai parity)

A **workspace** is an isolated compilation environment, exactly as in Jai. Layer 1
creates one per artifact for you; Layer 2 lets you drive them directly.

```k2
build :: fn(b: *Build) {
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

    w.add_file("main.k2");
    // add generated code as text …
    w.add_source("VERSION :: 3;");
    // … or as TYPED AST (validated at the generation site — better than a string)
    w.add_quote(#quote { build_id :: 0xC0FFEE; });
}
```

### `Options` — the full knob set (Jai's `Build_Options`, modernized)

```k2
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
    overflow_check:  Check,        // K2's overflow policy lives here

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

`set_optimization(o, .release_fast)` is sugar that flips the whole safety/codegen
block at once, like Jai's `set_optimization`.

---

## 4. Layer 3 — the compiler intercept (message loop)

This is the Jai message loop, built on K2's `#compiler` hook + `compiler_decls()`
(already implemented). Register interest in a workspace, then pull typed messages
as each phase finishes a unit — and **inspect or alter the program** before it
lowers.

```k2
build :: fn(b: *Build) {
    w := b.workspace("Main");
    w.add_file("main.k2");
    w.intercept();                       // begin

    had_error := false;
    while true {
        m := w.wait_message();
        match m.kind {
            .file_parsed => {}
            .typechecked => {
                // m carries the typed declaration: name, kind, type info,
                // and (K2 extension) the decl's AST for rewriting.
                if !check_decl(b, m) { had_error = true; }
            }
            .phase => {}
            .complete => break;
            else => {}
        }
    }

    w.end_intercept();
    if had_error { w.set_status(.failed); }
}
```

```k2
pub MessageKind :: enum { file_parsed, typechecked, phase, complete, error }

pub Message :: struct {
    kind:      MessageKind,
    workspace: u32,
    // typechecked payload (Jai gives you syntax trees + types here; K2 too):
    decl_name: []const u8,
    decl_kind: []const u8,   // "fn" | "struct" | ...  (from compiler_decls())
    // …typed AST handle + type_info handle (Layer-3 extensions)
}
```

Today `compiler_decls()` already gives a hook the program's declarations (name +
kind) at compile time; Layer 3 generalizes that into the streamed message form
and adds the typed-AST/type-info handles.

---

## 5. Beyond Jai

The parts that make this *exceed* Jai rather than merely match it.

### 5.1 Capability-sandboxed dependency builds — the supply-chain fix
Jai's build is arbitrary code with full host access; so is `build.rs`. **K2 hands
every build hook a capability set.** A dependency's `build.k2` receives a
`*Caps` it cannot forge or widen:

```k2
// vendor/raylib/build.k2  — runs sandboxed
build :: fn(b: *Build, caps: *Caps) {
    lib := b.static("raylib", "src/raylib.k2");
    lib.optimize(.release_fast);

    caps.read_dir(".");          // ALLOWED — granted its own folder
    // caps.shell("curl ...");   // DENIED at the VM — no ambient OS authority
    b.default(lib);
}
```

The root build grants capabilities explicitly:
`b.require_path("raylib", "vendor/raylib").allow(.read_self)`. A dependency that
never received `shell`/`net`/`write` *physically cannot* reach them — it's
enforced by the VM's capability table, not policy. This is the structural answer
to the build-script supply-chain hole.

### 5.2 Content-hashed, parallel build graph
Steps and artifacts form a DAG. Each step declares inputs/outputs and is
**content-hashed**: unchanged steps are skipped, independent steps run in
parallel. Jai's build is largely linear; K2's is incremental by construction.
`k2 build --explain` prints the graph and why each step ran or was cached.

### 5.3 Typed-AST codegen + `#provided`
Generated code goes in as **typed AST** (`w.add_quote(#quote { … })`), validated
at the generation site — not a raw string that fails at splice time. The
`#provided NAME;` directive is K2's typed `#placeholder`: it promises a symbol the
build will generate, and the type-checker trusts it until the build supplies it.

```k2
// main.k2
#provided GIT_REV: []const u8;       // build will define this
println(GIT_REV);
```

### 5.4 Targets as values → build matrices
`Target` is an ordinary value, so cross-compilation is a loop:

```k2
targets := [_]Target{ Target.win_x64, Target.linux_x64, Target.macos_arm64 };
for t in targets {
    e := b.executable("tool", "src/main.k2");
    e.target(t);
    e.output(out_for(t));
}
```

### 5.5 `--watch`, hermetic builds, asset pipelines
- **`k2 build --watch`** re-runs only affected steps on file change; the
  microsecond-class `k2lnk` linker makes the loop feel instant.
- **Hermetic/reproducible:** pin the toolchain, record input hashes, `--frozen`
  fails on lockfile drift.
- **Asset/codegen steps** (shader compile, embed-file, bindings) are first-class
  graph nodes with declared inputs/outputs, so they cache and parallelize too.

### 5.6 Bindings generation, on typed AST
A `b.codegen` step can read C/C++ headers (or, natively, introspect K2 via
`compiler_decls()`/`type_info`) and emit **typed AST** bindings into a workspace —
the safer, faster cousin of Jai's `generate_bindings`.

---

## 6. CLI surface

```text
k2 build                  run ./build.k2, build the default artifact
k2 build <name>           build a named artifact or step
k2 build run [-- args]    build the default exe, then run it
k2 build test             build + run the test step
k2 build --list           list artifacts and steps
k2 build --release        shorthand override (debug → release_fast)
k2 build -D key=value     set an option the script reads via b.option(...)
k2 build --watch          rebuild affected steps on change
k2 build --explain        print the build graph + cache decisions
k2 build --frozen         fail if the lockfile would change
k2 build <file.k2>        direct single-file build (back-compat, today's behavior)
```

Like Jai (`-- meta Build`) and the Default_Metaprogram, the no-`build.k2` path is
the built-in default metaprogram: it just turns flags into `Options`.

---

## 7. Location directives (Jai parity)

For asserts, logging, and codegen:

| Directive | Meaning |
| --- | --- |
| `#file` | full path of the current file |
| `#line` | current line number |
| `#filepath` | directory of the current file |
| `#location(x)` | `(file, line)` of a piece of code |
| `#caller_location` | default-arg form: caller's `(file, line)` |

Paths always use `/`, even on Windows.

---

## 8. Jai → K2 mapping (and the extensions)

| Jai | K2 |
| --- | --- |
| `build.jai` / `first.jai`, `#run build()` | `build.k2`, bare `k2 build` (or `#run build()`) |
| module `Compiler`, `#compiler` proc | `std.build`, `#compiler` hook (built) |
| `compiler_create_workspace()` | `b.workspace(name)` |
| `get_build_options` / `set_build_options` | `w.options()` / `w.set_options(o)` |
| `set_optimization(*o, .OPTIMIZED)` | `set_optimization(o, .release_fast)` |
| `add_build_file` / `add_build_string` | `w.add_file` / `w.add_source` **+ `w.add_quote` (typed)** |
| `#placeholder` | `#provided` (typed) |
| `compiler_begin_intercept` / `wait_for_message` / `end_intercept` | `w.intercept()` / `w.wait_message()` / `w.end_intercept()` |
| `compiler_set_workspace_status(.FAILED)` | `w.set_status(.failed)` |
| `set_build_options_dc(.{do_output=false})` | implicit — the build script never self-compiles to an exe |
| Default_Metaprogram | `k2 build` with no `build.k2` |
| `generate_bindings` | `b.codegen` step emitting typed AST |
| — | **capabilities/sandbox, content-hashed parallel graph, `--watch`, target matrix, hermetic/`--frozen`** |

---

## 9. Implementation plan

What the build system needs, against what already exists:

| Piece | Status |
| --- | --- |
| Comptime VM that runs IR | ✅ done |
| `#compiler` hook + `compiler_decls()` (program introspection) | ✅ done |
| Driver `compileFileWithLlvm` (exe/dll/obj) + `k2lnk` linker | ✅ done |
| **`k2 build` dir-mode**: find `build.k2`, run `build(b)` in the VM | ✅ done |
| **Config capture**: `host_call` opcode → `__build_*` intrinsics → host `BuildPlan` | ✅ done |
| **Plan executor**: per-artifact `compileFileWithLlvm`, wired outputs/libs/opt | ✅ done |
| Layer 1 surface: `executable`/`shared`/`static`/`object`, `link`/`lib_path`/`output`/`optimize`/`define`, `require_*`/`depend`, `run_step`/`test_dir`/`default` | ✅ done |
| CLI: `k2 build` / `run` / `<name>` / `--list` / `--release` / `-q` | ✅ done |
| `test_dir` step execution | ⏳ next |
| Build graph: deps/steps DAG, topo order, parallel | later |
| Content hashing + incremental + `--watch` | later |
| Capabilities / `*Caps` sandbox + VM capability table | later (Phase 5 of the comptime roadmap) |
| `add_quote` typed codegen / `#provided` / `define` injection | later (extends `#quote`/`#insert`) |
| Layer 2 (`workspace`/`Options`) + Layer 3 (intercept) surface | later |
| Cross-compile targets | later (needs Linux/macOS codegen + entry) |

**Execution mechanism (as built):** instead of reading the `Build` struct back
out of VM memory, the builder methods call `__build_*` compiler intrinsics that
lower (in the VM) to a new `host_call` opcode. The VM's `Vm.host` bridge forwards
each call to the build driver, which records it into a `BuildPlan` (so config is
captured imperatively as the script runs — robust, no fragile offset math, and
the model Jai itself uses). `Build`/`Artifact` are tiny value handles carrying an
id; all state lives in the driver.

**Build order from here:** `test_dir` execution → dependency/build graph +
incremental → capabilities → Layers 2–3 surface → cross-compile.

---

## 10. Minimal end-to-end (the target for v1)

```k2
// build.k2
#import std.build;

build :: fn(b: *Build) {
    app := b.executable("app", "src/main.k2");
    app.release();
    app.link("user32");
    b.run_step("run", app);
    b.default(app);
}
```

```text
$ k2 build            # → bin/app.exe via k2lnk
$ k2 build run        # → builds, then runs app.exe
$ k2 build --release  # → release_fast override
```
