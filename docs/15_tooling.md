# Tooling & the language server — design

`fels lsp` works: diagnostics, completion, hover, go-to-definition, document symbols,
find references, rename, document highlight and workspace symbols. §8 wires it into your
editor. `fels test` and the `#test` comptime lane work too ([docs/17](17_testing.md)), and
`fels new` starts a project from a template (§9). A tree-sitter grammar (`tree-sitter-fels`) and a Zed
extension (`zed-fels`) are being written in their own repositories. A formatter, doc generator and
REPL aren't built yet.

## 0. The principle: the compiler is a library

fels's tooling does **not** re-parse or re-model the language. The compiler is
already a library (`fels_compiler`) whose frontend is reusable and, crucially,
*tolerant*:

- `parseSource(alloc, file, src) -> ast.Module` — the AST.
- `sema_mod.collectSymbols(alloc, module) -> SymbolTable` — names + scopes.
- `sema_mod.checkTypesTolerant(alloc, module, &syms, src, file) -> TypeEnv` —
  type-checks and **returns a partial result even on errors** (it was built for
  the two-pass `#insert` rail). That is exactly what an editor needs: code is
  broken most of the time you're typing it.

The `TypeEnv` already carries everything the tools below want, keyed by AST node
id ([src/sema.zig](../src/sema.zig)):

| Data | Field | Powers |
| --- | --- | --- |
| type at a node | `expr_types: NodeId → Ty` | hover, semantic tokens, signature help |
| name → its symbol | `expr_symbols: NodeId → SymbolId` | go-to-definition, references, rename |
| method call → method | `extension_calls: NodeId → SymbolId` | go-to-def on `x.foo()` |
| errors/warnings | `diagnostics: []Diagnostic` (line:col, severity) | live diagnostics, quick-fixes |
| symbol metadata | `Symbol{ name, kind, span, file }` | definition location, outline, completion |
| scopes | `SymbolTable.resolve*` | scope-aware completion |

So every tool is a *thin* consumer of the frontend, sharing one model of the
language. No second parser to drift.

## 1. `fels lsp` — the language server

A `fels lsp` subcommand speaking LSP (JSON-RPC over stdio). One server, every
editor (Zed/Neovim/Helix/VS Code each need only a few lines of client config).

### 1.1 Document lifecycle

- Keep an in-memory store of open documents (uri → text + version).
- On open/change: lex → parse → `checkTypesTolerant`, cache the `(Module, TypeEnv,
  SymbolTable)` for that document. fels compiles in **milliseconds**, so a full
  re-check per keystroke (debounced) is fine for v1; salsa-style query caching is
  a later optimization.
- Publish `diagnostics` immediately — they already have spans and severities.

### 1.2 Position mapping

LSP positions are UTF-16 `(line, character)`; fels spans are byte offsets.
`Span.line_col(source)` ([src/lexer/span.zig](../src/lexer/span.zig)) already
yields `(line, col)` — wrap it with a byte↔UTF-16 column converter (one small
utility, exercised by a property test against multibyte source).

### 1.3 Feature map (all backed by data that already exists)

| LSP request | Implementation |
| --- | --- |
| `publishDiagnostics` | `TypeEnv.diagnostics` → LSP diagnostics |
| `hover` | node under cursor → `expr_types[node]` → `formatTy`, plus the symbol's leading doc comment |
| `definition` | `expr_symbols[node]` / `extension_calls[node]` → `Symbol.span`/`.file` |
| `references` / `rename` | a reference index per file (`src/lsp_nav.zig`): every name with the declaration it means, from `expr_symbols`, `extension_calls`, `impl_method_calls`, `enum_lits`, `expr_types` and the walk's own scopes for locals; rename rewrites every place |
| `completion` | scope-visible symbols at the cursor + **member completion** (the `expr_types` of the `.`-base gives the struct → its fields/methods) + `core::`/`#attribute` builtins |
| `signatureHelp` | the call being typed → `fn_sigs[symbol]` → params + active arg |
| `documentSymbol` | walk the `Module` top-level + in-struct methods (the semantic cousin of `outline.scm`) |
| `formatting` | delegate to `fels fmt` (§2) |
| `semanticTokens` | classify each node by symbol kind + comptime-ness (§1.5) |
| `codeAction` | turn diagnostics into fixes (§1.4) |

### 1.4 Quick-fixes from the diagnostics engine

The diagnostics already *suggest*; the LSP turns those into one-click fixes:

- "unknown type `Poimt`; did you mean `Point`?" → a rename edit. (The
  did-you-mean engine landed in [sema.zig](../src/sema.zig) — `suggestTypeName`.)
- "non-exhaustive match: variant `.X` not handled" → insert the missing arm
  (sema already enumerates the missing variants).
- "`fail` used in a function without a `!` error return type" → add the `! Err`.
- A struct with hand-written `eq`/`hash` → offer `#derive(Eq, Hash)` instead.

This is where reusing the compiler pays off: the analysis that produces the error
already knows the fix.

### 1.5 The fels differentiators

What a generic LSP-over-tree-sitter can't do, but fels's reusable, comptime-capable
frontend can:

- **Comptime-aware navigation.** `#derive`, `#compiler` hooks, and macros
  generate real declarations at comptime. The server runs that generation pass
  (it already happens in the pipeline) and indexes the **generated** symbols — so
  hover/go-to-def/completion work on a derived `eq`/`hash`/`format` method, not
  just hand-written ones. (Rust-analyzer fights proc-macro opacity; fels's
  generation is structured AST, so the server simply sees the output.)
- **Type-aware semantic tokens.** Beyond tree-sitter's syntactic colors, color by
  *meaning*: distinguish a type from a value, a `#run`/comptime-constant from a
  runtime one, an `#extern` symbol, a region/`zone` handle. All derivable from
  `expr_types` + `Symbol.kind`.
- **Region/lifetime hints.** Inlay hints showing which `*Arena` a `Vec`/`Map` is
  bound to, or flagging a value that escapes its region — fels's memory model made
  visible inline.
- **Capability hints in `build.fels`.** Show, inline, which capabilities a
  dependency requests (ties into the package manager, doc 16).

### 1.6 Scope

v1: diagnostics, hover, definition, completion, document symbols, formatting.
v2: references/rename, signature help, semantic tokens, code actions.
v3: comptime-aware indexing, inlay hints, workspace-wide symbol search.

## 2. `fels fmt` — the canonical formatter

Opinionated and **config-free** (the gofmt/`zig fmt` philosophy): one true style,
no bikeshedding. Idempotent: `fmt(fmt(x)) == fmt(x)`.

- Implementation: reuse the parser, then pretty-print the AST. The one hard part
  is **comment preservation** — comments aren't in the AST. Approach: a
  token-anchored printer that re-emits from the AST but threads trailing/leading
  comments by their source position relative to the nearest node. (Alternatively a
  CST/loss-less parse; the AST+anchoring path is lighter and matches what exists.)
- Drives the LSP `formatting`/`rangeFormatting` requests and a `--check` mode for
  CI (`fels fmt --check` exits non-zero on unformatted files).

## 3. `fels doc` — reflection-driven documentation

fels's reflection is the unfair advantage here. `compiler_decls()` and `type_info`
already expose every declaration's shape; doc generation reads those plus the
leading doc comments and emits HTML/Markdown.

- It shows **derive-generated** API (the `eq`/`hash`/`format` a `#derive` added),
  because those are real decls in the program — documentation that matches what
  actually compiles.
- It can render **comptime-evaluated constants** with their *values* (`#run`-folded
  consts), not just their declarations.
- Output is a static site (or Markdown for embedding). A `b.doc` build step makes
  it a first-class, cacheable node in the build graph (doc 10 §5).

## 4. `fels test`, the test runner

Built; [docs/17](17_testing.md) describes it. Functions marked `#test` run in two ways:

- `fels test` builds a program per file that runs the file's tests and reports each one,
  so a test can do I/O and call C. A crash ends only its own test.
- `fels build` runs them **at compile time on the comptime VM** (instant, hermetic), and
  a failed one fails the build. A test that needs the running program is skipped there.

Still to come: a filter (`fels test --filter substr`), a time limit, and a TAP or JSON
report for CI.

## 5. `fels repl` — interactive evaluation

The comptime VM (`src/vm/`) already evaluates fels to real values over a modeled
host memory. A REPL is an interactive driver over it: enter a decl or expression,
the VM evaluates it, the result prints. Distinctive because it's the *same engine*
that runs `#run`/`#compiler` — the REPL is comptime fels, live. Good for exploring
`std`, prototyping a generic, or inspecting `type_info`.

## 6. Editor integrations — one grammar, one server

- **Syntax**: `grammar.js` in the separate `tree-sitter-fels` repository is the single syntactic source
  of truth. It is meant to feed the Zed extension; the same grammar + queries drive
  nvim-treesitter, Helix, and VS Code (tree-sitter, with a TextMate grammar as a
  no-WASM fallback). Keep the highlight/indent/bracket/outline `.scm` queries in
  the grammar repo; editors consume them verbatim.
- **Semantics**: every editor points its LSP client at `fels lsp`. Syntax from
  tree-sitter, meaning from the server — no per-editor logic.
- **Distribution**: publish the grammar (tree-sitter), the Zed/VS Code extensions,
  and ship `fels lsp` inside the `fels` binary so "install fels" gives you the server
  for free.

## 7. Build order

1. `fels fmt` (smallest, unblocks LSP formatting + CI style).
2. `fels lsp` v1 (diagnostics + hover + definition + completion) — the highest-impact
   tool, almost entirely a thin wrapper over `checkTypesTolerant`.
3. `#test` + `fels test`.
4. `fels doc` (reflection-driven).
5. LSP v2/v3 (rename, semantic tokens, code actions, comptime-aware indexing).
6. `fels repl`.

The throughline: because the compiler is already a tolerant, reflection-capable
library, each tool is small. The investment is the **library seams**
(position mapping, a reference index, comment-anchoring) — not re-implementing the
language five times.

## 8. Using `fels lsp` today

`fels lsp` is built into the `fels` binary and speaks LSP over stdio. Point any
LSP-capable editor at `fels lsp`. Fels source files end in `.fels`.

What it does:

- **Project aware.** Each open file is analyzed together with the modules it imports, using
  the compiler's own loader: `std` (found as the compiler finds it: `--std-path`,
  `FELS_STD`, `FELS_HOME`, next to the executable) and sibling `.fels` files (next to
  the importing file, then under the project root, which is the nearest folder above the
  file with a `build.fels`, else the workspace folder). A file that `fels check` accepts
  gives no diagnostics.
- **Open documents win over disk.** If an imported module is open in the editor, its
  unsaved text is used. Editing a module re-analyzes the open files that import it.
- **Diagnostics per file.** The errors of an imported module are published to that module's
  own URI, not to the file that imports it. Errors inside `std` are not shown. A file that
  does not parse gives its syntax errors; the rest of the project still checks.
- **Go to definition and hover across files.** A name imported from another module jumps to
  its declaration there (also in `std`). Hover shows the declaration as written and the
  module it comes from. `alias::name` and the module path of an `#import` work too.
- **Completion and outline** include the names in scope: the file's own declarations, the
  names its imports bring in (selective imports, `as` aliases, `.*` wildcards, only `pub`
  names), the locals and parameters visible at the cursor, and the members of a module
  after `alias::`.
- **Member completion.** After `expr.` the fields (with their types), methods (with their
  signatures), the methods of interfaces the type implements and the free functions whose
  first parameter is `self` of that type. It works through pointers (`p.` for a `*T`),
  along chains (`a.b.`, `f().`, `a[i].`, `x?.`, `x!!.`), on slices and arrays (`len`,
  `ptr`), on `Type.` (the variants of an enum or error set; choosing an associated
  function turns the `.` into `::`) and on `Type::`. A `.` that starts an enum literal
  offers the variants of the type expected there: after `==`, `!=` and `=`, in a call
  argument, after `return`, in a `match` arm and after `name: Type =`. A method of a
  generic struct instance shows its type arguments (`Vec(i32).push` takes `item: i32`).
- **Signature help** (`(` and `,`): the function, method, interface method, function
  pointer field, macro or `#extern` being called, with its parameters as written and the
  active one.
- **Inlay hints**: the inferred type after a name declared with `:=` and after `for`,
  `match`, `if` and `while` captures, written as Fels source writes types (`[]const u8`,
  `*Node`, `?T`, `T ! Err`, `Vec(i32)`). A declaration with a written type gets none.
- **Hover** on a local, a parameter or a field shows `name: Type`; on a method its
  signature.
- **While typing.** Code is broken most of the time during typing (`p.` alone does not
  parse). The server keeps the last analysis whose text parsed and answers completion,
  hover, signature help and inlay hints from it while the current text does not parse.
  Positions are mapped from that text to the current one with a line diff, so the answers
  stay correct outside the lines being edited; an inlay hint is only shown where the
  mapping is exact. Diagnostics always come from the current text.
- **Find references across the project.** The project is the folder with `build.fels` above
  the file (else the workspace folder, else the file's folder) and every `.fels` file under it,
  open or not, except `std` and the `zig-out`, `.zig-cache`, `.git`, `.claude`, `dist` and
  `out` folders; at most 400 files (the server says so when a project has more). A reference
  is a use in an expression, a type name (field and parameter types, casts, generic
  arguments), a field in an access or in a `.{ .x = … }` literal, a method call (struct
  methods, interface methods and their implementations, functions called as methods), an
  enum or error variant (`.red`, `Color.red`, a `match` arm, `fail .Bad`), a name in
  `#import a.{ name }` and `alias::name`. Names are told apart by what they mean, not by
  their text: two locals `x` in two blocks are two names. A name declared in `std` lists its
  declaration there too.
- **Rename** edits every one of those places, also in files that are not open. It refuses a
  name declared in `std` or by an `#extern`, `main` and a plain `#export`, a new name that is
  not an identifier or is a keyword or a built-in name, and a new name that would change what
  another name means: one declared or imported where the symbol is used, a local that would
  hide it or that it would hide, another field, variant or method of the same type.
- **Document highlight** marks the name under the cursor in the file (written or read), and
  **workspace symbols** search the top level declarations of the projects of the open files.
- **Speed.** Analysis runs when no more input is waiting, so a burst of edits costs one run.
  A 830 line file with imports of `std.sync`, `std.utf16` and a `win32` binding module
  analyzes in about 5 ms in a release build (about 30 ms in a debug build); the standard
  library is parsed again each time, which is cheap enough that no cache is kept. Set
  `FELS_LSP_TIMING=1` to see each run on stderr. References keep an index per file and
  rebuild it only when the file or a module it imports changes; the index of a file comes
  from an analysis that loaded it (one analysis of a `main.fels` that imports everything
  covers the project), and a local or a declaration without `pub` is only looked for in its
  own file. In the 55 files of `examples/`, the first search for a `std` function used in 10
  to 18 of them takes 30 to 65 ms in a release build (200 to 300 ms in a debug build), a
  repeated one about 4 ms.
  Completion and signature help answer in about 1 ms on that file while it does not parse
  and in about 6 ms (the analysis included) when it does.
- **Not done yet:** semantic tokens, formatting, code actions.
  `#compiler` hooks and computed `#insert` run during analysis, as in a build. Locals
  inside generic functions have no recorded types (the checker types those bodies per
  instance), so they get no hover type, no inlay hint and no member completion.

**Helix** — `~/.config/helix/languages.toml` (zero compilation):

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

**Neovim** — in your config:

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

**Zed** — a Zed extension (`zed-fels`) is being written in its own repository; it
declares the server and launches `fels lsp` from your `PATH`. It is not part of this
repository. The tree-sitter grammar (`tree-sitter-fels`) is a separate repository too.
VS Code support is a thin client wrapper (future).

> Smoke-test the protocol without an editor: `python tests/lsp_smoke.py` drives an
> `initialize`, `didOpen`, `completion`/`hover`/`definition`/`documentSymbol` exchange
> against the built binary, on one file and on a two-file project.
> `python tests/lsp_nav_test.py` checks references, rename, highlight and workspace symbols on
> a small project, with edits in files that are not open.
> `python tests/lsp_all_files.py` opens every `.fels` file of the repository through the
> server and compares with `fels check`, and checks that rejected programs still give an
> error at the right line. `python tests/lsp_perf.py <fels.exe> <file.fels>` times repeated
> edits. `python tests/lsp_assist_test.py` checks member completion, signature help, inlay
> hints and hover, also while the file does not parse.

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

Every template also writes `fels.pkg`, a `README.md`, a `.gitignore` and a `LICENSE`, and
puts what `fels build` makes into `bin/`. Right after `fels new`, `fels test` passes and
`fels build run` runs the program or the example. The cbind template binds two kernel32
functions, so it builds and its tests run before your library is there; replace them with
your library's functions.

- **The name.** The folder's name is the package name. It has to work as a Fels name:
  `-`, `.` and spaces become `_` (`fels new my-lib` makes the package `my_lib`, with a
  note), and a name that starts with a digit is refused.
- **The license.** MIT by default, with this year and `git config user.name`.
  `--license Apache-2.0` writes the Apache license, `--license none` writes none and leaves
  `#license` out of fels.pkg.
- **git.** `fels new` runs `git init` when git is there and the folder is not inside a
  repository already. `--no-git` skips it.
- **Nothing is written over.** `fels new` wants a folder that does not exist or is empty.
  `fels init` keeps every file that is there (it lists them) and stops when the folder has
  a fels.pkg.

The templates are part of fels.exe ([src/new_cmd.zig](../src/new_cmd.zig)); in them
`{{name}}`, `{{year}}` and `{{author}}` are filled in. Still to come: templates from a git
repository, and a game template.

## Diagnostics in the terminal

A diagnostic is a header, a location, a source snippet with the offending span
underlined, then any `note:`/`help:` lines:

```text
error: unknown type `Poin`
  --> demo.fels:4:8
  │
4 │     p: Poin = .{ .x = 1, .y = 2 };
  │        ^^^^ not a known type
  = help: did you mean `Point`?
```

`src/diagnostic.zig` renders it. The `Diagnostic` carries the parts: a primary span
plus label, secondary `labels` (other underlines, or the frames of a trace),
`notes`, and `helps`. `sema` attaches them through `emitErrorRich`: a type mismatch
underlines the value and names the expected type; an unknown name, function, or type
gets a `help: did you mean …?` (a Levenshtein search over the locals in scope,
top-level functions and consts, and the type names).

Color is on when stderr is a console, off when it's a pipe or file, so captured
output stays plain. `NO_COLOR` forces it off, `FELS_COLOR=1` forces it on (handy
when paging). `src/style.zig` makes the call and enables VT processing on Windows.
