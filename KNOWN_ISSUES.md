# Known issues

Collected on 2026-10-10 from the fix sessions, the agent reports and the docs review, and
re-checked on 2026-10-17 against `main` (`58f686c`): what is fixed is gone from this list (the
changelog has it). "Verified" means the case was run then and still fails. "Reported" means a
session found it and it was not re-checked.

## 1. Wrong code for valid programs (most serious)

These compile without a message and give a wrong result.

- **A dangling pointer the frame check does not see.** Returning the address of a local, a
  parameter or a temporary is an error, and so is storing one into a global (outside `main`), but
  these are not checked yet: a slice of a local array (`return buf[:]`, which a function that
  `#run` calls uses to return bytes, or `S = buf[:]`), an address passed back through a call
  (`return id(&x);`), and an address stored through a pointer (`*pp = &x;`). Verified
  2026-10-19. The slice is left unchecked on purpose: a function that a `#run` calls returns the
  bytes it built that way, and telling those calls from run-time ones is not done yet.

- **On the comptime VM, a copy of an optional struct shares its payload with the original**:
  after `b := a;` for `a: ?P`, a write to `b`'s payload changes `a`'s. (Copies of structs,
  arrays and enum values are their own since 2026-10-19.) Reported 2026-10-19.

## 2. Compiler crashes and missing messages

- **A payload capture of one `match` arm and a loop variable of another with the same name**
  crash the code generator: `.int |i| => …` in one arm and `for i in 0..n { if i > 0 … }` in
  another. Name the loop variable differently. Verified 2026-10-18.

- **`Atomic(T)` methods take any `Native` type**, so `Atomic(f64).and` or `Atomic(bool).add` passes
  the type check and then fails in LLVM. The free functions in `std.atomics` give a type error.
- **`fels check` misses a field error in a named struct literal** ("missing field", "no field"):
  only lowering reports it, so `fels build` does.

- **`#derive(Neg)`, `Min`, `Max` and `Clamp` on a struct with a nested struct field** pass
  `fels check` and then crash the code generator ("Intrinsic has incorrect return type").
  `Ord`, `Hash`, `Add`, `Sub`, `Mul`, `Scale` and `Lerp` give a clear error there instead.
  Verified 2026-10-17.
- **`#derive(Eq)` on a struct with an enum field fails** with "no visible method or extension
  function `eq`": `fieldIsNamedStruct` in `src/parser.zig` takes any named type for a struct.
  Verified 2026-10-17.
- **Macro errors go to stderr only**; the language server does not show them. Reported.
- **`std.json` and `std.serde` cannot be imported together**: both declare a `Parser`, and the
  field tables the runtime gets for reflection are named after the type alone ("`<runtime>`:
  duplicate top-level declaration `__fld_Parser`"). Two types of one name in two modules are fine
  otherwise. Verified 2026-10-17.

## 3. Decisions to make

- **`&x as usize` parses as `&(x as usize)`**; the cast of an address needs parentheses. Intended
  or not?
- **`heap.dupe` takes no `borrow` parameter**, so a zone-owned slice cannot be duplicated into
  another arena ("zone-owned value from `scratch` can only be passed to a `borrow` parameter").
  Not a one-line fix: `dupe` copies shallowly, so with a borrowed source every element it copies
  is borrowed too, and `dupe(Group, …)` of structs holding slices (Strata does this) would be
  refused. A copy of a zone's bytes, or of elements without pointers, needs its own function.
  Verified 2026-10-17.

## 4. Missing features and limits

- **A lambda in a generic function cannot use the function's values**: `fn(v: $T) { g := fn()
  -> i32 { return v as i32; }; … }` is "unknown name `v`". The lifted lambda is checked and built
  once, not per instantiation. So a format with values cannot be in a generic function either
  (its code is such a lambda); that is refused with the reason.

- **`std.fs` does not read files in a `#run`**, even where the `read` capability allows it: its
  platform functions pass local arrays (`w: [1024]u16`) to the host, and the comptime FFI passes a
  pointer into compile-time memory as one scratch word. `#embed("path")` reads a file at compile
  time. Verified 2026-10-18.

- **`any_elem` and `any_deref` know only the slice and pointer types of struct fields**: the
  navigators are written from the program's struct declarations, before types are known, so
  `any_elem(core::any(xs[0..3]), 1)` and `any_deref(core::any(&p))` give `null`. Through a field
  (`any_field_at` and then `any_elem`) they work. The fix is an `Any` that carries its type's
  `TypeInfo` (docs/12, "`v.info()`"). Verified 2026-10-18.

- A zone handle is typed `Zone`, not `*Arena`, so a function that takes an `*Arena`
  (`strings::builder(&temp)`) refuses it; only methods reach the zone's arena. And no `std.io`
  function takes a `borrow` parameter, so zone memory cannot be printed directly.
- On Linux `fs::read_all` fails on `/proc` files: it sizes the file by seeking, and they have no
  size.
- Artifacts with the same name share one up-to-date stamp in `fels build`, so a target matrix
  that names each build `"tool"` rebuilds all of them every time. Give each artifact its own name.
- No debug information: the LLVM backend emits no DWARF or CodeView, so a debugger shows no
  source lines and `fels build` has no `debug_info()`.
- Libraries (`b.static`, `b.shared`) cannot target Linux yet; the archive writer reads COFF objects.
- At compile time (`#run`, `#assert`), `&5` and `&(x + 1)` are refused ("the comptime VM cannot
  run `f`"). Verified 2026-10-17.
- The `atomic` field qualifier is not checked: a plain read or write of such a field compiles,
  and the qualifier is accepted on a local too. Verified 2026-10-17.
- At compile time an enum with a payload, an optional or a union stored in arena memory (a
  `heap::alloc` or a `Vec` of one) stops with `TypeMismatch`: the comptime VM keeps arena memory
  as real bytes and lays structs, arrays and numbers out there, but not these. Verified 2026-10-19.
- At compile time `std.map.AutoHashMap` stops with `OutOfBounds`: it hashes a key's bytes through
  a pointer, and a value on the comptime VM has no bytes to read. `StrMap` works there.
  Verified 2026-10-19.
- At compile time a string value in a format (`"{name}"` with `name: []const u8`) stops with
  `TypeMismatch`: std.io prints a slice by reading its address and length as raw memory.
  Numbers and `bool`s print. Verified 2026-10-19.
- A constant computed by a call or `#run` cannot be read by other compile-time code
  (`SUM :: PLAIN + 3` with `PLAIN :: plain();`). Verified 2026-10-17.

## 5. Language server (`fels lsp`)

- Locals inside generic functions (also methods of generic structs such as `Vec`) have no types:
  no hover type, inlay hint or member completion.
- When checking a function stops at an error, the locals after that point have no types.
- Text scanning does not handle `(a + b).`, struct literal fields (`.{ .c = .`), `Vec(i32).`, hover on
  enum literals, or signature help for variant payloads.
- A slice returned by a generic call loses its `const` in hints (`[][]u8` instead of `[][]const u8`).
- References miss named call arguments, names inside `#quote` and macros, attribute arguments,
  `#import` path segments and `as` aliases (aliases cannot be renamed), and `#derive` generated
  methods.
- A file that does not parse has an empty reference index.
- A hard crash inside sema still ends the server.
- The outline of a file that uses `#quote` lists the injected `Ast*` prelude types as its own.
- The project root fallback for imports can accept an import that `fels build` rejects.
- The static data check of `fels check` is not part of the server analysis.
- A broken imported module replaces the importer's last good analysis.
- Go to definition on a derived method (`#derive`) returns nothing, and for a function a
  `#compiler` hook generated, hover shows the file's first line and definition jumps to line 0.

## 6. Grammar (`tree-sitter-fels`)

- Looser than the parser: attributes on `Type as Iface` impl blocks; `unsafe a ?? b` binds a little
  differently; an inline error set (`! { a, b }`) and a body after a bare `!` are told apart by
  precedence, where the parser takes `{` followed by a name and a `,` or `}` for a set.
- Stricter than the parser: commas are required between aggregate literal elements; `#run <stmt>;`
  is only supported as `#run { }` or an expression statement; `if a | b | c {` cannot be parsed;
  `where` cannot be an error type name.
- Highlighting: `.name` in expressions is always an enum literal (never an error variant); a use of
  `T` in a body is a plain type; constants are recognized only by ALL_CAPS names.
- `scripts/parse_doc_blocks.py` keeps the `> ` prefix of fences inside block quotes, and its line
  numbers are one too high.

## 7. Tooling, release and the editor

- The released compiler has a Windows SDK library path baked in: on a machine without that SDK
  version, linking programs needs a matching SDK or a compiler built with
  `-Dwindows-sdk-lib-path`.
- Many parallel Zig builds exhaust memory; the PC froze once. Some test runs need `-j1`.
- The Zed extension's `runnables.scm` was never tried; `injections.scm` was removed because Zed
  rejected the empty file.
- One program with a `main` in the docs does not build on its own: 11:458 needs the raylib
  bindings generated first.
