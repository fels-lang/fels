# kernel_aarch64: a kernel for 64-bit ARM

`main.fels` is a small AArch64 kernel for QEMU's `virt` machine. QEMU loads the ELF and starts
it at EL1, a few lines of assembly in `boot` set the stack and turn FP and SIMD on, and the
`_start` the compiler makes for `main` calls it. It prints through the PL011 UART, reads the
timer, sums a slice from a zone, handles a `brk` in an ordinary function and turns the machine
off.

```text
cd examples/kernel_aarch64
fels build
qemu-system-aarch64 -machine virt -cpu cortex-a57 -kernel kernel.elf -nographic
```

`build.fels` builds for `.freestanding` with `.arch(.aarch64)` and hands the linker
`kernel.ld`, which puts the kernel in the machine's RAM. Without `build.fels` that is:

```text
fels build main.fels --target aarch64-freestanding -O2 -o kernel.elf --link-arg --script=kernel.ld
```

Exceptions: `aarch64::set_exception_handler(on_exception)` points the CPU's vector table at
the one `std.aarch64` has. It saves every register, calls `on_exception` with them and the
vector, puts them back and returns to `frame.elr`, which the handler may move on.

Code for `--target aarch64-freestanding` makes no unaligned memory access: until a kernel
turns the MMU on, the CPU faults on one. `std.aarch64` also has the barriers, `wfi`, the
interrupt mask, the timer and the registers for paging. The x86-64 kernel is
`examples/kernel`.
