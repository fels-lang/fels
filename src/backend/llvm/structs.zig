/// StructDef → named LLVM struct type.
/// Records field names so instrs.zig can resolve field indices.
const std = @import("std");
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
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

        const field_tys = try cg.allocator.alloc(llvm.LLVMTypeRef, s.fields.len);
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

        llvm.LLVMStructSetBody(lty, field_tys.ptr, @intCast(field_tys.len), if (s.is_packed) 1 else 0);
        try cg.struct_fields.put(s.name, field_entries);
        // Store alignment in module metadata for use when allocating instances.
        if (s.alignment > 0) {
            try cg.struct_alignments.put(s.name, s.alignment);
        }
    }
}
