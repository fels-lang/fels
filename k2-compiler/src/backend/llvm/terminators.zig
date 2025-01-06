/// Terminator lowering: ret, branch, cond_branch, unreachable, fail.
const std = @import("std");
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const types = @import("types.zig");
const values = @import("values.zig");
const panic_mod = @import("panic.zig");
const ModuleCg = @import("context.zig").ModuleCg;

pub fn lower(
    cg: *ModuleCg,
    fncg: anytype, // *FnCg — see functions.zig
    term: ir.Terminator,
    func: ir.IrFunction,
) void {
    switch (term) {
        .return_value => |maybe_val| {
            // Fallible functions (error_ty != null): wrap ok value in { ok_val, 0 }.
            if (func.error_ty != null) {
                const ret_lty = types.fallibleReturnType(cg, func);
                var ret = llvm.LLVMGetUndef(ret_lty);
                if (maybe_val) |val| {
                    const ok_lv = values.resolveValue(cg, fncg, val, func.return_ty);
                    ret = llvm.LLVMBuildInsertValue(cg.builder, ret, ok_lv, 0, "");
                }
                const zero = llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(cg.ctx), 0, 0);
                ret = llvm.LLVMBuildInsertValue(cg.builder, ret, zero, 1, "");
                _ = llvm.LLVMBuildRet(cg.builder, ret);
                return;
            }

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
        .panic => |panic| panic_mod.lower(cg, panic),

        // fail: build { undef_ok, discriminant } and return it.
        .fail => |err_val| {
            if (func.error_ty == null) {
                _ = llvm.LLVMBuildUnreachable(cg.builder);
                return;
            }
            const ret_lty = types.fallibleReturnType(cg, func);
            var ret = llvm.LLVMGetUndef(ret_lty);
            // Resolve the error value (discriminant i32).
            const disc_raw = values.resolveValue(cg, fncg, err_val, .unknown);
            const i32_ty = llvm.LLVMInt32TypeInContext(cg.ctx);
            const disc = values.coerce(cg.builder, cg.ctx, disc_raw, i32_ty);
            ret = llvm.LLVMBuildInsertValue(cg.builder, ret, disc, 1, "");
            _ = llvm.LLVMBuildRet(cg.builder, ret);
        },
    }
}
