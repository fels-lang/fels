/// IrGlobal → LLVM global variable.
///
/// A global's initializer is data in the image: the constants, aggregates and addresses
/// the IR's `ConstInit` describes become LLVM constants, and the linker places them (with
/// the relocations an address needs) in `.data`, or in `.rdata` for an immutable global.
/// Nothing is computed at startup.
const std = @import("std");
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const types = @import("types.zig");
const values = @import("values.zig");
const instrs = @import("instrs.zig");
const ModuleCg = @import("context.zig").ModuleCg;

/// Two passes: every global is declared first, so an initializer can take the address of
/// any other global whatever their order in the source, then the initializers are set.
/// Function declarations must already exist (a `fn` initializer is the function's address).
pub fn lowerAll(cg: *ModuleCg, globals: []const ir.IrGlobal) !void {
    for (globals) |g| try declareOne(cg, g);
    for (globals) |g| try initOne(cg, g);
}

fn declareOne(cg: *ModuleCg, g: ir.IrGlobal) !void {
    const name_z = try cg.allocator.dupeZ(u8, g.name);
    defer cg.allocator.free(name_z);

    const lty = types.lower(cg, g.ty);
    const gval = llvm.LLVMAddGlobal(cg.mod, lty, name_z);

    try cg.global_decls.put(g.name, gval);
    try cg.global_ir_types.put(g.name, g.ty);

    // `#export`: a data export. External linkage keeps it through the linker, `dllexport`
    // puts it in a DLL's export table (a host reads it with `GetProcAddress`/`dlsym`-style
    // lookup, exactly like a function), and an explicit name renames the symbol.
    if (g.export_sym) |sym| {
        llvm.LLVMSetLinkage(gval, llvm.LLVMExternalLinkage);
        llvm.LLVMSetDLLStorageClass(gval, llvm.LLVMDLLExportStorageClass);
        if (sym.len > 0 and !std.mem.eql(u8, sym, g.name)) llvm.LLVMSetValueName2(gval, sym.ptr, sym.len);
    }
}

fn initOne(cg: *ModuleCg, g: ir.IrGlobal) !void {
    const gval = cg.global_decls.get(g.name).?;
    const lty = types.lower(cg, g.ty);

    llvm.LLVMSetInitializer(gval, lowerConstInit(cg, g.init, g.ty, lty));
    if (!g.mutable) llvm.LLVMSetGlobalConstant(gval, 1);

    // Apply struct alignment if the global is of a named struct type with #align.
    switch (g.ty) {
        .struct_type => |struct_name| {
            if (cg.struct_alignments.get(struct_name)) |a| {
                llvm.LLVMSetAlignment(gval, a);
            }
        },
        else => {},
    }
}

/// `ty` is the value's IR type (to read an immediate against); `lty` is the LLVM type the
/// slot has — they differ for a `fn` struct field, whose IR type is a closure but which is
/// stored as a bare code pointer.
fn lowerConstInit(cg: *ModuleCg, init: ir.ConstInit, ty: ir.IrType, lty: llvm.LLVMTypeRef) llvm.LLVMValueRef {
    return switch (init) {
        .imm => |imm| values.lowerImm(cg, imm, ty),
        .zero => llvm.LLVMConstNull(lty),
        .struct_init => |si| lowerStructInit(cg, si),
        .array_init => |elems| lowerArrayInit(cg, elems, ty, lty),
        .func_ref => |name| lowerFuncRef(cg, name, lty),
        .global_addr => |name| cg.global_decls.get(name) orelse blk: {
            cg.recordLoweringError("static initializer takes the address of unknown global `{s}`", .{name}, @src());
            break :blk llvm.LLVMConstNull(lty);
        },
        .variant_tag => |tag| lowerVariantTag(tag, lty),
        // Only the module the comptime VM reads holds a value that was never computed; the
        // lowering of the program itself either has the value or stopped with the reason.
        .pending => blk: {
            cg.recordLoweringError("internal error: a static initializer reached the code generator before its compile-time value was computed", .{}, @src());
            break :blk llvm.LLVMConstNull(lty);
        },
    };
}

/// An enum value with no payload. A simple enum is its `i32` discriminant; an enum that has
/// payload variants is `{ i32 tag, [N x i8] data }` and a variant without a payload leaves
/// the data bytes zero (see variants.zig `buildVariantLit`).
fn lowerVariantTag(tag: u32, lty: llvm.LLVMTypeRef) llvm.LLVMValueRef {
    if (llvm.LLVMGetTypeKind(lty) == llvm.LLVMIntegerTypeKind) return llvm.LLVMConstInt(lty, tag, 0);
    if (llvm.LLVMGetTypeKind(lty) != llvm.LLVMStructTypeKind or llvm.LLVMCountStructElementTypes(lty) != 2)
        return llvm.LLVMConstNull(lty);
    var elems = [_]llvm.LLVMValueRef{
        llvm.LLVMConstInt(llvm.LLVMStructGetTypeAtIndex(lty, 0), tag, 0),
        llvm.LLVMConstNull(llvm.LLVMStructGetTypeAtIndex(lty, 1)),
    };
    return llvm.LLVMConstNamedStruct(lty, &elems, 2);
}

fn lowerStructInit(cg: *ModuleCg, si: ir.StructInit) llvm.LLVMValueRef {
    const struct_ty = cg.struct_types.get(si.ty_name) orelse
        return llvm.LLVMConstNull(llvm.LLVMPointerTypeInContext(cg.ctx, 0));
    const declared = cg.struct_fields.get(si.ty_name) orelse return llvm.LLVMConstNull(struct_ty);

    // A `#align(N)` struct carries a zero-sized tail member beyond its declared
    // fields (see structs.zig `alignTail`); a constant has to supply it too.
    const elems: usize = @max(si.fields.len, llvm.LLVMCountStructElementTypes(struct_ty));
    const fields = cg.allocator.alloc(llvm.LLVMValueRef, elems) catch
        return llvm.LLVMConstNull(struct_ty);
    defer cg.allocator.free(fields);

    for (si.fields, 0..) |f, i| {
        const slot_ty = llvm.LLVMStructGetTypeAtIndex(struct_ty, @intCast(i));
        const ir_ty: ir.IrType = if (i < declared.len) declared[i].ir_ty else .unknown;
        fields[i] = lowerConstInit(cg, f.value, ir_ty, slot_ty);
    }
    for (si.fields.len..elems) |i| {
        fields[i] = llvm.LLVMConstNull(llvm.LLVMStructGetTypeAtIndex(struct_ty, @intCast(i)));
    }
    return llvm.LLVMConstNamedStruct(struct_ty, fields.ptr, @intCast(fields.len));
}

fn lowerArrayInit(cg: *ModuleCg, elems: []const ir.ConstInit, ty: ir.IrType, lty: llvm.LLVMTypeRef) llvm.LLVMValueRef {
    const arr = switch (ty) {
        .array => |a| a,
        else => return llvm.LLVMConstNull(lty),
    };
    const elem_lty = types.lower(cg, arr.elem.*);
    const total: usize = @intCast(arr.len);
    const out = cg.allocator.alloc(llvm.LLVMValueRef, total) catch return llvm.LLVMConstNull(lty);
    defer cg.allocator.free(out);
    for (out, 0..) |*slot, i| {
        slot.* = if (i < elems.len)
            lowerConstInit(cg, elems[i], arr.elem.*, elem_lty)
        else
            llvm.LLVMConstNull(elem_lty);
    }
    return llvm.LLVMConstArray2(elem_lty, out.ptr, total);
}

/// The address of function `name`. A slot of pointer type (a `fn` struct field, an
/// `extern fn`) holds the code address itself; a slot of closure type holds the
/// `{ thunk, null }` pair a plain `fn` value is, the thunk being the forwarder that drops
/// the environment argument.
fn lowerFuncRef(cg: *ModuleCg, name: []const u8, lty: llvm.LLVMTypeRef) llvm.LLVMValueRef {
    const fn_val = cg.fn_decls.get(name) orelse {
        cg.recordLoweringError("static initializer names unknown function `{s}`", .{name}, @src());
        return llvm.LLVMConstNull(lty);
    };
    if (llvm.LLVMGetTypeKind(lty) == llvm.LLVMPointerTypeKind) return fn_val;
    const thunk = instrs.getOrCreateThunk(cg, name, fn_val) orelse return llvm.LLVMConstNull(lty);
    const null_env = llvm.LLVMConstNull(llvm.LLVMPointerTypeInContext(cg.ctx, 0));
    var pair = [_]llvm.LLVMValueRef{ thunk, null_env };
    return llvm.LLVMConstStructInContext(cg.ctx, &pair, 2, 0);
}
