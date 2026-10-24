# kernel: a program with no operating system and no firmware

`main.fels` is a small x86-64 kernel. QEMU loads it as a multiboot kernel, a few lines of
assembly in `boot32` switch the CPU from 32-bit to 64-bit mode, and the `_start` the compiler
makes for `main` calls it. It prints on the VGA text screen and the serial port, sums a slice
from a zone, handles an `int3` in an `#interrupt` function and halts.

```text
cd examples/kernel
fels build
qemu-system-x86_64 -kernel kernel.bin -serial stdio
```

`build.fels` builds for `.freestanding` and hands the linker `kernel.ld` and
`--oformat=binary`: QEMU's `-kernel` takes a 32-bit image, so the kernel is a flat binary
whose multiboot header says where to load it. Without `build.fels` that is:

```text
fels build main.fels --target freestanding -O2 -o kernel.bin --link-arg --script=kernel.ld --link-arg --oformat=binary
```

What a freestanding program has: `println` and the rest of `std.io`'s printing (to whatever
`std.freestanding.set_output` names), zones (from a 1 MiB static heap and the memory
`std.freestanding.add_memory` gives), `core::asm` and `std.x86`: port I/O, `cli`/`sti`/`hlt`,
`lgdt`/`lidt`, the control registers, MSRs, `rdtsc` and `cpuid`, an `Idt` and the
`InterruptFrame` an `#interrupt` function gets. Every function is built without the red zone,
so an interrupt can't overwrite a caller's locals. What it does not have: files, processes,
threads, the network and `#extern`.

Without `main`, the program's own `#entry` is where the ELF starts, for a boot loader that
sets up long mode itself.
