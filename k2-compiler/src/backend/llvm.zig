/// LLVM codegen backend — entry point.
///
/// Quick start (Windows, no libc):
///
///   var be = LlvmBackend.init(allocator, "my_module");
///   defer be.deinit();
///   try be.lower(ir_module);
///   try be.emitObject("output.o", 2);          // → .o file
///   try be.linkWindows(.{                       // → .exe
///       .llvm_bin  = "Y:/SDK/llvm/bin",
///       .obj_files = &.{"output.o"},
///       .output    = "output.exe",
///   });
///
/// The Windows entry point (mainCRTStartup) is **automatically generated**
/// when the module contains a function marked as entry (`main` or `#entry`).
/// It calls the K2 main, then ExitProcess — no separate k2rt file needed.
const std = @import("std");
const ir = @import("../ir.zig");
const ctx_mod = @import("llvm/context.zig");
const structs = @import("llvm/structs.zig");
const globals = @import("llvm/globals.zig");
const fns = @import("llvm/functions.zig");
const emit = @import("llvm/emit.zig");
const link = @import("llvm/link.zig");
const vars_mod = @import("llvm/variants.zig");
const vtables = @import("llvm/vtables.zig");
const llvm_c = @import("llvm/c_api.zig").llvm;

pub const LlvmBackend = struct {
    cg: ctx_mod.ModuleCg,

    pub fn init(allocator: std.mem.Allocator, module_name: [*:0]const u8) LlvmBackend {
        return .{ .cg = ctx_mod.ModuleCg.init(allocator, module_name) };
    }

    pub fn deinit(self: *LlvmBackend) void {
        self.cg.deinit();
    }

    /// Lower a complete IrModule to LLVM IR in memory.
    pub fn lower(self: *LlvmBackend, module: ir.IrModule) !void {
        try vars_mod.lowerAll(&self.cg, module.variants); // enums first (referenced by fns)
        try structs.lowerAll(&self.cg, module.structs);
        try globals.lowerAll(&self.cg, module.globals);
        try fns.declareAll(&self.cg, module.functions);
        try vtables.lowerAll(&self.cg, module.vtables);
        try fns.defineAll(&self.cg, module.functions);

        // Auto-generate the platform entry point if needed.
        for (module.functions) |f| {
            if (f.entry) {
                try emitWindowsEntryPoint(&self.cg, f.name);
                break;
            }
        }
    }

    /// Emit a native object file.
    /// `opt_level`: 0=none 1=less 2=default 3=aggressive.
    pub fn emitObject(self: *LlvmBackend, path: [*:0]const u8, opt_level: u2) !void {
        const tm = try emit.TargetMachine.initNative(opt_level);
        defer tm.deinit();
        tm.applyToModule(&self.cg);
        try emit.verify(&self.cg);
        try emit.emitObject(&self.cg, tm, path);
    }

    /// Link object files into a Windows executable via lld-link.
    pub fn linkWindows(self: *LlvmBackend, allocator: std.mem.Allocator, io: std.Io, opts: link.WindowsLinkOptions) !void {
        _ = self;
        return link.windows(allocator, io, opts);
    }

    /// Dump the LLVM IR to stderr (debugging).
    pub fn dumpIr(self: *LlvmBackend) void {
        emit.dumpIr(&self.cg);
    }

    /// Return the LLVM IR as text (debugging/testing).
    pub fn getIrText(self: *LlvmBackend, allocator: std.mem.Allocator) ![]u8 {
        return emit.getIrText(&self.cg, allocator);
    }
};

/// Convenience wrapper — link step exposed at module level.
pub const linkWindows = link.windows;

// ── Windows entry point generator ────────────────────────────────────────────
//
// When the K2 module has an `entry` function, automatically emit:
//
//   void mainCRTStartup() {
//       ExitProcess((u32)main());
//   }
//
// This replaces k2rt — no separate object file to compile or distribute.

fn emitWindowsEntryPoint(cg: *ctx_mod.ModuleCg, main_name: []const u8) !void {
    // Declare ExitProcess(u32) if not already present.
    const ep_sym = "ExitProcess";
    if (!cg.fn_decls.contains(ep_sym)) {
        const u32_ty = llvm_c.LLVMInt32TypeInContext(cg.ctx);
        const void_ty = llvm_c.LLVMVoidTypeInContext(cg.ctx);
        const ep_ty = llvm_c.LLVMFunctionType(void_ty, @constCast(&[_]llvm_c.LLVMTypeRef{u32_ty}), 1, 0);
        const ep = llvm_c.LLVMAddFunction(cg.mod, ep_sym, ep_ty);
        llvm_c.LLVMSetLinkage(ep, llvm_c.LLVMExternalLinkage);
        try cg.fn_decls.put(ep_sym, ep);
    }

    // Emit mainCRTStartup.
    const void_ty = llvm_c.LLVMVoidTypeInContext(cg.ctx);
    const crt_ty = llvm_c.LLVMFunctionType(void_ty, null, 0, 0);
    const crt_fn = llvm_c.LLVMAddFunction(cg.mod, "mainCRTStartup", crt_ty);
    const bb = llvm_c.LLVMAppendBasicBlockInContext(cg.ctx, crt_fn, "entry");
    llvm_c.LLVMPositionBuilderAtEnd(cg.builder, bb);

    // Call K2 main.
    const main_fn = cg.fn_decls.get(main_name) orelse return;
    const main_fn_ty = llvm_c.LLVMGlobalGetValueType(main_fn);
    const main_ret = llvm_c.LLVMBuildCall2(cg.builder, main_fn_ty, main_fn, null, 0, "ret");

    // Coerce i32 → u32 (bitcast — same bits, different signedness).
    const u32_ty = llvm_c.LLVMInt32TypeInContext(cg.ctx);
    const exit_code = llvm_c.LLVMBuildBitCast(cg.builder, main_ret, u32_ty, "");

    // Call ExitProcess.
    const ep_fn = cg.fn_decls.get(ep_sym).?;
    const ep_fn_ty = llvm_c.LLVMGlobalGetValueType(ep_fn);
    var ep_args = [_]llvm_c.LLVMValueRef{exit_code};
    _ = llvm_c.LLVMBuildCall2(cg.builder, ep_fn_ty, ep_fn, &ep_args, 1, "");
    _ = llvm_c.LLVMBuildUnreachable(cg.builder);
}
