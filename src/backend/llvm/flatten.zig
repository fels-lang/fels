//! Takes slices and structs apart where a debug build would otherwise pass, return, load or
//! store them whole, so that LLVM's fast instruction selector (FastISel) can select the code.
//!
//! The backend handles a slice, an optional, a fallible or a struct as one LLVM value, a
//! "first-class aggregate". FastISel selects none of the instructions that move such a value
//! as a whole: a `ret` of one, an argument or result of a call, a `load`, a `store`, an
//! `insertvalue`. For each, it hands the rest of the block to SelectionDAG, the slow selector,
//! which was most of the time a debug build spent in LLVM. This pass runs on the finished
//! module, at `-O0` only (the optimiser takes the aggregates apart by itself), and rewrites:
//!
//! - A Fels function that is only ever called directly (no pointer to it is taken: not a
//!   closure, an interface method, an entry in static data, a callback for C) takes a small
//!   aggregate parameter as its fields, one parameter each, and returns an aggregate through
//!   a pointer to the caller's slot. At its call sites, the fields come from where they are:
//!   a constant, the fields of a value being built, or loads from memory; the result's fields
//!   are read from the slot. A function whose address is taken keeps its signature, so every
//!   call through a pointer still agrees with its callee.
//! - In every function, a store of an aggregate is a store of each of its fields, and a field
//!   read out of a loaded aggregate is a load of that field.
//!
//! The values do not change, only how they travel: each field is read from memory where the
//! aggregate was read, and stored where it was stored.

const std = @import("std");
const llvm = @import("c_api.zig").llvm;
const abi = @import("abi.zig");
const ModuleCg = @import("context.zig").ModuleCg;

const Ty = llvm.LLVMTypeRef;
const Val = llvm.LLVMValueRef;

/// `LLVMAttributeFunctionIndex`, which the C header writes as -1 for an unsigned parameter.
const fn_index: c_uint = 0xFFFF_FFFF;

/// A parameter is taken apart when it has at most this many fields (a slice has 2, a format
/// `Spec` 7).
const max_param_leaves = 8;
/// A store is split into the stores of its fields when it has at most this many.
const max_store_leaves = 32;

/// Where a field (a leaf: no aggregate inside) sits in an aggregate: its indices, outermost
/// first.
const Path = struct {
    idx: [8]c_uint = undefined,
    len: u8 = 0,

    fn slice(self: *const Path) []const c_uint {
        return self.idx[0..self.len];
    }

    fn child(self: Path, i: c_uint) Path {
        var p = self;
        p.idx[p.len] = i;
        p.len += 1;
        return p;
    }
};

const Pass = struct {
    cg: *ModuleCg,
    /// Builds before the instruction being rewritten.
    b: llvm.LLVMBuilderRef,
    /// Builds the loads of fields right after the load of their aggregate, without moving `b`.
    lb: llvm.LLVMBuilderRef,
    a: std.mem.Allocator,
    td: llvm.LLVMTargetDataRef,
    /// Instructions an erased one used, which may be unused now (`sweep`). An instruction that
    /// is erased leaves it, so nothing here is gone.
    pending: std.AutoArrayHashMapUnmanaged(Val, void) = .empty,

    fn isAggregate(ty: Ty) bool {
        const k = llvm.LLVMGetTypeKind(ty);
        return k == llvm.LLVMStructTypeKind or k == llvm.LLVMArrayTypeKind;
    }

    fn isLeafType(ty: Ty) bool {
        return switch (llvm.LLVMGetTypeKind(ty)) {
            llvm.LLVMIntegerTypeKind, llvm.LLVMPointerTypeKind, llvm.LLVMFloatTypeKind, llvm.LLVMDoubleTypeKind => true,
            else => false,
        };
    }

    /// The fields of `ty` and their paths, or false when it has more than `limit`, an array
    /// inside, or a field that is no plain integer, pointer or float.
    fn leaves(ty: Ty, path: Path, out: *std.ArrayList(Path), a: std.mem.Allocator, limit: usize) bool {
        if (llvm.LLVMGetTypeKind(ty) == llvm.LLVMStructTypeKind) {
            if (path.len == 8) return false;
            const n = llvm.LLVMCountStructElementTypes(ty);
            var i: c_uint = 0;
            while (i < n) : (i += 1) {
                if (!leaves(llvm.LLVMStructGetTypeAtIndex(ty, i), path.child(i), out, a, limit)) return false;
            }
            return true;
        }
        if (!isLeafType(ty)) return false;
        if (out.items.len == limit) return false;
        out.append(a, path) catch return false;
        return true;
    }

    fn typeAt(ty: Ty, path: []const c_uint) Ty {
        var t = ty;
        for (path) |i| t = if (llvm.LLVMGetTypeKind(t) == llvm.LLVMStructTypeKind)
            llvm.LLVMStructGetTypeAtIndex(t, i)
        else
            llvm.LLVMGetElementType(t);
        return t;
    }

    /// The byte offset of `path` in `ty`.
    fn offsetAt(self: *Pass, ty: Ty, path: []const c_uint) u64 {
        var t = ty;
        var off: u64 = 0;
        for (path) |i| {
            if (llvm.LLVMGetTypeKind(t) == llvm.LLVMStructTypeKind) {
                off += llvm.LLVMOffsetOfElement(self.td, t, i);
                t = llvm.LLVMStructGetTypeAtIndex(t, i);
            } else {
                t = llvm.LLVMGetElementType(t);
                off += @as(u64, i) * llvm.LLVMABISizeOfType(self.td, t);
            }
        }
        return off;
    }

    /// The alignment a field at `offset` of something aligned to `base` has for sure.
    fn alignAt(self: *Pass, base: c_uint, offset: u64, ty: Ty) c_uint {
        var al: u64 = if (base == 0) 1 else base;
        while (al > 1 and offset % al != 0) al /= 2;
        const natural = llvm.LLVMABIAlignmentOfType(self.td, ty);
        return @intCast(@min(al, natural));
    }

    fn gep(self: *Pass, b: llvm.LLVMBuilderRef, ty: Ty, ptr: Val, path: []const c_uint) Val {
        var idx: [9]Val = undefined;
        const i32_ty = llvm.LLVMInt32TypeInContext(self.cg.ctx);
        idx[0] = llvm.LLVMConstInt(i32_ty, 0, 0);
        for (path, 0..) |p, i| idx[i + 1] = llvm.LLVMConstInt(i32_ty, p, 0);
        return llvm.LLVMBuildInBoundsGEP2(b, ty, ptr, &idx, @intCast(path.len + 1), "");
    }

    /// Put builder `b` right after `inst`.
    fn after(b: llvm.LLVMBuilderRef, inst: Val) void {
        if (llvm.LLVMGetNextInstruction(inst)) |next|
            llvm.LLVMPositionBuilderBefore(b, next)
        else
            llvm.LLVMPositionBuilderAtEnd(b, llvm.LLVMGetInstructionParent(inst));
    }

    fn isPrefix(short: []const c_uint, long: []const c_uint) bool {
        return short.len <= long.len and std.mem.eql(c_uint, short, long[0..short.len]);
    }

    /// The value of field `path` of the aggregate `v` (of type `ty`), for an instruction the
    /// builder is placed before: an element of a constant, the value an `insertvalue` put
    /// there, a load of the field where `v` was loaded, or else an `extractvalue`.
    fn leafOf(self: *Pass, v: Val, ty: Ty, path: []const c_uint) Val {
        if (path.len == 0) return v;
        if (llvm.LLVMIsConstant(v) != 0) {
            var c = v;
            for (path) |i| {
                c = llvm.LLVMGetAggregateElement(c, i) orelse return self.extract(v, path);
            }
            return c;
        }
        if (llvm.LLVMIsAInsertValueInst(v) != null) {
            const n = llvm.LLVMGetNumIndices(v);
            const idx = llvm.LLVMGetIndices(v)[0..n];
            // the field the insert puts there, or a part of it
            if (isPrefix(idx, path)) return self.leafOf(llvm.LLVMGetOperand(v, 1), typeAt(ty, idx), path[n..]);
            // a field the insert does not touch: as it was before it
            if (!isPrefix(path, idx)) return self.leafOf(llvm.LLVMGetOperand(v, 0), ty, path);
            return self.extract(v, path);
        }
        if (llvm.LLVMIsALoadInst(v) != null and llvm.LLVMGetVolatile(v) == 0) {
            // The field as memory held it when the aggregate was loaded.
            after(self.lb, v);
            const leaf_ty = typeAt(ty, path);
            const field = self.gep(self.lb, ty, llvm.LLVMGetOperand(v, 0), path);
            const load = llvm.LLVMBuildLoad2(self.lb, leaf_ty, field, "");
            llvm.LLVMSetAlignment(load, self.alignAt(llvm.LLVMGetAlignment(v), self.offsetAt(ty, path), leaf_ty));
            return load;
        }
        return self.extract(v, path);
    }

    fn extract(self: *Pass, v: Val, path: []const c_uint) Val {
        var cur = v;
        for (path) |i| cur = llvm.LLVMBuildExtractValue(self.b, cur, i, "");
        return cur;
    }

    /// Store `v`, an aggregate of type `ty`, at `dst` (aligned to `dst_align`), one field at a
    /// time. Fields left undefined (`undef`) are not stored.
    fn storeLeaves(self: *Pass, v: Val, ty: Ty, dst: Val, dst_align: c_uint, paths: []const Path) void {
        for (paths) |p| {
            const leaf = self.leafOf(v, ty, p.slice());
            if (llvm.LLVMIsUndef(leaf) != 0) continue;
            const leaf_ty = typeAt(ty, p.slice());
            const st = llvm.LLVMBuildStore(self.b, leaf, self.gep(self.b, ty, dst, p.slice()));
            llvm.LLVMSetAlignment(st, self.alignAt(dst_align, self.offsetAt(ty, p.slice()), leaf_ty));
        }
    }

    // Functions called only directly

    const Rewrite = struct {
        old: Val,
        new: Val,
        /// The aggregate it returns (through the leading pointer of `new`), or null.
        ret_ty: Ty,
        /// Per old parameter: its fields (taken apart) or null (passed as it was).
        params: []?[]Path,
        param_tys: []Ty,
    };

    fn onlyCalledDirectly(f: Val) bool {
        const fty = llvm.LLVMGlobalGetValueType(f);
        var use = llvm.LLVMGetFirstUse(f);
        if (use == null) return false;
        while (use) |u| : (use = llvm.LLVMGetNextUse(u)) {
            const user = llvm.LLVMGetUser(u);
            if (llvm.LLVMIsACallInst(user) == null) return false;
            if (llvm.LLVMGetCalledValue(user) != f) return false;
            if (llvm.LLVMGetCalledFunctionType(user) != fty) return false;
            const n = llvm.LLVMGetNumArgOperands(user);
            var i: c_uint = 0;
            while (i < n) : (i += 1) if (llvm.LLVMGetOperand(user, i) == f) return false;
        }
        return true;
    }

    fn hasStringAttr(f: Val, name: []const u8) bool {
        return llvm.LLVMGetStringAttributeAtIndex(f, fn_index, name.ptr, @intCast(name.len)) != null;
    }

    /// The new signature of `f`, or null when it keeps its own.
    fn plan(self: *Pass, f: Val) ?Rewrite {
        if (llvm.LLVMIsDeclaration(f) != 0) return null;
        if (llvm.LLVMGetLinkage(f) != llvm.LLVMInternalLinkage) return null;
        const fty = llvm.LLVMGlobalGetValueType(f);
        if (llvm.LLVMIsFunctionVarArg(fty) != 0) return null;
        if (hasStringAttr(f, "naked")) return null;
        if (llvm.LLVMGetFunctionCallConv(f) != llvm.LLVMCCallConv) return null; // `#interrupt`
        if (abi.sretOf(f) != null) return null; // already returns through memory
        if (!onlyCalledDirectly(f)) return null;

        const ret = llvm.LLVMGetReturnType(fty);
        const ret_ty: Ty = if (llvm.LLVMGetTypeKind(ret) == llvm.LLVMStructTypeKind) ret else null;
        const n = llvm.LLVMCountParamTypes(fty);
        const ptys = self.a.alloc(Ty, n) catch return null;
        if (n > 0) llvm.LLVMGetParamTypes(fty, ptys.ptr);
        const params = self.a.alloc(?[]Path, n) catch return null;
        var any = ret_ty != null;
        for (ptys, 0..) |pt, i| {
            params[i] = null;
            if (llvm.LLVMGetTypeKind(pt) != llvm.LLVMStructTypeKind) continue;
            var list: std.ArrayList(Path) = .empty;
            if (leaves(pt, .{}, &list, self.a, max_param_leaves) and list.items.len > 0) {
                params[i] = list.items;
                any = true;
            }
        }
        if (!any) return null;
        return .{ .old = f, .new = null, .ret_ty = ret_ty, .params = params, .param_tys = ptys };
    }

    fn declare(self: *Pass, rw: *Rewrite) void {
        var tys: std.ArrayList(Ty) = .empty;
        const ptr_ty = llvm.LLVMPointerTypeInContext(self.cg.ctx, 0);
        if (rw.ret_ty != null) tys.append(self.a, ptr_ty) catch return;
        for (rw.param_tys, rw.params) |pt, leaves_of| {
            if (leaves_of) |paths| {
                for (paths) |p| tys.append(self.a, typeAt(pt, p.slice())) catch return;
            } else tys.append(self.a, pt) catch return;
        }
        const old_ty = llvm.LLVMGlobalGetValueType(rw.old);
        const ret = if (rw.ret_ty != null) llvm.LLVMVoidTypeInContext(self.cg.ctx) else llvm.LLVMGetReturnType(old_ty);
        const new_ty = llvm.LLVMFunctionType(ret, tys.items.ptr, @intCast(tys.items.len), 0);

        var name_len: usize = 0;
        const name_ptr = llvm.LLVMGetValueName2(rw.old, &name_len);
        const name = self.a.dupeZ(u8, name_ptr[0..name_len]) catch return;
        const old_name = std.fmt.allocPrintSentinel(self.a, "{s}.whole", .{name}, 0) catch return;
        llvm.LLVMSetValueName2(rw.old, old_name.ptr, old_name.len);
        const f = llvm.LLVMAddFunction(self.cg.mod, name.ptr, new_ty);
        llvm.LLVMSetLinkage(f, llvm.LLVMInternalLinkage);
        // the function's own attributes (`noinline`, `noreturn`, ...)
        const fi = fn_index;
        const count = llvm.LLVMGetAttributeCountAtIndex(rw.old, fi);
        if (count > 0) {
            const attrs = self.a.alloc(llvm.LLVMAttributeRef, count) catch return;
            llvm.LLVMGetAttributesAtIndex(rw.old, fi, attrs.ptr);
            for (attrs) |at| llvm.LLVMAddAttributeAtIndex(f, fi, at);
        }
        abi.markBoolExt(self.cg, f);
        if (rw.ret_ty != null) {
            const no_alias = llvm.LLVMGetEnumAttributeKindForName("noalias", 7);
            llvm.LLVMAddAttributeAtIndex(f, 1, llvm.LLVMCreateEnumAttribute(self.cg.ctx, no_alias, 0));
        }
        rw.new = f;
    }

    /// Call `rw.new` in place of the call `call` of `rw.old`.
    fn rewriteCall(self: *Pass, rw: *const Rewrite, call: Val) void {
        llvm.LLVMPositionBuilderBefore(self.b, call);
        var args: std.ArrayList(Val) = .empty;
        const caller = llvm.LLVMGetBasicBlockParent(llvm.LLVMGetInstructionParent(call));
        var slot: Val = null;
        if (rw.ret_ty) |rt| {
            slot = abi.entryAlloca(self.cg, caller, rt);
            args.append(self.a, slot) catch return;
        }
        for (rw.param_tys, rw.params, 0..) |pt, leaves_of, i| {
            const arg = llvm.LLVMGetOperand(call, @intCast(i));
            if (leaves_of) |paths| {
                for (paths) |p| args.append(self.a, self.leafOf(arg, pt, p.slice())) catch return;
            } else args.append(self.a, arg) catch return;
        }
        llvm.LLVMPositionBuilderBefore(self.b, call);
        const new_ty = llvm.LLVMGlobalGetValueType(rw.new);
        const new_call = llvm.LLVMBuildCall2(self.b, new_ty, rw.new, args.items.ptr, @intCast(args.items.len), "");
        abi.markCallBoolExt(self.cg, new_call, new_ty);

        if (rw.ret_ty) |rt| {
            // The result's fields are read from the slot, right after the call.
            var uses: std.ArrayList(Val) = .empty;
            var use = llvm.LLVMGetFirstUse(call);
            while (use) |u| : (use = llvm.LLVMGetNextUse(u)) uses.append(self.a, llvm.LLVMGetUser(u)) catch return;
            var whole: Val = null;
            for (uses.items) |user| {
                if (llvm.LLVMIsAExtractValueInst(user) != null and llvm.LLVMGetOperand(user, 0) == call) {
                    const n = llvm.LLVMGetNumIndices(user);
                    const idx = llvm.LLVMGetIndices(user)[0..n];
                    after(self.b, new_call);
                    const fty = typeAt(rt, idx);
                    const ld = llvm.LLVMBuildLoad2(self.b, fty, self.gep(self.b, rt, slot, idx), "");
                    llvm.LLVMSetAlignment(ld, self.alignAt(llvm.LLVMGetAlignment(slot), self.offsetAt(rt, idx), fty));
                    llvm.LLVMReplaceAllUsesWith(user, ld);
                    self.erase(user);
                } else if (whole == null) {
                    after(self.b, new_call);
                    whole = llvm.LLVMBuildLoad2(self.b, rt, slot, "");
                    llvm.LLVMSetAlignment(whole, llvm.LLVMGetAlignment(slot));
                }
            }
            if (whole) |w| llvm.LLVMReplaceAllUsesWith(call, w);
        } else if (llvm.LLVMGetFirstUse(call) != null) {
            llvm.LLVMReplaceAllUsesWith(call, new_call);
        }
        self.erase(call);
    }

    /// Move the body of `rw.old` into `rw.new`, its parameters taken apart and its returns
    /// stored through the leading pointer.
    fn moveBody(self: *Pass, rw: *const Rewrite) void {
        var blocks: std.ArrayList(llvm.LLVMBasicBlockRef) = .empty;
        var bb = llvm.LLVMGetFirstBasicBlock(rw.old);
        while (bb) |blk| : (bb = llvm.LLVMGetNextBasicBlock(blk)) blocks.append(self.a, blk) catch return;
        for (blocks.items) |blk| {
            llvm.LLVMRemoveBasicBlockFromParent(blk);
            llvm.LLVMAppendExistingBasicBlock(rw.new, blk);
        }
        // The debug info goes with the body: its lines are in the old function's subprogram.
        if (llvm.LLVMGetSubprogram(rw.old)) |sp| {
            llvm.LLVMSetSubprogram(rw.new, sp);
            llvm.LLVMSetSubprogram(rw.old, null);
        }
        const entry = llvm.LLVMGetEntryBasicBlock(rw.new);

        // Parameters: a taken-apart one is rebuilt only where it is used whole.
        var next: c_uint = if (rw.ret_ty != null) 1 else 0;
        for (rw.param_tys, rw.params, 0..) |pt, leaves_of, i| {
            const old_param = llvm.LLVMGetParam(rw.old, @intCast(i));
            if (leaves_of) |paths| {
                const first_leaf = next;
                next += @intCast(paths.len);
                var uses: std.ArrayList(Val) = .empty;
                var use = llvm.LLVMGetFirstUse(old_param);
                while (use) |u| : (use = llvm.LLVMGetNextUse(u)) uses.append(self.a, llvm.LLVMGetUser(u)) catch return;
                var whole: Val = null;
                for (uses.items) |user| {
                    if (llvm.LLVMIsAExtractValueInst(user) != null and llvm.LLVMGetOperand(user, 0) == old_param) {
                        const n = llvm.LLVMGetNumIndices(user);
                        const idx = llvm.LLVMGetIndices(user)[0..n];
                        for (paths, 0..) |p, k| if (std.mem.eql(c_uint, p.slice(), idx)) {
                            llvm.LLVMReplaceAllUsesWith(user, llvm.LLVMGetParam(rw.new, first_leaf + @as(c_uint, @intCast(k))));
                            self.erase(user);
                            break;
                        };
                    }
                }
                if (llvm.LLVMGetFirstUse(old_param) != null) {
                    // (the first instruction now: the reads of fields above may have been it)
                    if (llvm.LLVMGetFirstInstruction(entry)) |f| llvm.LLVMPositionBuilderBefore(self.b, f) else llvm.LLVMPositionBuilderAtEnd(self.b, entry);
                    whole = llvm.LLVMGetUndef(pt);
                    for (paths, 0..) |p, k| {
                        whole = self.insertAt(whole, pt, p.slice(), llvm.LLVMGetParam(rw.new, first_leaf + @as(c_uint, @intCast(k))));
                    }
                    llvm.LLVMReplaceAllUsesWith(old_param, whole);
                }
            } else {
                llvm.LLVMReplaceAllUsesWith(old_param, llvm.LLVMGetParam(rw.new, next));
                next += 1;
            }
        }

        // Returns: through the leading pointer.
        if (rw.ret_ty) |rt| {
            const out = llvm.LLVMGetParam(rw.new, 0);
            var ret_paths: std.ArrayList(Path) = .empty;
            const splittable = leaves(rt, .{}, &ret_paths, self.a, max_store_leaves);
            var rets: std.ArrayList(Val) = .empty;
            var blk = llvm.LLVMGetFirstBasicBlock(rw.new);
            while (blk) |b2| : (blk = llvm.LLVMGetNextBasicBlock(b2)) {
                const term = llvm.LLVMGetBasicBlockTerminator(b2) orelse continue;
                if (llvm.LLVMIsAReturnInst(term) != null) rets.append(self.a, term) catch return;
            }
            for (rets.items) |r| {
                llvm.LLVMPositionBuilderBefore(self.b, r);
                const v = llvm.LLVMGetOperand(r, 0);
                const out_align = llvm.LLVMABIAlignmentOfType(self.td, rt);
                if (splittable)
                    self.storeLeaves(v, rt, out, out_align, ret_paths.items)
                else {
                    const st = llvm.LLVMBuildStore(self.b, v, out);
                    llvm.LLVMSetAlignment(st, out_align);
                }
                llvm.LLVMPositionBuilderBefore(self.b, r);
                _ = llvm.LLVMBuildRetVoid(self.b);
                self.erase(r);
            }
        }
    }

    fn insertAt(self: *Pass, agg: Val, ty: Ty, path: []const c_uint, v: Val) Val {
        if (path.len == 1) return llvm.LLVMBuildInsertValue(self.b, agg, v, path[0], "");
        const inner = llvm.LLVMBuildExtractValue(self.b, agg, path[0], "");
        const updated = self.insertAt(inner, typeAt(ty, path[0..1]), path[1..], v);
        return llvm.LLVMBuildInsertValue(self.b, agg, updated, path[0], "");
    }

    // Every function: stores and field reads

    fn splitStores(self: *Pass, f: Val) void {
        var stores: std.ArrayList(Val) = .empty;
        var reads: std.ArrayList(Val) = .empty;
        var bb = llvm.LLVMGetFirstBasicBlock(f);
        while (bb) |blk| : (bb = llvm.LLVMGetNextBasicBlock(blk)) {
            var inst = llvm.LLVMGetFirstInstruction(blk);
            while (inst) |i| : (inst = llvm.LLVMGetNextInstruction(i)) {
                if (llvm.LLVMIsAStoreInst(i) != null) {
                    if (llvm.LLVMGetVolatile(i) == 0 and isAggregate(llvm.LLVMTypeOf(llvm.LLVMGetOperand(i, 0))))
                        stores.append(self.a, i) catch return;
                } else if (llvm.LLVMIsAExtractValueInst(i) != null) {
                    const agg = llvm.LLVMGetOperand(i, 0);
                    if (llvm.LLVMIsALoadInst(agg) != null and llvm.LLVMGetVolatile(agg) == 0)
                        reads.append(self.a, i) catch return;
                }
            }
        }
        for (stores.items) |st| {
            const v = llvm.LLVMGetOperand(st, 0);
            const ty = llvm.LLVMTypeOf(v);
            if (llvm.LLVMIsNull(v) != 0) {
                llvm.LLVMPositionBuilderBefore(self.b, st);
                self.fill(llvm.LLVMGetOperand(st, 1), llvm.LLVMABISizeOfType(self.td, ty), llvm.LLVMGetAlignment(st));
                self.erase(st);
                continue;
            }
            if (llvm.LLVMGetTypeKind(ty) != llvm.LLVMStructTypeKind) continue;
            var paths: std.ArrayList(Path) = .empty;
            if (!leaves(ty, .{}, &paths, self.a, max_store_leaves)) continue;
            llvm.LLVMPositionBuilderBefore(self.b, st);
            self.storeLeaves(v, ty, llvm.LLVMGetOperand(st, 1), llvm.LLVMGetAlignment(st), paths.items);
            self.erase(st);
        }
        for (reads.items) |ev| {
            const ld = llvm.LLVMGetOperand(ev, 0);
            const n = llvm.LLVMGetNumIndices(ev);
            const idx = llvm.LLVMGetIndices(ev)[0..n];
            llvm.LLVMPositionBuilderBefore(self.b, ev);
            const leaf = self.leafOf(ld, llvm.LLVMTypeOf(ld), idx);
            llvm.LLVMReplaceAllUsesWith(ev, leaf);
            self.erase(ev);
        }
    }

    /// `memset(dst, 0, size)`, which FastISel selects (as stores, or a call of the program's
    /// `memset` for a large one).
    fn fill(self: *Pass, dst: Val, size: u64, alignment: c_uint) void {
        const ctx = self.cg.ctx;
        const ptr_ty = llvm.LLVMPointerTypeInContext(ctx, 0);
        const i64_ty = llvm.LLVMInt64TypeInContext(ctx);
        var overloads = [_]Ty{ ptr_ty, i64_ty };
        const name = "llvm.memset";
        const f = llvm.LLVMGetIntrinsicDeclaration(self.cg.mod, llvm.LLVMLookupIntrinsicID(name.ptr, name.len), &overloads, overloads.len);
        var args = [_]Val{ dst, llvm.LLVMConstInt(llvm.LLVMInt8TypeInContext(ctx), 0, 0), llvm.LLVMConstInt(i64_ty, size, 0), llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(ctx), 0, 0) };
        const call = llvm.LLVMBuildCall2(self.b, llvm.LLVMGlobalGetValueType(f), f, &args, args.len, "");
        if (alignment > 1) {
            const kind = llvm.LLVMGetEnumAttributeKindForName("align", 5);
            llvm.LLVMAddCallSiteAttribute(call, 1, llvm.LLVMCreateEnumAttribute(ctx, kind, alignment));
        }
    }

    /// An instruction without side effects, which may go when nothing uses it.
    fn removable(v: Val) bool {
        if (llvm.LLVMIsAInstruction(v) == null) return false;
        return (llvm.LLVMIsALoadInst(v) != null and llvm.LLVMGetVolatile(v) == 0) or
            llvm.LLVMIsAInsertValueInst(v) != null or llvm.LLVMIsAExtractValueInst(v) != null or
            llvm.LLVMIsAGetElementPtrInst(v) != null;
    }

    /// Erase `inst`, and remember what it used: the loads and `insertvalue`s of the aggregates
    /// taken apart, which nothing may use any more.
    fn erase(self: *Pass, inst: Val) void {
        const n: c_uint = @intCast(llvm.LLVMGetNumOperands(inst));
        var i: c_uint = 0;
        while (i < n) : (i += 1) {
            const op = llvm.LLVMGetOperand(inst, i);
            if (op != null and op != inst and removable(op)) self.pending.put(self.a, op, {}) catch {};
        }
        _ = self.pending.swapRemove(inst);
        llvm.LLVMInstructionEraseFromParent(inst);
    }

    /// Erase what `erase` remembered that nothing uses, and what that used in turn.
    fn sweep(self: *Pass) void {
        while (self.pending.pop()) |entry| {
            const v = entry.key;
            if (removable(v) and llvm.LLVMGetFirstUse(v) == null) self.erase(v);
        }
    }
};

/// Run the pass over the module of `cg` (a debug build's, before it is emitted).
pub fn run(cg: *ModuleCg) void {
    var arena = std.heap.ArenaAllocator.init(cg.allocator);
    defer arena.deinit();
    const b = llvm.LLVMCreateBuilderInContext(cg.ctx);
    defer llvm.LLVMDisposeBuilder(b);
    const lb = llvm.LLVMCreateBuilderInContext(cg.ctx);
    defer llvm.LLVMDisposeBuilder(lb);
    var pass: Pass = .{ .cg = cg, .b = b, .lb = lb, .a = arena.allocator(), .td = cg.targetData() };

    // 1. The functions to rewrite, with their new declarations.
    var rewrites: std.ArrayList(Pass.Rewrite) = .empty;
    var f = llvm.LLVMGetFirstFunction(cg.mod);
    while (f) |fv| : (f = llvm.LLVMGetNextFunction(fv)) {
        if (pass.plan(fv)) |rw| rewrites.append(pass.a, rw) catch return;
    }
    for (rewrites.items) |*rw| pass.declare(rw);

    // 2. Their call sites (first, so a function whose result goes to another's return is seen
    // as the load from the slot it then is).
    for (rewrites.items) |*rw| {
        if (rw.new == null) continue;
        var calls: std.ArrayList(Val) = .empty;
        var use = llvm.LLVMGetFirstUse(rw.old);
        while (use) |u| : (use = llvm.LLVMGetNextUse(u)) calls.append(pass.a, llvm.LLVMGetUser(u)) catch return;
        for (calls.items) |call| pass.rewriteCall(rw, call);
    }

    // 3. Their bodies, then the old functions go (and the backend's table of functions names
    // the new ones).
    var renamed: std.AutoHashMapUnmanaged(Val, Val) = .empty;
    for (rewrites.items) |*rw| {
        if (rw.new == null) continue;
        pass.moveBody(rw);
        renamed.put(pass.a, rw.old, rw.new) catch {};
    }
    var it = cg.fn_decls.valueIterator();
    while (it.next()) |v| if (renamed.get(v.*)) |new| {
        v.* = new;
    };
    for (rewrites.items) |*rw| if (rw.new != null) llvm.LLVMDeleteFunction(rw.old);

    // 4. Stores and field reads everywhere.
    f = llvm.LLVMGetFirstFunction(cg.mod);
    while (f) |fv| : (f = llvm.LLVMGetNextFunction(fv)) {
        if (llvm.LLVMIsDeclaration(fv) == 0) pass.splitStores(fv);
    }
    pass.sweep();
}
