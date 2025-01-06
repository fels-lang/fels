/// IrType → LLVMTypeRef.
/// Slices lower to the fat-pointer struct { ptr, usize } cached in ModuleCg.
/// LLVM 15+ opaque pointers: all pointer types become a single `ptr`.
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const ModuleCg = @import("context.zig").ModuleCg;

pub fn lower(cg: *ModuleCg, ty: ir.IrType) llvm.LLVMTypeRef {
    const ctx = cg.ctx;
    return switch (ty) {
        .i => |bits| llvm.LLVMIntTypeInContext(ctx, bits),
        .u => |bits| llvm.LLVMIntTypeInContext(ctx, bits),
        .f32 => llvm.LLVMFloatTypeInContext(ctx),
        .f64 => llvm.LLVMDoubleTypeInContext(ctx),
        .bool => llvm.LLVMInt1TypeInContext(ctx),
        .byte => llvm.LLVMInt8TypeInContext(ctx),
        .usize, .isize, .addr => llvm.LLVMInt64TypeInContext(ctx),
        .void => llvm.LLVMVoidTypeInContext(ctx),

        // Slices are fat pointers: { ptr, i64 }
        .slice => cg.getSliceType(),
        .interface_value => cg.getInterfaceType(),

        // Optional pointer → nullable raw pointer (null = none, non-null = some).
        // This avoids wrapping *T in { i1, ptr } which would pass a struct address
        // where the C API expects a raw NULL pointer — causing WriteFile to treat
        // synchronous writes as overlapped async I/O.
        .optional => |inner| if (inner.* == .ptr)
            llvm.LLVMPointerTypeInContext(ctx, 0)
        else
            optionalType(cg, inner.*),

        // Fallible types: !T — represented as { T, i32 } where i32=0 means ok.
        // Void ok-type uses i8 placeholder (can't have void in a struct).
        .fallible => |f| blk: {
            const ok_lty = if (f.ok.* == .void)
                llvm.LLVMInt8TypeInContext(ctx)
            else
                lower(cg, f.ok.*);
            var fields = [_]llvm.LLVMTypeRef{ ok_lty, llvm.LLVMInt32TypeInContext(ctx) };
            break :blk llvm.LLVMStructTypeInContext(ctx, &fields, 2, 0);
        },

        // Error/variant discriminant types lower to i32.
        .variant_type => llvm.LLVMInt32TypeInContext(ctx),

        // All other pointer-like types are opaque `ptr` (LLVM 15+).
        .ptr => llvm.LLVMPointerTypeInContext(ctx, 0),

        .array => |arr| llvm.LLVMArrayType2(lower(cg, arr.elem.*), arr.len),

        .struct_type => |name| cg.struct_types.get(name) orelse
            llvm.LLVMPointerTypeInContext(ctx, 0),

        // Fallback: treat as opaque pointer.
        else => llvm.LLVMPointerTypeInContext(ctx, 0),
    };
}

pub fn optionalPayloadType(cg: *ModuleCg, payload_ty: ir.IrType) llvm.LLVMTypeRef {
    return if (payload_ty == .void)
        llvm.LLVMInt8TypeInContext(cg.ctx)
    else
        lower(cg, payload_ty);
}

pub fn optionalType(cg: *ModuleCg, payload_ty: ir.IrType) llvm.LLVMTypeRef {
    var fields = [_]llvm.LLVMTypeRef{
        llvm.LLVMInt1TypeInContext(cg.ctx),
        optionalPayloadType(cg, payload_ty),
    };
    return llvm.LLVMStructTypeInContext(cg.ctx, &fields, 2, 0);
}

/// Lower a slice of IrTypes into a heap-allocated array (caller frees).
pub fn lowerSlice(cg: *ModuleCg, tys: []const ir.IrType) ![]llvm.LLVMTypeRef {
    const out = try cg.allocator.alloc(llvm.LLVMTypeRef, tys.len);
    for (tys, 0..) |t, i| out[i] = lower(cg, t);
    return out;
}

/// Build an LLVM function type from an IrFunction.
/// Fallible functions (!T) get return type { T, i32 } where i32 is the error discriminant.
pub fn fnType(cg: *ModuleCg, func: ir.IrFunction) !llvm.LLVMTypeRef {
    const param_tys = try cg.allocator.alloc(llvm.LLVMTypeRef, func.params.len);
    defer cg.allocator.free(param_tys);
    for (func.params, 0..) |p, i| param_tys[i] = lower(cg, p.ty);
    const ret_lty = fallibleReturnType(cg, func);
    return llvm.LLVMFunctionType(ret_lty, param_tys.ptr, @intCast(param_tys.len), 0);
}

/// Return the LLVM return type for a function.
/// Fallible: { ok_lty, i32 }.  Non-fallible: lower(return_ty).
pub fn fallibleReturnType(cg: *ModuleCg, func: ir.IrFunction) llvm.LLVMTypeRef {
    if (func.error_ty == null) return lower(cg, func.return_ty);
    const ok_lty = if (func.return_ty == .void)
        llvm.LLVMInt8TypeInContext(cg.ctx) // void ok → i8 placeholder
    else
        lower(cg, func.return_ty);
    var fields = [_]llvm.LLVMTypeRef{ ok_lty, llvm.LLVMInt32TypeInContext(cg.ctx) };
    return llvm.LLVMStructTypeInContext(cg.ctx, &fields, 2, 0);
}
