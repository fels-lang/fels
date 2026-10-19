# uefi: a program with no operating system

`main.fels` runs straight on the firmware. It prints through the firmware's console, draws a
gradient and a white box on the screen, waits for a key and turns the machine off.

```text
fels build examples/uefi/main.fels --target uefi
```

That makes `main.efi`, a UEFI application. To run it in QEMU, put it where the firmware looks
for one on a FAT drive, and start QEMU with the UEFI firmware that comes with it
(`share/edk2-x86_64-code.fd`):

```text
mkdir esp/EFI/BOOT
copy main.efi esp/EFI/BOOT/BOOTX64.EFI
qemu-system-x86_64 -machine q35 -m 256 ^
    -drive if=pflash,format=raw,readonly=on,file=<qemu>/share/edk2-x86_64-code.fd ^
    -drive format=raw,file=fat:rw:esp
```

The text also goes to the serial port: add `-serial stdio` to see it in the terminal. On a real
PC, copy `BOOTX64.EFI` to `EFI/BOOT/` on a FAT32 USB stick and boot from it (with Secure Boot
off, as the program is not signed).

What a UEFI program has: `println` and the rest of `std.io`'s printing, zones (their memory
comes from the firmware's pages) and `std.uefi`: the system table, `stall`, `read_key`,
`clear`, `framebuffer`, `shutdown` and `reboot`. What it does not have: files, processes,
threads, the network and `#extern`, as there is no operating system to give them.
