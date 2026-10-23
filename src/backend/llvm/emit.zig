/// Object file emission via LLVM TargetMachine.
///
/// Primary output: .o (native object file).
/// Debug helper:  dumpIr() prints the module as text to stderr.
const std = @import("std");
const llvm = @import("c_api.zig").llvm;
const ModuleCg = @import("context.zig").ModuleCg;

pub const EmitError = error{ TargetInitFailed, VerifyFailed, EmitFailed, OutOfMemory };

// Target setup

/// One-time global initialisation of the native target.
/// Safe to call multiple times (LLVM checks internally).
pub fn initNativeTarget() EmitError!void {
    if (llvm.LLVMInitializeNativeTarget() != 0)
        return error.TargetInitFailed;
    if (llvm.LLVMInitializeNativeAsmPrinter() != 0)
        return error.TargetInitFailed;
    if (llvm.LLVMInitializeNativeAsmParser() != 0)
        return error.TargetInitFailed;
    fastIsel();
}

/// The AArch64 backend, for a target that isn't the host's.
fn initAArch64() EmitError!void {
    llvm.LLVMInitializeAArch64TargetInfo();
    llvm.LLVMInitializeAArch64Target();
    llvm.LLVMInitializeAArch64TargetMC();
    llvm.LLVMInitializeAArch64AsmPrinter();
    llvm.LLVMInitializeAArch64AsmParser();
    fastIsel();
}

/// LLVM's command-line options, set once per process: at `-O0` it takes the instruction selector
/// from them (`LLVMSetTargetMachineFastISel` does not reach it).
var options_set = false;

/// Select instructions with FastISel at `-O0`, LLVM's default there. It cannot select a slice or
/// a struct passed, returned, loaded or stored whole, and hands the rest of each block where it
/// meets one to SelectionDAG, the slow selector. Fels code did that all the time, and Strata
/// took 2.5 s to emit with FastISel and 1.8 s with SelectionDAG alone, so FastISel was off.
/// Since fields are read where they are (`instrs.fieldOf`), FastISel is the faster of the two:
/// 1.1 s against 1.4 s for Strata.
fn fastIsel() void {
    if (options_set) return;
    options_set = true;
    const argv = [_][*:0]const u8{ "fels", "-fast-isel=true" };
    llvm.LLVMParseCommandLineOptions(argv.len, @ptrCast(&argv), null);
}

pub const TargetMachine = struct {
    tm: llvm.LLVMTargetMachineRef,
    triple: [*c]u8,

    /// Create a TargetMachine for the host machine.
    /// `opt_level`: 0 = none, 1 = less, 2 = default, 3 = aggressive.
    pub fn initNative(opt_level: u2) EmitError!TargetMachine {
        try initNativeTarget();

        const triple = llvm.LLVMGetDefaultTargetTriple();

        var target: llvm.LLVMTargetRef = undefined;
        var err: [*c]u8 = null;
        if (llvm.LLVMGetTargetFromTriple(triple, &target, &err) != 0) {
            if (err) |msg| llvm.LLVMDisposeMessage(msg);
            llvm.LLVMDisposeMessage(triple);
            return error.TargetInitFailed;
        }

        // Use the host CPU name and its feature string so the emitted code
        // can use all available instruction sets (AVX, SSE4, etc.).
        const cpu = llvm.LLVMGetHostCPUName();
        const features = llvm.LLVMGetHostCPUFeatures();
        defer llvm.LLVMDisposeMessage(cpu);
        defer llvm.LLVMDisposeMessage(features);

        const llvm_opt: llvm.LLVMCodeGenOptLevel = switch (opt_level) {
            0 => llvm.LLVMCodeGenLevelNone,
            1 => llvm.LLVMCodeGenLevelLess,
            2 => llvm.LLVMCodeGenLevelDefault,
            3 => llvm.LLVMCodeGenLevelAggressive,
        };

        const tm = llvm.LLVMCreateTargetMachine(
            target,
            triple,
            cpu,
            features,
            llvm_opt,
            llvm.LLVMRelocDefault, // executables use absolute addressing; PIC is for DLLs
            llvm.LLVMCodeModelDefault,
        );

        return .{ .tm = tm, .triple = triple };
    }

    /// Create a TargetMachine for an explicit target OS and architecture (cross-compilation).
    /// Falls back to the host path when the target is the host. Linux x86-64 is a static,
    /// non-PIE ELF using the SysV ABI (LLVM derives both from the triple); aarch64 is built for
    /// UEFI and freestanding programs.
    pub fn initTarget(target_os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch, opt_level: u2) EmitError!TargetMachine {
        const builtin = @import("builtin");
        if (target_os == builtin.os.tag and arch == builtin.cpu.arch) return initNative(opt_level);
        if (arch == .aarch64) try initAArch64() else try initNativeTarget(); // the host's X86 backend also emits for x86_64-linux

        const triple_lit = if (arch == .aarch64) switch (target_os) {
            // AArch64 UEFI is a PE file too, with the AAPCS64 convention.
            .uefi => "aarch64-pc-windows-msvc",
            .freestanding => "aarch64-unknown-none-elf",
            else => return error.TargetInitFailed,
        } else switch (target_os) {
            .linux => "x86_64-unknown-linux-musl",
            // A UEFI program is a PE file that calls the firmware with the Windows convention.
            .uefi => "x86_64-pc-windows-msvc",
            // No OS: an ELF a boot loader loads, or a kernel's own.
            .freestanding => "x86_64-unknown-none-elf",
            else => return error.TargetInitFailed,
        };
        const triple = llvm.LLVMCreateMessage(triple_lit); // disposable copy (deinit frees it)

        var target: llvm.LLVMTargetRef = undefined;
        var err: [*c]u8 = null;
        if (llvm.LLVMGetTargetFromTriple(triple, &target, &err) != 0) {
            if (err) |msg| llvm.LLVMDisposeMessage(msg);
            llvm.LLVMDisposeMessage(triple);
            return error.TargetInitFailed;
        }

        const llvm_opt: llvm.LLVMCodeGenOptLevel = switch (opt_level) {
            0 => llvm.LLVMCodeGenLevelNone,
            1 => llvm.LLVMCodeGenLevelLess,
            2 => llvm.LLVMCodeGenLevelDefault,
            3 => llvm.LLVMCodeGenLevelAggressive,
        };

        const tm = llvm.LLVMCreateTargetMachine(
            target,
            triple,
            // a baseline CPU, so the binary runs on any x86-64 or ARMv8-A
            if (arch == .aarch64) "generic" else "x86-64",
            "",
            llvm_opt,
            llvm.LLVMRelocStatic, // static, non-PIE executable
            llvm.LLVMCodeModelDefault,
        );

        return .{ .tm = tm, .triple = triple };
    }

    pub fn deinit(self: TargetMachine) void {
        llvm.LLVMDisposeTargetMachine(self.tm);
        llvm.LLVMDisposeMessage(self.triple);
    }

    /// Stamp the target triple and data layout onto the LLVM module.
    /// Must be called before emitting — ensures the module matches the target.
    pub fn applyToModule(self: TargetMachine, cg: *ModuleCg) void {
        llvm.LLVMSetTarget(cg.mod, self.triple);

        const layout = llvm.LLVMCreateTargetDataLayout(self.tm);
        defer llvm.LLVMDisposeTargetData(layout);

        const layout_str = llvm.LLVMCopyStringRepOfTargetData(layout);
        defer llvm.LLVMDisposeMessage(layout_str);

        llvm.LLVMSetDataLayout(cg.mod, layout_str);
    }
};

// Verification

/// Verify the LLVM module.  On failure, prints LLVM's error to stderr and
/// returns `error.VerifyFailed`.
pub fn verify(cg: *ModuleCg) EmitError!void {
    var err: [*c]u8 = null;
    if (llvm.LLVMVerifyModule(cg.mod, llvm.LLVMReturnStatusAction, &err) != 0) {
        if (err) |msg| {
            std.debug.print("LLVM verification error:\n{s}\n", .{msg});
            llvm.LLVMDisposeMessage(msg);
        }
        return error.VerifyFailed;
    }
}

// Optimisation

/// LLVM's optimisation pipeline for `opt_level`, the one clang runs at the same `-O`: inlining,
/// SROA, loop-invariant code motion, unrolling, vectorisation and the rest. Without it the
/// level only reaches the code generator, which works one function at a time and leaves the
/// loops as they were written. Nothing runs at `-O0`.
pub fn optimize(cg: *ModuleCg, tm: TargetMachine, opt_level: u2) EmitError!void {
    const pipeline: [*:0]const u8 = switch (opt_level) {
        0 => return,
        1 => "default<O1>",
        2 => "default<O2>",
        3 => "default<O3>",
    };
    notBuiltins(cg);
    const options = llvm.LLVMCreatePassBuilderOptions();
    defer llvm.LLVMDisposePassBuilderOptions(options);
    if (llvm.LLVMRunPasses(cg.mod, pipeline, tm.tm, options)) |err| {
        const msg = llvm.LLVMGetErrorMessage(err);
        defer llvm.LLVMDisposeErrorMessage(msg);
        std.debug.print("LLVM optimisation error: {s}\n", .{msg});
        return error.EmitFailed;
    }
}

/// Marks the program's own functions `nobuiltin`, and with them every call to one. Fels names
/// its functions as they are written, so std.math's `sin` and `pow` are `@sin` and `@pow` in
/// the module, and LLVM takes a function by that name for the C library's: it would fold a
/// call to one by what the C function does, or replace it with a call to another the program
/// does not have (`pow(2.0, x)` with `exp2(x)`).
fn notBuiltins(cg: *ModuleCg) void {
    const kind = llvm.LLVMGetEnumAttributeKindForName("nobuiltin", "nobuiltin".len);
    const attr = llvm.LLVMCreateEnumAttribute(cg.ctx, kind, 0);
    var f = llvm.LLVMGetFirstFunction(cg.mod);
    while (f) |fv| : (f = llvm.LLVMGetNextFunction(fv)) {
        if (llvm.LLVMIsDeclaration(fv) == 0) llvm.LLVMAddAttributeAtIndex(fv, 0xFFFF_FFFF, attr); // LLVMAttributeFunctionIndex
    }
}

// Dead function removal

/// Delete every internal function nothing refers to, repeating until none is left (deleting
/// one can orphan the functions it called). The functions a `#run` evaluated at compile time
/// end up like this: the VM ran them and their result is now plain data, but they are still
/// in the module, and the code generator would compile them in full. A function that returns
/// or copies a large array by value is slow to compile — x86 splits the aggregate into one
/// piece per element, which with the host's wide vector registers took 15 s for 4096 `u32`s.
pub fn dropDeadFunctions(cg: *ModuleCg) void {
    var removed = true;
    while (removed) {
        removed = false;
        var f = llvm.LLVMGetFirstFunction(cg.mod);
        while (f) |fv| {
            const next = llvm.LLVMGetNextFunction(fv);
            if (llvm.LLVMGetLinkage(fv) == llvm.LLVMInternalLinkage and llvm.LLVMGetFirstUse(fv) == null) {
                llvm.LLVMDeleteFunction(fv);
                removed = true;
            }
            f = next;
        }
    }
}

// Object file emission

/// Emit a native object file at `path`.
///
/// Typical usage:
///   const tm = try TargetMachine.initNative(2);   // opt level 2
///   defer tm.deinit();
///   tm.applyToModule(&cg);
///   try verify(&cg);
///   try emitObject(&cg, tm, "output.o");
/// Emit the object into an allocator-owned byte buffer (caller frees) instead of
/// a file — so the linker can consume it in memory with no disk round-trip.
pub fn emitObjectToMemory(cg: *ModuleCg, tm: TargetMachine, allocator: std.mem.Allocator) EmitError![]u8 {
    var err: [*c]u8 = null;
    var membuf: llvm.LLVMMemoryBufferRef = null;
    if (llvm.LLVMTargetMachineEmitToMemoryBuffer(
        tm.tm,
        cg.mod,
        llvm.LLVMObjectFile,
        &err,
        &membuf,
    ) != 0) {
        if (err) |msg| {
            std.debug.print("LLVM emit error: {s}\n", .{msg});
            llvm.LLVMDisposeMessage(msg);
        }
        return error.EmitFailed;
    }
    defer llvm.LLVMDisposeMemoryBuffer(membuf);
    const start = llvm.LLVMGetBufferStart(membuf);
    const size = llvm.LLVMGetBufferSize(membuf);
    const bytes = allocator.alloc(u8, size) catch return error.EmitFailed;
    @memcpy(bytes, start[0..size]);
    return bytes;
}

pub fn emitObject(cg: *ModuleCg, tm: TargetMachine, path: [*:0]const u8) EmitError!void {
    var err: [*c]u8 = null;
    if (llvm.LLVMTargetMachineEmitToFile(
        tm.tm,
        cg.mod,
        // LLVM C API takes a mutable char* here, but we only read it
        @constCast(path),
        llvm.LLVMObjectFile,
        &err,
    ) != 0) {
        if (err) |msg| {
            std.debug.print("LLVM emit error: {s}\n", .{msg});
            llvm.LLVMDisposeMessage(msg);
        }
        return error.EmitFailed;
    }
}

// Debug helpers

/// Print the module as LLVM text IR to stderr (useful for debugging codegen).
pub fn dumpIr(cg: *ModuleCg) void {
    llvm.LLVMDumpModule(cg.mod);
}

/// Return the module as an LLVM text IR string (caller frees with allocator).
pub fn getIrText(cg: *ModuleCg, allocator: std.mem.Allocator) ![]u8 {
    const raw = llvm.LLVMPrintModuleToString(cg.mod);
    defer llvm.LLVMDisposeMessage(raw);
    return allocator.dupe(u8, std.mem.span(raw));
}
