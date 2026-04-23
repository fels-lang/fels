# Known issues

Collected on 2026-10-10 from the fix sessions, the agent reports and the docs review, and
re-checked on 2026-10-17 against `main` (`58f686c`): what is fixed is gone from this list (the
changelog has it). "Verified" means the case was run then and still fails. "Reported" means a
session found it and it was not re-checked.

## 1. Wrong code for valid programs (most serious)

These compile without a message and give a wrong result.

- **A dangling pointer the frame check does not see.** Returning the address of a local, a
  parameter or a temporary is an error, but these are not checked yet: a slice of a local array
  (`return buf[:]`, which a function that `#run` calls uses to return bytes), an address passed
  back through a call (`return id(&x);`), and an address stored into a global or through a pointer
  (`G = &x;`). Verified 2026-10-17. The slice is left unchecked on purpose: a function that a
  `#run` calls returns the bytes it built that way, and telling those calls from run-time ones
  is not done yet.

- **Structs passed by value to C on Linux follow the Win64 rules.** The SysV classification is not
  built: `abi.zig` applies its Win64 `classify` on every target. A `Vector2` (`{ float, float }`)
  goes as an `i64` where SysV wants one XMM register, and a `{ double, double }` goes by reference
  where SysV wants two. Calling a real Linux C object under WSL gave wrong values for both; a
  `Color` (four bytes) happens to match. Verified 2026-10-17.

- **`core::sizeof(byte)` is 8.** `byte` is laid out like a pointer: `[4]byte` takes 32 bytes, and
  `byte` fields and elements sit 8 bytes apart. `lowerNamedType` in `src/ir.zig` has no case for
  `byte`. Verified 2026-10-17.
- **A sub-byte local can compare wrong.** A local `i3` is stored with an `i8` store into an `i3`
  slot and read back as `i3`; in one probe `x != -2` was true for `x: i3 = -2`. Sub-byte values are
  not range checked either (`x: i3 = -5` is accepted), because sema reads `i1`–`i7` as `i8`.
- **A write to a constant reached through a module name compiles**: `com::IID_IUnknown.data1 = 5;`
  passes and crashes at run time, and `&com::IID_IUnknown` is a `*Guid`. The same write through a
  local or an imported name is refused. Verified 2026-10-17.
- **A `#run { }` block inside a function runs when the program runs**, as ordinary code, not on the
  comptime VM. `#run expr` runs at compile time. Verified 2026-10-17.
- **A borrowed value can be stored into a global** with a plain assignment (`saved = name;`),
  though a store through a pointer is refused. Verified 2026-10-17.
- **`[]const T` converts to `[]T` without a word**, in an assignment and as an argument.
  (`*const T` to `*T` is refused.) Verified 2026-10-17.

## 2. Compiler crashes and missing messages

- **A payload capture of one `match` arm and a loop variable of another with the same name**
  crash the code generator: `.int |i| => …` in one arm and `for i in 0..n { if i > 0 … }` in
  another. Name the loop variable differently. Verified 2026-10-18.

- **`main :: fn() { … }` without a return type fails to build on Windows** with an LLVM verifier
  error (`%ret = call void @main()`): the entry point expects an `i32`. It builds for Linux.
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
- **An unknown escape such as `\xZZ`** in a string is kept as literal text, with no error.

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
- At compile time a write through `*Writer` into a `std.io.FixedBuf` stops with `OutOfBounds`, so
  `tests/fixtures/stdlib/fmt_tests.fels` runs natively only. Verified 2026-10-17.
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

- The released compiler has a Windows SDK library path baked in (RELEASING.md, "Known gap").
- Many parallel Zig builds exhaust memory; the PC froze once. Some test runs need `-j1`.
- The Zed extension's `runnables.scm` was never tried; `injections.scm` was removed because Zed
  rejected the empty file.
- One program with a `main` in the docs does not build on its own: 11:458 needs the raylib
  bindings generated first.
