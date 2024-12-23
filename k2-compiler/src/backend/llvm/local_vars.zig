/// Alloca management: scan all store_local instructions upfront,
/// then emit one alloca per unique local name in the entry block.
const std = @import("std");
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const types = @import("types.zig");
const ModuleCg = @import("context.zig").ModuleCg;

pub fn allocateLocals(
    cg: *ModuleCg,
    func: ir.IrFunction,
    entry_block: llvm.LLVMBasicBlockRef,
) !std.StringHashMap(llvm.LLVMValueRef) {
    var map = std.StringHashMap(llvm.LLVMValueRef).init(cg.allocator);
    errdefer map.deinit();

    // Collect unique local names + their IrType (first store_local wins).
    var seen = std.StringHashMap(ir.IrType).init(cg.allocator);
    defer seen.deinit();

    for (func.blocks) |block| {
        for (block.instrs) |instr| switch (instr.kind) {
            .store_local => |sl| {
                if (!seen.contains(sl.name))
                    try seen.put(sl.name, instr.ty);
            },
            else => {},
        };
    }

    // Emit allocas at the top of the entry block.
    llvm.LLVMPositionBuilderAtEnd(cg.builder, entry_block);
    var it = seen.iterator();
    while (it.next()) |entry| {
        const name_z = try cg.allocator.dupeZ(u8, entry.key_ptr.*);
        defer cg.allocator.free(name_z);
        // types.lower handles slice → fat-pointer struct.
        const lty = types.lower(cg, entry.value_ptr.*);
        const alloca = llvm.LLVMBuildAlloca(cg.builder, lty, name_z);
        try map.put(entry.key_ptr.*, alloca);
    }

    return map;
}
