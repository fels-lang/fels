# Targets, ABIs & support tiers

This page explains how Fels decides *what machine* it compiles for, *what it links against*,
and *how much we guarantee* for each target. It is the architecture for cross-compiling beyond
the original Windows-only backend.

## 1. The target model

A target has three orthogonal axes:

```
            arch         ×      os       ×       env (ABI / libc)
        ┌───────────┐        ┌────────┐        ┌──────────────────────┐
        │ x86_64    │        │ windows│        │ msvc   (Win runtime) │
        │ aarch64   │        │ linux  │        │ none   (freestanding)│
        │ riscv64   │        │ (macos)│        │ musl   (static libc) │
        │ (wasm32)  │        │ (wasi) │        │ gnu    (glibc, dyn)  │
        └───────────┘        └────────┘        └──────────────────────┘
```

You write a target as an LLVM-style triple, such as `x86_64-linux-gnu`, `aarch64-linux-none` or
`x86_64-windows-msvc`. The CLI also accepts shorthands. `--target linux` means
`x86_64-linux-none`, the static, freestanding default, and `--target linux-gnu` means
`x86_64-linux-gnu`.

**The front-end is target-independent.** The lexer, parser, sema, IR, comptime VM and macros
describe *computation*, not a platform, so every language feature works on every target. The
tiers (below) are **not** about language features. They are about how complete the codegen,
the runtime and the stdlib are.

## 2. Where platform differences live — the runtime ABI seam

The architectural decision is this: **all OS-specific behaviour goes through a small,
fixed set of `os_*` primitives provided by the platform runtime**. The standard library is
written against that seam and stays OS-agnostic. It uses no `#if TARGET.os == …`, because the
runtime is *selected* per target, so the seam is the only place where the OS appears in it. (A
program can still choose its own declarations by platform with a top-level `#if`.)

```
   std.io   std.heap   std.time   std.fs   std.net   …      (OS-agnostic)
      │         │          │         │        │
      └─────────┴────┬─────┴─────────┴────────┘
                     ▼
          os_* runtime primitives          ← the seam
      write/alloc/clock/open/socket/…
        ┌───────────┼───────────┐
        ▼           ▼           ▼
   windows.fels    linux.fels   (linux_gnu)     ← one impl per (os[,arch,env])
   kernel32     syscalls      libc
```

These seam primitives are in place today:

| Surface | Seam | Windows | Linux (freestanding) |
| --- | --- | --- | --- |
| I/O | `write_stdout`/`write_stderr` | `WriteFile` | `write` syscall |
| Heap | `os_reserve`/`os_commit`/`os_alloc`/`os_release` | `VirtualAlloc`/`VirtualFree` | `mmap`/`mprotect`/`munmap` |
| Time | `os_wall_nanos`/`os_monotonic_nanos`/`os_sleep_nanos` | kernel32 (FILETIME/QPC/Sleep) | `clock_gettime`/`nanosleep` |
| Exit/panic | `exit`/`abort`/`@panic` | `ExitProcess` | `exit` syscall |

To port a stdlib module to a new OS, you implement its seam primitives in that OS's runtime.
The module itself does not change. `std.io`, `std.heap` and `std.time` already run on Linux
this way, and so does everything built on them (`Vec`, maps, strings, `fmt`).

> **Runtime-free path note.** The `compile()` entry, which inline tests and tools use, has no
> runtime. The heap prelude is injected there automatically, so it ships a tiny host shim for
> the heap seam (`pipeline.prependHeapPrelude`). Modules imported from files (`std.time` and
> the like) always go through the file path, which prepends the runtime, so they need no shim.

## 3. libc vs freestanding (the `env` axis)

There are two ways to be a Linux binary. Fels supports both, and they differ **only** in the
entry point and the link step, never in the stdlib:

| | `none` / `musl` (freestanding, **default**) | `gnu` (glibc) |
| --- | --- | --- |
| Entry | our `#naked #entry _start` → `main` | crt1.o `_start` → `__libc_start_main` → `main` |
| Link | `ld.lld -static -e _start` | `-dynamic-linker /lib64/ld-linux-x86-64.so.2`, crt objects, `-lc` |
| Output | static non-PIE ELF, **zero deps** (`ldd` → "not a dynamic executable") | dynamically linked against `libc.so.6` |
| Needs at link time | only `ld.lld` | a libc toolchain / **sysroot** (crt1.o, libc.so, the loader) |
| OS seam | raw syscalls | raw syscalls *(unchanged)*, libc is used only for its loader/CRT |

**Decision: freestanding is the default and recommended Linux target.** It is self-contained
and portable across distros (the static-musl/Go/Zig model), and it needs nothing but `ld.lld`.
That is why it cross-compiles cleanly from a Windows host today. `gnu` is the opt-in for interop
with libc-only libraries, or for "a normal dynamically-linked binary."

Because the seam stays on raw syscalls, **`gnu` is purely a link-mode + entry change**. It means
gating off our `_start`, switching the `ld.lld` argument set and supplying the glibc objects.
The compiler plumbing for that is small. The real dependency is the **glibc files at link
time**, and those are not bundled. On a full Linux host, or with `--sysroot` pointing at one,
the link works with no extra steps. On a minimal box you first install `libc6-dev` (and use
`cc` as the link driver).

## 4. Architectures

LLVM gives us the back ends for free. The finite work for each arch is the **runtime** (syscall
ABI and entry stub) and the **aggregate ABI classifier** (`backend/llvm/abi.zig`, which is
already abstracted). Scalars are entirely LLVM's job, and only by-value aggregates at `#extern`
boundaries need a classifier.

| Arch | LLVM | Syscall ABI (nr / args / insn) | Aggregate ABI | Status |
| --- | --- | --- | --- | --- |
| **x86_64** | ✅ | `rax` / `rdi rsi rdx r10 r8 r9` / `syscall` | SysV AMD64 (done) | **implemented** |
| **aarch64** | ✅ | `x8` / `x0…x5` / `svc #0` | AAPCS64 | Tier 2 target, needs runtime + classifier |
| **riscv64** | ✅ | `a7` / `a0…a5` / `ecall` | RV calling conv | Tier 3, emerging |
| **wasm32** | ✅ | no syscalls, WASI imports | wasm ABI | Tier 3, different seam (WASI), no `_start` asm |

Adding an arch is a checklist, not a rewrite:

1. Triple and data layout: pass the arch to `emit.initTarget`.
2. Syscall wrappers for the arch and a `_start` stub in a runtime variant (the only asm).
3. An `abi.zig` `classify` arm for that arch's aggregate rules.
4. Register the arch in the `Target` and the runtime selector.

Everything above the seam (the entire stdlib) is already arch-independent.

aarch64-linux is the most valuable next arch, for cloud ARM, Apple Silicon through Linux VMs
and containers, and the Raspberry Pi. aarch64/x86_64 **macOS** is a separate and larger effort
(the Mach-O object format, different syscalls and ABI, code-signing), and it is tracked as
future Tier 3.

## 5. Support tiers

The tiers are borrowed from Rust's model and adapted to the seam architecture of Fels.

- **Tier 1 — guaranteed.** A first-class target that Fels commits to and gates releases on. The
  language, codegen and runtime build and run, and the test suite passes in CI. The stdlib is
  expected to be complete, and any remaining gap is a **release blocker**, not a reason to
  demote the target. *Regressions block a release.*
- **Tier 2 — supported.** The target builds and runs, and its stdlib is complete or nearly
  complete. It is smoke-tested, but not every module runs in CI. *Best-effort fixes.*
- **Tier 3 — experimental.** Codegen exists and may build, but the runtime and stdlib are
  partial or unverified, and there are no guarantees. *Community / opportunistic.*

| Target | Tier | Notes |
| --- | --- | --- |
| `x86_64-windows-msvc` | **1** | original host target, full stdlib |
| `x86_64-linux-none` (static) | **1** | first-class target that cross-compiles from Windows. Language, codegen and core stdlib (io/heap/time/Vec/strings) verified. Completing fs/process/net/thread is a **Tier-1 release blocker**, not a demotion |
| `x86_64-linux-gnu` (glibc) | **2** | implemented: `--target linux-gnu` + `--sysroot`. Our `_start` → `__libc_start_main`, links `libc.so.6` directly. Needs a sysroot with `libc.so.6` at link time |
| `aarch64-linux` | **3 → 2** | unblock by adding the aarch64 runtime + ABI arm |
| `riscv64-linux`, `wasm32-wasi` | **3** | LLVM-ready, runtime/seam not yet written |
| `*-macos` | **3** | Mach-O + Apple ABI, a larger effort |

## 6. Stdlib porting status (Linux)

| Module | Status | Seam needed on Linux |
| --- | --- | --- |
| `std.io` | ✅ ported | `write` (done) |
| `std.heap` | ✅ ported | `mmap`/`mprotect`/`munmap` (done) |
| `std.time` | ✅ ported | `clock_gettime`/`nanosleep` (done) |
| `std.fs` | ✅ ported | `openat`/`read`/`write`/`close`/`lseek`/`newfstatat`/`unlink`/`getdents64` (done) |
| `std.process` (all, incl. `set_env`) | ✅ ported | `getpid` + `/proc/self/{cmdline,environ}` + `fork`/`execve`(`/bin/sh -c`)/`wait4`/`kill`; `set_env`/`unset_env` via a runtime env overlay (done) |
| `std.net` | ✅ ported | socket syscalls (41/42/43/44/45/48/49/50/51/54) + SOL_SOCKET option translation + `fcntl` (done) |
| `std.thread` | ✅ ported | `clone` (allocated child stack, asm child-entry) + `wait4` join + `sched_getaffinity`/`sched_yield` (done) |
| `std.sync` | ✅ ported | `futex` (syscall 202, shared `FUTEX_WAIT`/`FUTEX_WAKE`) under a three-state mutex and a sequence-number condition variable (done) |

**Every `std` module runs on Linux, in full parity with Windows.** The static
`x86_64-linux-none` target has a complete stdlib, so it is Tier 1 in full.

> **Note — mutable globals + the env overlay.** `command_line`/`get_env` read
> `/proc/self/{cmdline,environ}`, so no captured `argv`/`envp` pointer is needed.
> `set_env`/`unset_env` were blocked at first, because Fels had no mutable top-level globals to
> anchor a process-wide environ. That language feature has since been added (`name: T = init;`,
> see [01_syntax](01_syntax.md)), so the runtime now keeps an env overlay. `get_env` consults it
> first, and `spawn` merges it into the child's environment. No parity gap remains.
