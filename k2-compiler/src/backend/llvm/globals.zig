/// IrGlobal → LLVM global variable.
const std      = @import("std");
const ir       = @import("../../ir.zig");
const llvm     = @import("c_api.zig").llvm;
const types    = @import("types.zig");
const values   = @import("values.zig");
const ModuleCg = @import("context.zig").ModuleCg;

pub fn lowerAll(cg: *ModuleCg, globals: []const ir.IrGlobal) !void {
    for (globals) |g| try lowerOne(cg, g);
}

fn lowerOne(cg: *ModuleCg, g: ir.IrGlobal) !void {
    const name_z = try cg.allocator.dupeZ(u8, g.name);
    defer cg.allocator.free(name_z);

    const lty  = types.lower(cg, g.ty);
    const gval = llvm.LLVMAddGlobal(cg.mod, lty, name_z);

    const init_val = lowerConstInit(cg, g.init, g.ty);
    llvm.LLVMSetInitializer(gval, init_val);

    if (!g.mutable) llvm.LLVMSetGlobalConstant(gval, 1);

    // Apply struct alignment if the global is of a named struct type with #align.
    if (g.ty == .struct_type) {
        // Look up alignment from the struct definition (if any was recorded).
        // For now, alignment is left at default; a future pass can propagate it.
    }

    try cg.global_decls.put(g.name, gval);
}

fn lowerConstInit(cg: *ModuleCg, init: ir.ConstInit, ty: ir.IrType) llvm.LLVMValueRef {
    return switch (init) {
        .imm         => |imm| values.lowerImm(cg, imm, ty),
        .struct_init => |si|  lowerStructInit(cg, si),
    };
}

fn lowerStructInit(cg: *ModuleCg, si: ir.StructInit) llvm.LLVMValueRef {
    const struct_ty = cg.struct_types.get(si.ty_name) orelse
        return llvm.LLVMConstNull(llvm.LLVMPointerTypeInContext(cg.ctx, 0));

    const fields = cg.allocator.alloc(llvm.LLVMValueRef, si.fields.len) catch
        return llvm.LLVMConstNull(struct_ty);
    defer cg.allocator.free(fields);

    for (si.fields, 0..) |f, i| {
        fields[i] = lowerConstInit(cg, f.value, .{ .struct_type = si.ty_name });
    }
    return llvm.LLVMConstNamedStruct(struct_ty, fields.ptr, @intCast(fields.len));
}
