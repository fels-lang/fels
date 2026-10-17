# Testing: `#test` and `fels test`

A test is a function marked `#test`. `fels test` runs the tests of a project. It builds each
file's tests into a small program and runs it, so a test can read files, call C and do whatever
the program can do. `fels build` runs the same tests on the comptime VM while it compiles, and a
failed assertion there fails the build the way a type error does.

Testing leans on two things the compiler already has:

- **The comptime VM models real host memory.** A pure test can run while the program
  compiles, so a broken invariant stops the build.
- **Reflection is total** (`core::type_info`, `Any`, the serde layer). That means the richer
  machinery (structural diffs, input generators and snapshots) can come from a type's shape,
  with no per-type code (§6).

## 1. Writing a test

A test is a function marked `#test` that takes a test context `t: *Test`:

```fels
#test
add_associates :: fn(t: *Test) {
    t.eq(2 + 2, 4);
    t.ne(2 + 2, 5);
    t.expect((1 + 2) + 3 == 1 + (2 + 3));
}
```

You don't import anything, because the `Test` type is added whenever a module declares a
`#test`. Tests are found by the attribute, so there is no list to keep up to date. A test can
sit next to the code it tests in the same file, or in a file of its own that imports that code.

## 2. `fels test`

```
fels test                     the tests of the project: src/, or the folder without src/
fels test src/parser.fels     the tests of one file
fels test examples tests      the tests of the files in these folders
fels test --comptime          run them on the comptime VM instead
fels test -j4                 test four files at once (default: one per core; -j1 one by one)
```

Each file is compiled on its own, and the tests declared in that file run. The tests of the
files it imports run when those files are tested. A folder is searched together with its
subfolders. Hidden folders, `zig-out`, `vendor` and `dist` are left out, and so is
`build.fels`. Imports work as they do in `fels build`, with the packages of fels.pkg and the
project's own package name ([docs/16](16_packages.md)). `fels test` never fetches. A package
that is in fels.pkg but not in the cache yet gets a note to run `fels fetch`.

```
$ fels test
src/main.fels
  ✓ doubles
  ✓ writes_a_file
  ✗ prints_and_fails: t.eq: values are not equal
      t.expect: condition was false
      | double(2) is computed
  ✗ out_of_bounds: panic: index out of bounds at src\main.fels:31:10
  ✓ last

Test Summary: 3 passed, 2 failed · 0.42s
```

A failed test shows every check that failed, and below them, after `|`, what the test printed.
A passing test prints nothing. On a terminal, a live tree shows which files are being built or
run while you wait, and the marks and counts are in color. `fels test` exits with 1 when a test
failed or a file does not compile, so you can use it in CI.

The files are tested at the same time, as many as the computer has cores, each in a `fels`
process of its own, and the live tree shows the stage each of them is in. The report still comes
in the order of the files. The tests of one file run one after the other, but two files run side
by side: if the tests of both write the same file in the project folder, they get in each other's
way. Give each file of output its own name, or test one file at a time with `-j1`. A run of four
files or more that takes a second or longer names its slowest files under the summary:

```text
Test Summary: 163 passed · 3.78s
slowest: src/sample_tests.fels 2.81s, src/imports/loader_tests.fels 2.74s, src/imports/updates_tests.fels 2.70s
```

### The test program

For every file with tests, `fels test` builds a program that runs them one after the other, and
it reads what they report. This is why a test can do what the program does:

- It runs in the project folder, so `fs::create("out.txt")` writes `out.txt` there.
- It links like an artifact of the project. It gets what the packages provide, and the library
  folders, libraries and runtime files that the project's build.fels names (for its artifacts
  and in its `provide_*` calls). So a binding to a C library can test the real calls.
- A check that fails does not stop the test. The next checks still run, and each one that fails
  is listed. `t.fatal(msg)` ends the test at once.
- A crash, a panic or an index out of bounds ends only that test. `fels test` starts the
  program again behind it, so the other tests still run.
- The file's own `main` does not run, and its `#entry` marks are dropped, because the test
  program has its own entry. Test the functions that `main` calls instead.

The programs go to `.fels-cache/test` in the project folder. Building them needs the LLVM
backend. In a Fels without it, `fels test` runs the tests on the comptime VM.

### On the comptime VM

`fels test --comptime` runs the tests on the comptime VM, the way `fels build` does (§3).
Nothing is built or linked, and a test that the VM cannot run is skipped:

```
src/app.fels
  · asks_the_os: skipped (comptime FFI to `GetCurrentProcessId` (in `kernel32`) is not allowed here)
  ✓ adds

Test Summary: 1 passed, 1 skipped · 31ms
```

## 3. The comptime lane in `fels build`

A `#test` also runs **on the comptime VM as part of compiling the module**. Each test gets a
fresh VM over the program's bytecode, so one failure cannot affect the next. When an assertion
fails, it calls `core::compiler_error(...)`. The VM stops that run, and the driver turns it into
a diagnostic:

```
$ fels build
comptime test 'arithmetic_is_broken' failed: t.eq: values are not equal

1 passed, 1 failed (comptime)
```

No executable is produced, and `fels` exits non-zero. A program whose tests all pass builds
normally. The test functions are **removed before code generation**, so they add nothing to the
binary, and a program with no `#test` pays nothing.

Some tests need the running program, because they open a file, ask the OS, write a global, or
use something the VM cannot do yet. The VM cannot run them. That is no fault of the test, so the
build skips them with a note and goes on:

```
note: building src/main.fels, 1 #test function cannot run at compile time; `fels test` runs it
```

## 4. The `Test` context

| Method | Passes when | On failure |
| --- | --- | --- |
| `t.eq(a, b)` | `a == b` | `t.eq: values are not equal` |
| `t.ne(a, b)` | `a != b` | `t.ne: values are unexpectedly equal` |
| `t.expect(cond)` | `cond` is true | `t.expect: condition was false` |
| `t.fatal(msg)` | never | `msg`, and the test ends |

`eq` and `ne` are generic (`fn(self: *Self, a: $V, b: $V)`), so they take any two values of the
same type.

On the comptime VM, every failed check ends the test, because it is a `core::compiler_error`.
In a test program, a failed check is counted and the test goes on, and only `t.fatal` ends it.

### What `t.eq` compares

`==` and `!=` cover:

- **scalars**: ints, floats, bools and simple enums
- **`[]const u8`** and other slices, by content (`t.eq("a", "a")`)
- **structs and arrays**, field by field and element by element (into nested structs and
  string fields), so `t.eq(point_a, point_b)` works

Two payload-enum values compare too, as long as the payloads are scalar (`E.c(1) == E.c(1)`).
A variant that carries a struct, string or array payload is the one case that errors, so use
`match` there. A failed `t.eq` says only that the values differ. A diff that shows which field
differs is designed in §6.

## 5. How it works

**`fels test`** ([src/test_cmd.zig](../src/test_cmd.zig)) compiles each file with
`pipeline.test_runner` set. The pipeline ([src/pipeline.zig](../src/pipeline.zig),
`addTestRunner`) then adds the `Test` of `ast_prelude.runtime_testing_source`, leaves out the
file's `main`, and generates a `main` that calls each `#test` function of the file in turn. The
program writes its results to stdout as lines that start with `@@fels-test `:

```
@@fels-test RUN <name>    a test starts
@@fels-test MSG <text>    a check failed
@@fels-test PASS          the test passed
@@fels-test FAIL          the test failed
@@fels-test END           every test ran
```

Each line follows a newline, so it stays apart from what the test printed. When the program
ends after `RUN` without `PASS` or `FAIL`, the test crashed, and its stderr says why.
`fels test` then starts the program again with the index of the next test as its argument, and
the generated `main` skips the tests before it. The program is built with
`driver.emitLlvmFromFrontend` and linked with `build.testLinkInputs`.

**The comptime lane** ([src/ir.zig](../src/ir.zig), `runComptimeTests`):

```
parse, preludes, sema (Test added if a #test exists)
                          │
   driver: hasTestDecl? ──┤ no: straight to codegen
                          │ yes
                          ▼
        runComptimeTests: for each #test fn,
          a fresh Vm over the bytecode,
          vm.call(name, &.{*Test}); a compiler_error trap is a failure,
          a stop at what only a running program can do is a skip
                          │
              any failure: print it, fail the build
              otherwise:   pruneTestDecls, go on to codegen
```

- `Test` and its methods are a prelude ([src/ast_prelude.zig](../src/ast_prelude.zig),
  `testing_source`). `prependTestingPrelude` adds it when `ir.hasTestDecl` is true. The
  assertion methods call `core::compiler_error`, which the VM keeps in `compiler_error_msg`
  when it stops.
- The VM sets `needs_runtime` when it stops at a host call it may not make, a write to a
  global, or a function it could not compile. Such a test is skipped.
- The driver ([src/driver.zig](../src/driver.zig), `runComptimeTestLane`) runs the lane
  between the diagnostics check and the LLVM backend.

## 6. Designed, not built yet

- **Per-test zones** with leak accounting in the test program, a time limit for a test that
  hangs, and a TAP or JSON report for CI.
- **Reflection-powered assertions**: on a failed `t.eq`, walk `core::type_info(V)` and print a
  field-by-field diff for any struct, enum or slice, with no `#derive` needed.
- **Property testing**: a `#test(prop)` function declares its generated inputs as extra typed
  parameters. The runner derives a generator from `core::type_info` for each one, runs N seeded
  cases, and **shrinks** to a minimal counterexample. (The inputs come in through parameters
  rather than an inline closure, because Fels lambdas don't capture.)
- **Snapshots**: `t.snapshot(value, "name")` serializes any value through serde and diffs it
  against a stored snapshot, and `fels test --update` rewrites the snapshot.

The idea that runs through all of this: tests are found by their attribute, assertions and
generators come from reflection, and the comptime lane makes a failing test a failing build.
