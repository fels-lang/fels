#!/usr/bin/env python3
"""Build an aarch64 freestanding kernel with fels and boot it on QEMU's `virt` machine: QEMU
loads the ELF and starts it at EL1; a few lines of assembly set the stack, turn FP and SIMD on
and call `_start`, which calls `main`. It prints through the PL011 UART, uses zones on the
static heap and on memory it adds, handles brk and a data abort in an ordinary function
(std.aarch64.set_exception_handler) and ends QEMU with an exit code through semihosting.

    python tests/freestanding_aarch64_qemu_test.py <fels.exe> <qemu folder> [--llvm-path <llvm>] [--std-path <lib>]

The QEMU folder holds qemu-system-aarch64. Prints PASS or FAIL.
"""
import os
import subprocess
import sys
import tempfile

KERNEL = r'''
#import std.io.{ println };
#import std.freestanding;
#import std.aarch64;

// the start QEMU jumps to: the stack, FP and SIMD on (CPACR_EL1.FPEN), then _start
#naked
#keep
boot :: fn() {
    unsafe {
        core::asm(volatile, """
            .pushsection .text.boot, "ax"
            .globl _boot
            _boot:
            mov x0, #0x300000
            msr cpacr_el1, x0
            isb
            adrp x0, stack_top
            add x0, x0, :lo12:stack_top
            mov sp, x0
            bl _start
            1:
            wfi
            b 1b
            .popsection
            """, inputs: {}, outputs: {}, clobbers: {});
    }
}

// the PL011 UART of QEMU's virt machine: a byte written to its data register goes out
uart_write :: fn(p: *const u8, n: usize) {
    for i in 0usize..n {
        c := unsafe *core::ptr_from_int(*const u8, (p as usize) + i);
        unsafe { core::volatile_store(core::ptr_from_int(*u8, 0x09000000usize), c); }
    }
}

// semihosting SYS_EXIT: QEMU (with -semihosting) exits with `code`
semihost_exit :: fn(code: u64) {
    block: [2]u64 = .{ 0x20026u64, code };
    unsafe {
        core::asm(volatile, "mov x0, #0x18; hlt #0xf000", inputs: { "{x1}"(&block[0]) }, outputs: {}, clobbers: { "x0", "memory" });
    }
}

sum :: fn(n: u32) -> u32 {
    total := 0u32;
    zone z: Arena {
        xs := z.new_slice(u32, n as usize);
        for i in 0usize..xs.len { xs[i] = (i as u32) + 1u32; }
        for x in xs { total += x; }
    }
    return total;
}

// 4 MiB zones, more than the static heap, from 32 MiB of RAM given at 0x41000000
heap_reuse :: fn() -> bool {
    freestanding::add_memory(0x41000000usize, 0x2000000usize);
    before := freestanding::free_memory();
    for round in 0u32..100u32 {
        zone z: Arena {
            big := z.new_slice(u8, 4194304usize);
            big[4194303usize] = 1u8;
        }
    }
    return freestanding::free_memory() == before;
}

breaks: u32 = 0u32;

// brk goes on after itself; a data abort can't, so it reports and ends QEMU
on_exception :: fn(frame: *aarch64::ExceptionFrame, vector: u64) {
    class := aarch64::exception_class(frame.esr);
    if vector == aarch64::SYNC && class == 0x3Cu64 {
        breaks += 1u32;
        frame.elr += 4u64;
        return;
    }
    println("exception {vector} class {class} at {frame.far}");
    semihost_exit(33u64);
}

main :: fn() -> i32 {
    freestanding::set_output(uart_write);
    println("fels kernel on {core::arch} at EL{aarch64::current_el()}");
    println("sum {sum(100u32)}");
    if heap_reuse() { println("heap reused"); }
    f := 1.5;
    println("float {f * 3.0}");
    aarch64::set_exception_handler(on_exception);
    aarch64::breakpoint();
    aarch64::breakpoint();
    println("breaks {breaks}");
    println("fels kernel: done");
    // nothing answers at 4 GiB: a synchronous external abort
    v := unsafe *core::ptr_from_int(*const u8, 0x100000000usize);
    println("not reached {v}");
    return 0;
}
'''

LINKER_SCRIPT = '''
ENTRY(_boot)
SECTIONS {
    . = 0x40080000;
    .text : { KEEP(*(.text.boot)) *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    .bss : { *(.bss*) *(COMMON) }
    . = ALIGN(16);
    . = . + 0x20000;
    stack_top = .;
}
'''


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    fels, qemu_dir = sys.argv[1], sys.argv[2]
    extra = sys.argv[3:]
    qemu = os.path.join(qemu_dir, "qemu-system-aarch64" + (".exe" if os.name == "nt" else ""))
    if not os.path.exists(qemu):
        print("SKIP: no " + qemu)
        return

    work = tempfile.mkdtemp()
    src = os.path.join(work, "kernel.fels")
    ld = os.path.join(work, "kernel.ld")
    with open(src, "w", encoding="utf-8", newline="\n") as f:
        f.write(KERNEL)
    with open(ld, "w", encoding="utf-8", newline="\n") as f:
        f.write(LINKER_SCRIPT)
    out = os.path.join(work, "kernel.elf")
    b = subprocess.run([fels, "build", src, "--target", "aarch64-freestanding", "-O2", "-q", "-o", out,
                        "--link-arg", "--script=" + ld] + extra,
                       capture_output=True, text=True)
    if b.returncode != 0:
        print(b.stdout + b.stderr)
        print("RESULT: FAIL (build)")
        sys.exit(1)

    serial = os.path.join(work, "serial.txt")
    cmd = [qemu, "-machine", "virt", "-cpu", "cortex-a57", "-m", "128", "-kernel", out,
           "-display", "none", "-serial", "file:" + serial, "-semihosting", "-no-reboot"]
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=60)
        code = r.returncode
    except subprocess.TimeoutExpired:
        code = None
    text = open(serial, encoding="utf-8", errors="replace").read() if os.path.exists(serial) else ""

    checks = [
        ("main runs at EL1 and prints through the UART", "fels kernel on aarch64 at EL1" in text and "fels kernel: done" in text),
        ("a zone takes the static heap", "sum 5050" in text),
        ("zones give their memory back, and take memory added at run time", "heap reused" in text),
        ("floating point works", "float 4.5" in text),
        ("an ordinary function handles brk and goes on", "breaks 2" in text),
        ("it gets the data abort, with the address", "exception 4 class 37 at 4294967296" in text),
        ("semihosting ends QEMU with the code", code == 33 and "not reached" not in text),
    ]
    failed = False
    for name, ok in checks:
        print("%-4s %s" % ("ok" if ok else "FAIL", name))
        failed = failed or not ok
    if failed:
        print("exit code:", code)
        print(text[-2000:])
        print("RESULT: FAIL")
        sys.exit(1)
    print("RESULT: PASS")


if __name__ == "__main__":
    main()
