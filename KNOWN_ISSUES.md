# Known issues

Collected on 2026-10-10 from the fix sessions, the agent reports and the docs review. "Verified" means
the case was run on the current `main` (`fb7556b`, before `f4c76b5`) and still fails. "Reported" means a session found
it and it was not re-checked.

## 1. Wrong code for valid programs (most serious)

These compile without a message and give a wrong result.

- ~~An integer literal stored into a wider or narrower type uses the wrong width.~~ Fixed (see
  0.3.1 in CHANGELOG.md): sema records the type a literal takes, so `k: i64 = -5;`,
  `e: i8 = -128;` and `big: u64 = 1 << 40;` are computed and stored at their type, also under
  `as`, in a generic struct's field default, in `5 + big` and in `1 << b`.
- ~~A local inferred from a literal, read as another integer type, has the wrong value.~~ Fixed on
  `main` (`f4c76b5`): `x := 5` is an `i32`, so `y: i64 = x;` is now a type error and takes
  `x as i64`.
- ~~`p == .green` on a plain enum compares against `undef`.~~ Fixed in `b159d1c`: the bare
  variant takes the enum type of the other operand (either side), and a name the enum does not have
  is an error. The same `undef` came from a bare variant in an array or slice literal and in a field
  default (`color: Color = .green`); fixed in `1baae6b`.
- ~~Returning `&local` or `&5` gives a dangling pointer.~~ Fixed in `1f2583b`: returning the
  address of a local, a parameter or a temporary is an error (docs/02, "Single Pointers"). Not
  checked yet: a slice of a local array (`return buf[:]`, which a function that `#run` calls uses
  to return bytes), an address passed through a call, and an address stored into a global or
  through a pointer.
- ~~An array whose length comes from a `#run` constant is empty.~~ Fixed (see 0.3.1 in
  CHANGELOG.md): the comptime VM computes such a constant and the type check runs again with it;
  an array literal with more elements than its array is now an error.

## 2. Compiler crashes and missing messages

- ~~`"xyz"[1]` stops the compiler without a message.~~ Fixed 2026-10-17: a string literal is
  indexed as the `[]const u8` it is, bounds-checked.
- **`core::ptr_from_int(*p, 16usize)` with a variable `p` stops the compiler without a message.**
  Verified. With a type argument it works.
- **`fels ir file.fels | head` panics** ("reached unreachable code"; earlier also "wrong File
  nonblocking flag") when the output pipe closes early. Verified. In `src/main.zig` `cmdIr`.
- ~~An error inside an imported module or the runtime is shown at line 1, column 1.~~ Fixed: every
  message is located in its own file's text.
- **Macro errors go to stderr only**; the language server does not show them. Reported.
- **`core::atomic_*` without its ordering argument compiles**: `core::atomic_load(&x)` and
  `core::atomic_store(&x, 5)` give wrong values instead of an error about the missing argument.
  Verified 2026-10-17.
- **`std.json` and `std.serde` cannot be imported together**: both declare a `Parser`, and the
  field tables the runtime gets for reflection are named after the type alone ("`<runtime>`:
  duplicate top-level declaration `__fld_Parser`"). Verified 2026-10-17.

## 3. Decisions to make

- ~~`x := 5`: a fixed `i32`, or a value that adapts when read?~~ Decided 2026-10-10: a variable is
  a fixed `i32`; a constant (`N :: 300`) keeps adapting and is checked where it is used.
- **Literal range checks** (now on `main`): a hex value too large for a signed type is rejected
  (`x: i32 = 0x80004005` needs `as i32`); `n == -1` with `n: usize` is rejected; literal arithmetic
  such as `b: u8 = 200 + 100` is not range checked: the program stores 44 (it crashed before the
  literal width fix), the comptime VM keeps 300.
- **`&x as usize` parses as `&(x as usize)`**; the cast of an address needs parentheses. Reported.
  Intended or not?
- **Type names collide across modules**: two modules cannot both declare a type of the same name.
  Reported by the docs review; docs/06 now says so.
- **`heap.dupe` takes no `borrow` parameter**, so a zone owned slice cannot be duplicated. Reported.

## 4. Missing features and limits

- No debug information: the LLVM backend emits no DWARF or CodeView, so a debugger shows no
  source lines and `fels build` has no `debug_info()`.
- Libraries (`b.static`, `b.shared`) cannot target Linux yet; the archive writer reads COFF objects.

- At compile time (`#run`, `#assert`), `&5` and `&(x + 1)` are refused as "could not be evaluated".
- The `atomic` field qualifier is not checked: a plain read or write of such a field compiles,
  and the qualifier is accepted on a local too.
- At compile time a write through `*Writer` into a `std.io.FixedBuf` stops with `OutOfBounds`, so
  `tests/fixtures/stdlib/fmt_tests.fels` runs natively only.
- A constant computed by a call or `#run` cannot be read by other compile time code
  (`SUM :: PLAIN + 3`).
- ~~`F :: seven; F()` (a constant holding a function) fails.~~ Fixed 2026-10-17: a constant
  naming a function is that function.
- No exponent notation for floats (`1e5`); the error now says so.
- `#extern("msvcrt", "strlen")` does not link; the docs use `lstrlenA` instead.
- ~~A bare variant does not take an optional enum type (`o: ?Color = .green;`).~~ Fixed: it
  takes the enum inside the optional, and `.circle(r)` does too.

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

## 6. Grammar (`tree-sitter-fels`)

- Looser than the parser: attributes on `Type as Iface` impl blocks; `unsafe a ?? b` binds a little
  differently; an inline error set `{ .a }` versus a body after a bare `!` is told apart only by the dot.
- Stricter than the parser: commas are required between aggregate literal elements; `#run <stmt>;`
  is only supported as `#run { }` or an expression statement; `if a | b | c {` cannot be parsed;
  `where` cannot be an error type name.
- Highlighting: `.name` in expressions is always an enum literal (never an error variant); a use of
  `T` in a body is a plain type; constants are recognized only by ALL_CAPS names.
- `scripts/parse_doc_blocks.py` keeps the `> ` prefix of fences inside block quotes, and its line
  numbers are one too high.

## 7. Tooling, release and the editor

- ~~`release.yml` never runs.~~ Fixed: the workflows download LLVM from llvm.org themselves
  (RELEASING.md, "LLVM in CI").
- The released compiler has a Windows SDK library path baked in (RELEASING.md, "Known gap").
- Many parallel Zig builds exhaust memory; the PC froze once today. Some test runs need `-j1`.
- The Zed extension's `runnables.scm` was never tried; `injections.scm` was removed because Zed
  rejected the empty file.
- The docs still contain four "complete programs" that are not whole (03:278, 06:113, 08:173,
  11:456).
