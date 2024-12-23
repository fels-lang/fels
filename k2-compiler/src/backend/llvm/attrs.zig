/// Map K2 function attributes to LLVM function attributes.
/// Called from functions.zig after LLVMAddFunction.
const std = @import("std");
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const ModuleCg = @import("context.zig").ModuleCg;

/// Apply all relevant K2 attributes to an LLVM function value.
pub fn applyFunctionAttrs(cg: *ModuleCg, func: ir.IrFunction, lv: llvm.LLVMValueRef) void {
    const fn_idx: c_uint = 0xFFFF_FFFF; // LLVMAttributeFunctionIndex

    if (func.inline_hint)
        addStrAttr(cg, lv, fn_idx, "alwaysinline", "");

    if (func.naked)
        addStrAttr(cg, lv, fn_idx, "naked", "");

    if (func.entry) {
        // Mark as the module entry point (noinline so it survives optimisation).
        addStrAttr(cg, lv, fn_idx, "noinline", "");
    }
}

/// Apply struct alignment when creating a global or alloca.
/// Returns the alignment (0 = default) parsed from the `#align(N)` attribute.
pub fn structAlignment(attrs: []const ir.IrType) u32 {
    // Currently alignment is not stored in IrType; it's a future extension.
    // Placeholder: return 0 (LLVM default alignment).
    _ = attrs;
    return 0;
}

// ── Helpers ────────────────────────────────────────────────────────────────

fn addStrAttr(
    cg: *ModuleCg,
    lv: llvm.LLVMValueRef,
    index: c_uint,
    key: []const u8,
    val: []const u8,
) void {
    const attr = llvm.LLVMCreateStringAttribute(
        cg.ctx,
        key.ptr,
        @intCast(key.len),
        val.ptr,
        @intCast(val.len),
    );
    llvm.LLVMAddAttributeAtIndex(lv, index, attr);
}
