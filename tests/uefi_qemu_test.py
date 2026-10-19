#!/usr/bin/env python3
"""Build a UEFI program with fels and boot it in QEMU with the UEFI firmware QEMU comes with:
it prints, allocates in a zone and turns the machine off, and the firmware's console (the
serial port) must show what it printed.

    python tests/uefi_qemu_test.py <fels.exe> <qemu folder> [--std-path <lib>]

The QEMU folder holds qemu-system-x86_64 and share/edk2-x86_64-code.fd. Prints PASS or FAIL.
"""
import os
import shutil
import subprocess
import sys
import tempfile

SRC = """\
#import std.io.{ println };
#import std.uefi;

sum :: fn(n: u32) -> u32 {
    total := 0u32;
    zone z: Arena {
        xs := z.new_slice(u32, n as usize);
        for i in 0usize..xs.len { xs[i] = (i as u32) + 1u32; }
        for x in xs { total += x; }
    }
    return total;
}

main :: fn() -> i32 {
    println("fels uefi test: start");
    println("sum {sum(100u32)}");
    println("fels uefi test: done");
    uefi::shutdown();
    return 0;
}
"""


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    fels, qemu_dir = sys.argv[1], sys.argv[2]
    extra = sys.argv[3:]
    qemu = os.path.join(qemu_dir, "qemu-system-x86_64" + (".exe" if os.name == "nt" else ""))
    firmware = os.path.join(qemu_dir, "share", "edk2-x86_64-code.fd")
    for p in (qemu, firmware):
        if not os.path.exists(p):
            print("SKIP: no " + p)
            return

    work = tempfile.mkdtemp()
    src = os.path.join(work, "uefi_test.fels")
    with open(src, "w", encoding="utf-8", newline="\n") as f:
        f.write(SRC)
    efi = os.path.join(work, "uefi_test.efi")
    b = subprocess.run([fels, "build", src, "--target", "uefi", "-q", "-o", efi] + extra, capture_output=True, text=True)
    if b.returncode != 0:
        print(b.stdout + b.stderr)
        print("RESULT: FAIL (build)")
        sys.exit(1)

    boot = os.path.join(work, "esp", "EFI", "BOOT")
    os.makedirs(boot)
    shutil.copy(efi, os.path.join(boot, "BOOTX64.EFI"))
    serial = os.path.join(work, "serial.txt")
    cmd = [qemu, "-machine", "q35", "-m", "256",
           "-drive", "if=pflash,format=raw,readonly=on,file=" + firmware,
           "-drive", "format=raw,file=fat:rw:" + os.path.join(work, "esp"),
           "-display", "none", "-serial", "file:" + serial, "-no-reboot"]
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=60)
        ended = r.returncode == 0
    except subprocess.TimeoutExpired:
        ended = False
    out = open(serial, encoding="utf-8", errors="replace").read().replace("\r", "") if os.path.exists(serial) else ""

    checks = [
        ("the program's lines on the firmware's console", "fels uefi test: start" in out and "fels uefi test: done" in out),
        ("a zone allocates the firmware's pages", "sum 5050" in out),
        ("shutdown ends QEMU", ended),
    ]
    failed = False
    for name, ok in checks:
        print("%-4s %s" % ("ok" if ok else "FAIL", name))
        failed = failed or not ok
    if failed:
        print(out[-2000:])
        print("RESULT: FAIL")
        sys.exit(1)
    print("RESULT: PASS")


if __name__ == "__main__":
    main()
