/* the kernel at 1 MiB; edata and end tell the multiboot loader what to load and zero */
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
