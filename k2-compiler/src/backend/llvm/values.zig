/// Imm / Value → LLVMValueRef.
const std = @import("std");
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const types = @import("types.zig");
const ModuleCg = @import("context.zig").ModuleCg;

pub fn lowerImm(cg: *ModuleCg, imm: ir.Imm, hint_ty: ir.IrType) llvm.LLVMValueRef {
    const lty = types.lower(cg, hint_ty);
    return lowerImmAs(cg, imm, lty);
}

pub fn lowerImmAs(cg: *ModuleCg, imm: ir.Imm, lty: llvm.LLVMTypeRef) llvm.LLVMValueRef {
    return switch (imm) {
        .int => |v| llvm.LLVMConstInt(lty, @bitCast(@as(i64, @intCast(v))), 1),
        .uint => |v| llvm.LLVMConstInt(lty, @as(c_ulonglong, @truncate(v)), 0),
        .float => |v| llvm.LLVMConstReal(lty, v),
        .bool => |v| llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(cg.ctx), if (v) 1 else 0, 0),
        .null => llvm.LLVMConstNull(lty),
        .rune => |r| llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(cg.ctx), r, 0),

        // String literals → private global constant + { ptr, len } slice struct.
        // With LLVM opaque pointers (15+), the global value itself is already a ptr.
        .text => |s| blk: {
            var name_buf: [32]u8 = undefined;
            const name_z = std.fmt.bufPrintZ(&name_buf, ".str.{d}", .{cg.string_counter}) catch break :blk llvm.LLVMGetUndef(cg.getSliceType());
            cg.string_counter += 1;

            const i8_ty = llvm.LLVMInt8TypeInContext(cg.ctx);
            const arr_ty = llvm.LLVMArrayType2(i8_ty, s.len);

            const gv = llvm.LLVMAddGlobal(cg.mod, arr_ty, name_z);
            // dont_null_terminate=1: we store the raw string, no NUL
            llvm.LLVMSetInitializer(gv, llvm.LLVMConstStringInContext(cg.ctx, s.ptr, @intCast(s.len), 1));
            llvm.LLVMSetGlobalConstant(gv, 1);
            llvm.LLVMSetLinkage(gv, llvm.LLVMPrivateLinkage);
            llvm.LLVMSetUnnamedAddress(gv, llvm.LLVMGlobalUnnamedAddr);

            // Build slice struct { ptr=gv, len=s.len }
            const i64_ty = llvm.LLVMInt64TypeInContext(cg.ctx);
            var fields = [_]llvm.LLVMValueRef{
                gv,
                llvm.LLVMConstInt(i64_ty, s.len, 0),
            };
            break :blk llvm.LLVMConstStructInContext(cg.ctx, &fields, 2, 0);
        },
    };
}

/// Resolve a K2 Value to an LLVMValueRef.
/// `fncg` is *FnCg from functions.zig — passed as anytype to avoid circular imports.
pub fn resolveValue(
    cg: *ModuleCg,
    fncg: anytype,
    val: ir.Value,
    ty: ir.IrType,
) llvm.LLVMValueRef {
    const undef = llvm.LLVMGetUndef(types.lower(cg, ty));
    return switch (val) {
        .imm => |imm| lowerImm(cg, imm, ty),
        .reg => |id| fncg.regs.get(id) orelse undef,
        .param => |name| fncg.params.get(name) orelse undef,

        .local => |name| blk: {
            const alloca = fncg.locals.get(name) orelse break :blk undef;
            const load_ty = fncg.local_ir_types.get(name) orelse ty;
            break :blk llvm.LLVMBuildLoad2(cg.builder, types.lower(cg, load_ty), alloca, "");
        },

        .global => |name| blk: {
            const gv = cg.global_decls.get(name) orelse break :blk undef;
            break :blk llvm.LLVMBuildLoad2(cg.builder, types.lower(cg, ty), gv, "");
        },
    };
}

/// Emit a type-coercion from `v` to `dest_lty` if needed.
/// Handles integer widening (sext/zext), narrowing (trunc), and ptr↔int casts.
pub fn coerce(
    builder: llvm.LLVMBuilderRef,
    ctx: llvm.LLVMContextRef,
    v: llvm.LLVMValueRef,
    dest_lty: llvm.LLVMTypeRef,
) llvm.LLVMValueRef {
    const src_lty = llvm.LLVMTypeOf(v);
    if (src_lty == dest_lty) return v;

    const src_kind = llvm.LLVMGetTypeKind(src_lty);
    const dst_kind = llvm.LLVMGetTypeKind(dest_lty);

    if (src_kind == llvm.LLVMIntegerTypeKind and dst_kind == llvm.LLVMIntegerTypeKind) {
        const src_w = llvm.LLVMGetIntTypeWidth(src_lty);
        const dst_w = llvm.LLVMGetIntTypeWidth(dest_lty);
        if (dst_w > src_w) return llvm.LLVMBuildSExt(builder, v, dest_lty, "");
        if (dst_w < src_w) return llvm.LLVMBuildTrunc(builder, v, dest_lty, "");
        return v; // same width, different signedness — no op in LLVM
    }

    if (src_kind == llvm.LLVMPointerTypeKind and dst_kind == llvm.LLVMIntegerTypeKind)
        return llvm.LLVMBuildPtrToInt(builder, v, dest_lty, "");

    if (src_kind == llvm.LLVMIntegerTypeKind and dst_kind == llvm.LLVMPointerTypeKind)
        return llvm.LLVMBuildIntToPtr(builder, v, dest_lty, "");

    if (src_kind == llvm.LLVMStructTypeKind and dst_kind == llvm.LLVMStructTypeKind) {
        // e.g. slice struct passed where another struct is expected — alloca + bitload trick
        const tmp = llvm.LLVMBuildAlloca(builder, src_lty, "");
        _ = llvm.LLVMBuildStore(builder, v, tmp);
        return llvm.LLVMBuildLoad2(builder, dest_lty, tmp, "");
    }

    // Fallback: bitcast
    _ = ctx;
    return llvm.LLVMBuildBitCast(builder, v, dest_lty, "");
}
