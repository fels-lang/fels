/// StructDef → named LLVM struct type.
/// Records field names so instrs.zig can resolve field indices.
const std = @import("std");
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const layout = @import("../../layout.zig");
const ModuleCg = ctx_mod.ModuleCg;

pub fn lowerAll(cg: *ModuleCg, structs: []const ir.StructDef) !void {
    // Pass 1: create named shells so forward-references work.
    for (structs) |s| {
        const name_z = try cg.allocator.dupeZ(u8, s.name);
        defer cg.allocator.free(name_z);
        const lty = llvm.LLVMStructCreateNamed(cg.ctx, name_z);
        try cg.struct_types.put(s.name, lty);
    }

    // Pass 2: fill bodies + record field metadata.
    for (structs) |s| {
        const lty = cg.struct_types.get(s.name).?;

        // One slot beyond the fields for the `#align(N)` tail member, if any.
        const field_tys = try cg.allocator.alloc(llvm.LLVMTypeRef, s.fields.len + 1);
        defer cg.allocator.free(field_tys);

        const field_entries = try cg.allocator.alloc(ctx_mod.StructField, s.fields.len);
        for (s.fields, 0..) |f, i| {
            // A `fn(...)` struct field is a THIN function pointer, not the fat
            // `{fn, env}` closure — so the layout matches C structs (e.g. a Win32
            // `WNDCLASSEXA.lpfnWndProc`) and holds a raw callback pointer.
            field_tys[i] = if (f.ty == .fn_ptr)
                llvm.LLVMPointerTypeInContext(cg.ctx, 0)
            else
                types.lower(cg, f.ty);
            field_entries[i] = .{ .name = f.name, .ir_ty = f.ty };
        }

        var body_len: usize = s.fields.len;
        if (alignTail(cg, s, structs)) |tail| {
            field_tys[body_len] = tail;
            body_len += 1;
        }
        llvm.LLVMStructSetBody(lty, field_tys.ptr, @intCast(body_len), if (s.is_packed) 1 else 0);
        try cg.struct_fields.put(s.name, field_entries);
        // Store alignment in module metadata for use when allocating instances.
        if (s.alignment > 0) {
            try cg.struct_alignments.put(s.name, s.alignment);
        }
    }
}

/// The trailing member that gives a `#align(N)` struct C's `alignas(N)` layout: a
/// zero-length array of a type aligned to N. It adds no data, so field indices and
/// by-value C-ABI classification are untouched, but LLVM then rounds the struct's
/// size up to a multiple of N and aligns it to N wherever it is nested or arrayed.
///
/// A packed struct has alignment 1 whatever its members say, so there it is the size
/// that is rounded up, with explicit tail bytes (its alignment stays an allocation
/// property, see `struct_alignments`). Returns null when `s` has no `#align`.
fn alignTail(cg: *ModuleCg, s: ir.StructDef, structs: []const ir.StructDef) ?llvm.LLVMTypeRef {
    if (s.alignment == 0) return null;
    const i8_ty = llvm.LLVMInt8TypeInContext(cg.ctx);
    if (s.is_packed) {
        // `layout.of` includes the `#align` rounding; the padding is what separates
        // the fields' packed size from it.
        const rounded = layout.of(.{ .struct_type = s.name }, structs) orelse return null;
        const packed_size = packedSize(s, structs) orelse return null;
        const pad = rounded.size - packed_size;
        if (pad == 0) return null;
        return llvm.LLVMArrayType2(i8_ty, pad);
    }
    const n: u64 = s.alignment;
    const aligned = switch (n) {
        1 => i8_ty,
        2 => llvm.LLVMInt16TypeInContext(cg.ctx),
        4 => llvm.LLVMInt32TypeInContext(cg.ctx),
        8 => llvm.LLVMInt64TypeInContext(cg.ctx),
        // A vector's ABI alignment is its size, so `<N/8 x i64>` is aligned to N.
        else => llvm.LLVMVectorType(llvm.LLVMInt64TypeInContext(cg.ctx), @intCast(n / 8)),
    };
    return llvm.LLVMArrayType2(aligned, 0);
}

/// Size of a packed struct before `#align` rounds it: its fields back to back.
fn packedSize(s: ir.StructDef, structs: []const ir.StructDef) ?u64 {
    var total: u64 = 0;
    for (s.fields) |f| {
        const member = if (f.ty == .fn_ptr)
            layout.Layout{ .size = 8, .alignment = 8 }
        else
            layout.of(f.ty, structs) orelse return null;
        total += member.size;
    }
    return total;
}
