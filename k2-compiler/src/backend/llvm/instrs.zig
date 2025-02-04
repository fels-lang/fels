/// Instruction lowering.
const std = @import("std");
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const types = @import("types.zig");
const values = @import("values.zig");
const vars_mod = @import("variants.zig");
const ModuleCg = @import("context.zig").ModuleCg;

pub fn lower(cg: *ModuleCg, fncg: anytype, instr: ir.Instr) void {
    const result: ?llvm.LLVMValueRef = switch (instr.kind) {
        .const_value => |imm| values.lowerImm(cg, imm, instr.ty),

        .unary => |u| lowerUnary(cg, fncg, u, instr.ty, instr.location),
        .binary => |b| lowerBinary(cg, fncg, b, instr.ty, instr.location),

        .call => |call| lowerCall(cg, fncg, call, instr.ty),

        .builtin => |b| lowerBuiltin(cg, fncg, b, instr.ty),

        .alloc => |al| blk: {
            break :blk lowerZoneAlloc(cg, fncg, al.zone, llvm.LLVMSizeOf(types.lower(cg, al.ty)), instr.location);
        },

        .alloc_slice => |al| blk: {
            // Allocate a slice struct on the stack, then fill ptr+len.
            const count = resolveVal(cg, fncg, al.count, .usize);
            // Heap-allocate the element array via alloca(elem*count) — simplified.
            const elem_ty = types.lower(cg, al.elem_ty);
            const i64_ty = llvm.LLVMInt64TypeInContext(cg.ctx);
            const elem_size = values.coerce(cg.builder, cg.ctx, llvm.LLVMSizeOf(elem_ty), i64_ty);
            const count64 = values.coerce(cg.builder, cg.ctx, count, i64_ty);
            const size = if (cg.opt_level == 0)
                lowerOverflowingBinary(cg, fncg.llvm_fn, elem_size, count64, "llvm.umul.with.overflow", instr.location)
            else
                llvm.LLVMBuildMul(cg.builder, elem_size, count64, "");
            const data_ptr = lowerZoneAlloc(cg, fncg, al.zone, size, instr.location) orelse break :blk null;
            var slice = llvm.LLVMGetUndef(cg.getSliceType());
            slice = llvm.LLVMBuildInsertValue(cg.builder, slice, data_ptr, 0, "");
            break :blk llvm.LLVMBuildInsertValue(cg.builder, slice, count64, 1, "");
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

        .field => |f| lowerField(cg, fncg, f, instr.ty, false, instr.location),
        .field_addr => |f| lowerField(cg, fncg, f, instr.ty, true, instr.location),

        .index => |ix| blk: {
            // Debug: bounds check before loading.
            if (cg.opt_level == 0) emitBoundsCheck(cg, fncg, ix, instr.location);
            const elem_ty = types.lower(cg, instr.ty);
            const gep = lowerIndexAddress(cg, fncg, ix, instr.ty, instr.location) orelse break :blk null;
            break :blk llvm.LLVMBuildLoad2(cg.builder, elem_ty, gep, "");
        },
        .index_addr => |ix| blk: {
            // Debug: bounds check before taking address.
            if (cg.opt_level == 0) emitBoundsCheck(cg, fncg, ix, instr.location);
            break :blk lowerIndexAddress(cg, fncg, ix, pointerChild(instr.ty) orelse .unknown, instr.location);
        },

        .slice_expr => |slice| lowerSliceExpr(cg, fncg, slice),

        .optional_is_some => |value| blk: {
            const opt_ty = fncg.irTypeOf(value) orelse instr.ty;
            const opt = resolveVal(cg, fncg, value, opt_ty);
            // Nullable pointer optimisation: ?*T is just a raw ptr; non-null = some.
            if (opt_ty == .optional) {
                if (opt_ty.optional.* == .ptr) {
                    const null_ptr = llvm.LLVMConstNull(llvm.LLVMPointerTypeInContext(cg.ctx, 0));
                    break :blk llvm.LLVMBuildICmp(cg.builder, llvm.LLVMIntNE, opt, null_ptr, "");
                }
            }
            break :blk values.extractAggregateField(cg, opt, 0, "optional discriminant");
        },

        .optional_payload => |value| blk: {
            const opt_ty = fncg.irTypeOf(value) orelse break :blk null;
            const payload_ty = switch (opt_ty) {
                .optional => |inner| inner.*,
                else => break :blk null,
            };
            const opt = resolveVal(cg, fncg, value, opt_ty);
            // Nullable pointer optimisation: the pointer IS the payload.
            if (payload_ty == .ptr) break :blk opt;
            break :blk values.extractAggregateField(cg, opt, 1, "optional payload");
        },

        .cast => |cs| blk: {
            const src_ty = fncg.irTypeOf(cs.value) orelse .unknown;
            const val = resolveVal(cg, fncg, cs.value, src_ty);
            const dest = types.lower(cg, instr.ty);
            break :blk values.coerceTyped(cg.builder, cg.ctx, val, src_ty, instr.ty, dest);
        },

        .struct_lit => |sl| lowerStructLit(cg, fncg, sl, instr.ty),

        .inline_asm => |ai| lowerInlineAsm(cg, fncg, ai, instr.ty),

        .variant_lit => |vl| vars_mod.buildVariantLit(
            cg,
            vl.type_name,
            vl.variant,
            if (vl.payload) |pv| resolveVal(cg, fncg, pv, .unknown) else null,
        ),
        .variant_is => |vi| vars_mod.buildVariantIs(
            cg,
            resolveVal(cg, fncg, vi.value, .unknown),
            vi.type_name,
            vi.variant,
        ),
        .variant_payload => |vp| vars_mod.buildVariantPayload(
            cg,
            resolveVal(cg, fncg, vp.value, .unknown),
            vp.type_name,
            vp.variant,
            types.lower(cg, instr.ty),
        ),

        .call_indirect => |ci| lowerCallIndirect(cg, fncg, ci, instr.ty),
        .interface_make => |make| lowerInterfaceMake(cg, fncg, make),
        .interface_data => |value| lowerInterfaceData(cg, fncg, value),
        .interface_method => |method| lowerInterfaceMethod(cg, fncg, method),

        // ── Error / fallible ─────────────────────────────────────────────────

        // try_is_ok: extract discriminant field (1) and compare to zero.
        .try_is_ok => |val| blk: {
            const fallible = resolveVal(cg, fncg, val, .unknown);
            const disc = values.extractAggregateField(cg, fallible, 1, "fallible discriminant") orelse break :blk null;
            const zero = llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(cg.ctx), 0, 0);
            break :blk llvm.LLVMBuildICmp(cg.builder, llvm.LLVMIntEQ, disc, zero, "");
        },

        // try_ok: extract ok-value field (0).
        .try_ok => |val| blk: {
            const fallible = resolveVal(cg, fncg, val, .unknown);
            break :blk values.extractAggregateField(cg, fallible, 0, "fallible ok value");
        },

        // try_err: extract discriminant field (1).
        .try_err => |val| blk: {
            const fallible = resolveVal(cg, fncg, val, .unknown);
            break :blk values.extractAggregateField(cg, fallible, 1, "fallible error discriminant");
        },

        // try_payload: the error payload shares the value slot (field 0).
        .try_payload => |val| blk: {
            const fallible = resolveVal(cg, fncg, val, .unknown);
            break :blk values.extractAggregateField(cg, fallible, 0, "fallible error payload");
        },

        // Zone ops — not yet implemented.
        .zone_push => |zone| blk: {
            const head = fncg.zones.get(zone.name) orelse break :blk null;
            _ = llvm.LLVMBuildStore(cg.builder, llvm.LLVMConstNull(llvm.LLVMPointerTypeInContext(cg.ctx, 0)), head);
            break :blk null;
        },
        .zone_pop => |zone| blk: {
            lowerZonePop(cg, fncg, zone);
            break :blk null;
        },
        // Arena.free is intentionally deferred until the arena is popped.
        .zone_free => null,
        .iter_init, .iter_has_next, .iter_next, .at, .raw_pointer => null,
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

fn lowerInterfaceMake(cg: *ModuleCg, fncg: anytype, make: ir.InterfaceMakeInstr) ?llvm.LLVMValueRef {
    const data = resolveVal(cg, fncg, make.data, .{ .ptr = undefined });
    const vtable = cg.global_decls.get(make.vtable) orelse return null;
    var result = llvm.LLVMGetUndef(cg.getInterfaceType());
    result = llvm.LLVMBuildInsertValue(cg.builder, result, data, 0, "");
    return llvm.LLVMBuildInsertValue(cg.builder, result, vtable, 1, "");
}

fn lowerInterfaceData(cg: *ModuleCg, fncg: anytype, value: ir.Value) ?llvm.LLVMValueRef {
    const interface = resolveVal(cg, fncg, value, .{ .interface_value = "" });
    return values.extractAggregateField(cg, interface, 0, "interface data pointer");
}

fn lowerInterfaceMethod(cg: *ModuleCg, fncg: anytype, method: ir.InterfaceMethodInstr) ?llvm.LLVMValueRef {
    const interface = resolveVal(cg, fncg, method.value, .{ .interface_value = "" });
    const vtable = values.extractAggregateField(cg, interface, 1, "interface vtable pointer") orelse return null;
    const ptr_ty = llvm.LLVMPointerTypeInContext(cg.ctx, 0);
    const array_ty = llvm.LLVMArrayType2(ptr_ty, method.index + 1);
    const zero = llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(cg.ctx), 0, 0);
    const index = llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(cg.ctx), method.index, 0);
    var indices = [_]llvm.LLVMValueRef{ zero, index };
    const slot = llvm.LLVMBuildGEP2(cg.builder, array_ty, vtable, &indices, 2, "");
    return llvm.LLVMBuildLoad2(cg.builder, ptr_ty, slot, "");
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
    location: ir.SourceLocation,
) ?llvm.LLVMValueRef {
    const idx = resolveVal(cg, fncg, ix.index, .usize);
    const elem_lty = types.lower(cg, elem_ir_ty);

    const base_ir_ty = fncg.irTypeOf(ix.base);
    if (base_ir_ty) |base_ty| switch (base_ty) {
        .slice => {
            const base_val = resolveVal(cg, fncg, ix.base, base_ty);
            const ptr = values.extractAggregateField(cg, base_val, 0, "slice index base pointer") orelse return null;
            var indices = [_]llvm.LLVMValueRef{idx};
            return llvm.LLVMBuildGEP2(cg.builder, elem_lty, ptr, &indices, 1, "");
        },
        .ptr => |inner| switch (inner.*) {
            .array => |arr| {
                const base_ptr = resolveVal(cg, fncg, ix.base, base_ty);
                if (cg.opt_level == 0) emitNullCheck(cg, fncg.llvm_fn, base_ptr, location);
                const zero = llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), 0, 0);
                var indices = [_]llvm.LLVMValueRef{ zero, idx };
                return llvm.LLVMBuildGEP2(cg.builder, types.lower(cg, .{ .array = arr }), base_ptr, &indices, 2, "");
            },
            else => {
                const base_ptr = resolveVal(cg, fncg, ix.base, base_ty);
                if (cg.opt_level == 0) emitNullCheck(cg, fncg.llvm_fn, base_ptr, location);
                var indices = [_]llvm.LLVMValueRef{idx};
                return llvm.LLVMBuildGEP2(cg.builder, elem_lty, base_ptr, &indices, 1, "");
            },
        },
        .array => |arr| {
            const array_lty = types.lower(cg, .{ .array = arr });
            const base_ptr = localOrAllocaPtr(cg, fncg, ix.base, array_lty) orelse return null;
            const zero = llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), 0, 0);
            var indices = [_]llvm.LLVMValueRef{ zero, idx };
            return llvm.LLVMBuildGEP2(cg.builder, array_lty, base_ptr, &indices, 2, "");
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

fn lowerUnary(cg: *ModuleCg, fncg: anytype, u: ir.UnaryInstr, ty: ir.IrType, location: ir.SourceLocation) ?llvm.LLVMValueRef {
    const v = resolveVal(cg, fncg, u.value, ty);
    const bl = cg.builder;
    return switch (u.op) {
        .neg => if (cg.opt_level == 0 and !isFloat(ty))
            lowerOverflowingBinary(cg, fncg.llvm_fn, llvm.LLVMConstNull(llvm.LLVMTypeOf(v)), v, "llvm.ssub.with.overflow", location)
        else
            llvm.LLVMBuildNeg(bl, v, ""),
        .not => llvm.LLVMBuildNot(bl, v, ""),
        .bit_not => llvm.LLVMBuildNot(bl, v, ""),
        .deref => blk: {
            // Debug: null-pointer dereference check.
            if (cg.opt_level == 0) emitNullCheck(cg, fncg.llvm_fn, v, location);
            break :blk llvm.LLVMBuildLoad2(cg.builder, types.lower(cg, ty), v, "");
        },
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

fn lowerBinary(cg: *ModuleCg, fncg: anytype, b: ir.BinaryInstr, ty: ir.IrType, location: ir.SourceLocation) ?llvm.LLVMValueRef {
    const lhs_hint = fncg.irTypeOf(b.lhs) orelse fncg.irTypeOf(b.rhs) orelse ty;
    const rhs_hint = fncg.irTypeOf(b.rhs) orelse lhs_hint;
    const lhs = resolveVal(cg, fncg, b.lhs, lhs_hint);
    var rhs = resolveVal(cg, fncg, b.rhs, rhs_hint);
    rhs = values.coerce(cg.builder, cg.ctx, rhs, llvm.LLVMTypeOf(lhs));
    const bl = cg.builder;
    const is_float = isFloat(lhs_hint);
    const is_unsigned = isUnsigned(lhs_hint);
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
            break :blk if (is_float)
                llvm.LLVMBuildFAdd(bl, lhs, rhs, "")
            else if (cg.opt_level == 0)
                lowerOverflowingBinary(cg, fncg.llvm_fn, lhs, rhs, if (is_unsigned) "llvm.uadd.with.overflow" else "llvm.sadd.with.overflow", location)
            else
                llvm.LLVMBuildAdd(bl, lhs, rhs, "");
        },
        .sub => if (is_float)
            llvm.LLVMBuildFSub(bl, lhs, rhs, "")
        else if (cg.opt_level == 0)
            lowerOverflowingBinary(cg, fncg.llvm_fn, lhs, rhs, if (is_unsigned) "llvm.usub.with.overflow" else "llvm.ssub.with.overflow", location)
        else
            llvm.LLVMBuildSub(bl, lhs, rhs, ""),
        .mul => if (is_float)
            llvm.LLVMBuildFMul(bl, lhs, rhs, "")
        else if (cg.opt_level == 0)
            lowerOverflowingBinary(cg, fncg.llvm_fn, lhs, rhs, if (is_unsigned) "llvm.umul.with.overflow" else "llvm.smul.with.overflow", location)
        else
            llvm.LLVMBuildMul(bl, lhs, rhs, ""),
        .div => if (is_float)
            llvm.LLVMBuildFDiv(bl, lhs, rhs, "")
        else blk: {
            // Debug: check for division by zero.
            if (cg.opt_level == 0) {
                const zero = llvm.LLVMConstInt(llvm.LLVMTypeOf(rhs), 0, 0);
                const is_zero = llvm.LLVMBuildICmp(bl, llvm.LLVMIntEQ, rhs, zero, "");
                emitRuntimeCheck(cg, fncg.llvm_fn, is_zero, "division by zero", location);
                if (!is_unsigned) emitSignedDivisionOverflowCheck(cg, fncg.llvm_fn, lhs, rhs, location);
            }
            break :blk if (is_unsigned)
                llvm.LLVMBuildUDiv(cg.builder, lhs, rhs, "")
            else
                llvm.LLVMBuildSDiv(cg.builder, lhs, rhs, "");
        },
        .rem => if (is_float)
            llvm.LLVMBuildFRem(bl, lhs, rhs, "")
        else blk: {
            // Debug: check for division by zero (modulo).
            if (cg.opt_level == 0) {
                const zero = llvm.LLVMConstInt(llvm.LLVMTypeOf(rhs), 0, 0);
                const is_zero = llvm.LLVMBuildICmp(bl, llvm.LLVMIntEQ, rhs, zero, "");
                emitRuntimeCheck(cg, fncg.llvm_fn, is_zero, "remainder by zero", location);
                if (!is_unsigned) emitSignedDivisionOverflowCheck(cg, fncg.llvm_fn, lhs, rhs, location);
            }
            break :blk if (is_unsigned)
                llvm.LLVMBuildURem(cg.builder, lhs, rhs, "")
            else
                llvm.LLVMBuildSRem(cg.builder, lhs, rhs, "");
        },
        .shl => blk: {
            // Debug: check shift amount < bit width.
            if (cg.opt_level == 0) {
                const rhs_ty = llvm.LLVMTypeOf(rhs);
                const width = llvm.LLVMGetIntTypeWidth(llvm.LLVMTypeOf(lhs));
                const limit = llvm.LLVMConstInt(rhs_ty, width, 0);
                const over = llvm.LLVMBuildICmp(bl, llvm.LLVMIntUGE, rhs, limit, "");
                emitRuntimeCheck(cg, fncg.llvm_fn, over, "shift amount exceeds bit width", location);
            }
            break :blk llvm.LLVMBuildShl(cg.builder, lhs, rhs, "");
        },
        .shr => blk: {
            // Debug: check shift amount < bit width.
            if (cg.opt_level == 0) {
                const rhs_ty = llvm.LLVMTypeOf(rhs);
                const width = llvm.LLVMGetIntTypeWidth(llvm.LLVMTypeOf(lhs));
                const limit = llvm.LLVMConstInt(rhs_ty, width, 0);
                const over = llvm.LLVMBuildICmp(bl, llvm.LLVMIntUGE, rhs, limit, "");
                emitRuntimeCheck(cg, fncg.llvm_fn, over, "shift amount exceeds bit width", location);
            }
            break :blk if (is_unsigned)
                llvm.LLVMBuildLShr(cg.builder, lhs, rhs, "")
            else
                llvm.LLVMBuildAShr(cg.builder, lhs, rhs, "");
        },
        .bit_and => llvm.LLVMBuildAnd(bl, lhs, rhs, ""),
        .bit_or => llvm.LLVMBuildOr(bl, lhs, rhs, ""),
        .bit_xor => llvm.LLVMBuildXor(bl, lhs, rhs, ""),
        .and_op => llvm.LLVMBuildAnd(bl, lhs, rhs, ""),
        .or_op => llvm.LLVMBuildOr(bl, lhs, rhs, ""),
        .eq => if (is_float) llvm.LLVMBuildFCmp(bl, llvm.LLVMRealOEQ, lhs, rhs, "") else llvm.LLVMBuildICmp(bl, llvm.LLVMIntEQ, lhs, rhs, ""),
        .ne => if (is_float) llvm.LLVMBuildFCmp(bl, llvm.LLVMRealUNE, lhs, rhs, "") else llvm.LLVMBuildICmp(bl, llvm.LLVMIntNE, lhs, rhs, ""),
        .lt => if (is_float)
            llvm.LLVMBuildFCmp(bl, llvm.LLVMRealOLT, lhs, rhs, "")
        else
            llvm.LLVMBuildICmp(bl, if (is_unsigned) llvm.LLVMIntULT else llvm.LLVMIntSLT, lhs, rhs, ""),
        .le => if (is_float)
            llvm.LLVMBuildFCmp(bl, llvm.LLVMRealOLE, lhs, rhs, "")
        else
            llvm.LLVMBuildICmp(bl, if (is_unsigned) llvm.LLVMIntULE else llvm.LLVMIntSLE, lhs, rhs, ""),
        .gt => if (is_float)
            llvm.LLVMBuildFCmp(bl, llvm.LLVMRealOGT, lhs, rhs, "")
        else
            llvm.LLVMBuildICmp(bl, if (is_unsigned) llvm.LLVMIntUGT else llvm.LLVMIntSGT, lhs, rhs, ""),
        .ge => if (is_float)
            llvm.LLVMBuildFCmp(bl, llvm.LLVMRealOGE, lhs, rhs, "")
        else
            llvm.LLVMBuildICmp(bl, if (is_unsigned) llvm.LLVMIntUGE else llvm.LLVMIntSGE, lhs, rhs, ""),
        else => null,
    };
}

fn isFloat(ty: ir.IrType) bool {
    return ty == .f32 or ty == .f64;
}

fn isUnsigned(ty: ir.IrType) bool {
    return switch (ty) {
        .u, .byte, .usize, .addr => true,
        else => false,
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
    cg: *ModuleCg,
    fncg: anytype,
    ci: ir.CallIndirectInstr,
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
    const fn_ty = llvm.LLVMFunctionType(ret_lty, param_tys.ptr, @intCast(ci.args.len), 0);

    const result = llvm.LLVMBuildCall2(
        cg.builder,
        fn_ty,
        callee_ptr,
        resolved_args.ptr,
        @intCast(ci.args.len),
        "",
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
    location: ir.SourceLocation,
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
            return values.extractAggregateField(cg, base_val, idx, "slice field access");
        },

        .fallible => {
            const idx: u32 = if (std.mem.eql(u8, f.name, "ok")) 0 else 1;
            const lty = types.lower(cg, base_ir_ty);
            const base_val = resolveVal(cg, fncg, f.base, base_ir_ty);
            if (want_addr) {
                const tmp = llvm.LLVMBuildAlloca(cg.builder, lty, "");
                _ = llvm.LLVMBuildStore(cg.builder, base_val, tmp);
                return llvm.LLVMBuildStructGEP2(cg.builder, lty, tmp, idx, "");
            }
            return values.extractAggregateField(cg, base_val, idx, "fallible field access");
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
            return values.extractAggregateField(cg, base_val, idx, "struct field access");
        },

        .ptr => |inner| {
            const name = switch (inner.*) {
                .struct_type => |name| name,
                else => return null,
            };
            const idx = cg.fieldIndex(name, f.name) orelse return null;
            const struct_lty = cg.struct_types.get(name) orelse return null;
            const base_ptr = resolveVal(cg, fncg, f.base, base_ir_ty);
            if (cg.opt_level == 0) emitNullCheck(cg, fncg.llvm_fn, base_ptr, location);
            const field_ptr = llvm.LLVMBuildStructGEP2(cg.builder, struct_lty, base_ptr, idx, "");
            if (want_addr) return field_ptr;
            return llvm.LLVMBuildLoad2(cg.builder, types.lower(cg, result_ty), field_ptr, "");
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

    if (std.mem.eql(u8, b.name, "optional_some")) {
        if (b.args.len != 1 or ty != .optional) return null;
        const payload_ty = ty.optional.*;
        const payload = resolveVal(cg, fncg, b.args[0], payload_ty);
        return values.optionalSome(cg, payload, payload_ty);
    }

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

    // slice_from_raw_parts(Elem, ptr, len) -> []Elem — assemble a slice value
    // {ptr, len} from a raw pointer and length. Slices are type-erased to a
    // single {ptr, i64} struct in this backend, so no element type is needed
    // here — `ptr` and `len` are inserted directly. (See `.alloc_slice`.)
    if (std.mem.eql(u8, b.name, "slice_from_raw_parts")) {
        if (b.args.len < 3) return null;
        const i64_ty = llvm.LLVMInt64TypeInContext(cg.ctx);
        const ptr = resolveVal(cg, fncg, b.args[1], .{ .ptr = undefined });
        const len = values.coerce(bl, cg.ctx, resolveVal(cg, fncg, b.args[2], .usize), i64_ty);
        var slice = llvm.LLVMGetUndef(cg.getSliceType());
        slice = llvm.LLVMBuildInsertValue(bl, slice, ptr, 0, "");
        return llvm.LLVMBuildInsertValue(bl, slice, len, 1, "");
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
        const size_ty = types.lower(cg, b.type_arg orelse ty); // the actual type we're sizing
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

    // atomic_store(ptr, value, ordering) — atomic store with release ordering.
    if (std.mem.eql(u8, b.name, "atomic_store")) {
        if (b.args.len < 2) return null;
        const ptr = resolveVal(cg, fncg, b.args[0], .{ .ptr = undefined });
        const val = resolveVal(cg, fncg, b.args[1], .unknown);
        const st = llvm.LLVMBuildStore(bl, val, ptr);
        llvm.LLVMSetOrdering(st, llvm.LLVMAtomicOrderingRelease);
        llvm.LLVMSetAlignment(st, 4);
        return null;
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

    // ── Error builtins ──────────────────────────────────────────────────────

    // error.<VariantName> — emit the discriminant (i32) for an error variant.
    // The variant name is resolved against the current function's error type.
    if (std.mem.startsWith(u8, b.name, "error.")) {
        const variant_name = b.name["error.".len..];
        const error_type_name = errorTypeName(fncg.func.error_ty orelse .unknown);
        const disc = cg.errorDiscriminant(error_type_name, variant_name);
        return llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(cg.ctx), disc, 0);
    }

    // try_context(fallible_value) — propagate error if discriminant != 0.
    // Inserts: if (disc != 0) { return { undef, disc }; }
    // On the success path the builder lands at a fresh continuation BB.
    if (std.mem.eql(u8, b.name, "try_context")) {
        if (b.args.len < 1) return null;
        const fallible = resolveVal(cg, fncg, b.args[0], .unknown);
        const disc = values.extractAggregateField(cg, fallible, 1, "try_context discriminant") orelse return null;
        const zero = llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(cg.ctx), 0, 0);
        const is_err = llvm.LLVMBuildICmp(cg.builder, llvm.LLVMIntNE, disc, zero, "");

        const err_bb = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fncg.llvm_fn, "propagate_err");
        const ok_bb = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fncg.llvm_fn, "try_ok");
        _ = llvm.LLVMBuildCondBr(cg.builder, is_err, err_bb, ok_bb);

        // Error path: re-wrap and return the error discriminant.
        llvm.LLVMPositionBuilderAtEnd(cg.builder, err_bb);
        if (fncg.func.error_ty != null) {
            const ret_lty = types.fallibleReturnType(cg, fncg.func);
            var err_ret = llvm.LLVMGetUndef(ret_lty);
            err_ret = llvm.LLVMBuildInsertValue(cg.builder, err_ret, disc, 1, "");
            _ = llvm.LLVMBuildRet(cg.builder, err_ret);
        } else {
            _ = llvm.LLVMBuildUnreachable(cg.builder);
        }

        // Continue on the ok path.
        llvm.LLVMPositionBuilderAtEnd(cg.builder, ok_bb);
        return fallible; // pass-through for try_ok to extract field 0
    }

    // catch_handler is an IR marker; the handler CFG is emitted by IR lowering.
    if (std.mem.eql(u8, b.name, "catch_handler")) return null;

    // try_context / deferred OK/ERR — ignore for now.
    if (std.mem.eql(u8, b.name, "try_context_ok") or
        std.mem.eql(u8, b.name, "try_context_err")) return null;

    return null; // unknown builtin
}

/// Extract the error type name string from an IrType (error_ty field of IrFunction).
fn errorTypeName(err_ty: ir.IrType) []const u8 {
    return switch (err_ty) {
        .variant_type => |n| n,
        else => "",
    };
}

// ── Runtime safety checks ───────────────────────────────────────────────────

fn lowerZoneAlloc(
    cg: *ModuleCg,
    fncg: anytype,
    zone_name: []const u8,
    requested_size: llvm.LLVMValueRef,
    location: ir.SourceLocation,
) ?llvm.LLVMValueRef {
    const head = fncg.zones.get(zone_name) orelse return null;
    const i32_ty = llvm.LLVMInt32TypeInContext(cg.ctx);
    const i64_ty = llvm.LLVMInt64TypeInContext(cg.ctx);
    const ptr_ty = llvm.LLVMPointerTypeInContext(cg.ctx, 0);
    const size = values.coerce(cg.builder, cg.ctx, requested_size, i64_ty);
    const header_size = llvm.LLVMConstInt(i64_ty, 16, 0);
    const total = if (cg.opt_level == 0)
        lowerOverflowingBinary(cg, fncg.llvm_fn, size, header_size, "llvm.uadd.with.overflow", location)
    else
        llvm.LLVMBuildAdd(cg.builder, size, header_size, "");

    const process_heap = buildHeapCall(cg, .get_process_heap, &.{}, "zone_heap");
    const flags = llvm.LLVMConstInt(i32_ty, 8, 0);
    const raw = buildHeapCall(cg, .alloc, &.{ process_heap, flags, total }, "zone_raw");
    const is_null = llvm.LLVMBuildICmp(cg.builder, llvm.LLVMIntEQ, raw, llvm.LLVMConstNull(ptr_ty), "");
    emitRuntimeCheck(cg, fncg.llvm_fn, is_null, "zone allocation failed", location);

    const old_head = llvm.LLVMBuildLoad2(cg.builder, ptr_ty, head, "");
    _ = llvm.LLVMBuildStore(cg.builder, old_head, raw);
    _ = llvm.LLVMBuildStore(cg.builder, raw, head);
    var indices = [_]llvm.LLVMValueRef{header_size};
    return llvm.LLVMBuildGEP2(cg.builder, llvm.LLVMInt8TypeInContext(cg.ctx), raw, &indices, 1, "zone_data");
}

fn lowerZonePop(cg: *ModuleCg, fncg: anytype, zone_name: []const u8) void {
    const head = fncg.zones.get(zone_name) orelse return;
    const ptr_ty = llvm.LLVMPointerTypeInContext(cg.ctx, 0);
    const i32_ty = llvm.LLVMInt32TypeInContext(cg.ctx);
    const cond_bb = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fncg.llvm_fn, "zone_pop_cond");
    const free_bb = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fncg.llvm_fn, "zone_pop_free");
    const done_bb = llvm.LLVMAppendBasicBlockInContext(cg.ctx, fncg.llvm_fn, "zone_pop_done");
    _ = llvm.LLVMBuildBr(cg.builder, cond_bb);

    llvm.LLVMPositionBuilderAtEnd(cg.builder, cond_bb);
    const current = llvm.LLVMBuildLoad2(cg.builder, ptr_ty, head, "zone_current");
    const is_null = llvm.LLVMBuildICmp(cg.builder, llvm.LLVMIntEQ, current, llvm.LLVMConstNull(ptr_ty), "");
    _ = llvm.LLVMBuildCondBr(cg.builder, is_null, done_bb, free_bb);

    llvm.LLVMPositionBuilderAtEnd(cg.builder, free_bb);
    const next = llvm.LLVMBuildLoad2(cg.builder, ptr_ty, current, "zone_next");
    const process_heap = buildHeapCall(cg, .get_process_heap, &.{}, "zone_heap");
    _ = buildHeapCall(cg, .free, &.{ process_heap, llvm.LLVMConstInt(i32_ty, 0, 0), current }, "");
    _ = llvm.LLVMBuildStore(cg.builder, next, head);
    _ = llvm.LLVMBuildBr(cg.builder, cond_bb);

    llvm.LLVMPositionBuilderAtEnd(cg.builder, done_bb);
}

const HeapCall = enum { get_process_heap, alloc, free };

fn buildHeapCall(cg: *ModuleCg, call: HeapCall, args: []const llvm.LLVMValueRef, name: [*:0]const u8) llvm.LLVMValueRef {
    const function = getOrDeclareHeapFunction(cg, call);
    const fn_ty = llvm.LLVMGlobalGetValueType(function);
    return llvm.LLVMBuildCall2(cg.builder, fn_ty, function, if (args.len == 0) null else @constCast(args.ptr), @intCast(args.len), name);
}

fn getOrDeclareHeapFunction(cg: *ModuleCg, call: HeapCall) llvm.LLVMValueRef {
    const name = switch (call) {
        .get_process_heap => "GetProcessHeap",
        .alloc => "HeapAlloc",
        .free => "HeapFree",
    };
    if (cg.fn_decls.get(name)) |function| return function;

    const ptr_ty = llvm.LLVMPointerTypeInContext(cg.ctx, 0);
    const i32_ty = llvm.LLVMInt32TypeInContext(cg.ctx);
    const i64_ty = llvm.LLVMInt64TypeInContext(cg.ctx);
    const fn_ty = switch (call) {
        .get_process_heap => llvm.LLVMFunctionType(ptr_ty, null, 0, 0),
        .alloc => blk: {
            var params = [_]llvm.LLVMTypeRef{ ptr_ty, i32_ty, i64_ty };
            break :blk llvm.LLVMFunctionType(ptr_ty, &params, params.len, 0);
        },
        .free => blk: {
            var params = [_]llvm.LLVMTypeRef{ ptr_ty, i32_ty, ptr_ty };
            break :blk llvm.LLVMFunctionType(i32_ty, &params, params.len, 0);
        },
    };
    const function = llvm.LLVMAddFunction(cg.mod, name, fn_ty);
    llvm.LLVMSetLinkage(function, llvm.LLVMExternalLinkage);
    cg.fn_decls.put(name, function) catch {};
    return function;
}

/// Emit a conditional panic if `cond_fails` is true (i1).
/// Splits the current BB into panic_bb and cont_bb; builder lands at cont_bb.
fn emitRuntimeCheck(
    cg: *ModuleCg,
    llvm_fn: llvm.LLVMValueRef,
    cond_fails: llvm.LLVMValueRef,
    msg: []const u8,
    location: ir.SourceLocation,
) void {
    const panic_bb = llvm.LLVMAppendBasicBlockInContext(cg.ctx, llvm_fn, "check_fail");
    const cont_bb = llvm.LLVMAppendBasicBlockInContext(cg.ctx, llvm_fn, "check_ok");
    _ = llvm.LLVMBuildCondBr(cg.builder, cond_fails, panic_bb, cont_bb);

    llvm.LLVMPositionBuilderAtEnd(cg.builder, panic_bb);
    @import("panic.zig").lower(cg, .{
        .message = msg,
        .location = location,
    });

    llvm.LLVMPositionBuilderAtEnd(cg.builder, cont_bb);
}

fn emitNullCheck(
    cg: *ModuleCg,
    llvm_fn: llvm.LLVMValueRef,
    ptr: llvm.LLVMValueRef,
    location: ir.SourceLocation,
) void {
    const null_ptr = llvm.LLVMConstNull(llvm.LLVMPointerTypeInContext(cg.ctx, 0));
    const is_null = llvm.LLVMBuildICmp(cg.builder, llvm.LLVMIntEQ, ptr, null_ptr, "");
    emitRuntimeCheck(cg, llvm_fn, is_null, "null pointer dereference", location);
}

fn lowerOverflowingBinary(
    cg: *ModuleCg,
    llvm_fn: llvm.LLVMValueRef,
    lhs: llvm.LLVMValueRef,
    rhs: llvm.LLVMValueRef,
    intrinsic_name: []const u8,
    location: ir.SourceLocation,
) llvm.LLVMValueRef {
    const operand_ty = llvm.LLVMTypeOf(lhs);
    const intrinsic_id = llvm.LLVMLookupIntrinsicID(intrinsic_name.ptr, intrinsic_name.len);
    var overloaded_tys = [_]llvm.LLVMTypeRef{operand_ty};
    const intrinsic = llvm.LLVMGetIntrinsicDeclaration(cg.mod, intrinsic_id, &overloaded_tys, 1);
    const intrinsic_ty = llvm.LLVMGlobalGetValueType(intrinsic);
    var args = [_]llvm.LLVMValueRef{ lhs, rhs };
    const pair = llvm.LLVMBuildCall2(cg.builder, intrinsic_ty, intrinsic, &args, 2, "overflow_pair");
    const result = llvm.LLVMBuildExtractValue(cg.builder, pair, 0, "overflow_result");
    const overflowed = llvm.LLVMBuildExtractValue(cg.builder, pair, 1, "overflowed");
    emitRuntimeCheck(cg, llvm_fn, overflowed, "integer overflow", location);
    return result;
}

fn emitSignedDivisionOverflowCheck(
    cg: *ModuleCg,
    llvm_fn: llvm.LLVMValueRef,
    lhs: llvm.LLVMValueRef,
    rhs: llvm.LLVMValueRef,
    location: ir.SourceLocation,
) void {
    const int_ty = llvm.LLVMTypeOf(lhs);
    const width = llvm.LLVMGetIntTypeWidth(int_ty);
    if (width == 0 or width > 64) return;
    const min_value = llvm.LLVMConstInt(int_ty, @as(u64, 1) << @intCast(width - 1), 0);
    const negative_one = llvm.LLVMConstAllOnes(int_ty);
    const lhs_is_min = llvm.LLVMBuildICmp(cg.builder, llvm.LLVMIntEQ, lhs, min_value, "");
    const rhs_is_negative_one = llvm.LLVMBuildICmp(cg.builder, llvm.LLVMIntEQ, rhs, negative_one, "");
    const overflowed = llvm.LLVMBuildAnd(cg.builder, lhs_is_min, rhs_is_negative_one, "");
    emitRuntimeCheck(cg, llvm_fn, overflowed, "integer overflow", location);
}

/// Emit a slice/array bounds check before an index operation.
fn emitBoundsCheck(cg: *ModuleCg, fncg: anytype, ix: ir.IndexInstr, location: ir.SourceLocation) void {
    const base_ir_ty = fncg.irTypeOf(ix.base) orelse return;
    const len = switch (base_ir_ty) {
        .slice => blk: {
            const slice = resolveVal(cg, fncg, ix.base, base_ir_ty);
            break :blk values.extractAggregateField(cg, slice, 1, "slice bounds-check length") orelse return;
        },
        .array => |array| llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), array.len, 0),
        .ptr => |inner| switch (inner.*) {
            .array => |array| llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), array.len, 0),
            else => return,
        },
        else => return,
    };
    const idx = resolveVal(cg, fncg, ix.index, .usize);

    // Coerce both to i64 for comparison.
    const i64_ty = llvm.LLVMInt64TypeInContext(cg.ctx);
    const idx64 = values.coerce(cg.builder, cg.ctx, idx, i64_ty);
    const len64 = values.coerce(cg.builder, cg.ctx, len, i64_ty);
    const out_of_bounds = llvm.LLVMBuildICmp(cg.builder, llvm.LLVMIntUGE, idx64, len64, "");
    emitRuntimeCheck(cg, fncg.llvm_fn, out_of_bounds, "index out of bounds", location);
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
