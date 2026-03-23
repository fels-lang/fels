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
    var gval = cg.global_decls.get(g.name).?;
    const lty = types.lower(cg, g.ty);

    const init = lowerConstInit(cg, g.init, g.ty, lty);
    // A constant with a payload in it is a packed struct of the type's layout (see
    // `lowerVariantInit`): the global takes that type, at the alignment of its own.
    if (llvm.LLVMTypeOf(init) != lty) gval = try retypeGlobal(cg, g.name, gval, llvm.LLVMTypeOf(init), lty);
    llvm.LLVMSetInitializer(gval, init);
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

/// The global `gval` again, its value of type `init_ty` (the bytes of `lty`, laid out as
/// a packed struct). Every use of the old declaration, in code and in other initializers,
/// is the new one.
fn retypeGlobal(cg: *ModuleCg, name: []const u8, gval: llvm.LLVMValueRef, init_ty: llvm.LLVMTypeRef, lty: llvm.LLVMTypeRef) !llvm.LLVMValueRef {
    const fresh = llvm.LLVMAddGlobal(cg.mod, init_ty, "");
    llvm.LLVMSetLinkage(fresh, llvm.LLVMGetLinkage(gval));
    llvm.LLVMSetDLLStorageClass(fresh, llvm.LLVMGetDLLStorageClass(gval));
    llvm.LLVMSetAlignment(fresh, llvm.LLVMABIAlignmentOfType(cg.targetData(), lty));
    var len: usize = 0;
    const symbol = llvm.LLVMGetValueName2(gval, &len);
    const symbol_copy = try cg.allocator.dupe(u8, symbol[0..len]);
    defer cg.allocator.free(symbol_copy);
    llvm.LLVMReplaceAllUsesWith(gval, fresh);
    llvm.LLVMDeleteGlobal(gval);
    llvm.LLVMSetValueName2(fresh, symbol_copy.ptr, symbol_copy.len);
    try cg.global_decls.put(name, fresh);
    return fresh;
}

/// `ty` is the value's IR type (to read an immediate against); `lty` is the LLVM type the
/// slot has — they differ for a `fn` struct field, whose IR type is a closure but which is
/// stored as a bare code pointer. The constant has type `lty`, except one that holds a
/// payload (`lowerVariantInit`), which is a packed struct of the same size and layout.
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
        .variant => |v| lowerVariantInit(cg, v, lty),
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

/// An enum value or an error with a payload. Its type, `{ i32 tag, [N x i8] data }`, holds
/// the payload as bytes, and a constant of it cannot have a payload with an address in it
/// (a string, a pointer) there; so the constant is `<{ i32 tag, payload, [rest x i8] }>`,
/// the same bytes at the same offsets.
fn lowerVariantInit(cg: *ModuleCg, v: ir.VariantInit, lty: llvm.LLVMTypeRef) llvm.LLVMValueRef {
    if (llvm.LLVMGetTypeKind(lty) != llvm.LLVMStructTypeKind or llvm.LLVMCountStructElementTypes(lty) != 2)
        return llvm.LLVMConstNull(lty);
    const dl = cg.targetData();
    const payload_lty = types.lower(cg, v.payload_ty);
    var payload = lowerConstInit(cg, v.payload.*, v.payload_ty, payload_lty);
    // An integer whose width is no whole number of bytes (`u24`) is placed as its bytes: in a
    // packed struct it would take the 4 bytes of its alignment, past the data it has room in.
    if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(payload)) == llvm.LLVMIntegerTypeKind and
        llvm.LLVMABISizeOfType(dl, payload_lty) != llvm.LLVMStoreSizeOfType(dl, payload_lty))
        payload = intBytes(cg, payload, llvm.LLVMStoreSizeOfType(dl, payload_lty));

    var parts: [4]llvm.LLVMValueRef = undefined;
    var n: usize = 0;
    const tag_lty = llvm.LLVMStructGetTypeAtIndex(lty, 0);
    parts[n] = llvm.LLVMConstInt(tag_lty, v.tag, 0);
    n += 1;
    const data_at = llvm.LLVMOffsetOfElement(dl, lty, 1);
    const tag_end = llvm.LLVMABISizeOfType(dl, tag_lty);
    if (data_at > tag_end) {
        parts[n] = zeroBytes(cg, data_at - tag_end);
        n += 1;
    }
    parts[n] = payload;
    n += 1;
    const used = data_at + llvm.LLVMABISizeOfType(dl, llvm.LLVMTypeOf(payload));
    const total = llvm.LLVMABISizeOfType(dl, lty);
    if (used > total) {
        cg.recordLoweringError("internal error: a static payload is larger than the room its enum has for it", .{}, @src());
        return llvm.LLVMConstNull(lty);
    }
    if (total > used) {
        parts[n] = zeroBytes(cg, total - used);
        n += 1;
    }
    return llvm.LLVMConstStructInContext(cg.ctx, &parts, @intCast(n), 1);
}

fn zeroBytes(cg: *ModuleCg, len: u64) llvm.LLVMValueRef {
    return llvm.LLVMConstNull(llvm.LLVMArrayType2(llvm.LLVMInt8TypeInContext(cg.ctx), len));
}

/// The `len` little-endian bytes of the integer constant `value`, as an `[len x i8]`.
fn intBytes(cg: *ModuleCg, value: llvm.LLVMValueRef, len: u64) llvm.LLVMValueRef {
    const i8_ty = llvm.LLVMInt8TypeInContext(cg.ctx);
    const bits = llvm.LLVMConstIntGetZExtValue(value);
    var bytes: [8]llvm.LLVMValueRef = undefined;
    const n: usize = @intCast(@min(len, 8));
    for (bytes[0..n], 0..) |*b, i| b.* = llvm.LLVMConstInt(i8_ty, (bits >> @intCast(i * 8)) & 0xff, 0);
    return llvm.LLVMConstArray2(i8_ty, &bytes, n);
}

/// The aggregate of `parts` laid out as `lty` lays out its members, as a packed struct: what
/// an aggregate constant is when one of its parts has a type of its own (`lowerVariantInit`).
/// `offsets[i]` is where part `i` starts.
fn packedLike(cg: *ModuleCg, lty: llvm.LLVMTypeRef, parts: []const llvm.LLVMValueRef, offsets: []const u64) llvm.LLVMValueRef {
    const dl = cg.targetData();
    var out: std.ArrayList(llvm.LLVMValueRef) = .empty;
    defer out.deinit(cg.allocator);
    var at: u64 = 0;
    for (parts, offsets) |part, offset| {
        if (offset > at) out.append(cg.allocator, zeroBytes(cg, offset - at)) catch return llvm.LLVMConstNull(lty);
        out.append(cg.allocator, part) catch return llvm.LLVMConstNull(lty);
        at = offset + llvm.LLVMABISizeOfType(dl, llvm.LLVMTypeOf(part));
    }
    const total = llvm.LLVMABISizeOfType(dl, lty);
    if (total > at) out.append(cg.allocator, zeroBytes(cg, total - at)) catch return llvm.LLVMConstNull(lty);
    return llvm.LLVMConstStructInContext(cg.ctx, out.items.ptr, @intCast(out.items.len), 1);
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
    for (fields, 0..) |f, i| {
        if (llvm.LLVMTypeOf(f) == llvm.LLVMStructGetTypeAtIndex(struct_ty, @intCast(i))) continue;
        // A field holds a payload: the struct is its bytes, as a packed struct.
        const offsets = cg.allocator.alloc(u64, fields.len) catch return llvm.LLVMConstNull(struct_ty);
        defer cg.allocator.free(offsets);
        for (offsets, 0..) |*o, k| o.* = llvm.LLVMOffsetOfElement(cg.targetData(), struct_ty, @intCast(k));
        return packedLike(cg, struct_ty, fields, offsets);
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
    for (out) |v| {
        if (llvm.LLVMTypeOf(v) == elem_lty) continue;
        // An element holds a payload: the array is its bytes, as a packed struct.
        const stride = llvm.LLVMABISizeOfType(cg.targetData(), elem_lty);
        const offsets = cg.allocator.alloc(u64, total) catch return llvm.LLVMConstNull(lty);
        defer cg.allocator.free(offsets);
        for (offsets, 0..) |*o, k| o.* = k * stride;
        return packedLike(cg, lty, out, offsets);
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
