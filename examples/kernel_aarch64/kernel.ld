/* QEMU's virt machine has its RAM at 1 GiB; the kernel goes a little above, the stack after it */
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
