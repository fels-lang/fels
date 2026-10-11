# Changelog

Notable changes, newest first. Versions follow [SemVer](https://semver.org/): while
the major version is `0`, any minor bump may break source compatibility.

## Unreleased

### Added

- **`std.csv` reads CSV text**: records of fields between a comma, a semicolon (as German
  spreadsheets write it) or a tab, with fields in quotes as RFC 4180 has them. `reader`, `next`
  and `done` go record by record, `records` reads them all, `guess_separator` looks at the first
  line. Empty lines and a byte order mark are skipped; an open quote is
  `CsvError.unterminated_quote`. The reader's type is `CsvReader`.
- **`std.float`: `exp`, `ln` and `pow` for `f64`**, written in Fels, so a program needs no
  math library for them (`core::pow` becomes a call of the C library's `pow`, which a Fels
  program does not link).
- **Folders in `std.fs`**: `make_dir` (a folder that is there already is fine), `make_dirs`
  (the folders above it too) and `remove_dir` (an empty folder).
- **The arguments of a program**: `process::args(&a)`, the program first. On Windows the
  command line is split as the C runtime splits it, and `split_command_line` does that for
  any line.
- **Calendar dates in `std.time`.** `Date` is a day as the number of days since 1970-01-01:
  `time::date(y, m, d)` (null for a day that does not exist), `parts`, `weekday`, `add_days`,
  `add_months` (the day stays inside the month), `add_years`, `days_until`, `parse_date` and
  `format_date` for `YYYY-MM-DD`, `today_utc`, `is_leap_year`, `days_in_month`.
- **`fels add` without a version writes the range of the version it found**: `version "^0.4"`
  for 0.4.2, so a later `fels update` does not bring a version that breaks the project.
- **A string literal is also a C string**: its bytes end in a NUL that its length leaves out, so
  `"title".ptr` can go to a `const char*` parameter. Before, C read on past the literal.
- **A match arm can name several enum variants**: `.buy, .sell => …`, as integer and string
  patterns could already. A binding `|x|` still needs an arm of one variant.

### Fixed

- **Types of different modules may have the same name.** Two modules that each declared a
  `Point` (or a private `State`), or a program with a `Reader` next to `#import std.fs` (std.io
  has a `Reader`), or std.math with a binding that has its own `Vec2`, stopped with "duplicate
  top-level declaration". A type whose name another file declares too is now qualified, as a
  function already was, and each file sees its own, also as the type argument of a generic
  (`Vec(Item)` in a field) and in a `match` on an enum.
- **Arena memory at compile time.** On the comptime VM (`#run`, `fels test --comptime`)
  slicing a string (`s[1..3]`) failed with "TypeMismatch", and so did `heap::alloc(T, ...)`, a
  `Vec` of slices, a pointer cast (`p as *T`, `p as usize`) and a negative number read back from
  an arena. They now work as in a compiled program.
- **A float compared with a float literal as integers on the comptime VM** when the VM did
  not know the type of the other side (`size := want + 0.0; if size < 1.0 …`): "TypeMismatch".
- **The comptime VM leaked** the names and strings of every `#extern` call it made.
- **A local named like a builtin** (`any`, `narrow`) was declared, but using it said "expected
  `void`": the name was read as the builtin first. The local comes first now.
- **A free function hid a method of the same name from another module.** With
  `alloc_bytes :: fn(n: i32) -> i32` in a program, `a.alloc_bytes(4)` (std.heap's method on
  `Arena`) was "no visible method", and where it was found, the call could go to the free
  function. A candidate that cannot take the receiver is now passed over, and the call goes to
  the method that was chosen.
- **A type of another module as a type argument** (`vec::make(money::Currency, &a)`,
  `first(shapes::Point, xs)`) was "expected a type argument".
- **An enum literal where an optional enum is expected** (`return .sell;` from a
  `-> ?Kind`, `k: ?Kind = .sell;`) was read as an error value and did not compile.
- **A keyword in an import path** (`#import app.import.prices;`, for a folder `import`) said
  only "expected ; after import". It now says that the name is a keyword and the file or folder
  needs another one.
- **`fels update` said "everything is at the newest version"** right after it took a new
  one, when a range in fels.pkg had changed. It now tells the change against fels.lock as it
  was (`imgui: 0.2.0 -> 0.3.0`).
- **`fels test --comptime` skipped a test named like a function of another file** (a test
  `helper` next to `mathx::helper`) with "InvalidInstruction"; it runs now.
- **Assigning a param did nothing in a compiled program.** `x = 5; return x;` returned the
  value passed in, and so did a change through a field of a struct param (`p.v = 5`). Every
  param now has a slot of its own. (The comptime VM was right.)
- **A `*Self` method called on a struct param** (`p.get()` with `p: P`) got an invalid
  `self`: garbage values or a crash.
- **A constant made of typed values was 32 bits wide.** `MIN :: -9223372036854775807i64 - 1i64;`
  read as 0 in a compiled program; it now has the type of its values, as on the comptime VM.
- **Comparing the variable of a `for` loop over strings** (`for t in tags { if t == tag … }`)
  stopped the compiler with an internal error. The loop variable is now declared like any
  other local.
- **Slices are checked as slices**: `s[len..len]` (empty, at the end) panicked with "index out
  of bounds" in a debug build, while `s[a..b]` with `b` past the end or before `a` was not
  checked at all. Now `a <= b <= len` holds, in every build, or the program panics with
  "slice out of bounds".
- **`==` and `!=` on two optionals** (`a == b` with `a, b: ?i64`, or optional structs) did not
  compile, and failed on the comptime VM. Both null is equal, one null is not, both set
  compares the values.

## 0.6.1 — 2026-10-11

Fixes: `fels test` works on a project with files that have no tests, and a
"did you mean" hint no longer offers the name that was not found.

### Fixed

- **`fels test` failed on a file without tests** ("unknown function `__fels_test_from`"), so a
  project with such a file had errors. A file without tests compiles as it is again.
- **"did you mean `Build`?" offered the name that was not found.** A name that a module
  imported whole declares (`#import std.build;`) now gets the way to reach it:
  `` write `build::Build`, or import it with `#import std.build.{ Build };` ``. A suggestion is
  only a name the file can write, and a built-in type after `!` says it is not an error type.
- **`fels new --license Apache-2.0` wrote the LICENSE with Windows line ends**; it has LF like
  the other files now.

## 0.6.0 — 2026-10-11

`fels test` runs the tests of a project as programs, so they can read files and call C, and
`fels new` starts a project from a template.

### Added

- **`fels new` and `fels init`** start a project from a template: a program (`--app`, the
  default), a library (`--lib`) or bindings to a C library (`--cbind`). Each comes with
  tests that pass, a build.fels, a README, a .gitignore and a license (MIT, Apache-2.0 or
  none), and `fels new` runs `git init`. `fels init` fills the current folder and keeps the
  files that are there. See docs/15_tooling.md §9.
- **`fels test`** runs the `#test` functions of a project: of `src/`, or of the files and
  folders you name. Each file's tests are built into a program and run, so a test can read and
  write files and call C. A failed test shows each check that failed and what it printed; a
  crash or a panic ends only its own test. The test programs link with what the packages and
  the project's build.fels provide. `fels test --comptime` runs the tests on the comptime VM
  instead, as a fels without LLVM does. See docs/17_testing.md.
- **A project imports its own package by name.** A library with `#package mathx` can write
  `#import mathx;` in its examples and tests, in `fels build`, `fels test` and the editor.

### Changed

- **`fels build` skips a `#test` the comptime VM cannot run** (it calls the OS, writes a
  global, ...) with a note, instead of failing the build. `fels test` runs it.

### Fixed

- **A denied or failed compile-time FFI call leaked its message.**

## 0.5.0 — 2026-10-11

The editor knows the packages, the package manager gets its remaining commands, and the build
system gets test steps, targets and up-to-date builds.

### Changed

- **`.gab` files are no longer read**, as 0.4.0 announced. An import that only finds a `.gab`
  file, and a folder with only a `build.gab`, say to rename the file to `.fels`.

### Added

- **The editor knows the packages.** The language server reads `fels.pkg` (without running
  git), so imports of packages resolve in the editor; a package that is not fetched yet says
  to run `fels fetch` at its import.
- **`fels remove`, `fels why` and `fels vendor`.** `vendor` copies the git packages into
  `vendor/`, and builds then take them from there.
- **`fels build --offline` and `--frozen`.** Offline never runs git; frozen stops when
  `fels.lock` would change.
- **A package's build.fels provides libraries to its users** with `b.provide_lib_path`,
  `provide_link` and `provide_runtime_file`, running with the capabilities `fels.pkg` grants.
- **Test steps** find tests in sub-folders (`recursive`), filter them (`filter`, or
  `fels build test -- <text>`), choose the optimization and link libraries; a failing test
  shows its exit code and output, and tests see the project's packages.
- **`a.target(.linux | .linux_gnu)`, `a.sysroot`, `a.strip()` and `b.host_os()`** in build.fels.
- **Up-to-date artifacts are not built again**, and `fels build --rebuild` builds anyway.
- **`print` and `println` work at compile time**, in build.fels and in `#run`.

### Fixed

- **An error in an imported file was shown at 1:1** with an empty line; it shows the file's own
  line now.

## 0.4.0 — 2026-10-10

**Gabbro is now called Fels.** The compiler is `fels.exe`, source files end in `.fels`, the
build script is `build.fels`, the environment variables are `FELS_*` (`FELS_HOME`, `FELS_STD`,
`FELS_LLVM`, ...) and the repository is `github.com/fels-lang/fels`. Files ending in `.gab`
and a `build.gab` are still read, with a note to rename them, until 0.5.0.

Fels gets a package manager, and the build system gets most of its API.

### Changed

- **The name.** See above. The entries below 0.4.0 keep the old name.

### Added

- **Packages.** `fels.pkg` lists the packages a project uses (`#use name from "source"
  version "^1.2"`), from a folder or a git repository; `fels add`, `fels fetch` and
  `fels update` manage them, and `fels.lock` records the exact commit and a content hash of
  each. A package's compile-time code may only call into host libraries that `fels.pkg` grants
  it (`may ffi("user32")`), a package that needs more stops the update, and the VM enforces
  the grant. See docs/16_packages.md.
- **Typed build options.** `b.option_bool`, `option_int`, `option_string` and `option_choice`
  declare an option with a default and a help text. `fels build --list` shows them, and a `-D`
  option the script does not declare, or a value of the wrong kind, stops the build with a
  message that lists the options.
- **`a.link_artifact(lib)`** links a static or shared library the same build makes. The library
  is built first, each artifact once, and a DLL is copied next to the program.
- **`fels build install`** copies the artifacts marked with `install()` into an install prefix
  (`bin/` and `lib/`), with `b.install_file`, `b.install_dir`, `b.install_prefix` and
  `--prefix`.
- **`define`, `define_int` and `define_bool`** pass constants to the program through a generated
  `build_options` module (`#import build_options;`). `define` was recorded and then ignored.
- **`a.add_module(name, dir)`** maps an import name to a folder, so `#import name.x` reads
  `<dir>/x.fels`.
- **Build steps.** `b.step(name, description)` runs the artifacts and steps it depends on, then
  its actions: `command` and `run` (with `arg`, `arg_output`, `cwd` and `env`), `copy_file`,
  `copy_dir`, `write_file`, `remove` and `print`. `a.after(step)` generates code before an
  artifact compiles, `b.default_step` picks what a bare `fels build` runs, and `run_step`
  returns its command for arguments, a working directory and environment variables.

### Fixed

- **`b.static(...)` wrote a DLL named `.lib`**, which no linker can use as a static library. It
  now writes an archive. Only the library's `#export`ed symbols are visible to the program that
  links it, so the runtime both carry no longer clashes, and the libraries its `#extern`
  functions come from are linked along without being named.
- **A string's escapes were not resolved at compile time.** In the comptime VM `"a\nb\"c"` was
  7 bytes instead of 5, and a string a `#run` computed kept its backslashes. `s == "a\n"` also
  compared against the backslash and the `n`.

## 0.3.1 — 2026-10-10

Fixes for programs that compiled without a message and gave a wrong result: integer literals of
types other than `i32`, `p == .green` on an enum, and arrays sized by a `#run` constant.
Returning the address of a local is now an error. This is the first release built by the release
workflow on GitHub.

### Changed

- **Source change:** a function cannot return the address of a local, a parameter or a temporary
  (`&x`, `&p` of a parameter, `&s.field` or `&arr[i]` of a local, `&5`, `&f()`, `&(x + 1)`), directly,
  inside a returned struct or array literal, or through a local that was given it (`q := &x;
  return q;`). It compiled before and the pointer dangled once the function returned. Addresses of
  globals, through pointer parameters, into slices and from an allocator or a zone are unaffected.

### Fixed

- `p == .green` on a plain enum compared against an undefined value, so the result was wrong or
  changed with `-O`. The bare variant now takes the enum type of the other operand, on either side
  of `==` or `!=`, and a name the enum does not have is an error.
- A bare variant as an element of an array or slice literal (`a: [3]Color = .{ .red, .green, .blue }`)
  or as a field default (`color: Color = .green`) stored an undefined value.
- **An integer literal stored into a type other than `i32` had the wrong width.** `k: i64 = -5;`
  gave `k != -5`, `e: i8 = -128;` wrote four bytes into its one byte slot, and
  `big: u64 = 1 << 40;` stored 0, at every optimisation level and in the comptime VM. A negated
  literal and arithmetic on literals were computed and stored as an `i32` whatever type they were
  given, and so was a constant without a type (`A :: 3;`, `x: i64 = A - B;`). They now take
  that type in a typed declaration or global, an assignment, a struct or array literal, a call
  argument, a return value, a comparison with a typed operand, a cast
  (`(1 << 40) as u64`, `0xFFFFFFFF as u64`) and the default of a generic struct's field. In
  `5 + big` the literal takes the type of `big` (the expression was an untyped literal, so
  `x := 5 + big` made `x` an `i32`), and in `1 << b` with `b: u8` the shift is no longer done in
  8 bits.
- **An array whose length was a constant computed at compile time was empty.** With
  `N :: #run four();` (or `N :: four();`), `a: [N]i32 = .{ 1, 2, 3, 4 };` was a zero length array
  and `a[3]` panicked at run time; the same held for a global, a parameter and a struct field.
  Such a constant is now computed by the comptime VM before the type check that sizes the array.
  A part that could not be folded no longer counts as 0 either (`(#run four()) + 1` was 1), and a
  length that is negative or not an integer is an error.
- **An array literal with more elements than its array was accepted.** `x: [3]i32 = .{ 1, 2, 3, 4 };`
  dropped the fourth element without a word; it is now an error that names the array type
  (messages about an array type used to print it as `T`). A shorter literal is still zero filled.

## 0.3.0 — 2026-10-10

Editor support and a stricter rule for integer literals.

- The language server now finds references, renames across the project, highlights a name,
  searches symbols, completes members after `.`, shows signature help and inlay hints for inferred
  types, and keeps answering while the file being edited does not parse.
- **Source change:** an integer literal has to fit the type it takes, and a local inferred from a
  literal is an `i32`. `x := 5; y: i64 = x;` now needs `x as i64`; before, it compiled and read the
  value with the wrong width. `b: u8 = 300;` and `x := 5000000000;` are errors (the second suggests
  a suffix). A constant (`N :: 300`) still takes its type where it is used.
- Nine more fixes, among them two that gave wrong results without a message: `err == .x` in a
  `catch` through an inferred error set, and `&5`.
- The code examples in the docs were checked against the compiler and corrected.

### Added

- **`gabbro lsp` helps while typing.** Completion after `expr.` lists the fields, methods,
  interface methods and `self` functions of the expression's type (through pointers and along
  chains such as `a.b.`, `f().` and `a[i].`), the variants after `Type.`, the associated
  functions after `Type::`, and the variants of the expected enum after a `.` that starts an
  enum literal (`m == .`). Signature help shows the parameters of the function, method,
  interface method, function pointer field, macro or `#extern` being called, with the active
  one. Inlay hints show the inferred type after `x := …` and after `for`, `match`, `if` and
  `while` captures. Hover on a local, a parameter or a field shows `name: Type`.
- **Answers while the file does not parse.** Code is broken most of the time during typing
  (`p.` alone does not parse), so the server keeps the last analysis whose text parsed and
  answers completion, hover, signature help and inlay hints from it, with positions mapped
  through the edits. Diagnostics still come from the current text.
- **`gabbro lsp` finds references, renames, highlights and searches symbols across the project.**
  `textDocument/references` lists every place that refers to the name under the cursor, in all `.gab`
  files of the project (the folder with `build.gab`), not only in the files the open document
  imports: uses in expressions, type names in fields, parameters, casts and generic arguments,
  fields in accesses and `.{ .x = … }` literals, method calls (struct methods, interface methods and
  their implementations, functions called as methods), enum and error variants (`.red`, `Color.red`,
  `match` arms, `fail .Bad`), the names of `#import a.{ name }` and `alias::name`. Names are told
  apart by meaning: two locals `x` in two blocks are two names. `textDocument/rename` (with
  `prepareRename`) edits all of them, also in files that are not open, and refuses names declared
  in `std` or by an `#extern`, `main`, keywords and built-in names, and a new name that would change
  what another name means. `textDocument/documentHighlight` marks the name in the current file
  (written or read), and `workspace/symbol` searches the top level declarations of the project. The
  server keeps a reference index per file and rebuilds it only when the file or a module it imports
  changes: in the 55 files of `examples/` a first search takes 30 to 65 ms in a release build, a
  repeated one about 4 ms.

- **Docs: the examples match the compiler.** 25 code examples showed syntax the compiler rejects
  (a Zig style quick example in docs/01, `Type { f = v }` literals, `if x := e |err|`, builtins
  without `core::`, `#import std.build;` with the wrong parameter type and others). They are
  corrected, 16 of the 20 complete programs in the docs now build, and features that are only
  planned (`#provided`, `#for` over fields, parts of the build system) are marked as planned. The
  docs also say now that there is no exponent notation, no `else if` after `#if`, which `match`
  patterns exist, and that `macro` is not a reserved word.

### Fixed

- **`1e5` was reported as "unknown type `e5`".** Gabbro has no exponent notation, and the lexer
  reads `1e5` as the integer `1` with the suffix `e5`. The error now says that exponent notation
  is not supported and offers the number written out (`100000.0`; `1.5e3` gives `1500.0`).
  Hex literals such as `0x1e5` are not affected.
- **An error in a top level constant was reported twice.** The initializer is checked twice, and
  each check added the same message. The checker now drops a message it has already reported at
  the same place.
- **`x := 42; p: *i32 = &x;` was a type error about `*integer literal`.** A local inferred from an
  unsuffixed literal is stored as an `i32` (`f64` for a float literal), but its address was typed
  as a pointer to the literal, which no pointer type accepted, so `&x` could not be passed to a
  `*i32` parameter or compared with a `*i32` either. `&x` is now a `*i32` (`*f64`), and `x`
  itself is an `i32` (see the entry on integer literals below): reading it as an `i64` takes
  `x as i64`.
- **A `-> void ! E` function needed an explicit `return;` at its end.** Without one it was refused
  with "may not return a value on all code paths", although there is no value to return. Running
  to the end of such a function is now success and compiles to the same code as `return;`. A
  fallible function that returns a value still has to `return` or `fail` on every path.
- **`err == .x` in a `catch` was always false when the error came through an inferred error set.**
  Each error set numbered its own variants, and an inferred set (`-> T !` with nothing after the
  `!`) has none, so the comparison was made against nothing, with no diagnostic. The same numbering
  went wrong in related cases: `fail` in a function with an inferred set gave every variant the
  same number, as did `fail` in a function with an inline set (`! { .p, .x }`), and an error passed
  through an inferred set into a function with another set was read against that set's positions
  (an `.x` could compare equal to `.q`). Errors are now numbered by their variant's name, the same
  in every set, so `fail`, `?`, `catch` and `err == .x` agree whatever sets an error passes through,
  and the comptime VM (`#run`, `#assert`) agrees with the compiled code. A `main` that fails still
  exits with its error's position in its own set.
- **`&5` compiled and read garbage.** `p := &5; return *p;` exited with 72. A literal has no
  storage, and the address the backend made for it was `undef`; the same went for `&-5`,
  `&(2 + 3)` (constant folding turned the temporary back into a constant), `&"text"`, `&true`,
  `&Color.blue` and an array's `&a.len` and `&a.ptr`, some of which crashed or failed to
  compile. These now point at a temporary that holds the value, as `&f()` and `&(x + 1)`
  already did. An unsuffixed literal's temporary has the literal's default type, so `&5` is a
  `*i32` and can be passed where one is expected (it was a `*integer literal`, which no
  parameter accepted); write `&5i64` for a `*i64`.
- **A top level constant above the function it calls was an internal compiler error.**
  `X :: #run f();` or `X :: f();` declared above `f` stopped with "function symbol has no
  signature record", and `A :: B + 1;` above `B :: 6;` failed with "operator `+` requires numeric
  operands, found `B`". The checker typed each constant as it reached it, before the functions
  and types declared below had been read. It now types the constants after every signature and
  layout, a constant that uses a later one types that one first, and a constant whose value
  depends on itself (`A :: B; B :: A;`) is reported as such.
- **`p.x` read garbage when a local or parameter had the name of a type.** With
  `p :: struct { x: i32 }`, `p.x` on a parameter `p: *p` or a local `p := &v` was read as the
  variant `x` of the type `p`, not as the field (two such programs exited with 24 and 96 instead
  of 5 and 6). The local or parameter now wins, as it already did in the checker. A store through
  an array's `ptr` (`a.ptr.y = 9`), which crashed, now writes `a[0].y`.
- **A generic function whose parameter is `*$T`, `[]$T` or `?$T` rejected every argument.** Only
  a whole `$T` parameter type introduced `T`, so `bump :: fn(p: *$T)` was not generic: `bump(&y)`
  failed with "expected `*T`, found `*i32`", and a `T` in the return type or the body was an
  unknown name. A `$T` anywhere in a parameter's type (`*const $T`, `[N]$T`, `[]*$T`,
  `*List($T)`) now introduces `T`, and the call binds it from the argument at any depth. A `null`
  passed to `?$T` binds nothing, so the next argument decides `T`. `gabbro lsp` declares such a
  `T` at its `$T`.
- **An integer literal that did not fit its type was truncated without a word.** `b: u8 = 300;`
  stored 44 and `y: i32 = 5000000000;` stored 705032704, although a literal coerces to an integer
  type only when its value fits. Now it is an error that gives the range of the type, wherever a
  literal takes its type from the context: declarations, assignments (`+=` too), arguments,
  returns, struct fields and their defaults, array elements, `?T`, `??`, enum and error payloads,
  `if` and `match` values, match patterns, and the other operand of an operator (`b < 256` with
  `b: u8` compared with 0). `-128` (minus applied to `128`), hex, binary and `_` are read as
  written, a suffixed literal has to fit its suffix (`256u8`), and a constant without a type
  (`N :: 300;`) is checked like its literal; `300 as u8` still truncates on purpose. A literal with
  no type to take is an `i32`, which is how it is stored: `x := 5;` makes `x` an `i32` (it stayed
  an untyped literal, so `b: u8 = x` was accepted and wrote four bytes over the one-byte `b`), and
  `x := 5000000000;` or `BIG :: 5000000000;` is an error that suggests a suffix (`5000000000i64`).
  The runtime's panic exit code and `std.net`'s `INVALID_SOCKET` got the suffixes they needed, and
  messages no longer call `byte` and `addr` `T`.

## 0.2.2 — 2026-10-10

A release for editor support and five fixes. `gabbro lsp` now understands imports, so the language
server in Zed and other editors no longer reports errors on files that import `std` or other
modules. The tree-sitter grammar and a Zed extension live in their own repositories:
`gabbro-lang/tree-sitter-gabbro` and `gabbro-lang/zed-gabbro`.

### Changed

- **`gabbro lsp` is project aware.** It analyzes each open file together with the modules it
  imports (`std` and sibling `.gab` files), uses the editor's text for imported modules that are
  open, publishes the errors of each module to its own file, and supports go to definition, hover,
  completion and the outline across files. Before, an imported name such as `Mutex` was reported as
  unknown in a file that `gabbro build` accepts.

### Fixed

- **A `#run` that fills a big array made the build take seconds to minutes.** The comptime VM was never
  the slow part (it stores an element in O(1)): the function the `#run` evaluated stayed in the program,
  and compiling a function that returns a large array by value is superlinear (15 s for 4096 `u32`s,
  more with a wide CPU's vector registers). Internal functions nothing refers to are now removed before
  code generation, so a table built by `#run` costs only its data.
- **A function returning a big array or struct by value was slow to compile.** A return over 128 bytes
  now goes through a hidden leading pointer (`sret`) on every call path (direct calls, `fn` values,
  closures, interface methods, fallible returns), and such a value is copied or zeroed with one inline
  `memcpy`/`memset` instead of element by element. A function returning `[10000]u32` and its callers
  now compile in about 0.2 s at `-O2`. The machine-level convention is unchanged (LLVM already passed
  such returns through a hidden pointer), so `#export`ed functions keep their C ABI.
- **A struct with an `i64` after a smaller field was measured 4 bytes short during lowering.** The
  backend sized types with LLVM's default data layout, where `i64` is 4-aligned (`{ i32, i64 }` came
  out 12 bytes, not 16). A closure environment on a zone was allocated too small, and a payload enum
  carrying such a struct had too little room, so building one wrote past its stack slot. Sizes now
  come from the target's layout.
- **gabld wrote a DLL that does not load when the DLL imports nothing.** Its IAT data directory had an RVA
  but size 0, which the Windows loader refuses (error 87). The directory is now left empty in that case.
- **A literal argument to an interface method arrived as garbage.** `sh.one(1u32)` through a
  `*Shape` passed the literal as a zero-width `i0 0`, so the method read whatever was in the
  register; a variable argument worked. The call now takes each argument's type from the
  interface method's signature, as a call through a `fn` pointer does. Broken in 0.2.1.

## 0.2.1 — 2026-10-10

### Fixed

- **The release binaries crashed on many CPUs.** `scripts/package.ps1` built for the CPU of the machine
  that ran it, so `gabbro.exe` of 0.2.0 contained AVX-512 code and stopped with "illegal instruction"
  (exit code 0xC000001D) on any CPU without it, for example on some GitHub Actions runners. The release
  is now built for the baseline x86-64-v2 CPU. If you downloaded 0.2.0 and it does not start, replace it.

## 0.2.0 — 2026-10-10

A feature release. It adds what a real Windows program needs: aggregate data in the image,
compile-time tables, a thread/lock/COM standard library, and layout queries; and it fixes
several miscompilations found while building one (`?` skipping `defer`, arrays of closures,
`f(*p)` parsing).

### Added

- **Static aggregates.** A top-level global can now hold a struct, an array, a function
  pointer, the address of another global, `null`, a string or a payload-less enum
  variant, nested to any depth: `VT: Vtbl = .{ add, 7u32 };`, `A: Node = .{ 1, &B };`.
  The initializer is data in the image — laid out by the compiler, placed by the linker —
  and nothing runs at startup. A literal reads exactly as it does for a local; a mistake
  (a value that does not fit, an unknown or duplicate field, a missing field, a lambda or
  generic function, a pointer to a non-global) is a compile error pointing at the value.
  A typed scalar global is checked the same way, where `i8 = 128` used to be accepted.
  Before this, only a scalar fitted ("constant initializer could not be folded").
- **`gabbro check` reports an invalid static initializer**, with the source line, instead of
  saying "ok" and leaving the mistake for the build. A value that needs the compile-time
  evaluator (a `#run`) is still checked at build time.
- **A `#run` can return a whole table, struct, enum value, function pointer or string**, and it
  becomes the global's initial value — data in the image, laid out like a literal, nothing run at
  startup: `CRC: [256]u32 = #run make_crc_table();`, `SQUARES :: #run make_squares();` (an
  untyped constant takes the type of the call), `W: Wrap = .{ #run origin(), #run primes(), 5 }`.
  Before, only a number could ("a `#run` constant must evaluate to a scalar value"). A result
  that cannot be data is refused with the place in the value that is wrong: a pointer into
  compile-time memory, a variant with a payload, a lambda, a slice of anything but bytes, a
  number the type cannot hold (`in [0]: the value 300 does not fit in u8`).
- **Compile-time code reads static data.** A `#run` or `#assert` can index a table, take a
  field, call through a function-pointer field or table, take the address of an element and
  `match` on an enum element of any struct, array, enum or function-pointer global, as well as a
  scalar one. It sees the initial value, built once per run, and cannot change it: a write
  stops the build with "compile-time code cannot modify a global". A global that holds the
  address of another and a global that a `#run` computes are not readable yet; reading one
  stops that `#run` and names the global. See [`docs/09`](docs/09_comptime.md#data-at-compile-time).
- **`#export` on a global** exports it as data, by its own name or `#export("name")`.
  This is what a plugin entry point is (`clap_entry`). `examples/dll` exports one and is
  loaded from Python. On Linux the global gets a global symbol of that name.
- **Calling through a function-pointer expression:** `HANDLERS[i](x)`, `make()(x)`,
  `(addr as extern fn(i32) -> i32)(x)`. A global function pointer is callable by name,
  and a call through any function pointer — local, global, field or element — now checks
  its argument count and types. Before, `table[0](21)` type-checked as `unknown` and
  returned 16 instead of 42, and `f(1, 2)` on a one-parameter pointer compiled.
- **`core::offset_of(T, "field")`, `core::align_of(T)` and `#assert(cond, "message")`** —
  layout queries and compile-time assertions. The answers were compared with clang for
  `x86_64-pc-windows-msvc`. See [`docs/11`](docs/11_c_interop.md#checking-a-layout).
- **`std.bytes`** — fixed-width little- and big-endian reads and writes at an explicit
  offset in a byte slice; an out-of-range access fails with `out_of_bounds` and touches
  nothing.
- **`std.com` and `std.winrt`** — COM and Windows Runtime primitives. `std.com` is the data,
  portable to every target: `Guid` (text form, parser, `eq`), `HRESULT` helpers and `check`,
  which turns a failure into a named error; `IUnknown`, `IInspectable` and
  `IActivationFactory` with their vtables; `RefCount` for objects you write. `std.winrt` is the
  Windows-only part: `co_initialize` / `ro_initialize`, `co_create_instance`,
  `activation_factory`, and `HString` / `HStringRef` over `HSTRING`. Every layout, GUID and
  constant was compared with the Windows SDK headers through clang, and the test fixture runs
  against the real system: GUID text against `StringFromGUID2`, a COM object of the OS called
  through a hand-declared vtable, a COM object written in Gabbro that the OS calls back, and
  `Windows.Foundation.Uri` activated and read. A DLL name `combase` links through the SDK's
  `runtimeobject.lib` (the SDK has no `combase.lib`).
- **`std.sync`** — `Mutex`, `CondVar` (`wait`, `wait_timeout`, `signal`, `broadcast`) and a
  bounded blocking `Queue(T)` with `close()`. They sit on the operating system's own
  primitives — `SRWLOCK` and `CONDITION_VARIABLE` on Windows, `futex(2)` on Linux — so a
  blocked thread sleeps instead of polling; each is one word in your own struct, all zero
  bits is the unlocked state, and there is nothing to allocate or destroy.
- **`std.utf16`** — UTF-8 ⇄ UTF-16 with surrogate pairs and strict validation; a malformed
  input is an error, never silently replaced. Sizes are computed first, buffers are the
  caller's.

### Fixed

- **`#packed(N)` was accepted and ignored.** It compiled as plain `#packed`, so a struct meant
  to match C's `#pragma pack(2)` came out a different size with no message. `#packed` takes no
  argument; `#packed(N)` is an error that says there is no pack-to-N.
- **`defer` did not run when `?` propagated an error.** `?` returned from the function in the
  code generator, past the cleanups: after `defer close(file); n := file.read(buf)?;` a failing
  `read` left `file` open, a `defer.err` was skipped, and the exit of an enclosing `zone` was too.
  This is the pattern [`docs/04`](docs/04_error_handling.md) shows. `?` is now lowered the way
  `fail` is, so it runs the defers registered before it (last first), `defer.err`, and the zone
  exits; `defer.ok` does not run. The error and its discriminant pass through unchanged. `?` also
  works in code the compiler runs now (`#run`, `#assert`), where the function using it could not
  be evaluated before.
- **A local array of `fn` values crashed the code generator.** `c: [2]fn(i32) -> i32 = .{ dbl, neg };`
  stored bare function pointers into slots that are 16-byte `{ fn, env }` closures, and LLVM
  segfaulted emitting the object, at `-O0` and `-O2` and in 0.1.1. The thin pointer a `fn`
  struct field holds was applied to array elements too — which is also why a lambda or a
  local as an element was refused as "a C callback argument". An element is now an ordinary
  function value, so `c[i](x)` calls it and `f := c[i]` copies it out. A `fn` struct field
  and an `extern fn` element are still thin pointers.
- **Wrapping arithmetic, shifts, `~` and casts did not drop bits at compile time.** The VM
  computes in 128 bits and kept what a narrower type would have lost, so `0xFFFFFFFFu32 +% 1`
  was `4294967296`, `300u32 as u8` was `300`, and a xorshift generator or an FNV hash run in a
  `#run` fed the lost high bits back through the next `>>` and produced a different number than
  the program computes — [`docs/02`](docs/02_types.md#overflow-policy) said they behave
  identically at compile time. `+%`, `-%`, `*%`, `<<`, `~` and `as` now wrap to the operand type's width and
  signedness; 550 casts between all ten integer types and 50 wrapping operations were compared
  with the machine's results. A plain `+ - *` that overflows still keeps the exact result.
- **A `#run` that read a constant another `#run` computed silently saw `null`.** With
  `FLAG :: #run yes();` and `X :: #run pick();` where `pick` tests `FLAG`, `X` came out as the
  value for `FLAG == false` and was baked into the program. It now stops with "global `FLAG`
  cannot be read by compile-time code: its value is itself computed by a `#run`".
- **Comparing two payload-less enum values (`m == Mode.slow`) in a `#run` could not be
  evaluated.** The VM compared the two blocks instead of their tags.
- **A function named as a value in a struct literal inside a `#run`** (`.{ 9, dbl }` for a
  `fn` field) could not be evaluated.
- **`&&` and `||` did not short-circuit.** Both operands were always evaluated, as
  [`docs/01`](docs/01_syntax.md) said they were not: `side(false) && side(true)` ran `side`
  twice, and at `-O0` the guard `i < s.len && s[i] != x` read `s[s.len]` and trapped. The right
  operand now runs only when the left does not decide the result; a constant left operand
  (`DEBUG && check()`) needs no branch at all. The comptime VM, which runs the same lowering,
  behaves the same.
- **A `catch` handler that ran to its end ran off into other code.** It was lowered as
  `unreachable`, which happened to continue after the `catch` at `-O0` and, once optimised,
  fell through into whatever followed: `f() catch e {};` — the usual way to ignore an error —
  crashed at `-O2` as soon as `f` failed. A handler that ends now continues after the `catch`.
  Because a handler produces no value, a `catch` whose value is used (`v := f() catch e { … }`)
  must end its handler with `return`, `fail`, `break` or `continue`, and is an error otherwise;
  a `catch` that is a statement of its own, or on a `void` call, may simply end.
- **An error handed to another function was compared against the wrong variants** (every error
  looked like the first one). Comparing an error with a variant is now accepted only on the name
  the `catch` bound, and is a compile error anywhere else.
- **A builtin handed something that is not a type failed the build without a message.**
  `ptr_from_int(5usize, …)` is one: the builtins that take a type as their first argument now
  say what they expected.
- **Reading an array field of a struct in a loop overflowed the stack.** `b.order[i]` copied the
  whole array into a fresh stack slot on every pass — a dynamic allocation nothing released —
  so a loop over a 4000-byte field crashed after about 250 iterations (`STATUS_STACK_OVERFLOW`).
  It also affected the address of a slice or fallible field read from a value. The scratch
  slots now live in the function's entry block and are reused.
- **gabld produced DLLs that broke when not loaded at their preferred address.** gabld
  writes no base-relocation table, so an absolute address in a DLL's data (a vtable, now
  a static table of pointers) kept pointing into the first image loaded at that address —
  and every gabld DLL asks for the same one. gabld now hands such a DLL to LLD, which
  writes the table; a DLL with no absolute address is still linked by gabld. A bare
  `#export` on a function is now in gabld's export table as well.
- **`e == .variant` on an error value compared against nothing.** An error held in a
  local was stored as a pointer, so the comparison read garbage, and a misspelt variant
  was not diagnosed. It now compares the error's discriminant (its 1-based position in the
  function's own error set) and `Enum.variant` typos are an error. The comptime VM numbers
  errors the same way.
- **A program could not bind a Win32 function the runtime also declares.** Declaring
  `#extern("kernel32", "CloseHandle")` under that name — or a `STD_OUTPUT_HANDLE`
  constant, or the same API in two modules — failed with `duplicate top-level
  declaration` for something the program never wrote. It broke both `examples/diskscan`
  executables. A program's own declarations now shadow the runtime's inside its own
  file. Bindings of one C symbol also keep their own signatures: LLVM holds one function
  per symbol, and every call used to be built with the first declaration's types, so a
  `BOOL` bound as `i32` was truncated to the runtime's `bool`.
- **`expr ?? default` on a fallible (`T ! E`) value returned the wrong thing.** It was
  lowered as if the value were an optional, so a failure yielded stale data or the raw
  error tag instead of the default. `expr!!` on a fallible had the same mistake and
  returned the wrong value on success. Two further faults in `??` are fixed: every `??`
  in a function shared one temporary, so a later one of a different type (a slice, then
  a struct) misread it, and a bare literal default such as `.{ 9, 9 }` was lowered with
  no type.
- **`#align(N)` only aligned the variable holding the struct.** Its size stayed natural
  and a struct field of that type was not moved, so `#align(8)` over `[8]u8` — what
  `gabbro bindgen` emits for a C union — sat at offset 4 inside its parent, not 8. It is
  now `alignas(N)`: the struct is aligned and its size rounded up wherever it appears,
  including generic structs and `#packed` structs. `N` must be a power of two.
- **Comptime `core::sizeof` ignored padding.** The VM summed field sizes, so
  `#run core::sizeof(S)` gave 15 for a struct the program measured at 24. It now uses
  the layout the native backend produces.
- **The address of a `#packed` field was accepted.** `docs/02_types.md` always said it
  is an error; `&p.b` and `&p.arr[i]` now are. Field access through a `*Packed` pointer
  is emitted with alignment 1 instead of the field type's natural alignment.
- **A dereference as a call argument was read as a type.** `f(*p)` and `g(1, *p)` failed with
  "unknown type `p`" when the operand was a bare name (`f(x: *p)` too), and a variable named
  like a builtin type (`addr`, `byte`) became that pointer type, a type mismatch. The parser
  took `*name` in an argument list for a pointer type, which only a few builtins
  (`ptr_from_int(*T, …)`, `sizeof(*T)`) and generic functions with explicit type arguments
  (`new_slice(*Node, a, 4)`) want. It now reads `*name` as a dereference, and the checker turns
  it back into a pointer type where a type is wanted: the first argument of those builtins and
  the explicit type arguments of a generic function, whatever the type is (a struct, an alias
  such as `c_int`, a type parameter, a name an import brings in). `f(*p)` loads,
  `new_slice(*Node, …)` still names a type, and `v := *p; f(v)` is no longer needed.
- **A pointer-to-pointer type argument could not be written.** `**T` was read as two
  dereferences of `T`: `sizeof(**T)` failed with "cannot dereference value of type `T`",
  `ptr_from_int(**T, …)` failed without a message and `arena.new(**T)` with "expected a type
  argument". `**T`, and `***T`, now name pointer types in an argument, as `*T` does.
- **`#import std.c` did not compile, and neither did any alias of an identifier-spelled
  type.** The error, `constant initializer could not be folded at compile time`, pointed
  at `pub c_float :: f32;`. The parser reads `Name :: i32;` as a type alias but
  `Name :: f32;` as a value constant: only keyword-spelled types were recognised, and
  `f32`, `f64`, `byte`, `Text`, a struct, an enum or another alias are plain
  identifiers. Using such an alias as a type failed too (`` `my_float` is not a type
  (it is a constant) ``), as did the `pub Name :: f32;` typedefs `gabbro bindgen` emits
  for C `float` and `double`. Once every declaration and import is known, `X :: Name;`
  and `X :: ns::Name;` are now aliases when `Name` is a type, and constants when it is
  not (`C :: B;` with `B :: 8` is unchanged). An alias is resolved where it is
  declared, so a `pub` alias can be imported without the type it names, and an alias of
  a struct or enum lowers as that type behind a pointer, in a slice, as an enum payload
  and as the subject of a `match`.
- **An alias did not stand for its type in a few positions.** An optional of an alias
  (`?c_int`) and an alias in a generic function's signature hit an internal compiler
  error, `core::sizeof(c_int)` was a pointer's 8 bytes, and an alias passed as an
  explicit type argument (`vec::make(c_int, &a)`) was typed as the alias itself.

### Changed

- The README no longer claims `i128`/`u128`; the compiler rejects integers wider than 64
  bits.
- **A pointer type written where a value is wanted is refused.** `take(*Node)`, for a
  `take :: fn(p: *Node)`, compiled and passed a null pointer; it is now an error that says
  `Node` is a type, so `*Node` is a pointer type and not a value.

## 0.1.1 — 2026-09-08

A bug-fix release. **If you have 0.1.0, replace it:** its build system does not work
outside the machine that built it.

### Fixed

- **`gabbro build` could not find the standard library.** Running it in an extracted
  0.1.0 release failed with `cannot read imported module: FileNotFound` naming a path
  from the build machine. `gabbro build` with no source file dispatches to the build
  system early in `main` and returned before the relocatable path resolution ran, so
  `std.build` was looked up at the absolute path the compiler was built at. A direct
  `gabbro build <file>.gab` was unaffected, which is why it survived release testing.
  Setting `GABBRO_HOME` was the only way through on 0.1.0.

### Added

- `examples/mandel` — a Mandelbrot set drawn entirely by the comptime VM. `render`
  runs at compile time and returns Gabbro source, which `#insert #parse` splices into
  `main`; raising the resolution slows the build and leaves the run flat.
- `examples/raycaster` — a twelve-line text map walked in 3D in the terminal at
  roughly 22 fps.

## 0.1.0 — 2026-09-08

First tagged release. Gabbro compiles end-to-end on two targets, ships a standard
library and its own linker, and installs by unzipping.

**The project was previously called Skarn.** The language, the toolchain and the file
extension were all renamed in this release: `skarn` → `gabbro`, `skarnld` → `gabld`,
`.sk` → `.gab`, and the `SKARN_*` environment variables to `GABBRO_*`. The old
repository, `skarn-lang/skarn`, is superseded by `gabbro-lang/gabbro`.

### Language

- Structs, packed structs with sub-byte fields, enums with payloads, and exhaustive
  `match` with range, string and guard patterns.
- Integers `i8`–`i128` and `u1`–`u128`, `f32`/`f64`, pointers, arrays, slices and
  optionals. Arithmetic overflow traps in debug and wraps in release; `+%`/`-%`/`*%`
  always wrap.
- Errors as values: `T ! E`, `?` to propagate, `catch` to handle, `fail` to raise. An
  error is a small integer tag, not a stack unwind.
- Lexical `Arena` zones with compiler-enforced non-escape and deterministic cleanup.
  `borrow` parameters may take a zone-owned value but cannot store or forward it.
- Monomorphized generics with `$T:` constraints, `where {}` predicates and named
  constraints. Interfaces with explicit dynamic dispatch.
- Distinct/newtype and opaque types, UFCS extension methods, lambdas and iterators.
- Debug traps for overflow, divide-by-zero, bad shifts, out-of-bounds indexing, null
  deref and invalid optional unwraps.

### Compile-time execution

- `#run` on a register bytecode VM that executes the same IR the native backend
  lowers, so comptime and runtime cannot drift.
- `#quote`/`#insert` with re-checking and hygiene, template `macro`s with `$`-splices,
  `#for` unrolling, `#parse`, and first-class `ast.*` values you can `match` on.
- `#compiler` hooks with `compiler_decls()` introspection, and `#derive`.
- Reflection: `sizeof`, `type_name`, `type_info(T)`, `typeid` and `Any`, driving
  `std.serde` with no per-type code.
- A bare `#run` is capability-pure: it cannot call host DLLs at compile time, which
  closes the comptime side of the `build.rs` supply-chain surface. The grant is
  per-library rather than all-or-nothing — a run holds `.none`, an allowlist of
  libraries, or `.all` — and capabilities handed to a nested run can only narrow,
  failing closed when two allowlists are disjoint. The comptime heap's page
  primitives stay available to a pure run, so allocation still works.
- Content-addressed caching for pure `#run` results, behind `GABBRO_CACHE`.

### Toolchain

- `gabld`, a single-object PE/COFF linker written in Gabbro that links itself and is
  baked into the release binary. It skips LLD's largest cost by never parsing `.lib`
  import archives: the compiler already knows every import and emits a `.skimp`
  section for the linker to read. LLD remains the fallback for multi-object links,
  raw linker flags and static-CRT pull-in.
- The build system is Gabbro. `build.gab` runs inside the comptime VM; there is no
  second language and no Makefile.
- `gabbro bindgen` generates FFI declarations from a C header via libclang.

### Targets

- `x86_64-windows-msvc` — the original host target, full standard library.
- `x86_64-linux-none` (static) — cross-compiles from Windows, no libc, no crt1.o.
  Full standard library parity with Windows.
- `x86_64-linux-gnu` — behind `--target linux-gnu` with a `--sysroot`.
- No macOS backend.

### Standard library

25 modules: `io`, `fmt`, `mem`, `strings`, `slice`, `vec`, `map`, `list`, `heap`,
`math`, `rand`, `color`, `bits`, `ptr`, `path`, `time`, `crypto`, `serde`, `net`,
`atomics`, `thread`, `fs`, `process`, `c`, `build`.

### Tooling

- `gabbro lsp` with diagnostics, completion, hover, go-to-definition and document
  symbols.
- A tree-sitter grammar with highlight queries, and a Zed extension.
- The `#test` comptime lane: a failed assertion fails the build like a type error.

### Known limitations

Gabbro is experimental. Some accepted constructs still have incomplete backend
semantics. The full list, with file references, is in
[ROADMAP.md](ROADMAP.md#known-gaps); the headlines:

- No runtime test lane, formatter, doc generator, REPL or package manager.
- No external packages; projects are single-tree.
- `==` on enum payloads that are not scalars is rejected; use `match`.
- Struct and aggregate equality is not lowered.
- A `#run` producing a struct, slice or enum cannot become a top-level constant.
- Returning a capturing closure needs an `*Arena` parameter.
- `#quote` reflects range, string, guard and binding match patterns as the catch-all
  `anything`.
