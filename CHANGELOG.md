# Changelog

Notable changes, newest first. Versions follow [SemVer](https://semver.org/): while
the major version is `0`, any minor bump may break source compatibility.

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
