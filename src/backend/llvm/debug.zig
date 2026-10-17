//! Debug info (`-g`): each function's name and place, and the line of every instruction, so a
//! debugger shows the source, steps through statements and prints stack traces. CodeView on
//! Windows (the linker writes a PDB), DWARF elsewhere, through LLVM's DIBuilder.

const std = @import("std");
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const build_options = @import("build_options");
const types_mod = @import("types.zig");
const ModuleCg = @import("context.zig").ModuleCg;

pub const DebugCg = struct {
    allocator: std.mem.Allocator,
    di: llvm.LLVMDIBuilderRef,
    cu: llvm.LLVMMetadataRef = null,
    /// Relative source paths are made absolute against this folder, so a debugger finds the
    /// file from anywhere.
    cwd: []const u8,
    /// A DIFile per source path.
    files: std.StringHashMap(llvm.LLVMMetadataRef),
    /// The basic types by name (`i32`), and the structs and enums by IR name.
    basics: std.StringHashMap(llvm.LLVMMetadataRef),
    structs: std.StringHashMap(llvm.LLVMMetadataRef),
    name_buf: [8]u8 = undefined,
    optimized: bool,
    /// The subprogram of the function being defined; null while there is none.
    scope: llvm.LLVMMetadataRef = null,
    /// The line and column set last, so a run of instructions of one statement shares it.
    line: u32 = 0,
    column: u32 = 0,
    finished: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: llvm.LLVMContextRef,
        mod: llvm.LLVMModuleRef,
        root_file: []const u8,
        cwd: []const u8,
        optimized: bool,
        codeview: bool,
    ) DebugCg {
        var self: DebugCg = .{
            .allocator = allocator,
            .di = llvm.LLVMCreateDIBuilder(mod),
            .cwd = cwd,
            .files = std.StringHashMap(llvm.LLVMMetadataRef).init(allocator),
            .basics = std.StringHashMap(llvm.LLVMMetadataRef).init(allocator),
            .structs = std.StringHashMap(llvm.LLVMMetadataRef).init(allocator),
            .optimized = optimized,
        };
        const producer = "fels " ++ build_options.version;
        // There is no DWARF language code for Fels; C is what debuggers handle best.
        self.cu = llvm.LLVMDIBuilderCreateCompileUnit(
            self.di,
            llvm.LLVMDWARFSourceLanguageC99,
            self.file(root_file),
            producer.ptr,
            producer.len,
            @intFromBool(optimized),
            "",
            0,
            0,
            "",
            0,
            llvm.LLVMDWARFEmissionFull,
            0,
            0,
            0,
            "",
            0,
            "",
            0,
        );
        const i32_ty = llvm.LLVMInt32TypeInContext(ctx);
        addFlag(mod, i32_ty, "Debug Info Version", llvm.LLVMDebugMetadataVersion());
        if (codeview) addFlag(mod, i32_ty, "CodeView", 1) else addFlag(mod, i32_ty, "Dwarf Version", 4);
        return self;
    }

    /// The DIFile of `path`.
    fn file(self: *DebugCg, path: []const u8) llvm.LLVMMetadataRef {
        if (self.files.get(path)) |f| return f;
        // LLVM keeps its own copy of the name and the folder.
        const resolved = std.fs.path.resolve(self.allocator, &.{ self.cwd, path }) catch null;
        defer if (resolved) |r| self.allocator.free(r);
        const full = resolved orelse path;
        const name = std.fs.path.basename(full);
        const dir = std.fs.path.dirname(full) orelse "";
        const f = llvm.LLVMDIBuilderCreateFile(self.di, name.ptr, name.len, dir.ptr, dir.len);
        self.files.put(path, f) catch {};
        return f;
    }

    /// Start defining `func` as `llvm_fn`: give it a subprogram, and put what is built first (its
    /// stack slots) on the line of its declaration. A function the compiler made, or one of the
    /// embedded runtime (`<runtime>`), has no source and gets none.
    pub fn begin(self: *DebugCg, builder: llvm.LLVMBuilderRef, ctx: llvm.LLVMContextRef, func: ir.IrFunction, llvm_fn: llvm.LLVMValueRef) void {
        self.scope = null;
        self.line = 0;
        self.column = 0;
        llvm.LLVMSetCurrentDebugLocation2(builder, null);
        if (func.line == 0 or func.file.len == 0 or func.file[0] == '<') return;

        const f = self.file(func.file);
        const ty = llvm.LLVMDIBuilderCreateSubroutineType(self.di, f, null, 0, llvm.LLVMDIFlagZero);
        // `src_main_fels$run` is `run` in the source.
        const name = if (std.mem.lastIndexOfScalar(u8, func.name, '$')) |i| func.name[i + 1 ..] else func.name;
        var link_len: usize = 0;
        const link = llvm.LLVMGetValueName2(llvm_fn, &link_len);
        const local = llvm.LLVMGetLinkage(llvm_fn) == llvm.LLVMInternalLinkage;
        const sp = llvm.LLVMDIBuilderCreateFunction(
            self.di,
            f,
            name.ptr,
            name.len,
            link,
            link_len,
            f,
            func.line,
            ty,
            @intFromBool(local),
            1,
            func.line,
            llvm.LLVMDIFlagPrototyped,
            @intFromBool(self.optimized),
        );
        llvm.LLVMSetSubprogram(llvm_fn, sp);
        self.scope = sp;
        self.at(builder, ctx, func.line, 1);
    }

    /// Put what is built next at `line`:`column` of the function being defined. 0 keeps the
    /// place set last.
    pub fn at(self: *DebugCg, builder: llvm.LLVMBuilderRef, ctx: llvm.LLVMContextRef, line: u32, column: u32) void {
        const sp = self.scope orelse return;
        if (line == 0 or (line == self.line and column == self.column)) return;
        self.line = line;
        self.column = column;
        llvm.LLVMSetCurrentDebugLocation2(builder, llvm.LLVMDIBuilderCreateDebugLocation(ctx, line, column, sp, null));
    }

    /// The function is defined: what is built next belongs to no source line.
    pub fn end(self: *DebugCg, builder: llvm.LLVMBuilderRef) void {
        self.scope = null;
        llvm.LLVMSetCurrentDebugLocation2(builder, null);
    }

    /// Resolve the debug info into the module; it is complete after this.
    pub fn finish(self: *DebugCg) void {
        if (self.finished) return;
        self.finished = true;
        llvm.LLVMDIBuilderFinalize(self.di);
    }

    pub fn deinit(self: *DebugCg) void {
        self.finish();
        llvm.LLVMDisposeDIBuilder(self.di);
        self.files.deinit();
        var it = self.basics.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.basics.deinit();
        self.structs.deinit();
    }

    // Variables

    /// Describe the function's parameters and locals, so a debugger shows their values. Called
    /// once its stack slots exist: `locals` maps a local's IR name (`x`, or `x#2` for one that
    /// shadows another) to its slot, `first` is the first parameter's index in `llvm_fn` (1
    /// behind an `sret` pointer).
    pub fn declareVariables(
        self: *DebugCg,
        cg: *ModuleCg,
        func: ir.IrFunction,
        llvm_fn: llvm.LLVMValueRef,
        first: usize,
        locals: *const std.StringHashMap(llvm.LLVMValueRef),
        local_tys: *const std.StringHashMap(ir.IrType),
    ) void {
        const sp = self.scope orelse return;
        const f = self.file(func.file);
        const entry = llvm.LLVMGetEntryBasicBlock(llvm_fn);
        const expr = llvm.LLVMDIBuilderCreateExpression(self.di, null, 0);

        // A parameter is a value, not a slot: its value at the start of the function.
        var arg_no: c_uint = 0;
        for (func.params, 0..) |p, i| {
            arg_no += 1;
            if (hiddenName(p.name)) continue;
            const ty = self.diType(cg, p.ty) orelse continue;
            const v = llvm.LLVMDIBuilderCreateParameterVariable(self.di, sp, p.name.ptr, p.name.len, arg_no, f, func.line, ty, 1, llvm.LLVMDIFlagZero);
            const loc = llvm.LLVMDIBuilderCreateDebugLocation(cg.ctx, func.line, 1, sp, null);
            _ = llvm.LLVMDIBuilderInsertDbgValueRecordAtEnd(self.di, llvm.LLVMGetParam(llvm_fn, @intCast(first + i)), v, expr, loc, entry);
        }

        // A local lives in its slot, from the line it is declared on.
        var lines = std.StringHashMap(u32).init(self.allocator);
        defer lines.deinit();
        for (func.blocks) |block| for (block.instrs) |instr| switch (instr.kind) {
            .store_local => |sl| if (!lines.contains(sl.name)) lines.put(sl.name, instr.line) catch {},
            else => {},
        };
        var it = locals.iterator();
        while (it.next()) |e| {
            const ir_name = e.key_ptr.*;
            const name = if (std.mem.indexOfScalar(u8, ir_name, '#')) |k| ir_name[0..k] else ir_name;
            if (hiddenName(name)) continue;
            const ir_ty = local_tys.get(ir_name) orelse continue;
            const ty = self.diType(cg, ir_ty) orelse continue;
            const line = lines.get(ir_name) orelse func.line;
            const v = llvm.LLVMDIBuilderCreateAutoVariable(self.di, sp, name.ptr, name.len, f, line, ty, 1, llvm.LLVMDIFlagZero, 0);
            const loc = llvm.LLVMDIBuilderCreateDebugLocation(cg.ctx, line, 1, sp, null);
            _ = llvm.LLVMDIBuilderInsertDeclareRecordAtEnd(self.di, e.value_ptr.*, v, expr, loc, entry);
        }
    }

    // Types

    /// The debug type of `ty`; null for one a debugger has nothing to show of.
    fn diType(self: *DebugCg, cg: *ModuleCg, ty: ir.IrType) ?llvm.LLVMMetadataRef {
        return switch (ty) {
            .i => |bits| self.basic(intName(&self.name_buf, 'i', bits), bits, ate_signed),
            .u => |bits| self.basic(intName(&self.name_buf, 'u', bits), bits, ate_unsigned),
            .usize => self.basic("usize", 64, ate_unsigned),
            .isize => self.basic("isize", 64, ate_signed),
            .addr => self.basic("addr", 64, ate_unsigned),
            .byte => self.basic("byte", 8, ate_unsigned_char),
            .bool => self.basic("bool", 8, ate_boolean),
            .f32 => self.basic("f32", 32, ate_float),
            .f64 => self.basic("f64", 64, ate_float),
            .ptr => |to| blk: {
                const pointee = self.diType(cg, to.*) orelse self.basic("void", 8, ate_unsigned);
                break :blk llvm.LLVMDIBuilderCreatePointerType(self.di, pointee, 64, 64, 0, "", 0);
            },
            .slice, .text => self.sliceType(cg, ty),
            .array => |arr| blk: {
                const elem = self.diType(cg, arr.elem.*) orelse break :blk null;
                const lty = types_mod.lower(cg, ty);
                var range = [_]llvm.LLVMMetadataRef{llvm.LLVMDIBuilderGetOrCreateSubrange(self.di, 0, @intCast(arr.len))};
                break :blk llvm.LLVMDIBuilderCreateArrayType(self.di, sizeOf(cg, lty), alignOf(cg, lty), elem, &range, 1);
            },
            // An enum is a named type in the IR like a struct.
            .struct_type => |name| if (cg.enum_meta.contains(name)) self.enumType(cg, name) else self.structType(cg, name),
            .variant_type => |name| self.enumType(cg, name),
            .optional => |inner| if (inner.* == .ptr) self.diType(cg, inner.*) else self.aggregate(cg, ty, &.{ "has", "value" }),
            .fallible => self.aggregate(cg, ty, &.{ "value", "error", "payload" }),
            .fn_ptr => |fp| if (fp.thin) self.basic("fn", 64, ate_unsigned) else self.aggregate(cg, ty, &.{ "fn", "env" }),
            .interface_value => self.aggregate(cg, ty, &.{ "data", "vtable" }),
            else => null,
        };
    }

    fn basic(self: *DebugCg, name: []const u8, bits: u64, encoding: c_uint) llvm.LLVMMetadataRef {
        if (self.basics.get(name)) |t| return t;
        const t = llvm.LLVMDIBuilderCreateBasicType(self.di, name.ptr, name.len, bits, encoding, llvm.LLVMDIFlagZero);
        const key = self.allocator.dupe(u8, name) catch return t;
        self.basics.put(key, t) catch {};
        return t;
    }

    /// A slice, `{ ptr, len }`.
    fn sliceType(self: *DebugCg, cg: *ModuleCg, ty: ir.IrType) ?llvm.LLVMMetadataRef {
        const elem_ty: ir.IrType = switch (ty) {
            .slice => |e| e.*,
            else => .byte, // a string
        };
        const elem = self.diType(cg, elem_ty) orelse self.basic("byte", 8, ate_unsigned_char);
        const ptr = llvm.LLVMDIBuilderCreatePointerType(self.di, elem, 64, 64, 0, "", 0);
        var members = [_]llvm.LLVMMetadataRef{
            llvm.LLVMDIBuilderCreateMemberType(self.di, self.cu, "ptr", 3, null, 0, 64, 64, 0, llvm.LLVMDIFlagZero, ptr),
            llvm.LLVMDIBuilderCreateMemberType(self.di, self.cu, "len", 3, null, 0, 64, 64, 64, llvm.LLVMDIFlagZero, self.basic("usize", 64, ate_unsigned)),
        };
        const name = if (ty == .text) "[]const u8" else "slice";
        return llvm.LLVMDIBuilderCreateStructType(self.di, self.cu, name.ptr, name.len, null, 0, 128, 64, llvm.LLVMDIFlagZero, null, &members, members.len, 0, null, "", 0);
    }

    /// An aggregate whose fields are those of its LLVM struct, named `names` in order.
    fn aggregate(self: *DebugCg, cg: *ModuleCg, ty: ir.IrType, names: []const []const u8) ?llvm.LLVMMetadataRef {
        const lty = types_mod.lower(cg, ty);
        if (llvm.LLVMGetTypeKind(lty) != llvm.LLVMStructTypeKind) return null;
        const td = cg.targetData();
        const n = @min(llvm.LLVMCountStructElementTypes(lty), names.len);
        var members: [4]llvm.LLVMMetadataRef = undefined;
        for (0..n) |k| {
            const elty = llvm.LLVMStructGetTypeAtIndex(lty, @intCast(k));
            const ety = self.bytes(cg, elty);
            members[k] = llvm.LLVMDIBuilderCreateMemberType(self.di, self.cu, names[k].ptr, names[k].len, null, 0, sizeOf(cg, elty), alignOf(cg, elty), llvm.LLVMOffsetOfElement(td, lty, @intCast(k)) * 8, llvm.LLVMDIFlagZero, ety);
        }
        return llvm.LLVMDIBuilderCreateStructType(self.di, self.cu, "", 0, null, 0, sizeOf(cg, lty), alignOf(cg, lty), llvm.LLVMDIFlagZero, null, &members, @intCast(n), 0, null, "", 0);
    }

    /// A field of an LLVM type as plain bytes or a number of its size.
    fn bytes(self: *DebugCg, cg: *ModuleCg, lty: llvm.LLVMTypeRef) llvm.LLVMMetadataRef {
        const bits = sizeOf(cg, lty);
        const kind = llvm.LLVMGetTypeKind(lty);
        if (kind == llvm.LLVMIntegerTypeKind) return self.basic(intName(&self.name_buf, 'u', bits), bits, ate_unsigned);
        if (kind == llvm.LLVMPointerTypeKind) return self.basic("addr", 64, ate_unsigned);
        var range = [_]llvm.LLVMMetadataRef{llvm.LLVMDIBuilderGetOrCreateSubrange(self.di, 0, @intCast(bits / 8))};
        return llvm.LLVMDIBuilderCreateArrayType(self.di, bits, 8, self.basic("byte", 8, ate_unsigned_char), &range, 1);
    }

    /// A struct, with its fields; a field may point back to the struct, so a forward
    /// declaration stands in for it while its fields are described.
    fn structType(self: *DebugCg, cg: *ModuleCg, name: []const u8) ?llvm.LLVMMetadataRef {
        if (self.structs.get(name)) |t| return t;
        const lty = cg.struct_types.get(name) orelse return null;
        const size = sizeOf(cg, lty);
        const al = alignOf(cg, lty);
        const shown = if (std.mem.lastIndexOfScalar(u8, name, '$')) |k| name[k + 1 ..] else name;
        const fwd = llvm.LLVMDIBuilderCreateReplaceableCompositeType(self.di, tag_structure, shown.ptr, shown.len, self.cu, null, 0, 0, size, al, llvm.LLVMDIFlagZero, name.ptr, name.len);
        self.structs.put(name, fwd) catch {};

        var members: std.ArrayList(llvm.LLVMMetadataRef) = .empty;
        defer members.deinit(self.allocator);
        const union_ = cg.struct_unions.contains(name);
        // A bit-packed struct's fields are bits of a byte array: shown as its bytes for now.
        if (!cg.struct_bits.contains(name)) if (cg.struct_fields.get(name)) |fields| {
            const td = cg.targetData();
            for (fields, 0..) |fld, k| {
                const fty = self.diType(cg, fld.ir_ty) orelse continue;
                const flty = types_mod.lower(cg, fld.ir_ty);
                const offset: u64 = if (union_) 0 else llvm.LLVMOffsetOfElement(td, lty, @intCast(k)) * 8;
                members.append(self.allocator, llvm.LLVMDIBuilderCreateMemberType(self.di, self.cu, fld.name.ptr, fld.name.len, null, 0, sizeOf(cg, flty), alignOf(cg, flty), offset, llvm.LLVMDIFlagZero, fty)) catch {};
            }
        };
        const real = if (union_)
            llvm.LLVMDIBuilderCreateUnionType(self.di, self.cu, shown.ptr, shown.len, null, 0, size, al, llvm.LLVMDIFlagZero, members.items.ptr, @intCast(members.items.len), 0, name.ptr, name.len)
        else
            llvm.LLVMDIBuilderCreateStructType(self.di, self.cu, shown.ptr, shown.len, null, 0, size, al, llvm.LLVMDIFlagZero, null, members.items.ptr, @intCast(members.items.len), 0, null, name.ptr, name.len);
        llvm.LLVMMetadataReplaceAllUsesWith(fwd, real);
        self.structs.put(name, real) catch {};
        return real;
    }

    /// An enum: its variants by name. One whose variants carry payloads is its tag and the
    /// payload's bytes.
    fn enumType(self: *DebugCg, cg: *ModuleCg, name: []const u8) ?llvm.LLVMMetadataRef {
        if (self.structs.get(name)) |t| return t;
        const meta = cg.enum_meta.get(name) orelse return null;
        const shown = if (std.mem.lastIndexOfScalar(u8, name, '$')) |k| name[k + 1 ..] else name;
        var cases: std.ArrayList(llvm.LLVMMetadataRef) = .empty;
        defer cases.deinit(self.allocator);
        var it = meta.discriminants.iterator();
        while (it.next()) |e| cases.append(self.allocator, llvm.LLVMDIBuilderCreateEnumerator(self.di, e.key_ptr.ptr, e.key_ptr.len, e.value_ptr.*, 1)) catch {};
        const u32_ty = self.basic("u32", 32, ate_unsigned);
        const tag = llvm.LLVMDIBuilderCreateEnumerationType(self.di, self.cu, shown.ptr, shown.len, null, 0, 32, 32, cases.items.ptr, @intCast(cases.items.len), u32_ty);
        const t = if (meta.is_simple) tag else blk: {
            const lty = meta.llvm_ty;
            if (llvm.LLVMGetTypeKind(lty) != llvm.LLVMStructTypeKind or llvm.LLVMCountStructElementTypes(lty) < 2) break :blk tag;
            const td = cg.targetData();
            const payload = llvm.LLVMStructGetTypeAtIndex(lty, 1);
            var members = [_]llvm.LLVMMetadataRef{
                llvm.LLVMDIBuilderCreateMemberType(self.di, self.cu, "tag", 3, null, 0, 32, 32, 0, llvm.LLVMDIFlagZero, tag),
                llvm.LLVMDIBuilderCreateMemberType(self.di, self.cu, "payload", 7, null, 0, sizeOf(cg, payload), 8, llvm.LLVMOffsetOfElement(td, lty, 1) * 8, llvm.LLVMDIFlagZero, self.bytes(cg, payload)),
            };
            break :blk llvm.LLVMDIBuilderCreateStructType(self.di, self.cu, shown.ptr, shown.len, null, 0, sizeOf(cg, lty), alignOf(cg, lty), llvm.LLVMDIFlagZero, null, &members, members.len, 0, null, name.ptr, name.len);
        };
        self.structs.put(name, t) catch {};
        return t;
    }
};

// DWARF type encodings and tags.
const ate_boolean: c_uint = 0x02;
const ate_float: c_uint = 0x04;
const ate_signed: c_uint = 0x05;
const ate_unsigned: c_uint = 0x07;
const ate_unsigned_char: c_uint = 0x08;
const tag_structure: c_uint = 0x13;

/// A name the compiler made (`__env`, `__ret`): not shown.
fn hiddenName(name: []const u8) bool {
    return name.len == 0 or std.mem.startsWith(u8, name, "__");
}

fn intName(buf: *[8]u8, sign: u8, bits: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{c}{d}", .{ sign, bits }) catch "int";
}

fn sizeOf(cg: *ModuleCg, lty: llvm.LLVMTypeRef) u64 {
    return llvm.LLVMSizeOfTypeInBits(cg.targetData(), lty);
}

fn alignOf(cg: *ModuleCg, lty: llvm.LLVMTypeRef) u32 {
    return llvm.LLVMABIAlignmentOfType(cg.targetData(), lty) * 8;
}

fn addFlag(mod: llvm.LLVMModuleRef, i32_ty: llvm.LLVMTypeRef, key: []const u8, value: c_uint) void {
    const v = llvm.LLVMValueAsMetadata(llvm.LLVMConstInt(i32_ty, value, 0));
    llvm.LLVMAddModuleFlag(mod, llvm.LLVMModuleFlagBehaviorWarning, key.ptr, key.len, v);
}
