const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const ModuleCg = @import("context.zig").ModuleCg;

pub fn lowerAll(cg: *ModuleCg, vtables: []const ir.InterfaceVTable) !void {
    const ptr_ty = llvm.LLVMPointerTypeInContext(cg.ctx, 0);
    for (vtables) |vtable| {
        const methods = try cg.allocator.alloc(llvm.LLVMValueRef, vtable.methods.len);
        defer cg.allocator.free(methods);
        for (vtable.methods, 0..) |name, i| {
            methods[i] = cg.fn_decls.get(name) orelse llvm.LLVMConstNull(ptr_ty);
        }
        const array_ty = llvm.LLVMArrayType2(ptr_ty, vtable.methods.len);
        const name_z = try cg.allocator.dupeZ(u8, vtable.name);
        defer cg.allocator.free(name_z);
        const global = llvm.LLVMAddGlobal(cg.mod, array_ty, name_z);
        llvm.LLVMSetInitializer(global, llvm.LLVMConstArray2(ptr_ty, methods.ptr, methods.len));
        llvm.LLVMSetGlobalConstant(global, 1);
        llvm.LLVMSetLinkage(global, llvm.LLVMPrivateLinkage);
        try cg.global_decls.put(vtable.name, global);
    }
}
