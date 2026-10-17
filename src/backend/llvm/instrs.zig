/// Instruction lowering.
const std = @import("std");
const ctx_mod = @import("context.zig");
const layout_mod = @import("../../layout.zig");
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const types = @import("types.zig");
const values = @import("values.zig");
const vars_mod = @import("variants.zig");
const abi = @import("abi.zig");
const ModuleCg = @import("context.zig").ModuleCg;

pub fn lower(cg: *ModuleCg, fncg: anytype, instr: ir.Instr) void {
    const result: ?llvm.LLVMValueRef = switch (instr.kind) {
        .const_value => |imm| values.lowerImm(cg, imm, instr.ty),

        .unary => |u| lowerUnary(cg, fncg, u, instr.ty, instr.location),
        .binary => |b| lowerBinary(cg, fncg, b, instr.ty, instr.location),

        .call => |call| lowerCall(cg, fncg, call, instr.ty),

        .builtin => |b| lowerBuiltin(cg, fncg, b, instr.ty),

        // `.alloc`/`.alloc_slice` are vestigial: a `zone` handle is now a real
        // `std.heap.Arena`, so `new`/`new_slice` lower as ordinary calls and these
        // ops are never emitted for the LLVM backend. (The comptime VM still has
        // its own cell-based zone ops.) Kept as no-ops to keep the switch total.
        .alloc, .alloc_slice => null,

        .store_local => |sl| blk: {
            const alloca = fncg.locals.get(sl.name) orelse break :blk null;
            abi.storeValue(cg, resolveVal(cg, fncg, sl.value, instr.ty), alloca);
            break :blk null;
        },

        .store => |st| blk: {
            const target = resolveVal(cg, fncg, st.target, .{ .ptr = undefined });
            const val = resolveVal(cg, fncg, st.value, instr.ty);
            if (bitRefOf(fncg, st.target)) |ref| {
                writeBitField(cg, ref, val);
                break :blk null;
            }
            markPackedAccess(llvm.LLVMBuildStore(cg.builder, val, target), target);
            break :blk null;
        },

        .global_store => |gs| blk: {
            const gv = cg.global_decls.get(gs.name) orelse break :blk null;
            abi.storeValue(cg, resolveVal(cg, fncg, gs.value, instr.ty), gv);
            break :blk null;
        },

        .global_load => |name| blk: {
            const gv = cg.global_decls.get(name) orelse break :blk null;
            break :blk llvm.LLVMBuildLoad2(cg.builder, types.lower(cg, instr.ty), gv, "");
        },

        .field => |f| lowerField(cg, fncg, f, instr.ty, false, instr.location),
        .field_addr => |f| blk: {
            fncg.pending_bits = null;
            const addr = lowerField(cg, fncg, f, instr.ty, true, instr.location);
            if (fncg.pending_bits) |ref| if (instr.id) |id| fncg.bit_refs.put(id, ref) catch {};
            fncg.pending_bits = null;
            break :blk addr;
        },

        .index => |ix| blk: {
            // Safety: bounds check before loading.
            if (cg.safety) emitBoundsCheck(cg, fncg, ix, instr.location);
            const elem_ty = types.lower(cg, instr.ty);
            const gep = lowerIndexAddress(cg, fncg, ix, instr.ty, instr.location) orelse break :blk null;
            break :blk llvm.LLVMBuildLoad2(cg.builder, elem_ty, gep, "");
        },
        .index_addr => |ix| blk: {
            // Safety: bounds check before taking address (a slice's start checks its own).
            if (cg.safety and ix.checked) emitBoundsCheck(cg, fncg, ix, instr.location);
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
            // An immediate operand has no `irTypeOf`; `.unknown` would lower to
            // `ptr`, so `ConstInt(ptr, n)` produces garbage (e.g. `7 as i32` → 0).
            // Give the immediate its natural scalar type so the coercion is real.
            const src_ty = fncg.irTypeOf(cs.value) orelse switch (cs.value) {
                .imm => |im| switch (im) {
                    .int => ir.IrType{ .i = 64 },
                    .uint => ir.IrType{ .u = 64 },
                    .float => .f64,
                    .bool => .bool,
                    .rune => .rune,
                    .text => .text,
                    .null => instr.ty,
                },
                else => instr.ty,
            };
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
        .variant_tag => |vt| vars_mod.buildVariantTag(cg, resolveVal(cg, fncg, vt.value, .unknown), vt.type_name),

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
        .closure_make => |mk| lowerClosureMake(cg, fncg, mk),
        .closure_env_make => |mk| lowerClosureEnvMake(cg, fncg, mk),
        .closure_env_load => |ld| lowerClosureEnvLoad(cg, fncg, ld),

        // Error / fallible

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

        // try_err: the number of the error, field 1; or, typed as a set whose errors carry
        // payloads, the whole error, `{ number, payload bytes }` from fields 1 and 2.
        .try_err => |val| blk: {
            const fallible = resolveVal(cg, fncg, val, .unknown);
            const code = values.extractAggregateField(cg, fallible, 1, "fallible error discriminant") orelse break :blk null;
            if (types.errorPayloadBytes(cg, instr.ty) == null) break :blk code;
            const data = values.extractAggregateField(cg, fallible, 2, "fallible error payload") orelse break :blk null;
            var err = llvm.LLVMGetUndef(types.lower(cg, instr.ty));
            err = llvm.LLVMBuildInsertValue(cg.builder, err, code, 0, "");
            break :blk llvm.LLVMBuildInsertValue(cg.builder, err, data, 1, "");
        },

        // Zone enter/exit lower to `make()`/`deinit()` calls in the IR, so these
        // ops are no longer emitted for the LLVM backend (they remain only for the
        // comptime VM). `free` is a no-op on a bump arena (drained at `deinit`).
        .zone_push, .zone_pop, .zone_free => null,
        .iter_init, .iter_has_next, .iter_next, .at, .raw_pointer => null,
    };

    if (instr.id) |id| if (result) |v| {
        fncg.regs.put(id, v) catch {};
        fncg.reg_ir_types.put(id, instr.ty) catch {};
    };
}

// Helpers

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

fn lowerClosureMake(cg: *ModuleCg, fncg: anytype, mk: ir.ClosureMakeInstr) ?llvm.LLVMValueRef {
    const target = cg.fn_decls.get(mk.fn_link) orelse return null;
    // A lifted lambda already takes a leading `__env`; a plain function does not,
    // so wrap it in a forwarding thunk that drops the env and forwards the args.
    const fn_ptr = if (mk.fn_takes_env) target else getOrCreateThunk(cg, mk.fn_link, target) orelse return null;
    const ptr_ty = llvm.LLVMPointerTypeInContext(cg.ctx, 0);
    const env = switch (mk.env) {
        .imm => |imm| values.lowerImmAs(cg, imm, ptr_ty),
        else => values.coerce(cg.builder, cg.ctx, resolveVal(cg, fncg, mk.env, .unknown), ptr_ty),
    };
    var result = llvm.LLVMGetUndef(cg.getClosureType());
    result = llvm.LLVMBuildInsertValue(cg.builder, result, fn_ptr, 0, "clos.fn");
    return llvm.LLVMBuildInsertValue(cg.builder, result, env, 1, "clos.env");
}

/// Allocate a lambda's capture environment as an anonymous struct and store each
/// captured value into it; yields the pointer used as the closure's `env`.
fn lowerClosureEnvMake(cg: *ModuleCg, fncg: anytype, mk: ir.ClosureEnvMakeInstr) ?llvm.LLVMValueRef {
    const n = mk.fields.len;
    const ftys = cg.allocator.alloc(llvm.LLVMTypeRef, n) catch return null;
    defer cg.allocator.free(ftys);
    for (mk.fields, 0..) |f, i| ftys[i] = types.lower(cg, f.ty);
    const struct_ty = llvm.LLVMStructTypeInContext(cg.ctx, ftys.ptr, @intCast(n), 0);

    // Allocate the env on the `*Arena` region (an enclosing `zone` handle or a
    // caller-supplied `*Arena` param) so the closure may escape the current frame,
    // or on the stack when there's no region.
    const has_arena = switch (mk.arena) {
        .imm => false,
        else => true,
    };
    const env_ptr = blk: {
        if (has_arena) {
            if (cg.fn_decls.get("alloc_bytes")) |alloc_fn| {
                const arena = resolveVal(cg, fncg, mk.arena, .unknown); // a *Arena
                const i64_ty = llvm.LLVMInt64TypeInContext(cg.ctx);
                const size = llvm.LLVMABISizeOfType(cg.targetData(), struct_ty);
                var args = [_]llvm.LLVMValueRef{ arena, llvm.LLVMConstInt(i64_ty, size, 0) };
                const fn_ty = llvm.LLVMGlobalGetValueType(alloc_fn);
                const slice = llvm.LLVMBuildCall2(cg.builder, fn_ty, alloc_fn, &args, 2, "");
                break :blk llvm.LLVMBuildExtractValue(cg.builder, slice, 0, "clos.env.heap");
            }
        }
        break :blk llvm.LLVMBuildAlloca(cg.builder, struct_ty, "clos.env");
    };

    for (mk.fields, 0..) |f, i| {
        const gep = llvm.LLVMBuildStructGEP2(cg.builder, struct_ty, env_ptr, @intCast(i), "");
        _ = llvm.LLVMBuildStore(cg.builder, resolveVal(cg, fncg, f.value, f.ty), gep);
    }
    return env_ptr;
}

/// Read capture field `index` out of a lambda's `__env` pointer (the env's layout
/// is the anonymous struct of `fields`, matching `closure_env_make`).
fn lowerClosureEnvLoad(cg: *ModuleCg, fncg: anytype, ld: ir.ClosureEnvLoadInstr) ?llvm.LLVMValueRef {
    const n = ld.fields.len;
    const ftys = cg.allocator.alloc(llvm.LLVMTypeRef, n) catch return null;
    defer cg.allocator.free(ftys);
    for (ld.fields, 0..) |t, i| ftys[i] = types.lower(cg, t);
    const struct_ty = llvm.LLVMStructTypeInContext(cg.ctx, ftys.ptr, @intCast(n), 0);
    const env_ptr = resolveVal(cg, fncg, ld.env, .unknown);
    const gep = llvm.LLVMBuildStructGEP2(cg.builder, struct_ty, env_ptr, ld.index, "");
    return llvm.LLVMBuildLoad2(cg.builder, ftys[ld.index], gep, "");
}

/// Build (once, cached) `__thunk_<fn>(__env: ptr, args…) -> Ret { return fn(args); }`
/// so a plain function can be called through the uniform `fn(env, args)` closure
/// convention. The env argument is ignored.
pub fn getOrCreateThunk(cg: *ModuleCg, fn_link: []const u8, target: llvm.LLVMValueRef) ?llvm.LLVMValueRef {
    if (cg.closure_thunks.get(fn_link)) |t| return t;

    const target_ty = fnTypeOf(cg, fn_link, target);
    const n = llvm.LLVMCountParamTypes(target_ty);
    const ptr_ty = llvm.LLVMPointerTypeInContext(cg.ctx, 0);
    // A target returning through `sret` (a Fels function, not a C one) keeps that pointer
    // first: the thunk is `(sret, __env, args…)` and passes it on.
    const sret_ty: ?llvm.LLVMTypeRef = if (cg.fn_abi.contains(fn_link)) null else abi.sretOf(target);
    const s: c_uint = if (sret_ty != null) 1 else 0;

    const ptys = cg.allocator.alloc(llvm.LLVMTypeRef, n + 1) catch return null;
    defer cg.allocator.free(ptys);
    if (n > 0) llvm.LLVMGetParamTypes(target_ty, ptys.ptr + 1);
    if (s == 1) ptys[0] = ptys[1]; // the sret pointer moves before __env
    ptys[s] = ptr_ty; // __env
    const ret_ty = llvm.LLVMGetReturnType(target_ty);
    const thunk_ty = llvm.LLVMFunctionType(ret_ty, ptys.ptr, n + 1, 0);

    const name_slice = std.fmt.allocPrint(cg.allocator, "__thunk_{s}", .{fn_link}) catch return null;
    defer cg.allocator.free(name_slice);
    const name = cg.allocator.dupeZ(u8, name_slice) catch return null;
    defer cg.allocator.free(name);
    const thunk = llvm.LLVMAddFunction(cg.mod, name.ptr, thunk_ty);
    llvm.LLVMSetLinkage(thunk, llvm.LLVMInternalLinkage);

    // Build the body, then restore the builder to where it was.
    const saved = llvm.LLVMGetInsertBlock(cg.builder);
    const entry = llvm.LLVMAppendBasicBlockInContext(cg.ctx, thunk, "entry");
    llvm.LLVMPositionBuilderAtEnd(cg.builder, entry);
    const args = cg.allocator.alloc(llvm.LLVMValueRef, n) catch return null;
    defer cg.allocator.free(args);
    if (sret_ty) |ty| abi.markSret(cg, thunk, ty);
    var i: c_uint = 0;
    while (i < n) : (i += 1) args[i] = llvm.LLVMGetParam(thunk, if (i < s) i else i + 1); // skip __env
    const call = llvm.LLVMBuildCall2(cg.builder, target_ty, target, args.ptr, n, "");
    if (sret_ty) |ty| abi.markCallSret(cg, call, ty);
    if (llvm.LLVMGetTypeKind(ret_ty) == llvm.LLVMVoidTypeKind) {
        _ = llvm.LLVMBuildRetVoid(cg.builder);
    } else {
        _ = llvm.LLVMBuildRet(cg.builder, call);
    }
    if (saved) |bb| llvm.LLVMPositionBuilderAtEnd(cg.builder, bb);

    cg.closure_thunks.put(fn_link, thunk) catch {};
    return thunk;
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

    const base_ir_ty = indexBaseType(fncg, ix.base);
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
                if (cg.safety) emitNullCheck(cg, fncg.llvm_fn, base_ptr, location);
                const zero = llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), 0, 0);
                var indices = [_]llvm.LLVMValueRef{ zero, idx };
                return llvm.LLVMBuildGEP2(cg.builder, types.lower(cg, .{ .array = arr }), base_ptr, &indices, 2, "");
            },
            else => {
                const base_ptr = resolveVal(cg, fncg, ix.base, base_ty);
                if (cg.safety) emitNullCheck(cg, fncg.llvm_fn, base_ptr, location);
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

// Unary

fn lowerUnary(cg: *ModuleCg, fncg: anytype, u: ir.UnaryInstr, ty: ir.IrType, location: ir.SourceLocation) ?llvm.LLVMValueRef {
    // Taking an address reads nothing: resolving the operand as a value would load it (a
    // whole array, say) and coerce that to a pointer, which is not a valid instruction.
    if (u.op == .ref) return lowerRef(cg, fncg, u.value);
    if (u.op == .deref) if (bitRefOf(fncg, u.value)) |ref| return readBitField(cg, ref, types.lower(cg, ty));
    const v = resolveVal(cg, fncg, u.value, ty);
    const bl = cg.builder;
    return switch (u.op) {
        .neg => if (isFloat(ty))
            // Float negation: `0.0 - v` (LLVMBuildNeg is integer-only and would
            // emit an invalid `sub double`).
            llvm.LLVMBuildFSub(bl, llvm.LLVMConstNull(llvm.LLVMTypeOf(v)), v, "")
        else if (cg.safety)
            lowerOverflowingBinary(cg, fncg.llvm_fn, llvm.LLVMConstNull(llvm.LLVMTypeOf(v)), v, "llvm.ssub.with.overflow", location)
        else
            llvm.LLVMBuildNeg(bl, v, ""),
        .not => llvm.LLVMBuildNot(bl, v, ""),
        .bit_not => llvm.LLVMBuildNot(bl, v, ""),
        .deref => blk: {
            // Safety: null-pointer dereference check.
            if (cg.safety) emitNullCheck(cg, fncg.llvm_fn, v, location);
            const loaded = llvm.LLVMBuildLoad2(cg.builder, types.lower(cg, ty), v, "");
            markPackedAccess(loaded, v);
            break :blk loaded;
        },
        .ref => unreachable, // handled above
    };
}

/// Address-of: for a local name, just return its alloca pointer.
/// For anything else, build a temporary alloca and store into it.
fn lowerRef(cg: *ModuleCg, fncg: anytype, val: ir.Value) ?llvm.LLVMValueRef {
    // The spill allocas below go in the ENTRY block (static frame), not at the
    // current position: a mid-function alloca makes LLVM emit a dynamic stack
    // adjustment that calls `__chkstk`, which the CRT-less link doesn't provide.
    return switch (val) {
        .local => |name| fncg.locals.get(name), // alloca IS the address
        .global => |name| cg.global_decls.get(name), // so is a global's own storage
        .param => |name| blk: {
            const pv = fncg.params.get(name) orelse break :blk null;
            const pty = fncg.param_ir_types.get(name) orelse break :blk null;
            const tmp = abi.entryAlloca(cg, fncg.llvm_fn, types.lower(cg, pty));
            _ = llvm.LLVMBuildStore(cg.builder, pv, tmp);
            break :blk tmp;
        },
        .reg => |id| blk: {
            const rv = fncg.regs.get(id) orelse break :blk null;
            const rty = fncg.reg_ir_types.get(id) orelse break :blk null;
            const tmp = abi.entryAlloca(cg, fncg.llvm_fn, types.lower(cg, rty));
            _ = llvm.LLVMBuildStore(cg.builder, rv, tmp);
            break :blk tmp;
        },
        else => null,
    };
}

// Binary

fn lowerBinary(cg: *ModuleCg, fncg: anytype, b: ir.BinaryInstr, ty: ir.IrType, location: ir.SourceLocation) ?llvm.LLVMValueRef {
    // A shift has the type of the value shifted, never of the amount: in `1 << b` with `b: u8`
    // the literal takes the shift's own type, or `1 << 10` was computed in 8 bits.
    const is_shift = b.op == .shl or b.op == .shr;
    const lhs_hint = fncg.irTypeOf(b.lhs) orelse (if (is_shift) null else fncg.irTypeOf(b.rhs)) orelse ty;
    const rhs_hint = fncg.irTypeOf(b.rhs) orelse lhs_hint;
    const lhs = resolveVal(cg, fncg, b.lhs, lhs_hint);
    var rhs = resolveVal(cg, fncg, b.rhs, rhs_hint);
    rhs = values.coerce(cg.builder, cg.ctx, rhs, llvm.LLVMTypeOf(lhs));
    const bl = cg.builder;
    // Pick float vs integer ops by the actual operand type, not just the IR hint:
    // in a generic instantiation the hint can be lost (e.g. a generic helper call's
    // result type), and an integer `mul` on `double` operands is an LLVM verify
    // error. The LLVM type is the ground truth for add/sub/mul/div/cmp selection.
    const lhs_kind = llvm.LLVMGetTypeKind(llvm.LLVMTypeOf(lhs));
    const lhs_is_float_ty = lhs_kind == llvm.LLVMFloatTypeKind or
        lhs_kind == llvm.LLVMDoubleTypeKind or
        lhs_kind == llvm.LLVMHalfTypeKind;
    const is_float = isFloat(lhs_hint) or lhs_is_float_ty;
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
            else if (cg.safety)
                lowerOverflowingBinary(cg, fncg.llvm_fn, lhs, rhs, if (is_unsigned) "llvm.uadd.with.overflow" else "llvm.sadd.with.overflow", location)
            else
                llvm.LLVMBuildAdd(bl, lhs, rhs, "");
        },
        .sub => if (is_float)
            llvm.LLVMBuildFSub(bl, lhs, rhs, "")
        else if (cg.safety)
            lowerOverflowingBinary(cg, fncg.llvm_fn, lhs, rhs, if (is_unsigned) "llvm.usub.with.overflow" else "llvm.ssub.with.overflow", location)
        else
            llvm.LLVMBuildSub(bl, lhs, rhs, ""),
        .mul => if (is_float)
            llvm.LLVMBuildFMul(bl, lhs, rhs, "")
        else if (cg.safety)
            lowerOverflowingBinary(cg, fncg.llvm_fn, lhs, rhs, if (is_unsigned) "llvm.umul.with.overflow" else "llvm.smul.with.overflow", location)
        else
            llvm.LLVMBuildMul(bl, lhs, rhs, ""),
        // Wrapping ops never check: plain two's-complement add/sub/mul regardless
        // of opt level. (Integer-only — sema rejects float operands.)
        .wrap_add => llvm.LLVMBuildAdd(bl, lhs, rhs, ""),
        .wrap_sub => llvm.LLVMBuildSub(bl, lhs, rhs, ""),
        .wrap_mul => llvm.LLVMBuildMul(bl, lhs, rhs, ""),
        .div => if (is_float)
            llvm.LLVMBuildFDiv(bl, lhs, rhs, "")
        else blk: {
            // Safety: check for division by zero.
            if (cg.safety) {
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
            // Safety: check for division by zero (modulo).
            if (cg.safety) {
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
            // Safety: check shift amount < bit width.
            if (cg.safety) {
                const rhs_ty = llvm.LLVMTypeOf(rhs);
                const width = llvm.LLVMGetIntTypeWidth(llvm.LLVMTypeOf(lhs));
                const limit = llvm.LLVMConstInt(rhs_ty, width, 0);
                const over = llvm.LLVMBuildICmp(bl, llvm.LLVMIntUGE, rhs, limit, "");
                emitRuntimeCheck(cg, fncg.llvm_fn, over, "shift amount exceeds bit width", location);
            }
            break :blk llvm.LLVMBuildShl(cg.builder, lhs, rhs, "");
        },
        .shr => blk: {
            // Safety: check shift amount < bit width.
            if (cg.safety) {
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

/// Declare + call an LLVM intrinsic by name (e.g. `llvm.ctpop`). `overloads` are
/// the intrinsic's overloaded type params (usually the single operand type);
/// `args` are the call arguments. Powers the `core::` math/bit/memory builtins.
fn emitIntrinsic(
    cg: *ModuleCg,
    name: []const u8,
    overloads: []const llvm.LLVMTypeRef,
    args: []const llvm.LLVMValueRef,
) llvm.LLVMValueRef {
    const id = llvm.LLVMLookupIntrinsicID(name.ptr, name.len);
    const ovl: [*c]llvm.LLVMTypeRef = if (overloads.len == 0) null else @constCast(overloads.ptr);
    const f = llvm.LLVMGetIntrinsicDeclaration(cg.mod, id, ovl, overloads.len);
    const fty = llvm.LLVMGlobalGetValueType(f);
    const ap: [*c]llvm.LLVMValueRef = if (args.len == 0) null else @constCast(args.ptr);
    return llvm.LLVMBuildCall2(cg.builder, fty, f, ap, @intCast(args.len), "");
}

/// The LLVM min/max intrinsic for `core::min`/`max`/`clamp`, by element type.
fn minMaxIntrinsic(ty: ir.IrType, is_max: bool) []const u8 {
    if (isFloat(ty)) return if (is_max) "llvm.maxnum" else "llvm.minnum";
    if (isUnsigned(ty)) return if (is_max) "llvm.umax" else "llvm.umin";
    return if (is_max) "llvm.smax" else "llvm.smin";
}

/// The LLVM intrinsic for a unary float math builtin, or null if `name` isn't one.
fn unaryFloatIntrinsic(name: []const u8) ?[]const u8 {
    const eq = std.mem.eql;
    if (eq(u8, name, "sqrt")) return "llvm.sqrt";
    if (eq(u8, name, "floor")) return "llvm.floor";
    if (eq(u8, name, "ceil")) return "llvm.ceil";
    if (eq(u8, name, "round")) return "llvm.round";
    if (eq(u8, name, "trunc")) return "llvm.trunc";
    if (eq(u8, name, "sin")) return "llvm.sin";
    if (eq(u8, name, "cos")) return "llvm.cos";
    return null;
}

// Inline assembly

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

    // Resolve argument values and coerce each to i64 — the asm function type
    // declares every parameter i64 (registers are 64-bit), so a narrower int
    // (e.g. an `i32` fd / exit code) or a pointer must be widened to match, else
    // LLVM rejects the call as a signature mismatch.
    const args = cg.allocator.alloc(llvm.LLVMValueRef, ai.args.len) catch return null;
    defer cg.allocator.free(args);
    const i64_ty = llvm.LLVMInt64TypeInContext(cg.ctx);
    for (ai.args, 0..) |arg, i| {
        var v = resolveVal(cg, fncg, arg, .usize);
        const vty = llvm.LLVMTypeOf(v);
        if (llvm.LLVMGetTypeKind(vty) == llvm.LLVMIntegerTypeKind) {
            const w = llvm.LLVMGetIntTypeWidth(vty);
            if (w < 64) {
                v = llvm.LLVMBuildZExt(cg.builder, v, i64_ty, "");
            } else if (w > 64) {
                v = llvm.LLVMBuildTrunc(cg.builder, v, i64_ty, "");
            }
        } else {
            v = llvm.LLVMBuildPtrToInt(cg.builder, v, i64_ty, "");
        }
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

// Calls

/// Indirect call through a function pointer.
/// With opaque pointers we must reconstruct the LLVM function type from
/// the return type (instr.ty) and the actual argument types at the call site.
fn lowerCallIndirect(
    cg: *ModuleCg,
    fncg: anytype,
    ci: ir.CallIndirectInstr,
    ret_ty: ir.IrType,
) ?llvm.LLVMValueRef {
    // For a fels function value the callee is a fat closure `{ fn, env }`: extract
    // the `fn` field to call, and pass the `env` as a hidden leading argument so
    // every closure is invoked uniformly as `fn(env, args)`.
    const closure_val = if (ci.is_closure) resolveVal(cg, fncg, ci.callee, .unknown) else null;
    const callee_ptr = if (closure_val) |v|
        values.extractAggregateField(cg, v, 0, "closure function") orelse return null
    else
        resolveVal(cg, fncg, ci.callee, .unknown);
    // A large return comes back through a hidden `sret` slot, passed before everything else
    // (the env included), as the callee was defined (`types.returnsIndirect`).
    const ret_lty = types.lower(cg, ret_ty);
    const sret = ret_ty != .void and types.returnsIndirect(cg, ret_lty);
    const sret_n: usize = if (sret) 1 else 0;
    const lead: usize = sret_n + @as(usize, if (ci.is_closure) 1 else 0);

    // Resolve argument values and collect their LLVM types (then the env for a closure).
    const total = lead + ci.args.len;
    const resolved_args = cg.allocator.alloc(llvm.LLVMValueRef, total) catch return null;
    defer cg.allocator.free(resolved_args);
    const param_tys = cg.allocator.alloc(llvm.LLVMTypeRef, total) catch return null;
    defer cg.allocator.free(param_tys);

    if (sret) {
        resolved_args[0] = abi.entryAlloca(cg, fncg.llvm_fn, ret_lty);
        param_tys[0] = llvm.LLVMPointerTypeInContext(cg.ctx, 0);
    }
    if (closure_val) |v| {
        resolved_args[sret_n] = llvm.LLVMBuildExtractValue(cg.builder, v, 1, "clos.env");
        param_tys[sret_n] = llvm.LLVMPointerTypeInContext(cg.ctx, 0);
    }

    for (ci.args, 0..) |arg, i| {
        const slot = lead + i;
        // Prefer the type from the callee's fn-pointer signature (the IR records
        // it in `param_tys`): an `.imm` literal arg has no tracked type of its
        // own and would otherwise lower to a zero-width `i0`.
        const sig_ty: ?ir.IrType = if (i < ci.param_tys.len and ci.param_tys[i] != .unknown) ci.param_tys[i] else null;
        if (sig_ty) |ty| {
            const lty = types.lower(cg, ty);
            resolved_args[slot] = switch (arg) {
                .imm => |imm| values.lowerImmAs(cg, imm, lty),
                else => values.coerce(cg.builder, cg.ctx, resolveVal(cg, fncg, arg, ty), lty),
            };
        } else {
            const arg_ir_ty = fncg.irTypeOf(arg) orelse ir.IrType.unknown;
            resolved_args[slot] = resolveVal(cg, fncg, arg, arg_ir_ty);
        }
        param_tys[slot] = llvm.LLVMTypeOf(resolved_args[slot]);
    }

    // Reconstruct the function type from args + return type.
    const call_ret = if (sret) llvm.LLVMVoidTypeInContext(cg.ctx) else ret_lty;
    const fn_ty = llvm.LLVMFunctionType(call_ret, param_tys.ptr, @intCast(total), 0);

    const result = llvm.LLVMBuildCall2(
        cg.builder,
        fn_ty,
        callee_ptr,
        resolved_args.ptr,
        @intCast(total),
        "",
    );
    abi.markCallBoolExt(cg, result, fn_ty);
    if (sret) {
        abi.markCallSret(cg, result, ret_lty);
        return llvm.LLVMBuildLoad2(cg.builder, ret_lty, resolved_args[0], "");
    }
    return if (ret_ty == .void) null else result;
}

/// The LLVM function type a call to IR function `name` is built with: its own
/// declared type when it shares an LLVM function with another `#extern` binding of
/// the same C symbol, otherwise the type of the function itself.
fn fnTypeOf(cg: *ModuleCg, name: []const u8, lv: llvm.LLVMValueRef) llvm.LLVMTypeRef {
    return cg.fn_types.get(name) orelse llvm.LLVMGlobalGetValueType(lv);
}

fn lowerCall(cg: *ModuleCg, fncg: anytype, call: ir.CallInstr, ret_ty: ir.IrType) ?llvm.LLVMValueRef {
    // Calls to `#extern` C functions with by-value aggregate params/return take
    // the Win64 C-ABI path (coerce structs to integers / pass them indirectly).
    if (cg.fn_abi.get(call.callee)) |sig| return lowerCallAbi(cg, fncg, call, ret_ty, sig);

    const lv = cg.fn_decls.get(call.callee) orelse return null;
    const fn_ty = fnTypeOf(cg, call.callee, lv);
    const n_all = llvm.LLVMCountParamTypes(fn_ty);

    // A large return comes back through a hidden leading `sret` slot (`types.returnsIndirect`).
    const sret_ty = abi.sretOf(lv);
    const lead: usize = if (sret_ty != null) 1 else 0;
    const args = cg.allocator.alloc(llvm.LLVMValueRef, lead + call.args.len) catch return null;
    defer cg.allocator.free(args);

    // Get param types so we can hint resolveVal with the right type.
    const all_tys = cg.allocator.alloc(llvm.LLVMTypeRef, n_all) catch return null;
    defer cg.allocator.free(all_tys);
    llvm.LLVMGetParamTypes(fn_ty, all_tys.ptr);
    const param_tys = all_tys[lead..];
    const n_param = param_tys.len;

    if (sret_ty) |ty| args[0] = abi.entryAlloca(cg, fncg.llvm_fn, ty);
    for (call.args, 0..) |arg, i| {
        const v = if (i < n_param) switch (arg) {
            .imm => |imm| values.lowerImmAs(cg, imm, param_tys[i]),
            else => values.coerce(cg.builder, cg.ctx, resolveVal(cg, fncg, arg, .unknown), param_tys[i]),
        } else resolveVal(cg, fncg, arg, .unknown);
        args[lead + i] = v;
    }

    const result = llvm.LLVMBuildCall2(cg.builder, fn_ty, lv, args.ptr, @intCast(args.len), "");
    abi.markCallBoolExt(cg, result, fn_ty);
    if (sret_ty) |ty| {
        abi.markCallSret(cg, result, ty);
        return llvm.LLVMBuildLoad2(cg.builder, ty, args[0], "");
    }
    return if (ret_ty == .void) null else result;
}

/// Win64 C-ABI call to an `#extern` function: small by-value structs are
/// coerced to integers, large ones passed by pointer, and an aggregate return
/// is materialized from a coerced integer or an `sret` slot. See `abi.zig`.
fn lowerCallAbi(cg: *ModuleCg, fncg: anytype, call: ir.CallInstr, ret_ty: ir.IrType, sig: abi.FnAbi) ?llvm.LLVMValueRef {
    const lv = cg.fn_decls.get(call.callee) orelse return null;
    const fn_ty = fnTypeOf(cg, call.callee, lv);

    const total = call.args.len + @as(usize, if (sig.sret) 1 else 0);
    const args = cg.allocator.alloc(llvm.LLVMValueRef, total) catch return null;
    defer cg.allocator.free(args);

    var ai: usize = 0;
    var sret_slot: llvm.LLVMValueRef = null;
    if (sig.sret) {
        sret_slot = abi.entryAlloca(cg, fncg.llvm_fn, sig.ret_struct);
        args[0] = sret_slot;
        ai = 1;
    }

    for (call.args, 0..) |arg, i| {
        const p: abi.ParamAbi = if (i < sig.params.len)
            sig.params[i]
        else
            .{ .class = .direct, .ir_ty = .unknown };
        args[ai] = switch (p.class) {
            .direct => switch (arg) {
                .imm => |imm| values.lowerImmAs(cg, imm, types.lower(cg, p.ir_ty)),
                else => values.coerce(cg.builder, cg.ctx, resolveVal(cg, fncg, arg, .unknown), types.lower(cg, p.ir_ty)),
            },
            .coerce => |bits| abi.structToInt(cg, fncg.llvm_fn, resolveVal(cg, fncg, arg, p.ir_ty), p.llvm_struct, bits),
            .indirect => abi.structToPtr(cg, fncg.llvm_fn, resolveVal(cg, fncg, arg, p.ir_ty), p.llvm_struct),
        };
        ai += 1;
    }

    const result = llvm.LLVMBuildCall2(cg.builder, fn_ty, lv, args.ptr, @intCast(total), "");
    abi.markCallBoolExt(cg, result, fn_ty);

    if (sig.sret) return llvm.LLVMBuildLoad2(cg.builder, sig.ret_struct, sret_slot, "");
    return switch (sig.ret) {
        .coerce => abi.intToStruct(cg, fncg.llvm_fn, result, sig.ret_struct),
        else => if (ret_ty == .void) null else result,
    };
}

// Field access
//
// Strategy:
//   - Slice fields (.ptr / .len): extractvalue from the { ptr, usize } struct.
//   - Named-struct fields: extractvalue from the struct value.
//   - Pointer-to-struct: structGEP + load (or just GEP for field_addr).
//
// When `want_addr` is true we return a pointer to the field instead of loading.

// A folded string constant — `type_name(T)` or a string literal — lowers to an
// `.imm.text` Value, which is a `[]const u8` slice { ptr, len }.
const str_elem_ty: ir.IrType = .byte;
const str_slice_ty: ir.IrType = .{ .slice = &str_elem_ty };

fn lowerField(
    cg: *ModuleCg,
    fncg: anytype,
    f: ir.FieldInstr,
    result_ty: ir.IrType,
    want_addr: bool,
    location: ir.SourceLocation,
) ?llvm.LLVMValueRef {
    // An `.imm.text` base (a folded string constant) has no irTypeOf, yet it IS
    // a `[]const u8` slice value. Route it through the `.slice` branch so an
    // INLINE `.len`/`.ptr` resolves (e.g. `type_name(Point).len`); without this
    // the read bails to null and the result reg is left undef → garbage. Through
    // a local it already works — the local carries a `.slice` irType.
    const base_ir_ty = fncg.irTypeOf(f.base) orelse blk: {
        switch (f.base) {
            .imm => |im| if (im == .text) break :blk str_slice_ty,
            else => {},
        }
        return null;
    };

    switch (base_ir_ty) {
        .slice => {
            // Slice is a value type { ptr, usize }.  Use extractvalue.
            const idx: u32 = if (std.mem.eql(u8, f.name, "ptr")) 0 else 1;
            const base_val = resolveVal(cg, fncg, f.base, base_ir_ty);
            if (want_addr) {
                // Spill to a temp alloca so we can take an address. (In the entry block: an
                // alloca anywhere else is a dynamic allocation, and in a loop it grows the
                // stack on every iteration.)
                const tmp = abi.entryAlloca(cg, fncg.llvm_fn, cg.getSliceType());
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
                const tmp = abi.entryAlloca(cg, fncg.llvm_fn, lty);
                _ = llvm.LLVMBuildStore(cg.builder, base_val, tmp);
                return llvm.LLVMBuildStructGEP2(cg.builder, lty, tmp, idx, "");
            }
            return values.extractAggregateField(cg, base_val, idx, "fallible field access");
        },

        .struct_type => |name| {
            // A union's field is its bytes at its own address, read as the field's type.
            if (cg.isUnion(name)) {
                const struct_lty = cg.struct_types.get(name) orelse return null;
                const base_ptr = if (want_addr)
                    localOrAllocaPtr(cg, fncg, f.base, struct_lty) orelse return null
                else blk: {
                    const tmp = abi.entryAlloca(cg, fncg.llvm_fn, struct_lty);
                    _ = llvm.LLVMBuildStore(cg.builder, resolveVal(cg, fncg, f.base, base_ir_ty), tmp);
                    break :blk tmp;
                };
                if (want_addr) return base_ptr;
                return llvm.LLVMBuildLoad2(cg.builder, types.lower(cg, result_ty), base_ptr, "");
            }
            if (cg.bitPlaces(name)) |places| {
                const struct_lty = cg.struct_types.get(name) orelse return null;
                const base_ptr = if (want_addr)
                    localOrAllocaPtr(cg, fncg, f.base, struct_lty) orelse return null
                else blk: {
                    const tmp = abi.entryAlloca(cg, fncg.llvm_fn, struct_lty);
                    _ = llvm.LLVMBuildStore(cg.builder, resolveVal(cg, fncg, f.base, base_ir_ty), tmp);
                    break :blk tmp;
                };
                return bitFieldAccess(cg, fncg, name, places, base_ptr, f.name, result_ty, want_addr);
            }
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
            const struct_lty = cg.struct_types.get(name) orelse return null;
            const base_ptr = resolveVal(cg, fncg, f.base, base_ir_ty);
            if (cg.safety) emitNullCheck(cg, fncg.llvm_fn, base_ptr, location);
            if (cg.bitPlaces(name)) |places| return bitFieldAccess(cg, fncg, name, places, base_ptr, f.name, result_ty, want_addr);
            // A union's fields are all at its own address.
            const field_ptr = if (cg.isUnion(name))
                base_ptr
            else
                llvm.LLVMBuildStructGEP2(cg.builder, struct_lty, base_ptr, cg.fieldIndex(name, f.name) orelse return null, "");
            if (want_addr) return field_ptr;
            // A field is loaded as its type: a `fn(...)` field holds a `{fn, env}` closure, an
            // `extern fn(...)` one a bare code pointer (structs.zig).
            const field_lty = types.lower(cg, result_ty);
            const field_load = llvm.LLVMBuildLoad2(cg.builder, field_lty, field_ptr, "");
            markPackedAccess(field_load, field_ptr);
            return field_load;
        },

        .array => |arr| {
            // Fixed array: `.len` is the compile-time element count; `.ptr` is the
            // address of the first element.
            if (std.mem.eql(u8, f.name, "len")) {
                return llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), arr.len, 0);
            }
            if (std.mem.eql(u8, f.name, "ptr")) {
                const arr_lty = types.lower(cg, base_ir_ty);
                const base_ptr = localOrAllocaPtr(cg, fncg, f.base, arr_lty) orelse return null;
                var indices = [_]llvm.LLVMValueRef{
                    llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), 0, 0),
                    llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), 0, 0),
                };
                return llvm.LLVMBuildGEP2(cg.builder, arr_lty, base_ptr, &indices, 2, "");
            }
            return null;
        },

        else => return null,
    }
}

/// A field of a `#packed` struct can sit at any byte offset, so a load or store
/// through its address is only valid at alignment 1; LLVM would otherwise assume the
/// field type's natural alignment. `ptr` is inspected rather than tracked: a pointer
/// to such a field is a GEP whose source type is the packed struct.
fn markPackedAccess(access: llvm.LLVMValueRef, ptr: llvm.LLVMValueRef) void {
    const is_gep_inst = llvm.LLVMIsAGetElementPtrInst(ptr) != null;
    const is_gep_const = llvm.LLVMIsAConstantExpr(ptr) != null and
        llvm.LLVMGetConstOpcode(ptr) == llvm.LLVMGetElementPtr;
    if (!is_gep_inst and !is_gep_const) return;
    const source = llvm.LLVMGetGEPSourceElementType(ptr);
    if (llvm.LLVMGetTypeKind(source) == llvm.LLVMStructTypeKind and llvm.LLVMIsPackedStruct(source) != 0)
        llvm.LLVMSetAlignment(access, 1);
}

/// Where the bits of a `field_addr` register are, when it addresses a field of a
/// bit-packed struct.
fn bitRefOf(fncg: anytype, val: ir.Value) ?ctx_mod.BitRef {
    return switch (val) {
        .reg => |id| fncg.bit_refs.get(id),
        else => null,
    };
}

/// Field `field_name` of the bit-packed struct `name` at `base_ptr`, read as `result_ty`,
/// or its address. A field of whole bytes is at its byte offset; an integer is the bits of
/// the bytes it spans. The address is that of the field's first byte, and `pending_bits`
/// says where its bits are (`lower` files them under the register, for a `store` or a
/// `deref` through it).
fn bitFieldAccess(
    cg: *ModuleCg,
    fncg: anytype,
    name: []const u8,
    places: []const layout_mod.BitPlace,
    base_ptr: llvm.LLVMValueRef,
    field_name: []const u8,
    result_ty: ir.IrType,
    want_addr: bool,
) ?llvm.LLVMValueRef {
    const fields = cg.struct_fields.get(name) orelse return null;
    const i = for (fields, 0..) |fd, k| {
        if (std.mem.eql(u8, fd.name, field_name)) break k;
    } else return null;
    const place = places[i];
    var offset = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), place.bit / 8, 0)};
    const byte_ptr = llvm.LLVMBuildGEP2(cg.builder, llvm.LLVMInt8TypeInContext(cg.ctx), base_ptr, &offset, 1, "");
    const ref = ctx_mod.BitRef.of(byte_ptr, place, fields[i].ir_ty);
    if (want_addr) {
        fncg.pending_bits = ref;
        return byte_ptr;
    }
    return readBitField(cg, ref, types.lower(cg, result_ty));
}

/// The field `ref` names, as `result_lty`. An integer field is its own bits whatever type
/// the read has (`u3` is a `u8` to the checker), zero- or sign-extended to it.
fn readBitField(cg: *ModuleCg, ref: ctx_mod.BitRef, result_lty: llvm.LLVMTypeRef) llvm.LLVMValueRef {
    if (ref.whole) {
        const whole = llvm.LLVMBuildLoad2(cg.builder, result_lty, ref.ptr, "");
        llvm.LLVMSetAlignment(whole, 1);
        return whole;
    }
    const unit_bits = ref.span * 8;
    const unit = llvm.LLVMIntTypeInContext(cg.ctx, @intCast(unit_bits));
    const loaded = llvm.LLVMBuildLoad2(cg.builder, unit, ref.ptr, "");
    llvm.LLVMSetAlignment(loaded, 1);
    const shifted = if (ref.shift > 0) llvm.LLVMBuildLShr(cg.builder, loaded, llvm.LLVMConstInt(unit, ref.shift, 0), "") else loaded;
    const narrow = if (ref.bits < unit_bits)
        llvm.LLVMBuildTrunc(cg.builder, shifted, llvm.LLVMIntTypeInContext(cg.ctx, @intCast(ref.bits)), "")
    else
        shifted;
    if (llvm.LLVMGetTypeKind(result_lty) != llvm.LLVMIntegerTypeKind) return narrow;
    const result_bits = llvm.LLVMGetIntTypeWidth(result_lty);
    if (result_bits > ref.bits) return if (ref.signed)
        llvm.LLVMBuildSExt(cg.builder, narrow, result_lty, "")
    else
        llvm.LLVMBuildZExt(cg.builder, narrow, result_lty, "");
    if (result_bits < ref.bits) return llvm.LLVMBuildTrunc(cg.builder, narrow, result_lty, "");
    return narrow;
}

/// Write `value` to the field `ref` names, leaving the bits around it as they are.
fn writeBitField(cg: *ModuleCg, ref: ctx_mod.BitRef, value: llvm.LLVMValueRef) void {
    if (ref.whole) {
        const store = llvm.LLVMBuildStore(cg.builder, value, ref.ptr);
        llvm.LLVMSetAlignment(store, 1);
        return;
    }
    const width: u7 = @intCast(ref.span * 8);
    const unit = llvm.LLVMIntTypeInContext(cg.ctx, width);
    const ones: u128 = if (ref.bits >= 128) ~@as(u128, 0) else (@as(u128, 1) << @intCast(ref.bits)) - 1;
    const keep: u128 = ~(ones << @intCast(ref.shift));
    var words = [_]u64{ @truncate(keep), @truncate(keep >> 64) };
    const keep_mask = llvm.LLVMConstIntOfArbitraryPrecision(unit, 2, &words);
    const old = llvm.LLVMBuildLoad2(cg.builder, unit, ref.ptr, "");
    llvm.LLVMSetAlignment(old, 1);
    const kept = llvm.LLVMBuildAnd(cg.builder, old, keep_mask, "");
    // The value may be wider than the field (`u3` is a `u8` to the checker): only its own
    // bits go in, so it cannot spill into the next field.
    const value_width = llvm.LLVMGetIntTypeWidth(llvm.LLVMTypeOf(value));
    const wide = if (value_width < width) llvm.LLVMBuildZExt(cg.builder, value, unit, "") else if (value_width > width) llvm.LLVMBuildTrunc(cg.builder, value, unit, "") else value;
    var one_words = [_]u64{ @truncate(ones), @truncate(ones >> 64) };
    const own = llvm.LLVMBuildAnd(cg.builder, wide, llvm.LLVMConstIntOfArbitraryPrecision(unit, 2, &one_words), "");
    const placed = if (ref.shift > 0) llvm.LLVMBuildShl(cg.builder, own, llvm.LLVMConstInt(unit, ref.shift, 0), "") else own;
    const store = llvm.LLVMBuildStore(cg.builder, llvm.LLVMBuildOr(cg.builder, kept, placed, ""), ref.ptr);
    llvm.LLVMSetAlignment(store, 1);
}

/// A bit-packed struct of type `name` with the fields `values` gives (by field index; null
/// leaves one zero), built in a zeroed slot.
fn buildBitStruct(cg: *ModuleCg, fncg: anytype, name: []const u8, places: []const layout_mod.BitPlace, given: []const ?llvm.LLVMValueRef) ?llvm.LLVMValueRef {
    const struct_lty = cg.struct_types.get(name) orelse return null;
    const tmp = abi.entryAlloca(cg, fncg.llvm_fn, struct_lty);
    _ = llvm.LLVMBuildStore(cg.builder, llvm.LLVMConstNull(struct_lty), tmp);
    for (given, 0..) |maybe, i| {
        const v = maybe orelse continue;
        const place = places[i];
        var offset = [_]llvm.LLVMValueRef{llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(cg.ctx), place.bit / 8, 0)};
        const byte_ptr = llvm.LLVMBuildGEP2(cg.builder, llvm.LLVMInt8TypeInContext(cg.ctx), tmp, &offset, 1, "");
        const fields = cg.struct_fields.get(name) orelse return null;
        writeBitField(cg, ctx_mod.BitRef.of(byte_ptr, place, fields[i].ir_ty), v);
    }
    return llvm.LLVMBuildLoad2(cg.builder, struct_lty, tmp, "");
}

/// Returns the alloca pointer for a local, or a fresh alloca for params/regs.
fn localOrAllocaPtr(cg: *ModuleCg, fncg: anytype, val: ir.Value, lty: llvm.LLVMTypeRef) ?llvm.LLVMValueRef {
    return switch (val) {
        .local => |name| fncg.locals.get(name),
        // A global is addressed in place; spilling it would make a write to its field or
        // element land in a temporary copy.
        .global => |name| cg.global_decls.get(name),
        else => blk: {
            const v = resolveVal(cg, fncg, val, .unknown);
            // A scratch copy to take an address into. It lives in the entry block, so reading
            // an array field in a loop reuses one slot instead of growing the stack each pass.
            const tmp = abi.entryAlloca(cg, fncg.llvm_fn, lty);
            _ = llvm.LLVMBuildStore(cg.builder, v, tmp);
            break :blk tmp;
        },
    };
}

// Builtin instructions

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

    // Atomics
    // Each takes a trailing integer ordering constant: 0=relaxed, 1=acquire,
    // 2=release, 3=acq_rel, 4=seq_cst. Alignment is the type's natural width.

    // atomic_load(ptr, ord) -> T
    if (std.mem.eql(u8, b.name, "atomic_load")) {
        if (b.args.len < 2) return null;
        const ptr = resolveVal(cg, fncg, b.args[0], .{ .ptr = undefined });
        const lty = types.lower(cg, ty);
        const ld = llvm.LLVMBuildLoad2(bl, lty, ptr, "");
        llvm.LLVMSetOrdering(ld, atomicOrdering(b.args[1]));
        llvm.LLVMSetAlignment(ld, atomicAlign(cg, lty));
        return ld;
    }

    // atomic_store(ptr, value, ord)
    if (std.mem.eql(u8, b.name, "atomic_store")) {
        if (b.args.len < 3) return null;
        const ptr = resolveVal(cg, fncg, b.args[0], .{ .ptr = undefined });
        // Type the value from the pointer's pointee — an untyped `.imm` would
        // otherwise lower to a zero-width `i0` (wrong value + a bogus alignment).
        const pointee: ir.IrType = switch (fncg.irTypeOf(b.args[0]) orelse ir.IrType.unknown) {
            .ptr => |p| p.*,
            else => ir.IrType.unknown,
        };
        const val = resolveVal(cg, fncg, b.args[1], pointee);
        const st = llvm.LLVMBuildStore(bl, val, ptr);
        llvm.LLVMSetOrdering(st, atomicOrdering(b.args[2]));
        llvm.LLVMSetAlignment(st, atomicAlign(cg, llvm.LLVMTypeOf(val)));
        return null;
    }

    // atomic_add/sub/and/or/xor/nand/exchange(ptr, value, ord) -> T (the OLD value).
    // add/sub are float-aware (FAdd/FSub for floats); the rest are integer-only.
    {
        const is_float = (ty == .f32 or ty == .f64);
        const rmw_op: ?c_uint = if (std.mem.eql(u8, b.name, "atomic_add"))
            (if (is_float) llvm.LLVMAtomicRMWBinOpFAdd else llvm.LLVMAtomicRMWBinOpAdd)
        else if (std.mem.eql(u8, b.name, "atomic_sub"))
            (if (is_float) llvm.LLVMAtomicRMWBinOpFSub else llvm.LLVMAtomicRMWBinOpSub)
        else if (std.mem.eql(u8, b.name, "atomic_and"))
            llvm.LLVMAtomicRMWBinOpAnd
        else if (std.mem.eql(u8, b.name, "atomic_or"))
            llvm.LLVMAtomicRMWBinOpOr
        else if (std.mem.eql(u8, b.name, "atomic_xor"))
            llvm.LLVMAtomicRMWBinOpXor
        else if (std.mem.eql(u8, b.name, "atomic_nand"))
            llvm.LLVMAtomicRMWBinOpNand
        else if (std.mem.eql(u8, b.name, "atomic_exchange"))
            llvm.LLVMAtomicRMWBinOpXchg
        else
            null;
        if (rmw_op) |op| {
            if (b.args.len < 3) return null;
            const ptr = resolveVal(cg, fncg, b.args[0], .{ .ptr = undefined });
            const val = resolveVal(cg, fncg, b.args[1], ty);
            return llvm.LLVMBuildAtomicRMW(bl, op, ptr, val, atomicOrdering(b.args[2]), 0);
        }
    }

    // atomic_max/atomic_min(ptr, value, ord) -> T (signedness picks signed vs unsigned)
    if (std.mem.eql(u8, b.name, "atomic_max") or std.mem.eql(u8, b.name, "atomic_min")) {
        if (b.args.len < 3) return null;
        const ptr = resolveVal(cg, fncg, b.args[0], .{ .ptr = undefined });
        const val = resolveVal(cg, fncg, b.args[1], ty);
        const signed = switch (ty) {
            .i, .isize => true,
            else => false,
        };
        const is_min = std.mem.eql(u8, b.name, "atomic_min");
        const op: c_uint = if (is_min)
            (if (signed) llvm.LLVMAtomicRMWBinOpMin else llvm.LLVMAtomicRMWBinOpUMin)
        else
            (if (signed) llvm.LLVMAtomicRMWBinOpMax else llvm.LLVMAtomicRMWBinOpUMax);
        return llvm.LLVMBuildAtomicRMW(bl, op, ptr, val, atomicOrdering(b.args[2]), 0);
    }

    // atomic_cas(ptr, expected, desired, ord) -> T (the value seen; == expected on success)
    if (std.mem.eql(u8, b.name, "atomic_cas")) {
        if (b.args.len < 4) return null;
        const ptr = resolveVal(cg, fncg, b.args[0], .{ .ptr = undefined });
        const cmp = resolveVal(cg, fncg, b.args[1], ty);
        const new = resolveVal(cg, fncg, b.args[2], ty);
        const ord = atomicOrdering(b.args[3]);
        const xchg = llvm.LLVMBuildAtomicCmpXchg(bl, ptr, cmp, new, ord, failureOrdering(ord), 0);
        return llvm.LLVMBuildExtractValue(bl, xchg, 0, ""); // {old, i1 success} → old
    }

    // atomic_fence(ord)
    if (std.mem.eql(u8, b.name, "atomic_fence")) {
        if (b.args.len < 1) return null;
        _ = llvm.LLVMBuildFence(bl, atomicOrdering(b.args[0]), 0, "");
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

    // union_literal([field index, value]): the union's bytes zero, then the one field written.
    if (std.mem.eql(u8, b.name, "union_literal")) {
        const name = switch (ty) {
            .struct_type => |n| n,
            else => return null,
        };
        const union_lty = cg.struct_types.get(name) orelse return null;
        const tmp = abi.entryAlloca(cg, fncg.llvm_fn, union_lty);
        _ = llvm.LLVMBuildStore(cg.builder, llvm.LLVMConstNull(union_lty), tmp);
        if (b.args.len == 2) {
            const fields = cg.struct_fields.get(name) orelse return null;
            const index: usize = switch (b.args[0]) {
                .imm => |im| switch (im) {
                    .uint => |u| @intCast(u),
                    .int => |i| @intCast(i),
                    else => return null,
                },
                else => return null,
            };
            if (index >= fields.len) return null;
            const v = resolveVal(cg, fncg, b.args[1], fields[index].ir_ty);
            _ = llvm.LLVMBuildStore(cg.builder, v, tmp);
        }
        return llvm.LLVMBuildLoad2(cg.builder, union_lty, tmp, "");
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

    // Bit builtins (map to LLVM intrinsics)
    if (std.mem.eql(u8, b.name, "count_ones") or std.mem.eql(u8, b.name, "count_zeros")) {
        if (b.args.len < 1) return null;
        var x = resolveVal(cg, fncg, b.args[0], ty);
        if (std.mem.eql(u8, b.name, "count_zeros")) x = llvm.LLVMBuildNot(bl, x, "");
        return emitIntrinsic(cg, "llvm.ctpop", &.{llvm.LLVMTypeOf(x)}, &.{x});
    }
    if (std.mem.eql(u8, b.name, "leading_zeros") or std.mem.eql(u8, b.name, "trailing_zeros")) {
        if (b.args.len < 1) return null;
        const x = resolveVal(cg, fncg, b.args[0], ty);
        const i1f = llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(cg.ctx), 0, 0);
        const nm = if (std.mem.eql(u8, b.name, "leading_zeros")) "llvm.ctlz" else "llvm.cttz";
        return emitIntrinsic(cg, nm, &.{llvm.LLVMTypeOf(x)}, &.{ x, i1f });
    }
    if (std.mem.eql(u8, b.name, "swap_bytes") or std.mem.eql(u8, b.name, "reverse_bits")) {
        if (b.args.len < 1) return null;
        const x = resolveVal(cg, fncg, b.args[0], ty);
        const nm = if (std.mem.eql(u8, b.name, "swap_bytes")) "llvm.bswap" else "llvm.bitreverse";
        return emitIntrinsic(cg, nm, &.{llvm.LLVMTypeOf(x)}, &.{x});
    }
    if (std.mem.eql(u8, b.name, "rotate_left") or std.mem.eql(u8, b.name, "rotate_right")) {
        if (b.args.len < 2) return null;
        const x = resolveVal(cg, fncg, b.args[0], ty);
        const n = resolveVal(cg, fncg, b.args[1], ty);
        const nm = if (std.mem.eql(u8, b.name, "rotate_left")) "llvm.fshl" else "llvm.fshr";
        return emitIntrinsic(cg, nm, &.{llvm.LLVMTypeOf(x)}, &.{ x, x, n });
    }

    // Math builtins
    if (std.mem.eql(u8, b.name, "min") or std.mem.eql(u8, b.name, "max")) {
        if (b.args.len < 2) return null;
        const x = resolveVal(cg, fncg, b.args[0], ty);
        const y = resolveVal(cg, fncg, b.args[1], ty);
        return emitIntrinsic(cg, minMaxIntrinsic(ty, std.mem.eql(u8, b.name, "max")), &.{llvm.LLVMTypeOf(x)}, &.{ x, y });
    }
    if (std.mem.eql(u8, b.name, "clamp")) {
        if (b.args.len < 3) return null;
        const x = resolveVal(cg, fncg, b.args[0], ty);
        const lo = resolveVal(cg, fncg, b.args[1], ty);
        const hi = resolveVal(cg, fncg, b.args[2], ty);
        const xt = llvm.LLVMTypeOf(x);
        const capped = emitIntrinsic(cg, minMaxIntrinsic(ty, false), &.{xt}, &.{ x, hi });
        return emitIntrinsic(cg, minMaxIntrinsic(ty, true), &.{xt}, &.{ capped, lo });
    }
    if (std.mem.eql(u8, b.name, "abs")) {
        if (b.args.len < 1) return null;
        const x = resolveVal(cg, fncg, b.args[0], ty);
        if (isFloat(ty)) return emitIntrinsic(cg, "llvm.fabs", &.{llvm.LLVMTypeOf(x)}, &.{x});
        const i1f = llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(cg.ctx), 0, 0);
        return emitIntrinsic(cg, "llvm.abs", &.{llvm.LLVMTypeOf(x)}, &.{ x, i1f });
    }
    if (unaryFloatIntrinsic(b.name)) |fnm| {
        if (b.args.len < 1) return null;
        const x = resolveVal(cg, fncg, b.args[0], ty);
        return emitIntrinsic(cg, fnm, &.{llvm.LLVMTypeOf(x)}, &.{x});
    }
    if (std.mem.eql(u8, b.name, "pow")) {
        if (b.args.len < 2) return null;
        const x = resolveVal(cg, fncg, b.args[0], ty);
        const y = resolveVal(cg, fncg, b.args[1], ty);
        return emitIntrinsic(cg, "llvm.pow", &.{llvm.LLVMTypeOf(x)}, &.{ x, y });
    }
    if (std.mem.eql(u8, b.name, "fma")) {
        if (b.args.len < 3) return null;
        const a0 = resolveVal(cg, fncg, b.args[0], ty);
        const a1 = resolveVal(cg, fncg, b.args[1], ty);
        const a2 = resolveVal(cg, fncg, b.args[2], ty);
        return emitIntrinsic(cg, "llvm.fma", &.{llvm.LLVMTypeOf(a0)}, &.{ a0, a1, a2 });
    }

    // Memory / control builtins
    if (std.mem.eql(u8, b.name, "memcpy")) {
        if (b.args.len < 3) return null;
        const dst = resolveVal(cg, fncg, b.args[0], .{ .ptr = undefined });
        const src = resolveVal(cg, fncg, b.args[1], .{ .ptr = undefined });
        const n = values.coerce(bl, cg.ctx, resolveVal(cg, fncg, b.args[2], .usize), llvm.LLVMInt64TypeInContext(cg.ctx));
        _ = llvm.LLVMBuildMemCpy(bl, dst, 1, src, 1, n);
        return null;
    }
    if (std.mem.eql(u8, b.name, "memset")) {
        if (b.args.len < 3) return null;
        const dst = resolveVal(cg, fncg, b.args[0], .{ .ptr = undefined });
        const byte = values.coerce(bl, cg.ctx, resolveVal(cg, fncg, b.args[1], .byte), llvm.LLVMInt8TypeInContext(cg.ctx));
        const n = values.coerce(bl, cg.ctx, resolveVal(cg, fncg, b.args[2], .usize), llvm.LLVMInt64TypeInContext(cg.ctx));
        _ = llvm.LLVMBuildMemSet(bl, dst, byte, n, 1);
        return null;
    }
    if (std.mem.eql(u8, b.name, "trap") or std.mem.eql(u8, b.name, "unreachable")) {
        _ = emitIntrinsic(cg, "llvm.trap", &.{}, &.{});
        return null;
    }
    if (std.mem.eql(u8, b.name, "cycle_count")) {
        return emitIntrinsic(cg, "llvm.readcyclecounter", &.{}, &.{});
    }
    if (std.mem.eql(u8, b.name, "prefetch")) {
        if (b.args.len < 1) return null;
        const p = resolveVal(cg, fncg, b.args[0], .{ .ptr = undefined });
        const i32t = llvm.LLVMInt32TypeInContext(cg.ctx);
        // (ptr, rw=read, locality=3, cache=data)
        _ = emitIntrinsic(cg, "llvm.prefetch", &.{llvm.LLVMTypeOf(p)}, &.{
            p,
            llvm.LLVMConstInt(i32t, 0, 0),
            llvm.LLVMConstInt(i32t, 3, 0),
            llvm.LLVMConstInt(i32t, 1, 0),
        });
        return null;
    }

    // catch_handler is an IR marker; the handler CFG is emitted by IR lowering.
    if (std.mem.eql(u8, b.name, "catch_handler")) return null;

    return null; // unknown builtin
}

// Runtime safety checks

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
/// The type of an index's base. A string literal (`"xyz"[1]`, folded to an `.imm.text`) has
/// none recorded, yet it is a `[]const u8`, as `lowerField` reads it.
fn indexBaseType(fncg: anytype, base: ir.Value) ?ir.IrType {
    if (fncg.irTypeOf(base)) |ty| return ty;
    return switch (base) {
        .imm => |im| if (im == .text) str_slice_ty else null,
        else => null,
    };
}

fn emitBoundsCheck(cg: *ModuleCg, fncg: anytype, ix: ir.IndexInstr, location: ir.SourceLocation) void {
    const base_ir_ty = indexBaseType(fncg, ix.base) orelse return;
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

// Compound literals

fn lowerCompoundLiteral(
    cg: *ModuleCg,
    fncg: anytype,
    args: []const ir.Value,
    ty: ir.IrType,
) ?llvm.LLVMValueRef {
    switch (ty) {
        .array => |arr| {
            // The literal supplies the first `n` elements; the REST are zero-filled
            // to the array's declared length. `.{}` therefore zero-inits the whole
            // array (and a partial `.{ a, b }` zeroes the tail) — building only
            // `args.len` elements (the old behavior) produced a `[0 x T]` for `.{}`
            // / left the tail undef, so a stale stack slot leaked through (e.g. a
            // SHA-256 padding buffer not actually cleared on reuse).
            const elem_lty = types.lower(cg, arr.elem.*);
            const total: usize = arr.len;
            const n = @min(args.len, total);

            // `.{}` (empty) → a single `zeroinitializer`, which LLVM lowers a store
            // of to a memset. Otherwise the all-const path below builds a
            // `total`-element ConstArray2 of explicit zeros — O(total) Constants to
            // create and emit, which made `[N]u8 = .{}` codegen pathologically slow
            // for large N (a 4096-byte stack buffer cost ~125 ms on its own).
            if (n == 0) return llvm.LLVMConstNull(types.lower(cg, ty));

            const provided = cg.allocator.alloc(llvm.LLVMValueRef, n) catch return null;
            defer cg.allocator.free(provided);
            var all_const = true;
            for (0..n) |i| {
                provided[i] = resolveVal(cg, fncg, args[i], arr.elem.*);
                if (llvm.LLVMIsConstant(provided[i]) == 0) all_const = false;
            }

            if (all_const) {
                const full = cg.allocator.alloc(llvm.LLVMValueRef, total) catch return null;
                defer cg.allocator.free(full);
                const zero = llvm.LLVMConstNull(elem_lty);
                for (0..total) |i| full[i] = if (i < n) provided[i] else zero;
                return llvm.LLVMConstArray2(elem_lty, full.ptr, @intCast(total));
            }

            // Non-constant elements: start from a fully zeroed array and insert the
            // provided ones, so the unwritten tail stays zero (not undef).
            const arr_ty = types.lower(cg, ty);
            var agg = llvm.LLVMConstNull(arr_ty);
            for (0..n) |i| {
                agg = llvm.LLVMBuildInsertValue(cg.builder, agg, provided[i], @intCast(i), "");
            }
            return agg;
        },
        .struct_type => |name| {
            const struct_lty = cg.struct_types.get(name) orelse return null;
            const fields = cg.struct_fields.get(name) orelse return null;
            if (cg.bitPlaces(name)) |places| {
                const given = cg.allocator.alloc(?llvm.LLVMValueRef, fields.len) catch return null;
                defer cg.allocator.free(given);
                for (given, 0..) |*g, i| g.* = if (i < args.len) resolveVal(cg, fncg, args[i], fields[i].ir_ty) else null;
                return buildBitStruct(cg, fncg, name, places, given);
            }
            // Start zeroed so any field the literal omits (`.{}`, partial `.{ a }`)
            // is zero rather than undef — same fix as the array case above.
            var agg = llvm.LLVMConstNull(struct_lty);
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

// Struct literals (IrInstrKind.struct_lit)

fn lowerStructLit(
    cg: *ModuleCg,
    fncg: anytype,
    sl: ir.StructLitInstr,
    ty: ir.IrType,
) ?llvm.LLVMValueRef {
    const struct_lty = cg.struct_types.get(sl.ty_name) orelse return null;
    const fields = cg.struct_fields.get(sl.ty_name) orelse return null;
    _ = ty;
    if (cg.bitPlaces(sl.ty_name)) |places| {
        const given = cg.allocator.alloc(?llvm.LLVMValueRef, fields.len) catch return null;
        defer cg.allocator.free(given);
        @memset(given, null);
        for (sl.fields) |fv| for (fields, 0..) |fd, i| if (std.mem.eql(u8, fd.name, fv.name)) {
            given[i] = resolveVal(cg, fncg, fv.value, fd.ir_ty);
        };
        return buildBitStruct(cg, fncg, sl.ty_name, places, given);
    }
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

// Atomic helpers

/// Map a fels ordering constant (0=relaxed … 4=seq_cst) to an LLVM atomic ordering.
fn atomicOrdering(arg: ir.Value) c_uint {
    const n: i64 = switch (arg) {
        .imm => |im| switch (im) {
            .int => |v| @intCast(v),
            .uint => |v| @intCast(v),
            else => 4,
        },
        else => 4,
    };
    return switch (n) {
        0 => llvm.LLVMAtomicOrderingMonotonic, // relaxed
        1 => llvm.LLVMAtomicOrderingAcquire,
        2 => llvm.LLVMAtomicOrderingRelease,
        3 => llvm.LLVMAtomicOrderingAcquireRelease,
        else => llvm.LLVMAtomicOrderingSequentiallyConsistent,
    };
}

/// A valid failure ordering for a cmpxchg with the given success ordering: it
/// can't be release/acq_rel and can't be stronger than success.
fn failureOrdering(success: c_uint) c_uint {
    if (success == llvm.LLVMAtomicOrderingSequentiallyConsistent)
        return llvm.LLVMAtomicOrderingSequentiallyConsistent;
    if (success == llvm.LLVMAtomicOrderingAcquire or success == llvm.LLVMAtomicOrderingAcquireRelease)
        return llvm.LLVMAtomicOrderingAcquire;
    return llvm.LLVMAtomicOrderingMonotonic;
}

/// Natural alignment for an atomic of LLVM type `lty` (its ABI size).
fn atomicAlign(cg: *ModuleCg, lty: llvm.LLVMTypeRef) c_uint {
    return @intCast(llvm.LLVMABISizeOfType(cg.targetData(), lty));
}
