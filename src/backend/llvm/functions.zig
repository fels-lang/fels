/// Function declaration + definition.
const std = @import("std");
const ctx_mod = @import("context.zig");
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const types_mod = @import("types.zig");
const local_vars = @import("local_vars.zig");
const instrs = @import("instrs.zig");
const terminators = @import("terminators.zig");
const attrs = @import("attrs.zig");
const abi = @import("abi.zig");
const ModuleCg = @import("context.zig").ModuleCg;
const ui = @import("../../ui.zig");

/// Per-function codegen state.
pub const FnCg = struct {
    cg: *ModuleCg,
    func: ir.IrFunction,
    llvm_fn: llvm.LLVMValueRef,

    blocks: std.AutoHashMap(ir.BlockId, llvm.LLVMBasicBlockRef),
    regs: std.AutoHashMap(ir.RegId, llvm.LLVMValueRef),
    locals: std.StringHashMap(llvm.LLVMValueRef), // name → alloca
    params: std.StringHashMap(llvm.LLVMValueRef), // name → param value

    /// IrType of each register result — used by field-access to determine struct layout.
    reg_ir_types: std.AutoHashMap(ir.RegId, ir.IrType),
    /// IrType of each local variable.
    local_ir_types: std.StringHashMap(ir.IrType),
    /// IrType of each parameter.
    param_ir_types: std.StringHashMap(ir.IrType),
    /// The hidden `sret` parameter a large return is written through (see
    /// `types.returnsIndirect`), or null when the function returns its value directly.
    sret: llvm.LLVMValueRef = null,
    /// The `field_addr` registers that address a field of a bit-packed struct, and where its
    /// bits are: a `store` or a `deref` through one goes by them.
    bit_refs: std.AutoHashMap(ir.RegId, ctx_mod.BitRef),
    /// Set by the `field_addr` being lowered when it is one of those.
    pending_bits: ?ctx_mod.BitRef = null,

    fn deinit(self: *FnCg) void {
        self.bit_refs.deinit();
        self.blocks.deinit();
        self.regs.deinit();
        self.locals.deinit();
        self.params.deinit();
        self.reg_ir_types.deinit();
        self.local_ir_types.deinit();
        self.param_ir_types.deinit();
    }

    /// Return the IrType of a Value (used by field-access lowering).
    pub fn irTypeOf(self: *const FnCg, val: ir.Value) ?ir.IrType {
        return switch (val) {
            .reg => |id| self.reg_ir_types.get(id),
            .param => |name| self.param_ir_types.get(name),
            .local => |name| self.local_ir_types.get(name),
            .global => |name| self.cg.global_ir_types.get(name),
            else => null,
        };
    }
};

pub fn declareAll(cg: *ModuleCg, funcs: []const ir.IrFunction) !void {
    for (funcs) |f| try declareOne(cg, f);
}

fn declareOne(cg: *ModuleCg, func: ir.IrFunction) !void {
    if (cg.fn_decls.contains(func.name)) return;

    // External C functions get Win64 C-ABI lowering for by-value aggregate
    // params/returns; everything else keeps its natural LLVM signature.
    var abi_sig: ?abi.FnAbi = null;
    const fn_ty = blk: {
        if (func.extern_name != null) {
            var sig = try abi.computeFnAbi(cg, func);
            if (sig.nontrivial) {
                abi_sig = sig;
                break :blk try abi.externFnType(cg, func, sig);
            }
            sig.deinit(cg.allocator);
        }
        break :blk try types_mod.fnType(cg, func);
    };

    // An `#extern` function's LLVM symbol is its C symbol. More than one declaration
    // may bind the same symbol (a user's `CloseHandle` beside the runtime's), each
    // with its own IR name and signature, but LLVM holds one function per symbol:
    // later declarations share it and remember their own function type, which their
    // call sites use (see `fnTypeOf`).
    const symbol = func.extern_name orelse func.name;
    const name_z = try cg.allocator.dupeZ(u8, symbol);
    defer cg.allocator.free(name_z);

    if (func.extern_name != null) {
        if (llvm.LLVMGetNamedFunction(cg.mod, name_z)) |existing| {
            try cg.fn_types.put(func.name, fn_ty);
            if (abi_sig) |sig| try cg.fn_abi.put(func.name, sig);
            try cg.fn_decls.put(func.name, existing);
            return;
        }
    }

    const lv = llvm.LLVMAddFunction(cg.mod, name_z, fn_ty);
    abi.markBoolExt(cg, lv);

    // Parameter names are cosmetic; skip them for ABI-lowered externs whose
    // LLVM parameters no longer correspond 1:1 to source parameters.
    const sret_ty = types_mod.sretTypeOf(cg, func);
    const first: usize = if (sret_ty != null) 1 else 0;
    if (abi_sig == null) {
        for (func.params, 0..) |p, i| {
            const pv = llvm.LLVMGetParam(lv, @intCast(first + i));
            llvm.LLVMSetValueName2(pv, p.name.ptr, p.name.len);
        }
    }
    if (sret_ty) |ty| abi.markSret(cg, lv, ty);

    if (func.extern_name) |_| llvm.LLVMSetLinkage(lv, llvm.LLVMExternalLinkage);
    attrs.applyFunctionAttrs(cg, func, lv);
    // `#interrupt`: LLVM's x86 interrupt convention saves every register the function uses and
    // returns with `iretq`; the frame the cpu pushed is the first parameter, `byval`.
    if (func.interrupt and func.params.len > 0 and func.params[0].ty == .ptr) {
        llvm.LLVMSetFunctionCallConv(lv, llvm.LLVMX86INTRCallConv);
        const kind = llvm.LLVMGetEnumAttributeKindForName("byval", "byval".len);
        llvm.LLVMAddAttributeAtIndex(lv, 1, llvm.LLVMCreateTypeAttribute(cg.ctx, kind, types_mod.lower(cg, func.params[0].ty.ptr.*)));
    }

    // A defined Fels function that isn't the entry point, `#export`ed, or external
    // gets INTERNAL linkage. Fels emits the whole program as one object, so these
    // are module-private — and a global symbol like `exit`/`abort` would clash
    // with the C runtime once `link_libc` is used. (Also lets LLVM drop dead ones.)
    // `#weak` (overridable symbol) and `#keep` (survives stripping) need non-internal
    // linkage, so they opt out of the module-private internalization.
    if (func.blocks.len > 0 and func.extern_name == null and func.export_sym == null and
        !func.entry and !func.weak and !func.keep)
        llvm.LLVMSetLinkage(lv, llvm.LLVMInternalLinkage);

    if (abi_sig) |sig| {
        abi.applyAbiAttrs(cg, lv, sig);
        try cg.fn_abi.put(func.name, sig);
    }
    try cg.fn_decls.put(func.name, lv);
}

pub fn defineAll(cg: *ModuleCg, funcs: []const ir.IrFunction) !void {
    // The live tree counts the functions with a body, and names the one being generated.
    if (ui.active()) {
        var n: usize = 0;
        for (funcs) |f| n += @intFromBool(f.blocks.len > 0);
        ui.itemTotal(n);
    }
    for (funcs) |f| if (f.blocks.len > 0) {
        if (ui.active()) ui.item(shortName(f.name), fileOf(f));
        try defineOne(cg, f);
    };
}

/// A function's name without the module part a link name starts with (`src_main_fels$run`).
fn shortName(name: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, name, '$')) |i| name[i + 1 ..] else name;
}

/// The file a function is in, from the place of its first instruction; "" when it has none.
fn fileOf(f: ir.IrFunction) []const u8 {
    for (f.blocks) |b| for (b.instrs) |in| {
        if (in.location.file.len != 0) return in.location.file;
    };
    return "";
}

fn defineOne(cg: *ModuleCg, func: ir.IrFunction) !void {
    const llvm_fn = cg.fn_decls.get(func.name) orelse return;

    // Create all basic blocks first (terminators reference them by id).
    var blocks = std.AutoHashMap(ir.BlockId, llvm.LLVMBasicBlockRef).init(cg.allocator);
    errdefer blocks.deinit();
    for (func.blocks) |block| {
        var bb_name_buf: [32]u8 = undefined;
        const name_z = try std.fmt.bufPrintZ(&bb_name_buf, "bb{d}", .{block.id});
        try blocks.put(block.id, llvm.LLVMAppendBasicBlockInContext(cg.ctx, llvm_fn, name_z));
    }

    // Debug info: the subprogram, and the declaration's line for the stack slots below.
    if (cg.debug) |*d| d.begin(cg.builder, cg.ctx, func, llvm_fn);
    defer if (cg.debug) |*d| d.end(cg.builder);

    // Emit allocas at the start of the entry block.
    const entry_bb = blocks.get(func.blocks[0].id).?;
    var locals = try local_vars.allocateLocals(cg, func, entry_bb);
    errdefer locals.deinit();

    // Build param maps.
    var params = std.StringHashMap(llvm.LLVMValueRef).init(cg.allocator);
    var param_tys = std.StringHashMap(ir.IrType).init(cg.allocator);
    errdefer {
        params.deinit();
        param_tys.deinit();
    }
    const sret_ty = types_mod.sretTypeOf(cg, func);
    const first: usize = if (sret_ty != null) 1 else 0;
    for (func.params, 0..) |p, i| {
        try params.put(p.name, llvm.LLVMGetParam(llvm_fn, @intCast(first + i)));
        try param_tys.put(p.name, p.ty);
    }

    // Build local type map (from store_local instructions).
    var local_tys = std.StringHashMap(ir.IrType).init(cg.allocator);
    errdefer local_tys.deinit();
    for (func.blocks) |block| {
        for (block.instrs) |instr| switch (instr.kind) {
            .store_local => |sl| if (!local_tys.contains(sl.name))
                try local_tys.put(sl.name, instr.ty),
            else => {},
        };
    }

    // Debug info: the parameters and locals, now that the slots exist.
    if (cg.debug) |*d| d.declareVariables(cg, func, llvm_fn, first, &locals, &local_tys);

    var fncg = FnCg{
        .cg = cg,
        .func = func,
        .llvm_fn = llvm_fn,
        .blocks = blocks,
        .regs = std.AutoHashMap(ir.RegId, llvm.LLVMValueRef).init(cg.allocator),
        .locals = locals,
        .params = params,
        .reg_ir_types = std.AutoHashMap(ir.RegId, ir.IrType).init(cg.allocator),
        .local_ir_types = local_tys,
        .param_ir_types = param_tys,
        .sret = if (sret_ty != null) llvm.LLVMGetParam(llvm_fn, 0) else null,
        .bit_refs = std.AutoHashMap(ir.RegId, ctx_mod.BitRef).init(cg.allocator),
    };
    defer fncg.deinit();

    // Lower each block.
    for (func.blocks) |block| {
        llvm.LLVMPositionBuilderAtEnd(cg.builder, fncg.blocks.get(block.id).?);
        for (block.instrs) |instr| {
            if (cg.debug) |*d| d.at(cg.builder, cg.ctx, instr.line, instr.column);
            instrs.lower(cg, &fncg, instr);
        }
        if (block.terminator) |term| {
            if (cg.debug) |*d| d.at(cg.builder, cg.ctx, block.term_line, block.term_column);
            terminators.lower(cg, &fncg, term, func);
        }
    }
}
