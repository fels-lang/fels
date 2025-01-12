# K2 Compiler

K2 is an experimental systems programming language and compiler written in Zig.
It aims to keep low-level behavior explicit while providing generics, compile-time
evaluation, lexical allocation zones, and explicit dynamic interfaces.

The compiler and language are still evolving. K2 is not ready for production use,
and some accepted language constructs do not yet have complete backend semantics.

## Design Direction

- No hidden allocations.
- Dynamic dispatch is explicit through `*Interface` values.
- Static polymorphism uses monomorphized generics.
- Allocation zones provide lexical ownership without requiring a tracing garbage
  collector.
- Unsafe operations remain available, but debug builds should catch common
  undefined behavior close to its source.
- Features should have complete semantics before more syntax is added.

## Building

The frontend can be built and tested without LLVM:

```powershell
zig build
zig build test
```

LLVM code generation requires an LLVM installation:

```powershell
zig build -Dllvm-path=Y:/path/to/llvm
zig build test -Dllvm-path=Y:/path/to/llvm
```

The compiler currently exposes these commands:

```text
k2 check <file>     Parse and type-check a source file
k2 ir <file>        Print K2 IR
k2 object <file>    Emit an object file
k2 build <file>     Build an executable
```

Native executable linking is currently Windows-focused.

## Example

```k2
Writer :: interface {
    write :: fn(*Self, []const u8) -> usize;
}

FileHandle :: struct {
    fd: i32,
}

FileHandle as Writer {
    write :: fn(self: *FileHandle, data: []const u8) -> usize {
        return sys_write(self.fd, data);
    }
}

main :: fn() {
    file := FileHandle { fd = 1 };
    writer: *Writer = &file;
    writer.write("hello\n");
}
```

`*Writer` is a non-owning dynamic interface value containing a data pointer and a
vtable pointer. Converting `*FileHandle` to `*Writer` checks interface conformance
at compile time.

## Implementation Status

Status meanings:

- **Implemented**: supported end to end and covered by tests.
- **Partial**: syntax and meaningful behavior exist, but important cases or
  backend semantics are incomplete.
- **Planned**: direction is understood, but implementation has not started.
- **TBD**: language semantics still need a decision.

| Area | Status | Notes |
| --- | --- | --- |
| Lexer, parser, AST, diagnostics | Implemented | Includes source spans and diagnostic tests. |
| Semantic analysis and typed IR | Implemented | Includes IR validation and basic optimization passes. |
| LLVM object generation | Implemented | Core lowering, module verification, debug safety checks, and Windows executable integration are covered. |
| Structs, packed structs, enums | Implemented | Enums support payloads and pattern matching. |
| Integer types | Implemented | Includes sub-byte signed and unsigned integers. |
| Pointers, arrays, slices, optionals | Implemented | Debug builds check null dereferences, bounds, and invalid unwraps. |
| Distinct, opaque, and atomic types | Partial | Core syntax exists; backend and operation coverage vary. |
| Functions and generics | Implemented | Generic functions and structs are monomorphized. |
| Control flow | Implemented | `if`, `while`, range/slice `for`, `break`, `continue`, and `defer`. |
| Integer and enum `match` | Implemented | Integer matches support single and grouped cases. |
| Compile-time execution | Partial | `#if` and `#run` exist; reflection and several operations are incomplete. |
| Errors and fallible functions | Implemented | LLVM ABI, `fail`, `?` propagation, `catch`, and fallible entry points are lowered. |
| Zones | Implemented | `Arena` provides zero-initialized lexical allocation, non-escape checking, and deterministic cleanup. |
| Interfaces | Partial | Dynamic `*Interface` dispatch works; static constraints and advanced cases are missing. |
| Runtime | Implemented on Windows; source-valid on Linux | Embedded runtime provides checked output counts, exit/abort, panic, and assertions. Native executable linking is currently Windows-only. |
| Modules and imports | Partial | Local multi-file compilation exists; package and standard-library systems do not. |
| Tooling | Partial | Check, IR, object, and build commands exist; formatter, LSP, package manager, and test runner do not. |

## Attributes

Implemented attributes include:

```text
#extern #packed #inline #noinline #noreturn #naked #entry #export #deprecated
```

`#align` is parsed and stored, but is not consistently applied by LLVM lowering.

Still missing or undecided:

```text
#require #ensure #link #section #callconv #noalias
#init #fini #test #benchmark #attrdef
```

## Interfaces

The current interface implementation is the first useful dynamic-dispatch
baseline:

- Interfaces declare required methods.
- `Type as Interface { ... }` defines conformance.
- Missing, extra, duplicate, or incorrectly typed methods are rejected.
- `*Concrete` can coerce to `*Interface`.
- Interface values use generated LLVM vtables and indirect calls.
- Interface coercions work in assignments, arguments, and returns.

Interfaces are still partial. The following remain:

- Static generic constraints, such as a decided equivalent of `where T: Writer`.
- Direct statically dispatched calls through a concrete implementation.
- Const-correct dynamic interface values.
- Fallible and generic interface methods.
- Interface composition, inheritance, and upcasting.
- Default or optional methods.
- Coherence and cross-module implementation rules.
- Ownership and lifetime validation for non-owning interface values.
- Owned interface objects and downcasting, if K2 decides to support them.

Dynamic interfaces are therefore not a long-term-only goal anymore. They exist
today, but need completion and a firmer ownership model.

## Zones

`zone name: Arena { ... }` creates a lexical allocation arena. `name.new(T)`
returns `*T`, and `name.new_slice(T, count)` returns `[]T`. Allocations are
zero-initialized and reclaimed together when control leaves the zone.

The current ownership contract is deliberately strict:

- Zone-owned pointers and slices may be aliased and used inside their owning
  zone.
- `borrow *T` and `borrow []T` parameters may temporarily receive zone-owned
  values. Borrowed values may be aliased locally and forwarded only to another
  `borrow` parameter.
- Scalar values read from zone-owned memory may escape normally.
- Zone-owned values cannot be returned, assigned to an outer local, stored into
  an aggregate or through a pointer, or passed to an ordinary parameter.
- Borrowed values cannot be returned, stored into an aggregate or through a
  pointer, or passed to an ordinary parameter.
- Nested zones clean up in reverse order. Shadowing an active zone name is
  rejected.
- Deferred work runs before arena cleanup.
- Normal fallthrough, `return`, `fail`, `break`, and `continue` all clean up
  every zone they leave.
- `Arena.free(value)` validates ownership but intentionally defers reclamation
  until arena exit.
- A process-terminating panic does not run cleanup.

For example:

```k2
fill :: fn(data: borrow []u8) {
    data[0] = 42u8;
}

work :: fn() {
    zone scratch: Arena {
        data := scratch.new_slice(u8, 4);
        fill(data);
    }
}
```

`borrow` is currently a checked-body parameter qualifier only. It cannot appear
on returns, fields, locals, scalar parameters, or external function
declarations. It is erased before IR/backend ABI lowering. Unsafe pointer casts
can still bypass lifetime checking, as expected inside `unsafe`.

The current native backend implements arenas through the Windows process heap.
Other platform runtimes must provide the equivalent backend contract.

## Runtime

Real program builds automatically prepend one authoritative embedded runtime.
The core runtime contract is:

- `write_stdout(data: []const u8) -> usize`
- `write_stderr(data: []const u8) -> usize`
- `exit(code: u32)`
- `abort()`
- `@panic(msg: []const u8)`
- `assert(cond: bool)`
- `assert_msg(cond: bool, msg: []const u8)`

Output functions return the number of bytes reported by the operating system and
return zero when the write fails. `@panic` writes a prefixed message to stderr
and terminates through `abort`. Compiler-generated safety failures use the same
panic path.

Windows runtime compilation, linking, and execution are covered end to end.
The Linux runtime source parses, checks, and lowers, but native Linux entry-point
generation, object emission validation, and executable linking remain separate
backend work. Unsupported hosts now report that no runtime is available instead
of silently compiling without one. macOS has no runtime implementation yet.

## Safety And Undefined Behavior

K2 debug builds trap common invalid operations through the shared runtime panic
path. Compiler-generated traps include the originating `file:line:column`.

| Operation | Current behavior |
| --- | --- |
| Integer overflow | Debug builds trap signed/unsigned add, subtract, multiply, negate, and signed division overflow. |
| Division by zero | Debug builds trap integer division and remainder by zero. |
| Invalid shifts | Debug builds trap shift amounts greater than or equal to the operand width. |
| Out-of-bounds indexing | Debug builds guard slice and array indexing. |
| Null pointer dereference | Debug builds guard explicit dereference, pointer field access, and pointer indexing. |
| Invalid optional unwrap with `!!` | Calls the runtime `@panic` path and then terminates as unreachable. |
| `fail` and fallible propagation | Lowered through the `{ ok, error_discriminant }` LLVM ABI; `?`, `catch`, and fallible entry points are supported. |
| Use after zone cleanup | Safe code rejects zone-owned values that could outlive their zone; unsafe pointer misuse remains caller responsibility. |
| Uninitialized values | Some cases are rejected, but there is no complete definite-initialization proof. |
| Data races and unsafe pointer misuse | Caller responsibility. |

The implemented debug baseline is:

- Trap integer overflow, division by zero, invalid shifts, null dereferences,
  and out-of-bounds indexing in debug builds.
- Keep explicit invalid unwraps on the always-panic runtime path.
- Route language-level failures through `@panic` or a shared trap mechanism with
  useful source locations.
- Keep explicitly unsafe operations available inside `unsafe`.
- Omit compiler-generated debug checks in optimized builds.

Release-mode behavior and explicit wrapping arithmetic operators such as `+%`,
`-%`, and `*%` still need a final language-level decision.

## Priority Roadmap

### P0: Compiler Correctness And Debug Safety

Completed:

- `!!` now emits a runtime `@panic` call on its failure path.
- Compiler-generated traps use one structured IR panic path carrying
  `file:line:column`, lowered through the runtime `@panic` contract.
- Debug builds check integer overflow, division by zero, invalid shifts, array
  and slice bounds, and null pointer dereferences.
- Errors and fallible functions use a verified LLVM ABI supporting `fail`, `?`,
  `catch`, and fallible entry points.
- Numeric casts select signed or unsigned LLVM conversion instructions from K2
  source and destination types.
- End-to-end tests compile, link, and execute successful, panic, assertion,
  optional, catch, and fallible programs.
- Source-file LLVM builds now include the embedded runtime needed by generated
  panic calls.
- Signed, unsigned, and floating-point arithmetic, comparison, division,
  remainder, and right-shift operations select the correct LLVM instructions.
- Pointer-to-struct field reads and writes lower through the pointed-to layout.
- LLVM modules are verified immediately after lowering.

**Status:** complete. Debug-compiled K2 programs trap the common invalid
operations above, report the originating source location, and the covered
failure/control-flow paths produce verified LLVM IR.

### P1: Complete Existing Language Features

- Complete interfaces: static constraints, const correctness, fallible methods,
  coherence rules, and lifetime validation.
- Complete compile-time evaluation and make `sizeof` and type reflection
  accurate.
- Apply `#align` correctly and add decided calling-convention, linking, and
  section attributes.
- Define and implement wrapping arithmetic.
- Finish Linux native entry-point generation and linking, then add a macOS
  runtime and linker path.
- Establish a real module, visibility, package, and standard-library foundation.

### P2: Developer Usability

- Add a package/build manifest and dependency management.
- Add a first-class test runner and decide `#test` syntax.
- Add a formatter and language-server support.
- Improve diagnostics for generic instantiation, interface conformance, and
  backend failures.
- Build a small standard library around the stable core language.

### P3: Later Language Expansion

- Runtime type identity, reflection, and `Any`.
- SIMD and vector operations.
- Contracts with `#require` and `#ensure`.
- Interface composition, owned dynamic objects, and downcasting.
- User-defined attributes.

These features should wait until the current language has reliable safety,
lowering, and tooling foundations.

## Decisions Still Needed

The following choices should be written down before their implementations grow:

| Decision | Questions to resolve |
| --- | --- |
| Plain arithmetic | Does overflow trap, wrap, or become UB in release builds? Which explicit operators provide alternatives? |
| Debug safety | Which checks are mandatory, configurable, or disabled inside `unsafe`? |
| Error ABI | How are fallible returns represented and propagated across modules and foreign calls? |
| Borrow extensions | Should checked borrowing expand beyond pointer/slice parameters to extern contracts, fields, or returned lifetime relationships? |
| Interfaces | What is the static constraint syntax? Which module may implement an interface for a type? |
| Mutability | How do `const`, receiver mutability, pointers, slices, and interface coercions interact? |
| `Any` and reflection | Is `Any` borrowed or owned? What defines stable runtime type identity? |
| Modules and packages | How do visibility, package names, dependencies, and standard-library imports work? |
| Bit and endian handling | Are sub-byte integers plus packed structs sufficient, or are endian/bit-layout attributes needed? |

## Retired "Add Soon" List

The previous short-term list is no longer useful as a roadmap. Most of it is now
implemented:

- Sub-byte integers.
- Core function and export attributes.
- Runtime panic and assertion functions.
- Casts.
- Range and slice `for` loops.
- Integer matching.
- Dynamic interfaces.

Contracts and wrapping arithmetic remain, but they are now placed according to
dependency and impact: wrapping arithmetic belongs with safety semantics, while
contracts should follow the shared debug trap infrastructure.

## Current Non-Goals

Until the P0 and P1 work is complete, these are intentionally not priorities:

- Operator overloading.
- A general owning `Any`.
- Large reflection APIs.
- User-defined attributes.
- Broad SIMD support.
- More surface syntax without complete semantics.

## Testing

Run frontend and compiler tests:

```powershell
zig build test
```

Run the full suite with LLVM lowering enabled:

```powershell
zig build test -Dllvm-path=Y:/path/to/llvm
```

New features should include parser, semantic, IR, and LLVM tests where
applicable. Safety work should also include executable tests that verify the
expected debug trap.
