/// Instruction lowering.
const std      = @import("std");
const ir       = @import("../../ir.zig");
const llvm     = @import("c_api.zig").llvm;
const types    = @import("types.zig");
const values   = @import("values.zig");
const vars_mod = @import("variants.zig");
const ModuleCg = @import("context.zig").ModuleCg;

pub fn lower(cg: *ModuleCg, fncg: anytype, instr: ir.Instr) void {
    const result: ?llvm.LLVMValueRef = switch (instr.kind) {
        .const_value => |imm| values.lowerImm(cg, imm, instr.ty),

        .unary => |u| lowerUnary(cg, fncg, u, instr.ty),
        .binary => |b| lowerBinary(cg, fncg, b, instr.ty),

        .call => |call| lowerCall(cg, fncg, call, instr.ty),

        .builtin => |b| lowerBuiltin(cg, fncg, b, instr.ty),

        .alloc => |al| blk: {
            break :blk llvm.LLVMBuildAlloca(cg.builder, types.lower(cg, al.ty), "");
        },

        .alloc_slice => |al| blk: {
            // Allocate a slice struct on the stack, then fill ptr+len.
            const slice_ty = cg.getSliceType();
            const alloca = llvm.LLVMBuildAlloca(cg.builder, slice_ty, "");
            const count = resolveVal(cg, fncg, al.count, .usize);
            // Heap-allocate the element array via alloca(elem*count) — simplified.
            const elem_ty = types.lower(cg, al.elem_ty);
            const data_ptr = llvm.LLVMBuildArrayAlloca(cg.builder, elem_ty, count, "");
            // Store ptr and len into the slice struct.
            const ptr_gep = llvm.LLVMBuildStructGEP2(cg.builder, slice_ty, alloca, 0, "");
            _ = llvm.LLVMBuildStore(cg.builder, data_ptr, ptr_gep);
            const len_gep = llvm.LLVMBuildStructGEP2(cg.builder, slice_ty, alloca, 1, "");
            _ = llvm.LLVMBuildStore(cg.builder, count, len_gep);
            // Return the struct (load from alloca).
            break :blk llvm.LLVMBuildLoad2(cg.builder, slice_ty, alloca, "");
        },

        .store_local => |sl| blk: {
            const alloca = fncg.locals.get(sl.name) orelse break :blk null;
            _ = llvm.LLVMBuildStore(cg.builder, resolveVal(cg, fncg, sl.value, instr.ty), alloca);
            break :blk null;
        },

        .store => |st| blk: {
            const target = resolveVal(cg, fncg, st.target, .{ .ptr = undefined });
            const val = resolveVal(cg, fncg, st.value, instr.ty);
            _ = llvm.LLVMBuildStore(cg.builder, val, target);
            break :blk null;
        },

        .global_store => |gs| blk: {
            const gv = cg.global_decls.get(gs.name) orelse break :blk null;
            _ = llvm.LLVMBuildStore(cg.builder, resolveVal(cg, fncg, gs.value, instr.ty), gv);
            break :blk null;
        },

        .global_load => |name| blk: {
            const gv = cg.global_decls.get(name) orelse break :blk null;
            break :blk llvm.LLVMBuildLoad2(cg.builder, types.lower(cg, instr.ty), gv, "");
        },

        .field => |f| lowerField(cg, fncg, f, instr.ty, false),
        .field_addr => |f| lowerField(cg, fncg, f, instr.ty, true),

        .index => |ix| blk: {
            const elem_ty = types.lower(cg, instr.ty);
            const gep = lowerIndexAddress(cg, fncg, ix, instr.ty) orelse break :blk null;
            break :blk llvm.LLVMBuildLoad2(cg.builder, elem_ty, gep, "");
        },
        .index_addr => |ix| lowerIndexAddress(cg, fncg, ix, pointerChild(instr.ty) orelse .unknown),

        .slice_expr => |slice| lowerSliceExpr(cg, fncg, slice),

        .optional_is_some => |value| blk: {
            const opt_ty = fncg.irTypeOf(value) orelse instr.ty;
            const opt = resolveVal(cg, fncg, value, opt_ty);
            break :blk llvm.LLVMBuildExtractValue(cg.builder, opt, 0, "");
        },

        .optional_payload => |value| blk: {
            const opt_ty = fncg.irTypeOf(value) orelse break :blk null;
            const payload_ty = switch (opt_ty) {
                .optional => |inner| inner.*,
                else => break :blk null,
            };
            _ = payload_ty;
            const opt = resolveVal(cg, fncg, value, opt_ty);
            break :blk llvm.LLVMBuildExtractValue(cg.builder, opt, 1, "");
        },

        .cast => |cs| blk: {
            const val = resolveVal(cg, fncg, cs.value, .unknown);
            const dest = types.lower(cg, instr.ty);
            break :blk values.coerce(cg.builder, cg.ctx, val, dest);
        },

        .struct_lit => |sl| lowerStructLit(cg, fncg, sl, instr.ty),

        .inline_asm => |ai| lowerInlineAsm(cg, fncg, ai, instr.ty),

        .variant_lit => |vl| vars_mod.buildVariantLit(
            cg, vl.type_name, vl.variant,
            if (vl.payload) |pv| resolveVal(cg, fncg, pv, .unknown) else null,
        ),
        .variant_is => |vi| vars_mod.buildVariantIs(
            cg, resolveVal(cg, fncg, vi.value, .unknown), vi.type_name, vi.variant,
        ),
        .variant_payload => |vp| vars_mod.buildVariantPayload(
            cg, resolveVal(cg, fncg, vp.value, .unknown),
            vp.type_name, vp.variant, types.lower(cg, instr.ty),
        ),

        .call_indirect => |ci| lowerCallIndirect(cg, fncg, ci, instr.ty),

        // Zone/error — runtime-library concerns.
        .zone_push, .zone_pop, .zone_free,
        .try_is_ok, .try_ok, .try_err,
        .iter_init, .iter_has_next, .iter_next,
        .at, .raw_pointer => null,
    };

    if (instr.id) |id| if (result) |v| {
        fncg.regs.put(id, v) catch {};
        fncg.reg_ir_types.put(id, instr.ty) catch {};
    };
}

// ── Helpers ────────────────────────────────────────────────────────────────

fn resolveVal(cg: *ModuleCg, fncg: anytype, val: ir.Value, ty: ir.IrType) llvm.LLVMValueRef {
    return values.resolveValue(cg, fncg, val, ty);
}

fn pointerChild(ty: ir.IrType) ?ir.IrType {
    return switch (ty) {
        .ptr => |inner| inner.*,
        else => null,
    };
}

fn lowerIndexAddress(
    cg: *ModuleCg,
    fncg: anytype,
    ix: ir.IndexInstr,
    elem_ir_ty: ir.IrType,
) ?llvm.LLVMValueRef {
    const idx = resolveVal(cg, fncg, ix.index, .usize);
    const elem_lty = types.lower(cg, elem_ir_ty);

    const base_ir_ty = fncg.irTypeOf(ix.base);
    if (base_ir_ty) |base_ty| switch (base_ty) {
        .slice => {
            const base_val = resolveVal(cg, fncg, ix.base, base_ty);
            const ptr = llvm.LLVMBuildExtractValue(cg.builder, base_val, 0, "");
            var indices = [_]llvm.LLVMValueRef{idx};
            return llvm.LLVMBuildGEP2(cg.builder, elem_lty, ptr, &indices, 1, "");
        },
        .ptr => |inner| switch (inner.*) {
            .array => |arr| {
                const base_ptr = resolveVal(cg, fncg, ix.base, base_ty);
                const zero = llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), 0, 0);
                var indices = [_]llvm.LLVMValueRef{ zero, idx };
                return llvm.LLVMBuildGEP2(cg.builder, types.lower(cg, .{ .array = arr }), base_ptr, &indices, 2, "");
            },
            else => {
                const base_ptr = resolveVal(cg, fncg, ix.base, base_ty);
                var indices = [_]llvm.LLVMValueRef{idx};
                return llvm.LLVMBuildGEP2(cg.builder, elem_lty, base_ptr, &indices, 1, "");
            },
        },
        else => {},
    };

    const base = resolveVal(cg, fncg, ix.base, .{ .ptr = undefined });
    var indices = [_]llvm.LLVMValueRef{idx};
    return llvm.LLVMBuildGEP2(cg.builder, elem_lty, base, &indices, 1, "");
}

fn lowerSliceExpr(cg: *ModuleCg, fncg: anytype, slice: ir.SliceInstr) ?llvm.LLVMValueRef {
    var ptr = resolveVal(cg, fncg, slice.ptr, .{ .ptr = undefined });
    if (fncg.irTypeOf(slice.ptr)) |ptr_ty| switch (ptr_ty) {
        .ptr => |inner| switch (inner.*) {
            .array => |arr| {
                const zero = llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), 0, 0);
                var indices = [_]llvm.LLVMValueRef{ zero, zero };
                ptr = llvm.LLVMBuildGEP2(cg.builder, types.lower(cg, .{ .array = arr }), ptr, &indices, 2, "");
            },
            else => {},
        },
        else => {},
    };
    const len = values.coerce(cg.builder, cg.ctx, resolveVal(cg, fncg, slice.len, .usize), llvm.LLVMInt64TypeInContext(cg.ctx));
    var result = llvm.LLVMGetUndef(cg.getSliceType());
    result = llvm.LLVMBuildInsertValue(cg.builder, result, ptr, 0, "");
    result = llvm.LLVMBuildInsertValue(cg.builder, result, len, 1, "");
    return result;
}

// ── Unary ─────────────────────────────────────────────────────────────────

fn lowerUnary(cg: *ModuleCg, fncg: anytype, u: ir.UnaryInstr, ty: ir.IrType) ?llvm.LLVMValueRef {
    const v = resolveVal(cg, fncg, u.value, ty);
    const bl = cg.builder;
    return switch (u.op) {
        .neg => llvm.LLVMBuildNeg(bl, v, ""),
        .not => llvm.LLVMBuildNot(bl, v, ""),
        .bit_not => llvm.LLVMBuildNot(bl, v, ""),
        .deref => llvm.LLVMBuildLoad2(bl, types.lower(cg, ty), v, ""),
        .ref => lowerRef(cg, fncg, u.value),
    };
}

/// Address-of: for a local name, just return its alloca pointer.
/// For anything else, build a temporary alloca and store into it.
fn lowerRef(cg: *ModuleCg, fncg: anytype, val: ir.Value) ?llvm.LLVMValueRef {
    return switch (val) {
        .local => |name| fncg.locals.get(name), // alloca IS the address
        .param => |name| blk: {
            const pv = fncg.params.get(name) orelse break :blk null;
            const pty = fncg.param_ir_types.get(name) orelse break :blk null;
            const tmp = llvm.LLVMBuildAlloca(cg.builder, types.lower(cg, pty), "ref");
            _ = llvm.LLVMBuildStore(cg.builder, pv, tmp);
            break :blk tmp;
        },
        .reg => |id| blk: {
            const rv = fncg.regs.get(id) orelse break :blk null;
            const rty = fncg.reg_ir_types.get(id) orelse break :blk null;
            const tmp = llvm.LLVMBuildAlloca(cg.builder, types.lower(cg, rty), "ref");
            _ = llvm.LLVMBuildStore(cg.builder, rv, tmp);
            break :blk tmp;
        },
        else => null,
    };
}

// ── Binary ─────────────────────────────────────────────────────────────────

fn lowerBinary(cg: *ModuleCg, fncg: anytype, b: ir.BinaryInstr, ty: ir.IrType) ?llvm.LLVMValueRef {
    const lhs_hint = fncg.irTypeOf(b.lhs) orelse ty;
    const rhs_hint = fncg.irTypeOf(b.rhs) orelse lhs_hint;
    const lhs = resolveVal(cg, fncg, b.lhs, lhs_hint);
    var rhs = resolveVal(cg, fncg, b.rhs, rhs_hint);
    rhs = values.coerce(cg.builder, cg.ctx, rhs, llvm.LLVMTypeOf(lhs));
    const bl = cg.builder;
    return switch (b.op) {
        .add => blk: {
            // Pointer + integer → GEP (byte offset).
            const lhs_ty = fncg.irTypeOf(b.lhs);
            if (lhs_ty != null and lhs_ty.? == .ptr) {
                var indices = [_]llvm.LLVMValueRef{rhs};
                break :blk llvm.LLVMBuildGEP2(
                    bl,
                    llvm.LLVMInt8TypeInContext(cg.ctx), // byte GEP
                    lhs,
                    &indices,
                    1,
                    "",
                );
            }
            break :blk llvm.LLVMBuildAdd(bl, lhs, rhs, "");
        },
        .sub => llvm.LLVMBuildSub(bl, lhs, rhs, ""),
        .mul => llvm.LLVMBuildMul(bl, lhs, rhs, ""),
        .div => llvm.LLVMBuildSDiv(bl, lhs, rhs, ""),
        .rem => llvm.LLVMBuildSRem(bl, lhs, rhs, ""),
        .shl => llvm.LLVMBuildShl(bl, lhs, rhs, ""),
        .shr => llvm.LLVMBuildAShr(bl, lhs, rhs, ""),
        .bit_and => llvm.LLVMBuildAnd(bl, lhs, rhs, ""),
        .bit_or => llvm.LLVMBuildOr(bl, lhs, rhs, ""),
        .bit_xor => llvm.LLVMBuildXor(bl, lhs, rhs, ""),
        .and_op => llvm.LLVMBuildAnd(bl, lhs, rhs, ""),
        .or_op => llvm.LLVMBuildOr(bl, lhs, rhs, ""),
        .eq => llvm.LLVMBuildICmp(bl, llvm.LLVMIntEQ, lhs, rhs, ""),
        .ne => llvm.LLVMBuildICmp(bl, llvm.LLVMIntNE, lhs, rhs, ""),
        .lt => llvm.LLVMBuildICmp(bl, llvm.LLVMIntSLT, lhs, rhs, ""),
        .le => llvm.LLVMBuildICmp(bl, llvm.LLVMIntSLE, lhs, rhs, ""),
        .gt => llvm.LLVMBuildICmp(bl, llvm.LLVMIntSGT, lhs, rhs, ""),
        .ge => llvm.LLVMBuildICmp(bl, llvm.LLVMIntSGE, lhs, rhs, ""),
        else => null,
    };
}

// ── Inline assembly ────────────────────────────────────────────────────────

fn lowerInlineAsm(
    cg: *ModuleCg,
    fncg: anytype,
    ai: ir.InlineAsmInstr,
    ty: ir.IrType,
) ?llvm.LLVMValueRef {
    const is_void = ty == .void;

    // Build the LLVM function type: (arg0_ty, arg1_ty, ...) -> ret_ty
    const param_tys = cg.allocator.alloc(llvm.LLVMTypeRef, ai.args.len) catch return null;
    defer cg.allocator.free(param_tys);
    for (0..ai.args.len) |i| {
        // For syscall args we default to i64; a type-tracking pass could refine this.
        param_tys[i] = llvm.LLVMInt64TypeInContext(cg.ctx);
    }
    const ret_lty = types.lower(cg, ty);
    const fn_ty = llvm.LLVMFunctionType(ret_lty, param_tys.ptr, @intCast(param_tys.len), 0);

    // Build constraint z-string.
    const constraints_z = cg.allocator.dupeZ(u8, ai.constraints) catch return null;
    defer cg.allocator.free(constraints_z);
    const template_z = cg.allocator.dupeZ(u8, ai.template) catch return null;
    defer cg.allocator.free(template_z);

    const asm_val = llvm.LLVMGetInlineAsm(
        fn_ty,
        template_z,
        ai.template.len,
        constraints_z,
        ai.constraints.len,
        if (ai.volatile_) 1 else 0,
        0, // isAlignStack
        llvm.LLVMInlineAsmDialectATT,
        0, // canThrow
    );

    // Resolve argument values (cast each to i64 for now).
    const args = cg.allocator.alloc(llvm.LLVMValueRef, ai.args.len) catch return null;
    defer cg.allocator.free(args);
    const i64_ty = llvm.LLVMInt64TypeInContext(cg.ctx);
    for (ai.args, 0..) |arg, i| {
        var v = resolveVal(cg, fncg, arg, .usize);
        // If the value isn't already an integer, cast it.
        if (llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(v)) != llvm.LLVMIntegerTypeKind)
            v = llvm.LLVMBuildPtrToInt(cg.builder, v, i64_ty, "");
        args[i] = v;
    }

    const result = llvm.LLVMBuildCall2(
        cg.builder,
        fn_ty,
        asm_val,
        args.ptr,
        @intCast(args.len),
        "",
    );
    return if (is_void) null else result;
}

// ── Calls ──────────────────────────────────────────────────────────────────

/// Indirect call through a function pointer.
/// With opaque pointers we must reconstruct the LLVM function type from
/// the return type (instr.ty) and the actual argument types at the call site.
fn lowerCallIndirect(
    cg:   *ModuleCg,
    fncg: anytype,
    ci:   ir.CallIndirectInstr,
    ret_ty: ir.IrType,
) ?llvm.LLVMValueRef {
    // Resolve the callee — a `ptr` to the function.
    const callee_ptr = resolveVal(cg, fncg, ci.callee, .unknown);

    // Resolve argument values and collect their LLVM types.
    const resolved_args = cg.allocator.alloc(llvm.LLVMValueRef, ci.args.len) catch return null;
    defer cg.allocator.free(resolved_args);
    const param_tys = cg.allocator.alloc(llvm.LLVMTypeRef, ci.args.len) catch return null;
    defer cg.allocator.free(param_tys);

    for (ci.args, 0..) |arg, i| {
        // Use the tracked IR type of each arg to get the LLVM type.
        const arg_ir_ty = fncg.irTypeOf(arg) orelse ir.IrType.unknown;
        resolved_args[i] = resolveVal(cg, fncg, arg, arg_ir_ty);
        param_tys[i] = llvm.LLVMTypeOf(resolved_args[i]);
    }

    // Reconstruct the function type from args + return type.
    const ret_lty = types.lower(cg, ret_ty);
    const fn_ty   = llvm.LLVMFunctionType(ret_lty, param_tys.ptr, @intCast(ci.args.len), 0);

    const result = llvm.LLVMBuildCall2(
        cg.builder, fn_ty, callee_ptr,
        resolved_args.ptr, @intCast(ci.args.len), "",
    );
    return if (ret_ty == .void) null else result;
}

fn lowerCall(cg: *ModuleCg, fncg: anytype, call: ir.CallInstr, ret_ty: ir.IrType) ?llvm.LLVMValueRef {
    const lv = cg.fn_decls.get(call.callee) orelse return null;
    const fn_ty = llvm.LLVMGlobalGetValueType(lv);
    const n_param = llvm.LLVMCountParamTypes(fn_ty);

    const args = cg.allocator.alloc(llvm.LLVMValueRef, call.args.len) catch return null;
    defer cg.allocator.free(args);

    // Get param types so we can hint resolveVal with the right type.
    const param_tys = cg.allocator.alloc(llvm.LLVMTypeRef, n_param) catch return null;
    defer cg.allocator.free(param_tys);
    llvm.LLVMGetParamTypes(fn_ty, param_tys.ptr);

    for (call.args, 0..) |arg, i| {
        const v = if (i < n_param) switch (arg) {
            .imm => |imm| values.lowerImmAs(cg, imm, param_tys[i]),
            else => values.coerce(cg.builder, cg.ctx, resolveVal(cg, fncg, arg, .unknown), param_tys[i]),
        } else resolveVal(cg, fncg, arg, .unknown);
        args[i] = v;
    }

    const result = llvm.LLVMBuildCall2(cg.builder, fn_ty, lv, args.ptr, @intCast(args.len), "");
    return if (ret_ty == .void) null else result;
}

// ── Field access ────────────────────────────────────────────────────────────
//
// Strategy:
//   - Slice fields (.ptr / .len): extractvalue from the { ptr, usize } struct.
//   - Named-struct fields: extractvalue from the struct value.
//   - Pointer-to-struct: structGEP + load (or just GEP for field_addr).
//
// When `want_addr` is true we return a pointer to the field instead of loading.

fn lowerField(
    cg: *ModuleCg,
    fncg: anytype,
    f: ir.FieldInstr,
    result_ty: ir.IrType,
    want_addr: bool,
) ?llvm.LLVMValueRef {
    const base_ir_ty = fncg.irTypeOf(f.base) orelse return null;

    switch (base_ir_ty) {
        .slice => {
            // Slice is a value type { ptr, usize }.  Use extractvalue.
            const idx: u32 = if (std.mem.eql(u8, f.name, "ptr")) 0 else 1;
            const base_val = resolveVal(cg, fncg, f.base, base_ir_ty);
            if (want_addr) {
                // Spill to a temp alloca so we can take an address.
                const tmp = llvm.LLVMBuildAlloca(cg.builder, cg.getSliceType(), "");
                _ = llvm.LLVMBuildStore(cg.builder, base_val, tmp);
                return llvm.LLVMBuildStructGEP2(cg.builder, cg.getSliceType(), tmp, idx, "");
            }
            return llvm.LLVMBuildExtractValue(cg.builder, base_val, idx, "");
        },

        .struct_type => |name| {
            // Struct value (e.g. a local of named type loaded from alloca).
            const idx = cg.fieldIndex(name, f.name) orelse return null;
            const struct_lty = cg.struct_types.get(name) orelse return null;
            if (want_addr) {
                // Need a pointer to the struct.
                const base_ptr = localOrAllocaPtr(cg, fncg, f.base, struct_lty) orelse return null;
                return llvm.LLVMBuildStructGEP2(cg.builder, struct_lty, base_ptr, idx, "");
            }
            const base_val = resolveVal(cg, fncg, f.base, base_ir_ty);
            return llvm.LLVMBuildExtractValue(cg.builder, base_val, idx, "");
        },

        .ptr => {
            // Pointer to struct — GEP.  Requires pointed-to type tracking (TODO).
            _ = result_ty;
            return null;
        },

        else => return null,
    }
}

/// Returns the alloca pointer for a local, or a fresh alloca for params/regs.
fn localOrAllocaPtr(cg: *ModuleCg, fncg: anytype, val: ir.Value, lty: llvm.LLVMTypeRef) ?llvm.LLVMValueRef {
    return switch (val) {
        .local => |name| fncg.locals.get(name),
        else => blk: {
            const v = resolveVal(cg, fncg, val, .unknown);
            const tmp = llvm.LLVMBuildAlloca(cg.builder, lty, "");
            _ = llvm.LLVMBuildStore(cg.builder, v, tmp);
            break :blk tmp;
        },
    };
}

// ── Builtin instructions ────────────────────────────────────────────────────

fn lowerBuiltin(
    cg: *ModuleCg,
    fncg: anytype,
    b: ir.BuiltinInstr,
    ty: ir.IrType,
) ?llvm.LLVMValueRef {
    const bl = cg.builder;

    // truncate_to(DestType, value) — integer truncation / extension.
    if (std.mem.eql(u8, b.name, "truncate_to")) {
        if (b.args.len < 2) return null;
        const dest_lty = types.lower(cg, ty);
        const val = resolveVal(cg, fncg, b.args[1], .unknown);
        // Use IntCast which truncates or sign-extends as needed.
        return llvm.LLVMBuildIntCast2(bl, val, dest_lty, 1, "");
    }

    // ptr_from_int(PtrType, addr) — integer → pointer.
    if (std.mem.eql(u8, b.name, "ptr_from_int")) {
        if (b.args.len < 2) return null;
        const addr = resolveVal(cg, fncg, b.args[1], .usize);
        return llvm.LLVMBuildIntToPtr(bl, addr, llvm.LLVMPointerTypeInContext(cg.ctx, 0), "");
    }

    // volatile_store(ptr, value) — store with volatile flag.
    if (std.mem.eql(u8, b.name, "volatile_store")) {
        if (b.args.len < 2) return null;
        const ptr = resolveVal(cg, fncg, b.args[0], .{ .ptr = undefined });
        const val = resolveVal(cg, fncg, b.args[1], .unknown);
        const st = llvm.LLVMBuildStore(bl, val, ptr);
        llvm.LLVMSetVolatile(st, 1);
        return null;
    }

    // sizeof(Type) — compile-time size constant in bytes.
    if (std.mem.eql(u8, b.name, "sizeof")) {
        const size_ty = types.lower(cg, ty); // the type we're sizing
        return llvm.LLVMSizeOf(size_ty);
    }

    // unaligned_read(Type, ptr) — load with alignment 1.
    if (std.mem.eql(u8, b.name, "unaligned_read")) {
        if (b.args.len < 2) return null;
        const ptr = resolveVal(cg, fncg, b.args[1], .{ .ptr = undefined });
        const lty = types.lower(cg, ty);
        const ld = llvm.LLVMBuildLoad2(bl, lty, ptr, "");
        llvm.LLVMSetAlignment(ld, 1);
        return ld;
    }

    // atomic_load(ptr, ordering) — atomic load.
    if (std.mem.eql(u8, b.name, "atomic_load")) {
        if (b.args.len < 1) return null;
        const ptr = resolveVal(cg, fncg, b.args[0], .{ .ptr = undefined });
        const lty = types.lower(cg, ty);
        const ld = llvm.LLVMBuildLoad2(bl, lty, ptr, "");
        llvm.LLVMSetOrdering(ld, llvm.LLVMAtomicOrderingAcquire);
        llvm.LLVMSetAlignment(ld, 4);
        return ld;
    }

    // asm(volatile, "instruction", ...) — inline assembly.
    if (std.mem.eql(u8, b.name, "asm")) {
        if (b.args.len < 2) return null;
        // args[1] is the instruction string literal.
        const insn_val = b.args[1];
        const insn_str: []const u8 = switch (insn_val) {
            .imm => |imm| switch (imm) {
                .text => |s| s,
                else => return null,
            },
            else => return null,
        };
        const insn_z = cg.allocator.dupeZ(u8, insn_str) catch return null;
        defer cg.allocator.free(insn_z);
        const void_ty = llvm.LLVMVoidTypeInContext(cg.ctx);
        const fn_ty = llvm.LLVMFunctionType(void_ty, null, 0, 0);
        const asm_val = llvm.LLVMGetInlineAsm(fn_ty, insn_z, insn_z.len, "", 0, 1, 0, llvm.LLVMInlineAsmDialectATT, 0);
        _ = llvm.LLVMBuildCall2(bl, fn_ty, asm_val, null, 0, "");
        return null;
    }

    // compound_literal([args...]) — array or struct aggregate constant.
    if (std.mem.eql(u8, b.name, "compound_literal")) {
        return lowerCompoundLiteral(cg, fncg, b.args, ty);
    }

    // slice([base]) — take the base ptr and zero len; used for [:] expressions.
    if (std.mem.eql(u8, b.name, "slice")) {
        if (b.args.len < 1) return null;
        const zero = llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), 0, 0);
        var len = zero;
        var base_ptr = switch (b.args[0]) {
            .local => |name| blk: {
                const alloca = fncg.locals.get(name) orelse break :blk resolveVal(cg, fncg, b.args[0], .{ .ptr = undefined });
                if (fncg.local_ir_types.get(name)) |local_ty| switch (local_ty) {
                    .array => |arr| {
                        len = llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), arr.len, 0);
                        var indices = [_]llvm.LLVMValueRef{ zero, zero };
                        break :blk llvm.LLVMBuildGEP2(cg.builder, types.lower(cg, local_ty), alloca, &indices, 2, "");
                    },
                    else => {},
                };
                break :blk alloca;
            },
            else => resolveVal(cg, fncg, b.args[0], .{ .ptr = undefined }),
        };
        if (fncg.irTypeOf(b.args[0])) |arg_ty| switch (arg_ty) {
            .ptr => |inner| switch (inner.*) {
                .array => |arr| {
                    len = llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), arr.len, 0);
                    var indices = [_]llvm.LLVMValueRef{ zero, zero };
                    base_ptr = llvm.LLVMBuildGEP2(cg.builder, types.lower(cg, inner.*), base_ptr, &indices, 2, "");
                },
                else => {},
            },
            else => {},
        };
        var result = llvm.LLVMGetUndef(cg.getSliceType());
        result = llvm.LLVMBuildInsertValue(cg.builder, result, base_ptr, 0, "");
        result = llvm.LLVMBuildInsertValue(cg.builder, result, len, 1, "");
        return result;
    }

    return null; // unknown builtin
}

// ── Compound literals ───────────────────────────────────────────────────────

fn lowerCompoundLiteral(
    cg: *ModuleCg,
    fncg: anytype,
    args: []const ir.Value,
    ty: ir.IrType,
) ?llvm.LLVMValueRef {
    switch (ty) {
        .array => |arr| {
            const elem_lty = types.lower(cg, arr.elem.*);
            const vals = cg.allocator.alloc(llvm.LLVMValueRef, args.len) catch return null;
            defer cg.allocator.free(vals);
            for (args, 0..) |arg, i| vals[i] = resolveVal(cg, fncg, arg, arr.elem.*);
            // Try to build a constant array; fall back to insertvalue chain.
            const const_arr = llvm.LLVMConstArray2(elem_lty, vals.ptr, @intCast(vals.len));
            if (const_arr != null) return const_arr;
            // Non-constant: build via insertvalue.
            const arr_ty = types.lower(cg, ty);
            var agg = llvm.LLVMGetUndef(arr_ty);
            for (vals, 0..) |v, i| {
                const idx: u32 = @intCast(i);
                agg = llvm.LLVMBuildInsertValue(cg.builder, agg, v, idx, "");
            }
            return agg;
        },
        .struct_type => |name| {
            const struct_lty = cg.struct_types.get(name) orelse return null;
            const fields = cg.struct_fields.get(name) orelse return null;
            var agg = llvm.LLVMGetUndef(struct_lty);
            const n = @min(args.len, fields.len);
            for (0..n) |i| {
                const v = resolveVal(cg, fncg, args[i], fields[i].ir_ty);
                agg = llvm.LLVMBuildInsertValue(cg.builder, agg, v, @intCast(i), "");
            }
            return agg;
        },
        else => return null,
    }
}

// ── Struct literals (IrInstrKind.struct_lit) ────────────────────────────────

fn lowerStructLit(
    cg: *ModuleCg,
    fncg: anytype,
    sl: ir.StructLitInstr,
    ty: ir.IrType,
) ?llvm.LLVMValueRef {
    const struct_lty = cg.struct_types.get(sl.ty_name) orelse return null;
    const fields = cg.struct_fields.get(sl.ty_name) orelse return null;
    _ = ty;
    var agg = llvm.LLVMGetUndef(struct_lty);
    for (sl.fields) |fv| {
        // Find the index of this field name.
        var idx: ?u32 = null;
        for (fields, 0..) |fd, i| {
            if (std.mem.eql(u8, fd.name, fv.name)) {
                idx = @intCast(i);
                break;
            }
        }
        const i = idx orelse continue;
        const v = resolveVal(cg, fncg, fv.value, fields[i].ir_ty);
        agg = llvm.LLVMBuildInsertValue(cg.builder, agg, v, i, "");
    }
    return agg;
}
