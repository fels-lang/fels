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
| LLVM object generation | Partial | Core lowering works; correctness gaps remain for some operations and types. |
| Structs, packed structs, enums | Implemented | Enums support payloads and pattern matching. |
| Integer types | Implemented | Includes sub-byte signed and unsigned integers. |
| Pointers, arrays, slices, optionals | Implemented | Runtime safety checks are not yet inserted. |
| Distinct, opaque, and atomic types | Partial | Core syntax exists; backend and operation coverage vary. |
| Functions and generics | Implemented | Generic functions and structs are monomorphized. |
| Control flow | Implemented | `if`, `while`, range/slice `for`, `break`, `continue`, and `defer`. |
| Integer and enum `match` | Implemented | Integer matches support single and grouped cases. |
| Compile-time execution | Partial | `#if` and `#run` exist; reflection and several operations are incomplete. |
| Errors and fallible functions | Partial | Frontend support exists; failure and unwrap backend paths need completion. |
| Zones | Partial | Lexical structure and cleanup behavior exist; allocation/backend semantics need completion. |
| Interfaces | Partial | Dynamic `*Interface` dispatch works; static constraints and advanced cases are missing. |
| Runtime | Partial | Panic, assertions, and basic output exist; integration and platform coverage need work. |
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

## Safety And Undefined Behavior

K2 does **not currently trap common undefined behavior in debug builds**. LLVM
lowering generally emits unchecked native operations, and several failure paths
currently lower to `unreachable`.

| Operation | Current behavior |
| --- | --- |
| Integer overflow | No K2-inserted debug check. Plain arithmetic semantics still need a final decision. |
| Division by zero | No K2-inserted guard. |
| Out-of-bounds indexing | No K2-inserted guard. |
| Null pointer dereference | No K2-inserted guard. |
| Invalid optional unwrap with `!!` | Failure path currently becomes `unreachable`, not `@panic`. |
| `fail` and fallible propagation | Frontend exists; LLVM failure lowering is incomplete. |
| Use after zone cleanup | No runtime detector. |
| Uninitialized values | Some cases are rejected, but there is no complete definite-initialization proof. |
| Data races and unsafe pointer misuse | Caller responsibility. |

The intended debug policy should be decided and implemented before adding more
large language features. The recommended baseline is:

- Trap integer overflow, division by zero, invalid shifts, null dereferences,
  out-of-bounds indexing, and invalid unwraps in debug builds.
- Route language-level failures through `@panic` or a shared trap mechanism with
  useful source locations.
- Keep explicitly unsafe operations available inside `unsafe`.
- Define release behavior precisely rather than inheriting accidental LLVM
  behavior.
- Add explicit wrapping arithmetic operators such as `+%`, `-%`, and `*%`.

## Priority Roadmap

### P0: Compiler Correctness And Debug Safety

This is the next milestone. It has higher value than additional syntax.

- Add a shared debug trap and panic-lowering path with source locations.
- Insert debug checks for overflow, division by zero, invalid shifts, bounds,
  null dereferences, and invalid unwraps.
- Make `!!` call the runtime panic path instead of lowering failure to
  `unreachable`.
- Complete the error and fallible-function ABI through LLVM lowering.
- Audit signed, unsigned, floating-point, comparison, and cast lowering.
- Complete pointer-to-struct field lowering and validate generated LLVM IR.
- Add end-to-end executable tests for successful programs and runtime failures.

**Acceptance criteria:** a debug-compiled K2 program reliably traps the common
invalid operations above, reports the originating source location, and all
failure/control-flow paths produce valid LLVM IR.

### P1: Complete Existing Language Features

- Finish zone allocation semantics, backend behavior, escaping rules, and
  cleanup guarantees.
- Complete interfaces: static constraints, const correctness, fallible methods,
  coherence rules, and lifetime validation.
- Complete compile-time evaluation and make `sizeof` and type reflection
  accurate.
- Apply `#align` correctly and add decided calling-convention, linking, and
  section attributes.
- Define and implement wrapping arithmetic.
- Finish cross-platform runtime and native linking support.
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
| Zones | Can values escape a zone? How are destructors, nested zones, and failure paths handled? |
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
