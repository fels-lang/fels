/// Terminator lowering: ret, branch, cond_branch, unreachable.
const ir       = @import("../../ir.zig");
const llvm     = @import("c_api.zig").llvm;
const types    = @import("types.zig");
const values   = @import("values.zig");
const ModuleCg = @import("context.zig").ModuleCg;

pub fn lower(
    cg:      *ModuleCg,
    fncg:    anytype,   // *FnCg — see functions.zig
    term:    ir.Terminator,
    func:    ir.IrFunction,
) void {
    switch (term) {
        .return_value => |maybe_val| {
            if (maybe_val) |val| {
                const ret = values.resolveValue(cg, fncg, val, func.return_ty);
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
            const cond    = values.resolveValue(cg, fncg, cb.cond, .bool);
            const then_bb = fncg.blocks.get(cb.then_block).?;
            const else_bb = fncg.blocks.get(cb.else_block).?;
            _ = llvm.LLVMBuildCondBr(cg.builder, cond, then_bb, else_bb);
        },
        .unreachable_term => _ = llvm.LLVMBuildUnreachable(cg.builder),
        .fail => _ = llvm.LLVMBuildUnreachable(cg.builder), // TODO: error paths
    }
}
