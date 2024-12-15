/// IrType → LLVMTypeRef.
/// Slices lower to the fat-pointer struct { ptr, usize } cached in ModuleCg.
/// LLVM 15+ opaque pointers: all pointer types become a single `ptr`.
const ir       = @import("../../ir.zig");
const llvm     = @import("c_api.zig").llvm;
const ModuleCg = @import("context.zig").ModuleCg;

pub fn lower(cg: *ModuleCg, ty: ir.IrType) llvm.LLVMTypeRef {
    const ctx = cg.ctx;
    return switch (ty) {
        .i  => |bits| llvm.LLVMIntTypeInContext(ctx, bits),
        .u  => |bits| llvm.LLVMIntTypeInContext(ctx, bits),
        .f32  => llvm.LLVMFloatTypeInContext(ctx),
        .f64  => llvm.LLVMDoubleTypeInContext(ctx),
        .bool => llvm.LLVMInt1TypeInContext(ctx),
        .byte => llvm.LLVMInt8TypeInContext(ctx),
        .usize, .isize, .addr => llvm.LLVMInt64TypeInContext(ctx),
        .void => llvm.LLVMVoidTypeInContext(ctx),

        // Slices are fat pointers: { ptr, i64 }
        .slice => cg.getSliceType(),

        // All other pointer-like types are opaque `ptr` (LLVM 15+).
        .ptr => llvm.LLVMPointerTypeInContext(ctx, 0),

        .array => |arr| llvm.LLVMArrayType2(lower(cg, arr.elem.*), arr.len),

        .struct_type => |name| cg.struct_types.get(name) orelse
            llvm.LLVMPointerTypeInContext(ctx, 0),

        // Fallback: treat as opaque pointer.
        else => llvm.LLVMPointerTypeInContext(ctx, 0),
    };
}

/// Lower a slice of IrTypes into a heap-allocated array (caller frees).
pub fn lowerSlice(cg: *ModuleCg, tys: []const ir.IrType) ![]llvm.LLVMTypeRef {
    const out = try cg.allocator.alloc(llvm.LLVMTypeRef, tys.len);
    for (tys, 0..) |t, i| out[i] = lower(cg, t);
    return out;
}

/// Build an LLVM function type from an IrFunction.
pub fn fnType(cg: *ModuleCg, func: ir.IrFunction) !llvm.LLVMTypeRef {
    const param_tys = try cg.allocator.alloc(llvm.LLVMTypeRef, func.params.len);
    defer cg.allocator.free(param_tys);
    for (func.params, 0..) |p, i| param_tys[i] = lower(cg, p.ty);
    return llvm.LLVMFunctionType(
        lower(cg, func.return_ty),
        param_tys.ptr,
        @intCast(param_tys.len),
        0,
    );
}
