/// LLVM codegen backend.
///
/// Primary output: native .o object files via LLVM's TargetMachine API.
///
/// Quick start:
///
///   var be = LlvmBackend.init(allocator, "my_module");
///   defer be.deinit();
///
///   try be.lower(ir_module);              // K2 IR → LLVM IR
///   try be.emitObject("output.o", 2);     // → native object file (opt level 2)
///
/// Codegen is split across src/backend/llvm/:
///   c_api.zig       — @cImport of LLVM C headers
///   context.zig     — ModuleCg (LLVMContext / Module / Builder)
///   types.zig       — IrType → LLVMTypeRef
///   values.zig      — Imm / Value → LLVMValueRef
///   structs.zig     — StructDef lowering (2-pass)
///   globals.zig     — IrGlobal lowering
///   local_vars.zig  — per-function alloca management
///   functions.zig   — FnCg + declaration + definition
///   instrs.zig      — Instr lowering
///   terminators.zig — Terminator lowering
///   emit.zig        — TargetMachine setup + .o emission
const std     = @import("std");
const ir      = @import("../ir.zig");
const ctx_mod = @import("llvm/context.zig");
const structs = @import("llvm/structs.zig");
const globals = @import("llvm/globals.zig");
const fns     = @import("llvm/functions.zig");
const emit    = @import("llvm/emit.zig");

pub const LlvmBackend = struct {
    cg: ctx_mod.ModuleCg,

    pub fn init(allocator: std.mem.Allocator, module_name: [*:0]const u8) LlvmBackend {
        return .{ .cg = ctx_mod.ModuleCg.init(allocator, module_name) };
    }

    pub fn deinit(self: *LlvmBackend) void {
        self.cg.deinit();
    }

    /// Lower a complete IrModule into LLVM IR in memory.
    /// Call this before any emit function.
    pub fn lower(self: *LlvmBackend, module: ir.IrModule) !void {
        try structs.lowerAll(&self.cg, module.structs);
        try globals.lowerAll(&self.cg, module.globals);
        try fns.declareAll(&self.cg, module.functions);
        try fns.defineAll(&self.cg, module.functions);
    }

    /// Emit a native object file.
    ///
    /// `opt_level`: 0 = no optimisation, 1 = less, 2 = default, 3 = aggressive.
    ///
    /// This function:
    ///   1. Creates a TargetMachine for the host CPU
    ///   2. Stamps the data layout + triple onto the LLVM module
    ///   3. Verifies the module
    ///   4. Emits the .o file
    pub fn emitObject(self: *LlvmBackend, path: [*:0]const u8, opt_level: u2) !void {
        const tm = try emit.TargetMachine.initNative(opt_level);
        defer tm.deinit();

        tm.applyToModule(&self.cg);
        try emit.verify(&self.cg);
        try emit.emitObject(&self.cg, tm, path);
    }

    /// Dump the LLVM IR to stderr — useful for debugging codegen.
    pub fn dumpIr(self: *LlvmBackend) void {
        emit.dumpIr(&self.cg);
    }

    /// Return the LLVM IR as text — useful for tests / inspection.
    pub fn getIrText(self: *LlvmBackend, allocator: std.mem.Allocator) ![]u8 {
        return emit.getIrText(&self.cg, allocator);
    }
};
