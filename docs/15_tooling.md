# Tooling & the language server — design

`fels lsp` works today. It gives you diagnostics, completion, hover, go-to-definition, document
symbols, find references, rename, document highlight and workspace symbols, and §8 shows how to
wire it into your editor. `fels test` and the `#test` comptime lane work too
([docs/17](17_testing.md)), and `fels new` starts a project from a template (§9). A tree-sitter
grammar (`tree-sitter-fels`) and a Zed extension (`zed-fels`) are being written in their own
repositories. The formatter, the doc generator and the REPL aren't built yet.

## 0. The principle: the compiler is a library

The Fels tooling does **not** parse or model the language a second time. The compiler is
already a library (`fels_compiler`), and its frontend is reusable and, most importantly,
*tolerant*:

- `parseSource(alloc, file, src) -> ast.Module` builds the AST.
- `sema_mod.collectSymbols(alloc, module) -> SymbolTable` collects the names and scopes.
- `sema_mod.checkTypesTolerant(alloc, module, &syms, src, file) -> TypeEnv` type-checks and
  **returns a partial result even on errors** (it was built for the two-pass `#insert` rail).
  That is exactly what an editor needs, because code is broken most of the time while you are
  typing it.

The `TypeEnv` already carries everything the tools below need, keyed by AST node id
([src/sema.zig](../src/sema.zig)):

| Data | Field | Powers |
| --- | --- | --- |
| type at a node | `expr_types: NodeId → Ty` | hover, semantic tokens, signature help |
| name → its symbol | `expr_symbols: NodeId → SymbolId` | go-to-definition, references, rename |
| method call → method | `extension_calls: NodeId → SymbolId` | go-to-def on `x.foo()` |
| errors/warnings | `diagnostics: []Diagnostic` (line:col, severity) | live diagnostics, quick-fixes |
| symbol metadata | `Symbol{ name, kind, span, file }` | definition location, outline, completion |
| scopes | `SymbolTable.resolve*` | scope-aware completion |

So every tool is a *thin* consumer of the frontend, and they all share one model of the
language. There is no second parser that could drift apart from the first.

## 1. `fels lsp` — the language server

`fels lsp` is a subcommand that speaks LSP (JSON-RPC over stdio). One server serves every
editor, and Zed, Neovim, Helix and VS Code each need only a few lines of client config.

### 1.1 Document lifecycle

- Keep an in-memory store of open documents (uri → text + version).
- On open or change: lex → parse → `checkTypesTolerant`, then cache the
  `(Module, TypeEnv, SymbolTable)` for that document. Fels compiles in **milliseconds**, so a
  full re-check per keystroke (debounced) is fine for v1. Salsa-style query caching is a later
  optimization.
- Publish `diagnostics` right away, since they already have spans and severities.

### 1.2 Position mapping

LSP positions are UTF-16 `(line, character)`, but Fels spans are byte offsets.
`Span.line_col(source)` ([src/lexer/span.zig](../src/lexer/span.zig)) already yields
`(line, col)`. Wrap it with a byte↔UTF-16 column converter. That is one small utility, and a
property test against multibyte source exercises it.

### 1.3 Feature map (all backed by data that already exists)

| LSP request | Implementation |
| --- | --- |
| `publishDiagnostics` | `TypeEnv.diagnostics` → LSP diagnostics |
| `hover` | node under cursor → `expr_types[node]` → `formatTy`, plus the symbol's leading doc comment |
| `definition` | `expr_symbols[node]` / `extension_calls[node]` → `Symbol.span`/`.file` |
| `references` / `rename` | a reference index per file (`src/lsp_nav.zig`): every name with the declaration it means, from `expr_symbols`, `extension_calls`, `impl_method_calls`, `enum_lits`, `expr_types` and the walk's own scopes for locals, and rename rewrites every place |
| `completion` | scope-visible symbols at the cursor + **member completion** (the `expr_types` of the `.`-base gives the struct → its fields/methods) + `core::`/`#attribute` builtins |
| `signatureHelp` | the call being typed → `fn_sigs[symbol]` → params + active arg |
| `documentSymbol` | walk the `Module` top-level + in-struct methods (the semantic cousin of `outline.scm`) |
| `formatting` | delegate to `fels fmt` (§2) |
| `semanticTokens` | classify each node by symbol kind + comptime-ness (§1.5) |
| `codeAction` | turn diagnostics into fixes (§1.4) |

### 1.4 Quick-fixes from the diagnostics engine

The diagnostics already *suggest* a fix, and the LSP turns those suggestions into one-click
fixes:

- "unknown type `Poimt`; did you mean `Point`?" → a rename edit. (The did-you-mean engine
  landed in [sema.zig](../src/sema.zig) as `suggestTypeName`.)
- "non-exhaustive match: variant `.X` not handled" → insert the missing arm (sema already
  enumerates the missing variants).
- "`fail` used in a function without a `!` error return type" → add the `! Err`.
- A struct with hand-written `eq`/`hash` → offer `#derive(Eq, Hash)` instead.

This is where reusing the compiler pays off, because the analysis that produces the error
already knows the fix.

### 1.5 The fels differentiators

These are things a generic LSP over tree-sitter can't do, but the reusable, comptime-capable
Fels frontend can:

- **Comptime-aware navigation.** `#derive`, `#compiler` hooks and macros generate real
  declarations at comptime. The server runs that generation pass (it already happens in the
  pipeline) and indexes the **generated** symbols. So hover, go-to-def and completion work on a
  derived `eq`/`hash`/`format` method, not only on hand-written ones. (Rust-analyzer has to
  fight the opacity of proc-macros. Fels generates structured AST, so the server sees the
  output directly.)
- **Type-aware semantic tokens.** Beyond tree-sitter's syntactic colors, color by *meaning*.
  Tell a type from a value and a `#run`/comptime constant from a runtime one, and mark an
  `#extern` symbol or a region/`zone` handle. All of that is derivable from `expr_types` and
  `Symbol.kind`.
- **Region/lifetime hints.** Inlay hints that show which `*Arena` a `Vec`/`Map` is bound to, or
  that flag a value that escapes its region. They make the Fels memory model visible inline.
- **Capability hints in `build.fels`.** Show inline which capabilities a dependency requests.
  This ties into the package manager (doc 16).

### 1.6 Scope

v1: diagnostics, hover, definition, completion, document symbols, formatting.
v2: references/rename, signature help, semantic tokens, code actions.
v3: comptime-aware indexing, inlay hints, workspace-wide symbol search.

## 2. `fels fmt` — the canonical formatter

The formatter is opinionated and **config-free** (the gofmt/`zig fmt` philosophy). There is one
true style and no bikeshedding. It is idempotent: `fmt(fmt(x)) == fmt(x)`.

- Implementation: reuse the parser, then pretty-print the AST. The one hard part is **comment
  preservation**, because comments aren't in the AST. The approach is a token-anchored printer.
  It re-emits from the AST but threads leading and trailing comments in by their source
  position relative to the nearest node. (A CST or loss-less parse would be the alternative,
  but the AST+anchoring path is lighter and matches what exists.)
- It drives the LSP `formatting`/`rangeFormatting` requests and a `--check` mode for CI
  (`fels fmt --check` exits non-zero on unformatted files).

## 3. `fels doc` — reflection-driven documentation

Here the reflection of Fels is the unfair advantage. `core::compiler_decls()` and
`core::type_info` already expose the shape of every declaration. Doc generation reads those and
the leading doc comments, and emits HTML/Markdown.

- It shows the **derive-generated** API (the `eq`/`hash`/`format` a `#derive` added), because
  those are real decls in the program. So the documentation matches what actually compiles.
- It can render **comptime-evaluated constants** with their *values* (`#run`-folded consts),
  not only their declarations.
- The output is a static site (or Markdown for embedding). A `b.doc` build step makes it a
  first-class, cacheable node in the build graph (doc 10 §5).

## 4. `fels test`, the test runner

This one is built, and [docs/17](17_testing.md) describes it. Functions marked `#test` run in
two ways:

- `fels test` builds a program per file that runs the file's tests and reports each one, so a
  test can do I/O and call C. A crash ends only its own test.
- `fels build` runs them **at compile time on the comptime VM** (instant, hermetic), and a
  failed one fails the build. A test that needs the running program is skipped there.

Still to come: a filter (`fels test --filter substr`), a time limit, and a TAP or JSON report
for CI.

## 5. `fels repl` — interactive evaluation

The comptime VM (`src/vm/`) already evaluates Fels to real values over a modeled host memory. A
REPL is an interactive driver on top of it. You enter a decl or an expression, the VM evaluates
it, and the result prints. What makes it distinctive is that it's the *same engine* that runs
`#run`/`#compiler`, so the REPL is comptime Fels, live. It is good for exploring `std`,
prototyping a generic or inspecting `core::type_info`.

## 6. Editor integrations — one grammar, one server

- **Syntax**: `grammar.js` in the separate `tree-sitter-fels` repository is the single
  syntactic source of truth. It is meant to feed the Zed extension, and the same grammar and
  queries drive nvim-treesitter, Helix and VS Code (tree-sitter, with a TextMate grammar as a
  no-WASM fallback). Keep the highlight/indent/bracket/outline `.scm` queries in the grammar
  repo, and editors consume them verbatim.
- **Semantics**: every editor points its LSP client at `fels lsp`. The syntax comes from
  tree-sitter and the meaning from the server, so there is no per-editor logic.
- **Distribution**: publish the grammar (tree-sitter) and the Zed/VS Code extensions, and ship
  `fels lsp` inside the `fels` binary, so that "install fels" gives you the server for free.

## 7. Build order

1. `fels fmt` (the smallest, and it unblocks LSP formatting and CI style).
2. `fels lsp` v1 (diagnostics, hover, definition, completion). It is the tool with the highest
   impact, and almost entirely a thin wrapper over `checkTypesTolerant`.
3. `#test` + `fels test`.
4. `fels doc` (reflection-driven).
5. LSP v2/v3 (rename, semantic tokens, code actions, comptime-aware indexing).
6. `fels repl`.

The common thread: the compiler is already a tolerant library with reflection, so each tool is
small. The investment goes into the **library seams** (position mapping, a reference index,
comment-anchoring), not into implementing the language five times over.

## 8. Using `fels lsp` today

`fels lsp` is built into the `fels` binary and speaks LSP over stdio, so you can point any
LSP-capable editor at `fels lsp`. Fels source files end in `.fels`.

What it does:

- **Project aware.** Each open file is analyzed together with the modules it imports, with the
  compiler's own loader. It finds `std` the way the compiler finds it (`--std-path`,
  `FELS_STD`, `FELS_HOME`, next to the executable). It looks for sibling `.fels` files next to
  the importing file, then under the project root. The project root is the nearest folder above
  the file with a `build.fels`, or else the workspace folder. A file that `fels check` accepts
  gives no diagnostics.
- **Open documents win over disk.** If an imported module is open in the editor, the server
  uses its unsaved text. When you edit a module, the open files that import it are analyzed
  again.
- **Diagnostics per file.** The errors of an imported module are published to that module's own
  URI, not to the file that imports it. Errors inside `std` are not shown. A file that does not
  parse gives its syntax errors, and the rest of the project still checks.
- **Go to definition and hover across files.** A name imported from another module jumps to its
  declaration there (also in `std`). Hover shows the declaration as written and the module it
  comes from. `alias::name` and the module path of an `#import` work too.
- **Completion and outline** include the names in scope: the file's own declarations, the names
  its imports bring in (selective imports, `as` aliases, `.*` wildcards, only `pub` names), the
  locals and parameters visible at the cursor, and the members of a module after `alias::`.
- **Member completion.** After `expr.` you get the fields (with their types), the methods (with
  their signatures), the methods of interfaces the type implements and the free functions whose
  first parameter is `self` of that type. It works through pointers (`p.` for a `*T`) and along
  chains (`a.b.`, `f().`, `a[i].`, `x?.`, `x!!.`). It also works on slices and arrays (`len`,
  `ptr`), on `Type.` and on `Type::`. `Type.` offers the variants of an enum or error set, and
  choosing an associated function there turns the `.` into `::`. A `.` that starts an enum
  literal offers the variants of the type expected there: after `==`, `!=` and `=`, in a call
  argument, after `return`, in a `match` arm and after `name: Type =`. A method of a generic
  struct instance shows its type arguments (`Vec(i32).push` takes `item: i32`).
- **Signature help** (on `(` and `,`) shows the function, method, interface method, function
  pointer field, macro or `#extern` being called. You see its parameters as written, and which
  one is active.
- **Inlay hints** show the inferred type after a name declared with `:=` and after `for`,
  `match`, `if` and `while` captures. They write the type the way Fels source writes types
  (`[]const u8`, `*Node`, `?T`, `T ! Err`, `Vec(i32)`). A declaration with a written type gets
  none.
- **Hover** on a local, a parameter or a field shows `name: Type`, and on a method it shows the
  signature.
- **While typing.** Code is broken most of the time while you type (`p.` alone does not parse).
  So the server keeps the last analysis whose text parsed. While the current text does not
  parse, it answers completion, hover, signature help and inlay hints from that analysis. A
  line diff maps positions from that text to the current one, so the answers stay correct
  outside the lines being edited. An inlay hint is only shown where the mapping is exact.
  Diagnostics always come from the current text.
- **Find references across the project.** The project is the folder with `build.fels` above the
  file (or else the workspace folder, or else the file's folder) and every `.fels` file under
  it, open or not. It leaves out `std` and the `zig-out`, `.zig-cache`, `.git`, `.claude`,
  `dist` and `out` folders, and it holds at most 400 files (the server says so when a project
  has more). A reference is a use in an expression, a type name (field and parameter types,
  casts, generic arguments), a field in an access or in a `.{ .x = … }` literal, a method call
  (struct methods, interface methods and their implementations, functions called as methods),
  an enum or error variant (`.red`, `Color.red`, a `match` arm, `fail .Bad`), a name in
  `#import a.{ name }` and `alias::name`. Names are told apart by what they mean, not by their
  text, so two locals `x` in two blocks are two names. For a name declared in `std`, the list
  includes its declaration there too.
- **Rename** edits every one of those places, also in files that are not open. It refuses to
  rename `main`, a plain `#export`, and a name declared in `std` or by an `#extern`. It refuses a
  new name that is not an identifier, or that is a keyword or a built-in name. And it refuses a
  new name that would change what another name means: one declared or imported where the
  symbol is used, a local that would hide it or that it would hide, or another field, variant
  or method of the same type.
- **Document highlight** marks the name under the cursor in the file (where it is written or
  read), and **workspace symbols** search the top level declarations of the projects of the
  open files.
- **Speed.** Analysis runs when no more input is waiting, so a burst of edits costs one run. An
  830 line file with imports of `std.sync`, `std.utf16` and a `win32` binding module analyzes
  in about 5 ms in a release build (about 30 ms in a debug build). The standard library is
  parsed again each time, and that is cheap enough that no cache is kept. Set
  `FELS_LSP_TIMING=1` to see each run on stderr. References keep an index per file and rebuild
  it only when the file or a module it imports changes. The index of a file comes from an
  analysis that loaded it, so one analysis of a `main.fels` that imports everything covers the
  project. A local or a declaration without `pub` is only looked for in its own file. In the 55
  files of `examples/`, the first search for a `std` function used in 10 to 18 of them takes
  30 to 65 ms in a release build (200 to 300 ms in a debug build), and a repeated one about
  4 ms. Completion and signature help answer in about 1 ms on that file while it does not
  parse, and in about 6 ms (the analysis included) when it does.
- **Not done yet:** semantic tokens, formatting and code actions. `#compiler` hooks and computed
  `#insert` do run during analysis, as in a build. Locals inside generic functions have no
  recorded types, because the checker types those bodies per instance. So they get no hover
  type, no inlay hint and no member completion.

**Helix**, in `~/.config/helix/languages.toml` (no compilation needed):

```toml
[language-server.fels]
command = "fels"
args = ["lsp"]

[[language]]
name = "fels"
scope = "source.fels"
file-types = ["gab"]
roots = ["build.fels"]
language-servers = ["fels"]
comment-tokens = ["//"]
```

**Neovim**, in your config:

```lua
vim.filetype.add({ extension = { gab = "fels" } })
vim.api.nvim_create_autocmd("FileType", {
  pattern = "fels",
  callback = function()
    vim.lsp.start({ name = "fels", cmd = { "fels", "lsp" },
      root_dir = vim.fs.root(0, { "build.fels", ".git" }) })
  end,
})
```

**Zed**: a Zed extension (`zed-fels`) is being written in its own repository. It declares the
server and launches `fels lsp` from your `PATH`, and it is not part of this repository. The
tree-sitter grammar (`tree-sitter-fels`) lives in a separate repository too. VS Code support
will be a thin client wrapper, later.

> You can smoke-test the protocol without an editor. `python tests/lsp_smoke.py` drives an
> `initialize`, `didOpen`, `completion`/`hover`/`definition`/`documentSymbol` exchange against
> the built binary, on one file and on a two-file project. `python tests/lsp_nav_test.py`
> checks references, rename, highlight and workspace symbols on a small project, with edits in
> files that are not open. `python tests/lsp_all_files.py` opens every `.fels` file of the
> repository through the server and compares the result with `fels check`. It also checks that
> rejected programs still give an error at the right line.
> `python tests/lsp_perf.py <fels.exe> <file.fels>` times repeated edits.
> `python tests/lsp_assist_test.py` checks member completion, signature help, inlay hints and
> hover, also while the file does not parse.

## 9. Starting a project: `fels new` and `fels init`

```text
fels new hello                  a program in the new folder hello/
fels new mathx --lib            a library others use with `fels add`
fels new rl --cbind             Fels bindings to a C library
fels init                       the same in the current folder (--lib, --cbind)
fels new --list                 the templates
```

| Template | What it makes |
| --- | --- |
| `--app` (the default) | `src/main.fels` with `main`, a function and a `#test`; `build.fels` with the program and a `run` step |
| `--lib` | `src/<name>.fels` with `pub` functions and tests, `examples/demo.fels` that imports the library by its name, a README that shows `fels add` |
| `--cbind` | `src/<name>.fels` with `#extern` bindings, a `lib/` folder for the C library, `build.fels` that provides `lib/` to the package's users, an example |

Every template also writes `fels.pkg`, a `README.md`, a `.gitignore` and a `LICENSE`, and puts
what `fels build` makes into `bin/`. Right after `fels new`, `fels test` passes and
`fels build run` runs the program or the example. The cbind template binds two kernel32
functions, so it builds and its tests run before your library is there. Replace them with your
library's functions.

- **The name.** The folder's name is the package name, so it has to work as a Fels name. `-`,
  `.` and spaces become `_` (`fels new my-lib` makes the package `my_lib`, with a note), and a
  name that starts with a digit is refused.
- **The license.** The default is MIT, with this year and `git config user.name`.
  `--license Apache-2.0` writes the Apache license, and `--license none` writes none and leaves
  `#license` out of fels.pkg.
- **git.** `fels new` runs `git init` when git is available and the folder is not already
  inside a repository. `--no-git` skips that.
- **Nothing is written over.** `fels new` wants a folder that does not exist yet or is empty.
  `fels init` keeps every file that is already there (it lists them), and it stops when the
  folder has a fels.pkg.

The templates are part of fels.exe ([src/new_cmd.zig](../src/new_cmd.zig)), and the
placeholders `{{name}}`, `{{year}}` and `{{author}}` in them are filled in. Still to come:
templates from a git repository, and a game template.

## Diagnostics in the terminal

A diagnostic has a header, a location and a source snippet with the offending span underlined,
followed by any `note:`/`help:` lines:

```text
error: unknown type `Poin`
  --> demo.fels:4:8
  │
4 │     p: Poin = .{ .x = 1, .y = 2 };
  │        ^^^^ not a known type
  = help: did you mean `Point`?
```

`src/diagnostic.zig` renders it. The `Diagnostic` carries the parts: a primary span with its
label, secondary `labels` (other underlines, or the frames of a trace), `notes` and `helps`.
`sema` attaches them through `emitErrorRich`. A type mismatch underlines the value and names
the expected type. An unknown name, function or type gets a `help: did you mean …?`. The
suggestion comes from a Levenshtein search over the locals in scope and the functions, consts
and types the file can write by name, and it is never the unknown name itself. A name that is
declared by a module imported whole gets the way to reach it instead:
`` help: write `build::Build`, or import it with `#import std.build.{ Build };` ``.

Color is on when stderr is a console and off when it's a pipe or a file, so captured output
stays plain. `NO_COLOR` forces it off and `FELS_COLOR=1` forces it on, which is handy when
paging. `src/style.zig` makes the call and enables VT processing on Windows.
