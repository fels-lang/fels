# Linux / ELF / SysV backend

Fels cross-compiles from Windows to a static, freestanding Linux x86-64 ELF with no libc, and
runs it. Compute and CLI programs work today: I/O, the heap allocator, `Vec`, strings and
formatting. Filesystem, time, process, net and threads still call Win32 and aren't ported yet.

The design sections below (§2 on) are the original plan. The implementation went freestanding
with direct syscalls instead of glibc/crt1.o, and the notes point out where it differs from the
plan.

## 0. What works today

Use `--target linux` to cross-compile from a Windows host:

```
fels build hello.fels -o hello --target linux --llvm-path Y:/SDK/LLVM
# → a static, non-PIE ELF; runs under Linux/WSL with no shared-library deps

fels build app.fels -o app --target linux --libc --sysroot <dir-with-libc.so.6> --llvm-path Y:/SDK/LLVM
# → a normal dynamically-linked glibc ELF (ldd → libc.so.6); _start hands off to
#   __libc_start_main, which initializes glibc. `#extern("c", …)` now resolves
#   against libc.so.6 (verified: getpid, and puts via glibc stdio). The whole fels
#   stdlib still works under either ABI (it uses syscalls either way).
#   `--target linux-gnu` is sugar for `--target linux --libc`.
```

`--libc` (or `app.link_libc()` in build.fels) is the **portable "I need libc" switch**. It
means the Windows CRT on Windows and glibc on Linux. The entire `std` library runs on Linux,
with **full parity with Windows**: io, heap, time, fs, process (including `set_env`), net and
thread. Both ABIs are implemented and verified, the static one (`linux`, the default) and the
glibc one (`linux --libc`).

This is what works end to end, verified under WSL:

| Area | Status | How |
| --- | --- | --- |
| Codegen / object | ✅ | `emit.initTarget(.linux, …)` builds an `x86_64-unknown-linux-musl` `TargetMachine` (static reloc) and emits an ELF `.o` |
| Linking | ✅ | `link.linkLinux` invokes `ld.lld -static -e _start` (cross-links from Windows, **no libc, no crt1.o**) |
| Entry point | ✅ | a `#naked #entry _start` in the runtime: clears `%rbp`, aligns `%rsp`, `call main`, then the `exit` syscall, with no `mainCRTStartup` |
| Syscalls | ✅ | inline asm with explicit register constraints (`{rax}`,`{rdi}`,…; `r10` for the 4th arg); `write`, `exit`, `mmap`, `mprotect`, `munmap` |
| I/O (`std.io`) | ✅ | `write_stdout`/`write_stderr` route through the `write` syscall (already portable) |
| Allocator (`std.heap`) | ✅ | `Arena` reserve/commit/release go through runtime `os_reserve`/`os_commit`/`os_alloc`/`os_release`, and Linux backs them with `mmap`(PROT_NONE)/`mprotect`/`mmap`(RW)/`munmap` |
| `Vec`, strings, fmt | ✅ | fall out of the allocator + I/O above |
| `__chkstk`, `_fltused`, Windows entry | ✅ gated off | `context.applyTargetStubs` and `llvm.lower` emit them only when `target_os == .windows` |

All of `std` is ported. `std.fs`, `std.time`, `std.process`, `std.net` and `std.thread` sit
behind the same runtime/stdlib seam that the allocator uses, and the syscall wrappers in
[`src/runtime/linux.fels`](../src/runtime/linux.fels) back them. The per-module table is in
[18_targets_and_tiers.md](18_targets_and_tiers.md) §6.

Key implementation notes and gotchas:

- **Freestanding, not glibc.** The original plan (§4) linked glibc's `crt1.o` and let its
  `_start` call `main`. The implementation ships its own `#naked _start` instead and talks to
  the kernel directly. So the output is a single static ELF with **zero** dynamic dependencies
  (`ldd` → "not a dynamic executable"). This matches how Fels works without libc on Windows.
- **`_start` must be a GLOBAL symbol.** `ld.lld -e _start` resolves the entry against global
  symbols. `#keep` (external linkage) was not enough on its own, so `_start` uses `#entry`,
  which also keeps it out of internalization, like `main`. A local `_start` links
  "successfully" with entry `0x0`, and the program segfaults.
- **Inline-asm template quirks.** The Fels asm template does not process `\n` escapes, so asm
  with several instructions uses `;` separators (a valid x86 GAS statement separator). A
  literal `$` in an LLVM asm string is an operand reference, so AT&T immediates are escaped as
  `$$-16` / `$$60`. Integer asm arguments are coerced to `i64` to match the asm function type.
- **The platform allocator is a runtime seam, not `#if`.** `std.heap` stays OS-agnostic, and
  the *runtime* (selected per target) provides `os_*`. So the standard library has no platform
  branches of its own, though a program can still use a top-level `#if`. The runtime-free
  `compile` path injects a host shim so that the prelude still type-checks
  (`pipeline.prependHeapPrelude`).

## 1. What is already portable

More than you might expect. The front-end (lexer/parser/sema), the IR and the LLVM IR
generation are OS-agnostic, because they describe computation, not a platform. Two facts make
the port manageable:

- **Object emission already follows the host.** `TargetMachine.initNative`
  ([src/backend/llvm/emit.zig](../src/backend/llvm/emit.zig)) builds the machine from
  `LLVMGetDefaultTargetTriple()` and stamps the matching data layout onto the module. When the
  compiler is built on Linux, LLVM emits a correct **ELF** `.o` with the SysV data layout, so
  emitting the object itself needs no changes.
- **The ABI boundary is already abstracted.** All handling of aggregates passed by value goes
  through `Class` / `ParamAbi` / `FnAbi` and a single `classify`
  ([src/backend/llvm/abi.zig](../src/backend/llvm/abi.zig)). SysV slots in as a second
  `classify`, so the call/return lowering needs no rewrite.

So the port is **not** "make codegen portable". It is a finite list of platform-specific seams,
and everything else falls out of LLVM and the host triple.

## 2. The platform-specific surface (the actual work)

| Seam | Windows today | Linux target | Where |
| --- | --- | --- | --- |
| **Aggregate ABI** | Win64 (1/2/4/8 → int reg, else indirect) | SysV eightbyte INTEGER/SSE/MEMORY classification | `backend/llvm/abi.zig` |
| **Object format** | COFF (via host triple) | ELF (via host triple, *free*) | `emit.zig` (no change) |
| **Linker** | `lld-link` COFF, `/ENTRY:mainCRTStartup`, `kernel32.lib` | `cc`/`ld`/`ld.lld` ELF, crt1.o + libc, `_start`→`main` | `backend/llvm/link.zig`, `driver.zig` |
| **Entry point** | `mainCRTStartup` calls our `main` | glibc `_start` (from `crt1.o`) calls `main` | `link.zig`, `main.zig` |
| **Stack probe** | `__chkstk` stub for large frames | not needed (Linux auto-grows the stack) | `context.zig` module-asm, gate off |
| **Comptime FFI** | `LoadLibrary`/`GetProcAddress` | `dlopen`/`dlsym` (`-ldl`) | `vm/ffi.zig` |
| **stdlib OS layer** | `kernel32`/`ws2_32`/`ucrt` `#extern`s | glibc / raw syscalls | `lib/std/*` (see §6) |
| **CLI niceties** | `SetConsoleOutputCP` etc. | no-ops | `main.zig` |

## 3. The core abstraction: a `Target`

Introduce one enum. It is computed once and passed to every place where the platform branches:

```zig
pub const Target = enum { windows_x64, linux_x64 };
```

- **Default**: the host (`builtin.os.tag`), so Windows behavior is unchanged.
- **Override**: a `--target=linux-x64` CLI flag (and `-Dtarget=` for the build), which lays the
  groundwork for cross-compilation later.
- **Threaded into**: `abi.zig` (which `classify`), `link.zig` (which linker and args),
  `driver.compileWithLlvm` (which `link*Mem`), and the `#extern` / stdlib-injection decisions.

This keeps the Windows path a literal `switch (target)` arm. Nothing changes on Windows, and
every Linux branch stays visible and easy to review.

## 4. An ELF executable that runs (`exit 42`)

The goal: `main :: fn() -> i32 { return 42; }` builds to an ELF binary that runs on Linux. This
step has no aggregates, no FFI and no stdlib OS calls yet.

1. The `Target` enum, host detection and the `--target` flag (a no-op on Windows).
2. **Linker**: add `LinuxLinkOptions` and `buildArgsLinux` beside the Windows ones in
   `link.zig`. The easiest correct path is to invoke the system **`cc`** (gcc or clang) as the
   link driver. It supplies `crt1.o`/`crti.o`/`crtn.o`, the dynamic loader and libc, and it
   resolves `_start`→`main` for free: `cc out.o -o out -no-pie` (or PIE, see §7). When no `cc`
   is present, fall back to `ld.lld` with explicit crt objects.
3. **Entry**: drop `/ENTRY:mainCRTStartup`. With `cc`/crt1.o, the program entry is glibc's
   `_start`, which calls our `main(argc, argv)`. In Fels, `#entry main` already lowers to a
   C-callable `main` that returns `i32`. That is exactly what `_start` expects, so the exit
   code flows through.
4. Gate the `__chkstk` module-asm ([context.zig](../src/backend/llvm/context.zig)) behind
   `target == .windows_x64`.

Test: a Linux CI job runs the existing exe fixtures that need no OS calls (arithmetic,
generics, strings, containers) and checks their exit codes. The `exe_integration.zig` harness
already shells out to the produced binary. It only needs the non-Windows branch enabled instead
of `SkipZigTest`.

## 5. The System V AMD64 ABI

This is the one really intricate piece. SysV classifies an aggregate into **eightbytes**
(8-byte chunks), and each one is INTEGER, SSE or MEMORY on its own:

- Size > 16 bytes, or any unaligned field straddle → **MEMORY**. It is passed indirectly
  (`byval` pointer arg / `sret` return), the same as Win64's indirect.
- Otherwise it is 1–2 eightbytes, and each one is classified by the fields that land in it.
  All-float → **SSE** (passed in an XMM register), anything integer or pointer → **INTEGER** (a
  GP register). Two eightbytes coerce to a `{T0, T1}` pair. For example `{ double, double }` (a
  `Vector2`) → two XMMs, **not** an `i64` as on Win64.

Concretely, extend the `Class` union in `abi.zig`:

```zig
pub const Class = union(enum) {
    direct,
    coerce: u16,                       // Win64: one iN
    coerce_pair: struct { lo: EightbyteKind, hi: EightbyteKind },  // SysV: {lo, hi}
    indirect,
};
pub const EightbyteKind = enum { integer, sse };  // → i64 or double
```

`classifySysV(cg, ty)` walks the struct's fields and bins each one into eightbyte 0 or 1 by its
offset. Then it folds them (INTEGER beats SSE in a shared eightbyte) and returns
`coerce`/`coerce_pair`/`indirect`. The call/return lowering builds the coerced LLVM type
(`i64`, `double` or a 2-element struct) and `bitcast`s the aggregate through memory, exactly as
the Win64 path already does. Only the *chosen* type differs. The float-in-register difference
is the whole reason raylib's `Vector2`/`Color` need this and can't reuse Win64's "coerce to iN".

The entry-block allocas that avoid Win64's `__chkstk`, and the existing `sret`/`byval`
attribute plumbing ([abi.zig:159](../src/backend/llvm/abi.zig)), are already target-neutral and
carry straight over.

Test: re-run the C-ABI corpus (`tests/compiler/new_types_attrs.zig`) against a small Linux C
object that takes and returns `Color`/`Vector2`/`Rectangle` by value, and assert the field
values after the round trip. The Win64 suite already has this shape.

## 6. The stdlib OS layer

The pure-logic modules (`math`, `rand`, `color`, `bits`, `mem`, `serde`, `strings`, `vec`,
`map`, `fmt`, `crypto`, `path`) are already portable. Each module that touches the OS needs a
Linux backing:

| Module | Windows | Linux |
| --- | --- | --- |
| `std.heap` | `VirtualAlloc`/`VirtualFree` | `mmap`/`munmap` (`MAP_ANON`) |
| `std.time` | `kernel32` clocks | `clock_gettime(CLOCK_*)` |
| `std.process` | `GetCommandLine`, `ExitProcess` | `__libc_start_main` argv, `exit` |
| `std.fs` | Win32 file API | `open`/`read`/`write`/`close`/`stat` |
| `std.thread` | `CreateThread` | `pthread_create`/`pthread_join` (`-lpthread`) |
| `std.net` | Winsock2 (`ws2_32`) | BSD sockets (`socket`/`bind`/…, no `WSAStartup`) |

The pattern is to split each one into a thin **os shim**, the way `std.net` already layers
`std.net.os`, and to select the shim per target. There are two mechanisms, in order of
preference:

1. **`#extern` against libc.** `mmap`, `clock_gettime`, `socket` and `pthread_*` are all libc
   symbols, so bind them like the Win32 ones. This reuses the entire existing FFI path.
2. **Raw syscalls.** For a libc-free build, a `core::syscall(n, …)` builtin (an LLVM inline-asm
   `syscall`) lets `std.os.linux` issue syscalls directly. This is heavier, so defer it past
   first boot.

`std.net` pays off best. Because of the layered `os/socket/tcp/udp` split, only `net/os.fels`
changes. `socket.fels`/`tcp.fels`/`udp.fels` are already written against the shim and need no
edits. (BSD sockets even drop `WSAStartup`/`WSACleanup`, so `net::init` becomes a no-op on
Linux.)

Build-time selection: pick the shim file by target. The simplest way is a `std.os` facade that
`#import`s the right submodule for the build's target. In the shorter term, conditional
injection in the pipeline keyed on `Target` works too.

## 7. Comptime FFI, then loose ends

- **Comptime FFI** ([vm/ffi.zig](../src/backend/llvm/../vm/ffi.zig)) is gated with
  `os.tag != .windows → error`. Add a `dlopen`/`dlsym` path (link the compiler itself with
  `-ldl`) so that `#run`/`#compiler` hooks can call into shared objects on Linux, the way the
  `LoadLibrary` path does on Windows.
- **PIE**: modern Linux toolchains default to position-independent executables. You can build
  `-no-pie`, which is simplest because `RelocDefault` already suits it. Or you switch the
  `TargetMachine` reloc model to `PIC` for Linux and link a PIE. Start with `-no-pie` and
  revisit it for hardening.
- **`felsld`**: the self-hosted linker is COFF-only and purely an optimization (LLD is always
  the correctness path). An ELF `felsld` would be a *much* later, optional extra, and it is out
  of scope here.

## 8. Suggested order

1. The `Target` enum and the `--target` flag (a no-op on Windows). _Small, and it unblocks the
   rest._
2. The ELF link path via `cc`, plus entry and `__chkstk` gating → **`exit 42` runs on Linux**.
3. Linux CI running the OS-free exe fixtures.
4. SysV ABI `classify` → the C-ABI corpus passes.
5. `std.heap` on `mmap` → arenas work, then everything built on them (`vec`/`map`/`strings`)
   → most fixtures pass.
6. `std.time`/`std.fs`/`std.process`, then `std.thread`, then `std.net`.
7. Comptime FFI via `dlopen`, then PIE hardening.

You can ship and test each step on its own. The Windows target never regresses, because every
branch is a `switch (target)` arm that keeps the existing behavior on the `windows_x64` side.
