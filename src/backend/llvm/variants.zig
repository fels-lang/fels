/// Enum (tagged union) lowering.
///
/// Simple enums (no payloads): represented as i32 discriminant.
/// Enums with payloads:        { i32 discriminant, [max_payload_size x i8] data }
const std      = @import("std");
const ir       = @import("../../ir.zig");
const llvm     = @import("c_api.zig").llvm;
const types    = @import("types.zig");
const values   = @import("values.zig");
const abi      = @import("abi.zig");
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

/// Register every enum's *type* and metadata, but leave a payloaded enum's body
/// unset. Simple enums are plain `i32`; a payloaded enum gets a NAMED opaque shell
/// (`{ i32, [N x i8] }`, body filled by `bodyAll`). Declaring the shell up front —
/// before structs are bodied — means a struct's by-value enum field finds the real
/// enum type (resolved lazily at emit), instead of falling back to a pointer.
pub fn declareAll(cg: *ModuleCg, variant_defs: []const ir.VariantDef) !void {
    for (variant_defs) |vd| {
        const is_simple = for (vd.variants) |v| {
            if (v.payload != null) break false;
        } else true;

        const llvm_ty = if (is_simple)
            llvm.LLVMInt32TypeInContext(cg.ctx)
        else blk: {
            const nm = try std.fmt.allocPrintSentinel(cg.allocator, "{s}.enum", .{vd.name}, 0);
            defer cg.allocator.free(nm);
            break :blk llvm.LLVMStructCreateNamed(cg.ctx, nm.ptr);
        };

        var disc_map = std.StringHashMap(u32).init(cg.allocator);
        for (vd.variants, 0..) |v, i| try disc_map.put(v.name, @intCast(i));

        const meta = try cg.allocator.create(EnumMeta);
        meta.* = .{ .discriminants = disc_map, .llvm_ty = llvm_ty, .is_simple = is_simple };
        try cg.enum_meta.put(vd.name, meta);
        try cg.struct_types.put(vd.name, llvm_ty);
    }
}

/// Fill in each payloaded enum's body — run AFTER structs are bodied, so a struct
/// payload's size measures correctly (e.g. `TypeInfo.struct_: TiStruct` = 32 B,
/// not a truncated shell).
pub fn bodyAll(cg: *ModuleCg, variant_defs: []const ir.VariantDef) !void {
    for (variant_defs) |vd| {
        const meta = cg.enum_meta.get(vd.name).?;
        if (meta.is_simple) continue;

        var max_payload_bits: u64 = 0;
        for (vd.variants) |v| {
            if (v.payload) |pt| {
                const lty = types.lower(cg, pt);
                // Module layout isn't stamped until emit; the default target data
                // (64-bit ptrs, natural alignment) measures the now-bodied payload.
                const dl = llvm.LLVMCreateTargetData("");
                defer llvm.LLVMDisposeTargetData(dl);
                const payload_bits = if (llvm.LLVMGetTypeKind(lty) == llvm.LLVMIntegerTypeKind)
                    @as(u64, llvm.LLVMGetIntTypeWidth(lty))
                else
                    llvm.LLVMABISizeOfType(dl, lty) * 8;
                if (payload_bits > max_payload_bits) max_payload_bits = payload_bits;
            }
        }

        const payload_bytes: u64 = (max_payload_bits + 7) / 8;
        const i8_ty = llvm.LLVMInt8TypeInContext(cg.ctx);
        const data_ty = llvm.LLVMArrayType2(i8_ty, payload_bytes);
        var fields = [_]llvm.LLVMTypeRef{ llvm.LLVMInt32TypeInContext(cg.ctx), data_ty };
        llvm.LLVMStructSetBody(meta.llvm_ty, &fields, 2, 0);
    }
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
        // Reinterpret the payload as the data byte-array through stack memory.
        // The data array is sized to the LARGEST variant, so it may be wider than
        // this payload — alloca the data type (not the payload type) so the later
        // load stays in bounds. Entry-block alloca to avoid a `__chkstk` probe.
        const data_ty    = llvm.LLVMStructGetTypeAtIndex(meta.llvm_ty, 1);
        const cur_fn     = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(cg.builder));
        const tmp        = abi.entryAlloca(cg, cur_fn, data_ty);
        _ = llvm.LLVMBuildStore(cg.builder, pv, tmp);
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
    // Reinterpret the data bytes as the target type through stack memory. The
    // scratch must be an ENTRY-block alloca: a dynamic (mid-function) alloca on
    // Windows x64 emits a `__chkstk` probe the CRT-less link can't resolve.
    const data_ty = llvm.LLVMStructGetTypeAtIndex(meta.llvm_ty, 1);
    const cur_fn = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInsertBlock(cg.builder));
    const tmp = abi.entryAlloca(cg, cur_fn, data_ty);
    _ = llvm.LLVMBuildStore(cg.builder, data_bytes, tmp);
    return llvm.LLVMBuildLoad2(cg.builder, dest_ty, tmp, "");
}
