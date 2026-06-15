# Benchmarks: Fels, C and Zig

Ten small programs, each written in Fels, C and Zig the same way, built by each language's own
compiler and timed by one script. The point is a comparison you can check: the programs are short
enough to read side by side, every output is compared before anything is timed, and the script
writes down the machine, the compilers and every flag next to the numbers.

The latest results are in [results/](results/). To run them on your machine:

```
python bench/run.py            # about ten minutes
python bench/run.py --quick    # a minute: small sizes, to check the setup
```

It needs Python 3.8 or newer, `fels`, `zig` and `clang` on `PATH` (or `--fels`, `--zig`,
`--clang`). On Windows, C is built against the Visual Studio C runtime: the script finds the
newest Visual Studio and Windows SDK with `vswhere`, unless `INCLUDE` and `LIB` are set.

## The programs

| benchmark | what it exercises |
|---|---|
| [nbody](nbody) | floating-point arithmetic and `sqrt` on a small array of structs (the Benchmarks Game program) |
| [spectral-norm](spectral-norm) | floating-point division and dot products in nested loops (Benchmarks Game) |
| [fannkuch-redux](fannkuch-redux) | small integer arrays: copies, reversals, a permutation generator (Benchmarks Game) |
| [mandelbrot](mandelbrot) | a tight floating-point loop and bit packing (Benchmarks Game; prints a checksum instead of the bitmap) |
| [binary-trees](binary-trees) | many small allocations and pointer chasing, an arena per tree (Benchmarks Game) |
| [sieve](sieve) | memory traffic with strided writes, a branch per number |
| [matmul](matmul) | the naive i-k-j matrix product of doubles, the loop compilers vectorize |
| [quicksort](quicksort) | comparisons, swaps and unpredictable branches on 32-bit integers |
| [hashmap](hashmap) | an open-addressing hash table: random memory access and a branch per probe |
| [crc32](crc32) | byte loads, table lookups and shifts in a dependency chain |

Each folder holds `main.fels`, `main.c` and `main.zig`. The Fels file is the specification, and
its first comment says what the program does.

## The rules

- **The same algorithm and data layout** in all three: the same loops in the same order, the same
  types and widths, the same allocation pattern. Nothing a language could do differently is left
  to its standard library: the sort, the hash table, the arena and the random numbers are written
  out in each program.
- **No tricks**: no SIMD intrinsics or vector types, no threads, no hand unrolling, no `restrict`,
  no relaxed floating-point modes. What a compiler vectorizes or unrolls by itself counts.
- **The same output**, compared byte for byte before timing. A program whose output differs is
  reported and not timed. Checksums cover the whole result, so a compiler cannot drop work.
- **The size comes from the command line**, so no compiler can compute the result while building.
- **The same machine code target**: all three build for the CPU they run on (Fels always does;
  C gets `-march=native`; Zig does by default).
- **The same floating-point rules**: C gets `-ffp-contract=off`. clang otherwise fuses `a * b + c`
  into one rounding, which Fels and Zig do not do; with it, the floating-point results are the
  same bit for bit in all three.

## The variants

| variant | built with | checks at run time |
|---|---|---|
| `c` | `clang -O3 -march=native -ffp-contract=off -std=c11` | none |
| `zig-fast` | `zig build-exe -OReleaseFast` | none |
| `fels-fast` | `fels build -O3 --unchecked` | none |
| `zig-safe` | `zig build-exe -OReleaseSafe` | overflow, bounds, null, unreachable |
| `fels-safe` | `fels build -O3` | overflow, bounds, null, division by zero, shifts |

The `fast` variants are each language at full speed with its checks off; compare them with `c`.
The `safe` variants keep the checks a program has in a normal release build of Fels
(`fels build --release` keeps them too) and in Zig's ReleaseSafe; compare them with each other,
and with `c` for what the checks cost. Integer arithmetic that is meant to wrap (hashes, random
numbers) wraps explicitly in all three (`+%` and `*%` in Fels and Zig, unsigned types in C), so the
checked variants check only what a program would want checked.

About the compilers: Fels and clang both use LLVM, and when the clang is the version Fels uses
(LLVM 22 for Fels 0.11), the C and Fels columns compare the languages and their front ends on the
same optimizer and code generator. Zig 0.16 brings its own LLVM 21. The report names every
compiler's version.

## How it measures

1. Builds every program in every variant, timing each build and noting the binary's size.
2. Runs each program once and compares the outputs.
3. Runs each program once without timing it, then `--runs` times (10 by default), the variants
   interleaved, in a new shuffled order every round, so drift in the machine (heat, other
   programs) spreads over all of them.
4. Reports the median wall-clock time of the whole process, its ratio to C, the geometric mean of
   the ratios, the fastest and slowest run, the build times and the binary sizes, and writes all
   raw times to a JSON file next to the report.

The times include starting the process, which is a few milliseconds and the same for all three;
the sizes are chosen so a program runs for about a second in C. For numbers you want to publish,
close other programs, plug in a laptop, and look at the spread: a wide one means the machine was
busy.

## What it does not tell you

These are ten small kernels. They say how fast the code a compiler makes is for loops,
arithmetic, memory access and allocation, written the same way in each language. They do not say
how fast idiomatic programs are (a Zig or C programmer might write some of them differently, and
so might a Fels one), how long large programs take to compile (that is [below](#compile-speed)),
or how the standard libraries compare. If you think one of the programs is unfair to a language,
the programs are short: say which line, or send a better version that keeps to the rules.

## Compile speed

`bench/compile.py` times the compiler instead of the programs. It writes a program of ordinary
code (100 000 lines by default: functions of one 20-line shape, with arithmetic, loops, struct
fields and calls), builds it the way a debug build is made (`fels build`, -O0 with the safety
checks), runs it, and reports every phase of the fastest of three builds in milliseconds and
microseconds per line:

```
python bench/compile.py
python bench/compile.py --lines 1000000 --json out.json
```

The goal is a million lines a second for a debug build, every phase included: 1 µs a line.
