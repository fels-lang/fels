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

    if (func.no_inline)
        addStrAttr(cg, lv, fn_idx, "noinline", "");

    if (func.no_return)
        addStrAttr(cg, lv, fn_idx, "noreturn", "");

    if (func.naked)
        addStrAttr(cg, lv, fn_idx, "naked", "");

    if (func.entry) {
        addStrAttr(cg, lv, fn_idx, "noinline", "");
    }

    if (func.export_sym) |sym| {
        // Ensure external linkage so the symbol survives the linker.
        llvm.LLVMSetLinkage(lv, llvm.LLVMExternalLinkage);
        // If an explicit export name was given, rename the LLVM value.
        if (sym.len > 0 and !std.mem.eql(u8, sym, func.name)) {
            llvm.LLVMSetValueName2(lv, sym.ptr, sym.len);
        }
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
