#!/usr/bin/env python3
"""Build a freestanding kernel with fels and boot it in QEMU as a multiboot kernel: a 32-bit
start in its own assembly sets up long mode and calls `_start`, which calls `main`. It prints
through the serial port (std.freestanding.set_output, std.x86.outb), uses zones on the static
heap and on memory it adds, handles int3 and a page fault in #interrupt functions, and ends
QEMU through its debug-exit port.

    python tests/freestanding_qemu_test.py <fels.exe> <qemu folder> [--llvm-path <llvm>] [--std-path <lib>]

The QEMU folder holds qemu-system-x86_64. Prints PASS or FAIL.
"""
import os
import subprocess
import sys
import tempfile

KERNEL = r'''
#import std.io.{ println };
#import std.freestanding;
#import std.x86;

// QEMU's -kernel loads a multiboot kernel: the header (with the load addresses, as this is no
// 32-bit ELF), then the start in 32-bit mode: identity-map the first GiB with 2 MiB pages,
// enable long mode and SSE, and call _start.
#naked
#keep
boot32 :: fn() {
    unsafe {
        core::asm(volatile, """
            .pushsection .multiboot, "a"
            .align 4
            mb_header:
            .long 0x1BADB002
            .long 0x00010000
            .long -(0x1BADB002 + 0x00010000)
            .long mb_header
            .long mb_header
            .long edata
            .long end
            .long _start32
            .popsection
            .pushsection .text.boot32, "ax"
            .code32
            .globl _start32
            _start32:
            cli
            mov $$0x80000, %esp
            mov $$0x1000, %edi
            xor %eax, %eax
            mov $$3072, %ecx
            rep stosl
            movl $$0x2003, 0x1000
            movl $$0x3003, 0x2000
            mov $$0x3000, %edi
            mov $$0x83, %eax
            mov $$512, %ecx
            1:
            mov %eax, (%edi)
            add $$0x200000, %eax
            add $$8, %edi
            loop 1b
            mov $$0x1000, %eax
            mov %eax, %cr3
            mov %cr4, %eax
            or $$0x620, %eax
            mov %eax, %cr4
            mov $$0xC0000080, %ecx
            rdmsr
            or $$0x100, %eax
            wrmsr
            mov %cr0, %eax
            and $$0xFFFFFFFB, %eax
            or $$0x80000003, %eax
            mov %eax, %cr0
            lgdt gdt_ptr
            ljmp $$0x08, $$long_mode
            .code64
            long_mode:
            mov $$0x10, %ax
            mov %ax, %ds
            mov %ax, %es
            mov %ax, %ss
            mov %ax, %fs
            mov %ax, %gs
            mov $$0x80000, %rsp
            call _start
            2:
            hlt
            jmp 2b
            .align 8
            gdt:
            .quad 0
            .quad 0x00AF9B000000FFFF
            .quad 0x00CF93000000FFFF
            gdt_ptr:
            .word gdt_ptr - gdt - 1
            .long gdt
            .popsection
            """, inputs: {}, outputs: {}, clobbers: {});
    }
}

serial_write :: fn(p: *const u8, n: usize) {
    for i in 0usize..n {
        x86::outb(0x3F8u16, unsafe *core::ptr_from_int(*const u8, (p as usize) + i));
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

// 4 MiB zones, more than the static heap, from memory given at 4 MiB; each gives it back
heap_reuse :: fn() -> bool {
    freestanding::add_memory(0x400000usize, 0x2000000usize);
    before := freestanding::free_memory();
    for round in 0u32..200u32 {
        zone z: Arena {
            big := z.new_slice(u8, 4194304usize);
            big[4194303usize] = 1u8;
        }
    }
    return freestanding::free_memory() == before;
}

// ---- interrupts ----

breakpoints: u32 = 0u32;
table: x86::Idt = .{ .gates = .{} };

#interrupt
on_breakpoint :: fn(frame: *const x86::InterruptFrame) {
    breakpoints += 1u32;
}

// a page fault can't return to the access, so it reports and ends QEMU (isa-debug-exit:
// (0x10 << 1) | 1 = 33)
#interrupt
on_page_fault :: fn(frame: *const x86::InterruptFrame, code: u64) {
    println("page fault at {x86::read_cr2()} code {code} from kernel code {frame.cs == (x86::read_cs() as u64)}");
    x86::outb(0xF4u16, 0x10u8);
}

main :: fn() -> i32 {
    freestanding::set_output(serial_write);
    println("fels kernel: start");
    println("sum {sum(100u32)}");
    if heap_reuse() { println("heap reused"); }
    // leaf 0 gives the highest leaf, which is never 0 on a 64-bit cpu
    println("cpuid max leaf {x86::cpuid(0u32, 0u32).eax}");
    table.set(3u8, core::fn_ptr(on_breakpoint));
    table.set(14u8, core::fn_ptr(on_page_fault));
    table.load();
    x86::breakpoint();
    x86::breakpoint();
    println("breakpoints {breakpoints}");
    println("fels kernel: done");
    // the boot maps the first GiB; 1 GiB faults
    v := unsafe *core::ptr_from_int(*const u8, 0x40000000usize);
    println("not reached {v}");
    return 0;
}
'''

LINKER_SCRIPT = '''
ENTRY(_start32)
SECTIONS {
    . = 0x100000;
    .multiboot : { KEEP(*(.multiboot)) }
    .text : { *(.text.boot32) *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    edata = .;
    .bss : { *(.bss*) *(COMMON) }
    end = .;
}
'''


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    fels, qemu_dir = sys.argv[1], sys.argv[2]
    extra = sys.argv[3:]
    qemu = os.path.join(qemu_dir, "qemu-system-x86_64" + (".exe" if os.name == "nt" else ""))
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
    out = os.path.join(work, "kernel.bin")
    b = subprocess.run([fels, "build", src, "--target", "freestanding", "-O2", "-q", "-o", out,
                        "--link-arg", "--script=" + ld, "--link-arg", "--oformat=binary"] + extra,
                       capture_output=True, text=True)
    if b.returncode != 0:
        print(b.stdout + b.stderr)
        print("RESULT: FAIL (build)")
        sys.exit(1)

    serial = os.path.join(work, "serial.txt")
    cmd = [qemu, "-kernel", out, "-display", "none", "-serial", "file:" + serial,
           "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04", "-no-reboot"]
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=60)
        code = r.returncode
    except subprocess.TimeoutExpired:
        code = None
    text = open(serial, encoding="utf-8", errors="replace").read() if os.path.exists(serial) else ""

    checks = [
        ("main runs and prints through the serial port", "fels kernel: start" in text and "fels kernel: done" in text),
        ("a zone takes the static heap", "sum 5050" in text),
        ("zones give their memory back, and take memory added at run time", "heap reused" in text),
        ("cpuid answers", "cpuid max leaf " in text and "cpuid max leaf 0\n" not in text),
        ("an #interrupt function handles int3 and returns", "breakpoints 2" in text),
        ("an #interrupt function gets the page fault's error code",
         "page fault at 1073741824 code 0 from kernel code true" in text),
        ("the debug-exit port ends QEMU", code == 33 and "not reached" not in text),
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
