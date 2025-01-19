/// Enum (tagged union) lowering.
///
/// Simple enums (no payloads): represented as i32 discriminant.
/// Enums with payloads:        { i32 discriminant, [max_payload_size x i8] data }
const std      = @import("std");
const ir       = @import("../../ir.zig");
const llvm     = @import("c_api.zig").llvm;
const types    = @import("types.zig");
const values   = @import("values.zig");
const ModuleCg = @import("context.zig").ModuleCg;

/// Per-enum metadata stored in ModuleCg.
pub const EnumMeta = struct {
    /// Name → discriminant index.
    discriminants: std.StringHashMap(u32),
    /// LLVM type for this enum (i32 or { i32, [N x i8] }).
    llvm_ty: llvm.LLVMTypeRef,
    /// True if all variants have no payload.
    is_simple: bool,
};

/// Register all enum (VariantDef) types and build metadata.
pub fn lowerAll(cg: *ModuleCg, variant_defs: []const ir.VariantDef) !void {
    for (variant_defs) |vd| try lowerOne(cg, vd);
}

fn lowerOne(cg: *ModuleCg, vd: ir.VariantDef) !void {
    const i32_ty = llvm.LLVMInt32TypeInContext(cg.ctx);

    // Determine if any variant has a payload, and find max payload size.
    var is_simple = true;
    var max_payload_bits: u64 = 0;
    for (vd.variants) |v| {
        if (v.payload) |pt| {
            is_simple = false;
            const lty  = types.lower(cg, pt);
            const bits = llvm.LLVMGetIntTypeWidth(lty);  // works for int types
            // For non-int types, use a safe upper bound via sizeof
            const payload_bits = if (llvm.LLVMGetTypeKind(lty) == llvm.LLVMIntegerTypeKind)
                @as(u64, bits)
            else
                llvm.LLVMStoreSizeOfType(llvm.LLVMCreateTargetData(""), lty) * 8;
            if (payload_bits > max_payload_bits) max_payload_bits = payload_bits;
        }
    }

    // Build the LLVM type.
    const llvm_ty = if (is_simple) i32_ty else blk: {
        const payload_bytes: u64 = (max_payload_bits + 7) / 8;
        const i8_ty   = llvm.LLVMInt8TypeInContext(cg.ctx);
        const data_ty = llvm.LLVMArrayType2(i8_ty, payload_bytes);
        var fields    = [_]llvm.LLVMTypeRef{ i32_ty, data_ty };
        break :blk llvm.LLVMStructTypeInContext(cg.ctx, &fields, 2, 0);
    };

    // Build discriminant map.
    var disc_map = std.StringHashMap(u32).init(cg.allocator);
    for (vd.variants, 0..) |v, i| try disc_map.put(v.name, @intCast(i));

    // Store in cg.
    const meta = try cg.allocator.create(EnumMeta);
    meta.* = .{
        .discriminants = disc_map,
        .llvm_ty       = llvm_ty,
        .is_simple     = is_simple,
    };
    try cg.enum_meta.put(vd.name, meta);

    // Also register the LLVM type in struct_types so types.lower() can find it.
    try cg.struct_types.put(vd.name, llvm_ty);
}

/// Build an LLVM value for a variant literal (no payload).
pub fn buildVariantLit(
    cg:        *ModuleCg,
    type_name: []const u8,
    variant:   []const u8,
    payload:   ?llvm.LLVMValueRef,
) llvm.LLVMValueRef {
    const meta = cg.enum_meta.get(type_name) orelse
        return llvm.LLVMGetUndef(llvm.LLVMInt32TypeInContext(cg.ctx));
    const disc = meta.discriminants.get(variant) orelse 0;
    const disc_val = llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(cg.ctx), disc, 0);

    if (meta.is_simple) return disc_val;

    // Build { discriminant, payload_bytes }
    var agg = llvm.LLVMGetUndef(meta.llvm_ty);
    agg = llvm.LLVMBuildInsertValue(cg.builder, agg, disc_val, 0, "");
    if (payload) |pv| {
        // Store the payload into a temp alloca, then load as bytes.
        const pv_ty  = llvm.LLVMTypeOf(pv);
        const tmp    = llvm.LLVMBuildAlloca(cg.builder, pv_ty, "");
        _ = llvm.LLVMBuildStore(cg.builder, pv, tmp);
        const data_ty    = llvm.LLVMStructGetTypeAtIndex(meta.llvm_ty, 1);
        const data_bytes = llvm.LLVMBuildLoad2(cg.builder, data_ty, tmp, "");
        agg = llvm.LLVMBuildInsertValue(cg.builder, agg, data_bytes, 1, "");
    }
    return agg;
}

/// Emit an i1 check: does `value` have this variant (discriminant match)?
pub fn buildVariantIs(
    cg:        *ModuleCg,
    value:     llvm.LLVMValueRef,
    type_name: []const u8,
    variant:   []const u8,
) llvm.LLVMValueRef {
    const meta = cg.enum_meta.get(type_name) orelse
        return llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(cg.ctx), 0, 0);
    const disc = meta.discriminants.get(variant) orelse 0;
    const disc_val  = llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(cg.ctx), disc, 0);
    const actual_disc = if (meta.is_simple) value
    else values.extractAggregateField(cg, value, 0, "variant discriminant") orelse
        return llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(cg.ctx), 0, 0);
    return llvm.LLVMBuildICmp(cg.builder, llvm.LLVMIntEQ, actual_disc, disc_val, "");
}

/// Extract the payload from a tagged enum value, as the requested type.
pub fn buildVariantPayload(
    cg:        *ModuleCg,
    value:     llvm.LLVMValueRef,
    type_name: []const u8,
    variant:   []const u8,
    dest_ty:   llvm.LLVMTypeRef,
) llvm.LLVMValueRef {
    const meta = cg.enum_meta.get(type_name) orelse
        return llvm.LLVMGetUndef(dest_ty);
    _ = variant;
    if (meta.is_simple) return llvm.LLVMGetUndef(dest_ty);

    const data_bytes = values.extractAggregateField(cg, value, 1, "variant payload bytes") orelse
        return llvm.LLVMGetUndef(dest_ty);
    // Bitcast the data bytes to the target type via alloca.
    const data_ty = llvm.LLVMStructGetTypeAtIndex(meta.llvm_ty, 1);
    const tmp = llvm.LLVMBuildAlloca(cg.builder, data_ty, "");
    _ = llvm.LLVMBuildStore(cg.builder, data_bytes, tmp);
    return llvm.LLVMBuildLoad2(cg.builder, dest_ty, tmp, "");
}
