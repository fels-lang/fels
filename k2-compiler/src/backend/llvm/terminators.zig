/// Terminator lowering: ret, branch, cond_branch, unreachable.
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const types = @import("types.zig");
const values = @import("values.zig");
const ModuleCg = @import("context.zig").ModuleCg;

pub fn lower(
    cg: *ModuleCg,
    fncg: anytype, // *FnCg — see functions.zig
    term: ir.Terminator,
    func: ir.IrFunction,
) void {
    switch (term) {
        .return_value => |maybe_val| {
            if (maybe_val) |val| {
                const ret = switch (func.return_ty) {
                    .optional => |inner| blk: {
                        if (val == .imm and val.imm == .null) {
                            break :blk values.optionalNone(cg, inner.*);
                        }
                        const val_ty = fncg.irTypeOf(val) orelse inner.*;
                        const payload = values.resolveValue(cg, fncg, val, val_ty);
                        if (val_ty == .optional) break :blk payload;
                        break :blk values.optionalSome(cg, payload, inner.*);
                    },
                    else => values.resolveValue(cg, fncg, val, func.return_ty),
                };
                _ = llvm.LLVMBuildRet(cg.builder, ret);
            } else {
                _ = llvm.LLVMBuildRetVoid(cg.builder);
            }
        },
        .branch => |target_id| {
            const target = fncg.blocks.get(target_id).?;
            _ = llvm.LLVMBuildBr(cg.builder, target);
        },
        .cond_branch => |cb| {
            var cond = values.resolveValue(cg, fncg, cb.cond, .bool);
            const cond_ty = llvm.LLVMTypeOf(cond);
            if (llvm.LLVMGetTypeKind(cond_ty) == llvm.LLVMIntegerTypeKind and
                llvm.LLVMGetIntTypeWidth(cond_ty) != 1)
            {
                cond = llvm.LLVMBuildICmp(
                    cg.builder,
                    llvm.LLVMIntNE,
                    cond,
                    llvm.LLVMConstInt(cond_ty, 0, 0),
                    "",
                );
            }
            const then_bb = fncg.blocks.get(cb.then_block).?;
            const else_bb = fncg.blocks.get(cb.else_block).?;
            _ = llvm.LLVMBuildCondBr(cg.builder, cond, then_bb, else_bb);
        },
        .unreachable_term => _ = llvm.LLVMBuildUnreachable(cg.builder),
        .fail => _ = llvm.LLVMBuildUnreachable(cg.builder), // TODO: error paths
    }
}
