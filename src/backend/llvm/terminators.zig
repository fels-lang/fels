/// Terminator lowering: ret, branch, cond_branch, unreachable, fail.
const std = @import("std");
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const types = @import("types.zig");
const values = @import("values.zig");
const panic_mod = @import("panic.zig");
const abi = @import("abi.zig");
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
                // Tail-forward: `return inner();` where the value is ALREADY a
                // fallible `{ok,err}` — return it as-is, don't double-wrap it.
                if (maybe_val) |val| {
                    if (fncg.irTypeOf(val)) |vt| if (vt == .fallible) {
                        const fv = values.resolveValue(cg, fncg, val, vt);
                        buildRet(cg, fncg, forwardFallible(cg, fv, types.fallibleReturnType(cg, func)));
                        return;
                    };
                }
                const ret_lty = types.fallibleReturnType(cg, func);
                var ok: llvm.LLVMValueRef = null;
                if (maybe_val) |val| {
                    const val_ty = fncg.irTypeOf(val) orelse func.return_ty;
                    const ok_raw = values.resolveValue(cg, fncg, val, val_ty);
                    ok = values.coerceTyped(
                        cg.builder,
                        cg.ctx,
                        ok_raw,
                        val_ty,
                        func.return_ty,
                        types.lower(cg, func.return_ty),
                    );
                }
                const zero = llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(cg.ctx), 0, 0);
                buildFallibleRet(cg, fncg, ret_lty, ok, zero, null);
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
                buildRet(cg, fncg, ret);
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

        // fail: build { undef, number[, payload bytes] } and return it.
        .fail => |ft| {
            const err_ty = func.error_ty orelse {
                _ = llvm.LLVMBuildUnreachable(cg.builder);
                return;
            };
            const ret_lty = types.fallibleReturnType(cg, func);
            // An `i32`: the number of the error (`fail` gives an immediate, `?` a register).
            const disc_raw = values.resolveValue(cg, fncg, ft.disc, .{ .i = 32 });
            const i32_ty = llvm.LLVMInt32TypeInContext(cg.ctx);
            const disc = values.coerce(cg.builder, cg.ctx, disc_raw, i32_ty);
            // A set whose errors carry payloads keeps the error's payload bytes (none, all zero,
            // for an error that came through a set without room for one).
            var data: llvm.LLVMValueRef = null;
            if (types.errorPayloadBytes(cg, err_ty)) |data_ty| {
                data = llvm.LLVMConstNull(data_ty);
                if (ft.err) |e| {
                    const err_val = values.resolveValue(cg, fncg, e, err_ty);
                    data = values.extractAggregateField(cg, err_val, 1, "error payload bytes") orelse data;
                }
            }
            buildFallibleRet(cg, fncg, ret_lty, null, disc, data);
        },
    }
}

/// `ret v`, or for a function returning through memory (`fncg.sret`), store `v` there and
/// `ret void`.
fn buildRet(cg: *ModuleCg, fncg: anytype, v: llvm.LLVMValueRef) void {
    if (fncg.sret) |out| {
        abi.storeValue(cg, v, out);
        _ = llvm.LLVMBuildRetVoid(cg.builder);
    } else {
        _ = llvm.LLVMBuildRet(cg.builder, v);
    }
}

/// Return a fallible `{ ok, disc[, data] }` (`ok` null: left undefined; `data`, the error's
/// payload bytes, only for a set whose errors carry payloads). Through memory each field is
/// stored on its own, so a large `ok` is copied rather than rebuilt as one aggregate value.
fn buildFallibleRet(cg: *ModuleCg, fncg: anytype, ret_lty: llvm.LLVMTypeRef, ok: llvm.LLVMValueRef, disc: llvm.LLVMValueRef, data: llvm.LLVMValueRef) void {
    if (fncg.sret) |out| {
        if (ok) |v| abi.storeValue(cg, v, llvm.LLVMBuildStructGEP2(cg.builder, ret_lty, out, 0, ""));
        _ = llvm.LLVMBuildStore(cg.builder, disc, llvm.LLVMBuildStructGEP2(cg.builder, ret_lty, out, 1, ""));
        if (data) |d| _ = llvm.LLVMBuildStore(cg.builder, d, llvm.LLVMBuildStructGEP2(cg.builder, ret_lty, out, 2, ""));
        _ = llvm.LLVMBuildRetVoid(cg.builder);
        return;
    }
    var ret = llvm.LLVMGetUndef(ret_lty);
    if (ok) |v| ret = llvm.LLVMBuildInsertValue(cg.builder, ret, v, 0, "");
    ret = llvm.LLVMBuildInsertValue(cg.builder, ret, disc, 1, "");
    if (data) |d| ret = llvm.LLVMBuildInsertValue(cg.builder, ret, d, 2, "");
    _ = llvm.LLVMBuildRet(cg.builder, ret);
}

/// `return inner();` passes the callee's fallible on. Into a set that holds what the callee's
/// does it goes as it is; into one without room for its payload (an inferred set), or with room
/// the callee's has not, it is rebuilt from the success value and the number, and the payload
/// bytes are zero.
fn forwardFallible(cg: *ModuleCg, fv: llvm.LLVMValueRef, ret_lty: llvm.LLVMTypeRef) llvm.LLVMValueRef {
    const from_lty = llvm.LLVMTypeOf(fv);
    if (from_lty == ret_lty) return fv;
    const from_fields = llvm.LLVMCountStructElementTypes(from_lty);
    const to_fields = llvm.LLVMCountStructElementTypes(ret_lty);
    if (from_fields == to_fields) return fv;
    var ret = llvm.LLVMGetUndef(ret_lty);
    ret = llvm.LLVMBuildInsertValue(cg.builder, ret, llvm.LLVMBuildExtractValue(cg.builder, fv, 0, ""), 0, "");
    ret = llvm.LLVMBuildInsertValue(cg.builder, ret, llvm.LLVMBuildExtractValue(cg.builder, fv, 1, ""), 1, "");
    if (to_fields == 3) ret = llvm.LLVMBuildInsertValue(cg.builder, ret, llvm.LLVMConstNull(llvm.LLVMStructGetTypeAtIndex(ret_lty, 2)), 2, "");
    return ret;
}
