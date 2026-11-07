# Known issues

What doesn't work yet, roughly from most to least serious. Fixed issues move to the
[changelog](CHANGELOG.md).

## Wrong code for valid programs

These compile without an error and give a wrong result.

- **Some dangling pointers are not caught.** Returning the address of a local is an error, but
  a slice of a local array (`return buf[:]`), an address passed back through a call
  (`return id(&x);`) and one stored through a pointer (`*pp = &x;`) are not checked yet.
- **At compile time, a copy of an optional struct shares its value with the original.** After
  `b := a;` for `a: ?P`, writing to `b` changes `a`.

## Crashes and missing errors

- A `match` arm that captures `|i|` next to a loop variable `i` in another arm crashes the code
  generator. Name one of them differently.
- `Atomic(f64).and`, `Atomic(bool).add` and the like pass the type check and then fail in LLVM.
- `fels check` misses a wrong or missing field in a named struct literal; `fels build` reports it.
- `#derive(Neg)`, `Min`, `Max` and `Clamp` on a struct with a struct field crash the code
  generator.
- `#derive(Eq)` on a struct with an enum field fails with "no visible method `eq`".
- `std.json` and `std.serde` can't be imported together: both have a `Parser`.
- Macro errors are printed, but the language server doesn't show them.

## Open design questions

- `heap.dupe` can't copy a zone's slice into another arena: it takes no `borrow` parameter.

## Missing features and limits

- `std.fs` can't read files in a `#run`. `#embed("path")` reads a file at compile time.
- `any_elem` and `any_deref` work only through struct fields.
- A zone handle isn't an `*Arena`, so a function that takes `*Arena` refuses it, and zone
  memory can't be printed with `std.io` directly.
- On Linux, `fs::read_all` fails on `/proc` files.
- In `fels build`, artifacts with the same name rebuild each other every time. Give each its
  own name.
- `-g` on Windows needs the Windows SDK's import libraries. Locals of nested blocks show in the
  function's scope, and bit fields of a `#packed` struct aren't shown.
- Libraries (`b.static`, `b.shared`) can't target Linux yet.
- Without an operating system (`--target uefi`, `--target freestanding`):
  - a kernel turns SSE (x86-64) or FP and SIMD (aarch64) on before its first Fels call, as
    `examples/kernel` and `examples/kernel_aarch64` do;
  - `std.uefi` covers the console, the keys and the screen only;
  - on aarch64, `memcpy` and friends copy a byte at a time, and structs passed by value to or
    from C don't follow AAPCS64 yet.
- aarch64 is supported for UEFI and freestanding programs only, not for Linux or Windows.
- At compile time:
  - `&5` and `&(x + 1)` are refused;
  - an enum with a payload, an optional or a union in arena memory stops with `TypeMismatch`;
  - `AutoHashMap` stops with `OutOfBounds` (`StrMap` works);
  - a string in a format (`"{name}"`) stops with `TypeMismatch` (numbers and `bool`s print);
  - a constant computed by a call or `#run` can't be read by other compile-time code.
- The `atomic` field qualifier isn't checked yet.

## Language server (`fels lsp`)

- Locals in generic functions (and methods of generic structs like `Vec`) have no types: no
  hover type, inlay hint or member completion.
- After an error in a function, the locals that follow have no types.
- Completion doesn't understand `(a + b).`, fields in a struct literal or `Vec(i32).`.
- Go to definition doesn't work on fields, methods, enum literals and `#derive` methods.
- In the Fels repository, the server reads the installed standard library, not `lib/std`.
- `#import std.` doesn't complete module names.
- References miss named arguments, names in macros, attribute arguments and `#import` paths.
- A crash in the type checker ends the server.

## Editor grammar (`tree-sitter-fels`)

- A few constructs parse slightly differently than in the compiler, and names with `$(…)`
  splices (macro templates) aren't parsed. Highlighting treats every `.name` as an enum literal.

## Releases

- The released compiler expects the Windows SDK version it was built with; on another version,
  linking needs a matching SDK or a compiler built with `-Dwindows-sdk-lib-path`.
