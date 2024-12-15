/// Imm / Value → LLVMValueRef.
const ir       = @import("../../ir.zig");
const llvm     = @import("c_api.zig").llvm;
const types    = @import("types.zig");
const ModuleCg = @import("context.zig").ModuleCg;

pub fn lowerImm(cg: *ModuleCg, imm: ir.Imm, hint_ty: ir.IrType) llvm.LLVMValueRef {
    const lty = types.lower(cg, hint_ty);
    return switch (imm) {
        .int   => |v| llvm.LLVMConstInt(lty, @bitCast(@as(i64, @intCast(v))), 1),
        .uint  => |v| llvm.LLVMConstInt(lty, @as(c_ulonglong, @truncate(v)), 0),
        .float => |v| llvm.LLVMConstReal(lty, v),
        .bool  => |v| llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(cg.ctx), if (v) 1 else 0, 0),
        .null  => llvm.LLVMConstNull(lty),
        .text  => |s| llvm.LLVMConstStringInContext(cg.ctx, s.ptr, @intCast(s.len), 0),
        .rune  => |r| llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(cg.ctx), r, 0),
    };
}

/// Resolve a K2 Value to an LLVMValueRef.
/// `fncg` is *FnCg from functions.zig — passed as anytype to avoid circular imports.
pub fn resolveValue(
    cg:   *ModuleCg,
    fncg: anytype,
    val:  ir.Value,
    ty:   ir.IrType,
) llvm.LLVMValueRef {
    const undef = llvm.LLVMGetUndef(types.lower(cg, ty));
    return switch (val) {
        .imm   => |imm|  lowerImm(cg, imm, ty),
        .reg   => |id|   fncg.regs.get(id)    orelse undef,
        .param => |name| fncg.params.get(name) orelse undef,

        .local => |name| blk: {
            const alloca = fncg.locals.get(name) orelse break :blk undef;
            // Use the tracked IrType for the local if available (handles slices etc.)
            const load_ty = fncg.local_ir_types.get(name) orelse ty;
            break :blk llvm.LLVMBuildLoad2(cg.builder, types.lower(cg, load_ty), alloca, "");
        },

        .global => |name| blk: {
            const gv = cg.global_decls.get(name) orelse break :blk undef;
            break :blk llvm.LLVMBuildLoad2(cg.builder, types.lower(cg, ty), gv, "");
        },
    };
}
