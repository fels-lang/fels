//! Slab: a program as flat arrays, the input of the Obsidian backend.
//!
//! The IR is built for the compiler's convenience: a local is a string, an instruction a tagged
//! union holding slices, a type a tree of pointers. A code generator that reads it looks every
//! value up by name. Slab is the same program frozen into arrays of plain integers, so that a
//! backend streams through it and finds everything by index, and so that it crosses a C ABI as it
//! is: Obsidian, written in Fels, reads a `Slab` through pointers and lengths.
//!
//! - Every name is a `StrId` into one string pool, every type a `TypeId` into one type table that
//!   also holds the type's size and alignment (from `layout.zig`, the rules LLVM follows).
//! - Instructions of all functions sit in one set of parallel arrays (`Instrs`), a function's
//!   blocks are ranges of it, and a block's last instruction is its terminator.
//! - An operand is one `u32` (`Operand`): a register, parameter, local or constant by its index in
//!   the function or the module, or a global by its name.
//! - Lists an instruction carries (a call's arguments, a struct literal's fields) are runs of the
//!   `extra` array, which start with their length.
//!
//! `build` makes a Slab from an IR module and `toIr` makes the IR back from it, which is how the
//! format is checked to hold everything: a module that goes through both and is compiled must
//! behave as the original (`FELS_SLAB_ROUNDTRIP`, see `driver.zig`).

const std = @import("std");
const ir = @import("ir.zig");
const layout = @import("layout.zig");

/// "Nothing here": an absent name, type, operand or layout.
pub const none: u32 = 0xFFFF_FFFF;

pub const StrId = u32;
pub const TypeId = u32;
pub const ConstId = u32;

// Strings

pub const Str = extern struct { off: u32, len: u32 };

// Types

pub const TypeKind = enum(u8) {
    void,
    bool,
    int,
    uint,
    f32,
    f64,
    byte,
    usize,
    isize,
    addr,
    text,
    rune,
    zone,
    opaque_type,
    ptr,
    optional,
    slice,
    array,
    range,
    struct_type,
    variant_type,
    fallible,
    fn_ptr,
    interface_value,
    list,
    map,
    unknown,
};

/// A type. What `a`, `b` and `c` hold depends on `kind`:
/// - `int`, `uint`: `bits` is the width.
/// - `ptr`, `optional`, `slice`, `range`, `list`, `map`: `a` is the element type.
/// - `array`: `a` is the element type, `b` and `c` the low and high halves of the length.
/// - `struct_type`, `variant_type`, `interface_value`, `opaque_type`: `a` is the name.
/// - `fallible`: `a` is the success type, `b` the error type.
/// - `fn_ptr`: `a` is the start of its parameter types in `type_lists`, `b` their count, `c` the
///   return type; `flags` bit 0 says it is a thin pointer (a bare address).
/// `size` and `alignment` are its layout in bytes, or `none` when `layout.zig` does not model it.
pub const Type = extern struct {
    kind: TypeKind,
    flags: u8 = 0,
    bits: u16 = 0,
    a: u32 = none,
    b: u32 = none,
    c: u32 = none,
    size: u32 = none,
    alignment: u32 = none,
};

// Operands

pub const OperandKind = enum(u3) { reg, param, local, global, constant };

/// One operand: its kind in the top three bits, its index below. A register is numbered within its
/// function (0, 1, 2, ... in order of definition), a parameter and a local by their position in
/// the function's lists, a constant by its place in `consts`, a global (a function or a global
/// variable) by its name's `StrId`. `none` is no operand.
pub const Operand = u32;

pub fn operand(kind: OperandKind, index: u32) Operand {
    std.debug.assert(index < (1 << 29));
    return (@as(u32, @intFromEnum(kind)) << 29) | index;
}

pub fn kindOf(o: Operand) OperandKind {
    return @enumFromInt(o >> 29);
}

pub fn indexOf(o: Operand) u32 {
    return o & ((1 << 29) - 1);
}

// Constants

pub const ConstKind = enum(u8) { int, uint, float, bool, text, rune, null_ };

/// A constant: an integer in `lo` (and `hi`, the high half of 128 bits), a float's bits in `lo`,
/// a bool or a rune in `lo`, a text's `StrId` in `lo`.
pub const Const = extern struct {
    kind: ConstKind,
    _pad: [7]u8 = .{0} ** 7,
    lo: u64 = 0,
    hi: u64 = 0,
};

// Instructions

/// What an instruction does. The first part is the IR's instructions, in `ir.InstrKind`'s order;
/// the second the terminators, one of which ends each block. The operands of each:
///
/// | op | sub | a | b | c |
/// |---|---|---|---|---|
/// | const_value | | const | | |
/// | unary | `ir.UnaryOp` | value | | |
/// | binary | `ir.BinOp` | lhs | rhs | |
/// | cast | `ir.CastKind` | value | | |
/// | call | | callee (str) | extra: [n, args...] | |
/// | call_indirect | 1 = closure | callee | extra: [n, args..., m, param types...] | |
/// | builtin | | name (str) | extra: [n, args...] | type argument or none |
/// | inline_asm | 1 = volatile | template (str) | constraints (str) | extra: [n, args...] |
/// | struct_lit | | type name (str) | extra: [n, (field name, value)...] | |
/// | variant_lit | | type name (str) | variant (str) | payload or none |
/// | field, field_addr | | base | field name (str) | |
/// | index, index_addr | 1 = checked | base | index | |
/// | slice_expr | | ptr | len | |
/// | variant_is, variant_payload, variant_tag | | value | type name (str) | variant (str) |
/// | optional_is_some ... iter_next, interface_data | | value | | |
/// | alloc | | type | zone (str) | |
/// | alloc_slice | | element type | count | zone (str) |
/// | zone_push | | name (str) | kind (str) | |
/// | zone_pop | | name (str) | | |
/// | zone_free | | zone (str) | ptr | |
/// | at | | value | zone (str) | |
/// | raw_pointer | | type | address | |
/// | interface_make | | data | vtable (str) | |
/// | interface_method | | value | method index | |
/// | closure_make | 1 = takes env | function (str) | env | |
/// | closure_env_make | | extra: [n, (value, type)...] | arena | alloc function (str) |
/// | closure_env_load | | env | field index | extra: [n, types...] |
/// | store_local | | local | value | |
/// | global_load | | name (str) | | |
/// | global_store | | name (str) | value | |
/// | store | | target | value | |
/// | ret | | value or none | | |
/// | fail | | error number | whole error or none | |
/// | panic | | message (str) | | |
/// | br | | block | | |
/// | cond_br | | condition | then block | else block |
/// | unreachable_term, no_term | | | | |
///
/// A block is given by its index in the function's blocks. A type operand is a `TypeId`, a field
/// or method index a plain number.
pub const Op = enum(u8) {
    const_value,
    unary,
    binary,
    cast,
    call,
    call_indirect,
    builtin,
    inline_asm,
    struct_lit,
    variant_lit,
    field,
    field_addr,
    index,
    index_addr,
    slice_expr,
    variant_is,
    variant_payload,
    variant_tag,
    optional_is_some,
    optional_payload,
    try_is_ok,
    try_ok,
    try_err,
    iter_init,
    iter_has_next,
    iter_next,
    alloc,
    alloc_slice,
    zone_push,
    zone_pop,
    zone_free,
    at,
    raw_pointer,
    interface_make,
    interface_data,
    interface_method,
    closure_make,
    closure_env_make,
    closure_env_load,
    store_local,
    global_load,
    global_store,
    store,
    // terminators
    ret,
    fail,
    panic,
    br,
    cond_br,
    unreachable_term,
    /// A block the IR left without a terminator.
    no_term,
};

/// All instructions of the module, as parallel arrays: instruction `i` is `op[i]`, `sub[i]`,
/// `ty[i]` (its result type), `dst[i]` (the register it defines, or `none`), its operands `a[i]`,
/// `b[i]`, `c[i]`, and where it comes from: `file[i]` (a `StrId`), `line[i]`, `col[i]`.
pub const Instrs = struct {
    op: []Op,
    sub: []u8,
    ty: []TypeId,
    dst: []u32,
    a: []u32,
    b: []u32,
    c: []u32,
    file: []StrId,
    line: []u32,
    col: []u32,
};

// Functions

pub const fn_flag = struct {
    pub const inline_hint: u32 = 1 << 0;
    pub const no_inline: u32 = 1 << 1;
    pub const no_return: u32 = 1 << 2;
    pub const entry: u32 = 1 << 3;
    pub const naked: u32 = 1 << 4;
    pub const cold: u32 = 1 << 5;
    pub const weak: u32 = 1 << 6;
    pub const keep: u32 = 1 << 7;
};

/// A function: its names and flags, its return and error types (`err` is `none` when it cannot
/// fail), and ranges of `params`, `blocks` and `locals`. `regs` is how many registers it defines.
/// An extern function has no blocks.
pub const Function = extern struct {
    name: StrId,
    flags: u32 = 0,
    extern_name: StrId = none,
    extern_lib: StrId = none,
    export_sym: StrId = none,
    section: StrId = none,
    link_name: StrId = none,
    ret: TypeId,
    err: TypeId = none,
    params_start: u32,
    params_len: u32,
    blocks_start: u32,
    blocks_len: u32,
    locals_start: u32,
    locals_len: u32,
    regs: u32,
};

pub const Param = extern struct { name: StrId, ty: TypeId };

/// A local's name, and its type: that of the first store to it, as the slot is laid out.
pub const Local = extern struct { name: StrId, ty: TypeId };

/// A block: the IR's id and name, and its instructions, `len` of them from `first` (the last one
/// is its terminator).
pub const Block = extern struct { id: u32, name: StrId, first: u32, len: u32 };

// Data

/// One node of a global's initial value. What `a`, `b` and `c` hold depends on `kind`:
/// `imm`: a const; `struct_init`: the type name, and extra [n, (field name, node)...];
/// `array_init`: extra [n, nodes...]; `func_ref`, `global_addr`: a name; `variant_tag`: the tag;
/// `variant`: the tag, the payload's node, and its type.
pub const InitKind = enum(u8) { imm, struct_init, array_init, zero, func_ref, global_addr, variant_tag, variant, pending };

pub const Init = extern struct { kind: InitKind, a: u32 = none, b: u32 = none, c: u32 = none };

pub const Global = extern struct {
    name: StrId,
    ty: TypeId,
    init: u32,
    mutable: u32,
    export_sym: StrId = none,
};

pub const Struct = extern struct {
    name: StrId,
    fields_start: u32,
    fields_len: u32,
    /// bit 0: `#packed`, bit 1: a `union`.
    flags: u32,
    /// `#align(N)`, 0 when not given.
    alignment: u32,
};

/// A field: its name, its type, and its byte offset (`none` when not modelled; the byte its first
/// bit is in for a bit-packed struct).
pub const Field = extern struct { name: StrId, ty: TypeId, offset: u32 };

pub const ErrorSet = extern struct { name: StrId, cases_start: u32, cases_len: u32 };
pub const ErrorCase = extern struct { name: StrId, payload: TypeId };

pub const Variant = extern struct { name: StrId, cases_start: u32, cases_len: u32 };
pub const VariantCase = extern struct { name: StrId, payload: TypeId, disc: u32 };

pub const VTable = extern struct { name: StrId, methods_start: u32, methods_len: u32 };

// The module

pub const Slab = struct {
    file_name: StrId,
    bytes: []u8,
    strs: []Str,
    types: []Type,
    /// Lists of types (a function pointer's parameters).
    type_lists: []TypeId,
    consts: []Const,
    instrs: Instrs,
    extra: []u32,
    functions: []Function,
    params: []Param,
    locals: []Local,
    blocks: []Block,
    globals: []Global,
    inits: []Init,
    structs: []Struct,
    fields: []Field,
    errors: []ErrorSet,
    error_cases: []ErrorCase,
    variants: []Variant,
    variant_cases: []VariantCase,
    vtables: []VTable,
    /// Lists of names (a vtable's methods, the extern libraries).
    names: []StrId,
    extern_libs_start: u32,
    extern_libs_len: u32,

    pub fn str(self: *const Slab, id: StrId) []const u8 {
        const s = self.strs[id];
        return self.bytes[s.off..][0..s.len];
    }

    pub fn deinit(self: *Slab, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        gpa.free(self.strs);
        gpa.free(self.types);
        gpa.free(self.type_lists);
        gpa.free(self.consts);
        inline for (std.meta.fields(Instrs)) |f| gpa.free(@field(self.instrs, f.name));
        gpa.free(self.extra);
        gpa.free(self.functions);
        gpa.free(self.params);
        gpa.free(self.locals);
        gpa.free(self.blocks);
        gpa.free(self.globals);
        gpa.free(self.inits);
        gpa.free(self.structs);
        gpa.free(self.fields);
        gpa.free(self.errors);
        gpa.free(self.error_cases);
        gpa.free(self.variants);
        gpa.free(self.variant_cases);
        gpa.free(self.vtables);
        gpa.free(self.names);
        self.* = undefined;
    }
};

// Building a Slab from IR

pub const BuildError = error{ OutOfMemory, UnknownParam, UnknownBlock };

const TypeKey = struct { kind: TypeKind, flags: u8, bits: u16, a: u32, b: u32, c: u32 };

const Builder = struct {
    gpa: std.mem.Allocator,
    module: ir.IrModule,
    bytes: std.ArrayList(u8) = .empty,
    strs: std.ArrayList(Str) = .empty,
    str_ids: std.StringHashMapUnmanaged(StrId) = .empty,
    types: std.ArrayList(Type) = .empty,
    type_ids: std.AutoHashMapUnmanaged(TypeKey, TypeId) = .empty,
    type_lists: std.ArrayList(TypeId) = .empty,
    consts: std.ArrayList(Const) = .empty,
    op: std.ArrayList(Op) = .empty,
    sub: std.ArrayList(u8) = .empty,
    ty: std.ArrayList(TypeId) = .empty,
    dst: std.ArrayList(u32) = .empty,
    a: std.ArrayList(u32) = .empty,
    b: std.ArrayList(u32) = .empty,
    c: std.ArrayList(u32) = .empty,
    file: std.ArrayList(StrId) = .empty,
    line: std.ArrayList(u32) = .empty,
    col: std.ArrayList(u32) = .empty,
    extra: std.ArrayList(u32) = .empty,
    functions: std.ArrayList(Function) = .empty,
    params: std.ArrayList(Param) = .empty,
    locals: std.ArrayList(Local) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    globals: std.ArrayList(Global) = .empty,
    inits: std.ArrayList(Init) = .empty,
    structs: std.ArrayList(Struct) = .empty,
    fields: std.ArrayList(Field) = .empty,
    errors: std.ArrayList(ErrorSet) = .empty,
    error_cases: std.ArrayList(ErrorCase) = .empty,
    variants: std.ArrayList(Variant) = .empty,
    variant_cases: std.ArrayList(VariantCase) = .empty,
    vtables: std.ArrayList(VTable) = .empty,
    names: std.ArrayList(StrId) = .empty,

    // Per function
    param_index: std.StringHashMapUnmanaged(u32) = .empty,
    local_index: std.StringHashMapUnmanaged(u32) = .empty,
    reg_index: std.AutoHashMapUnmanaged(ir.RegId, u32) = .empty,
    block_index: std.AutoHashMapUnmanaged(ir.BlockId, u32) = .empty,
    locals_start: u32 = 0,
    regs: u32 = 0,
    extern_libs_start: u32 = 0,
    extern_libs_len: u32 = 0,

    fn intern(self: *Builder, s: []const u8) !StrId {
        if (self.str_ids.get(s)) |id| return id;
        const id: StrId = @intCast(self.strs.items.len);
        const off: u32 = @intCast(self.bytes.items.len);
        try self.bytes.appendSlice(self.gpa, s);
        try self.strs.append(self.gpa, .{ .off = off, .len = @intCast(s.len) });
        // the key must outlive the IR: it points into `bytes`, which only grows, so it is
        // looked up through a copy owned by the map's allocator
        const key = try self.gpa.dupe(u8, s);
        try self.str_ids.put(self.gpa, key, id);
        return id;
    }

    fn optStr(self: *Builder, s: ?[]const u8) !StrId {
        return if (s) |v| try self.intern(v) else none;
    }

    fn typeId(self: *Builder, t: ir.IrType) BuildError!TypeId {
        var key: TypeKey = .{ .kind = .unknown, .flags = 0, .bits = 0, .a = none, .b = none, .c = none };
        switch (t) {
            .i => |bits| key = .{ .kind = .int, .flags = 0, .bits = bits, .a = none, .b = none, .c = none },
            .u => |bits| key = .{ .kind = .uint, .flags = 0, .bits = bits, .a = none, .b = none, .c = none },
            .f32 => key.kind = .f32,
            .f64 => key.kind = .f64,
            .bool => key.kind = .bool,
            .byte => key.kind = .byte,
            .usize => key.kind = .usize,
            .isize => key.kind = .isize,
            .addr => key.kind = .addr,
            .void => key.kind = .void,
            .text => key.kind = .text,
            .rune => key.kind = .rune,
            .zone => key.kind = .zone,
            .unknown => key.kind = .unknown,
            .opaque_type => |n| key = .{ .kind = .opaque_type, .flags = 0, .bits = 0, .a = try self.intern(n), .b = none, .c = none },
            .struct_type => |n| key = .{ .kind = .struct_type, .flags = 0, .bits = 0, .a = try self.intern(n), .b = none, .c = none },
            .variant_type => |n| key = .{ .kind = .variant_type, .flags = 0, .bits = 0, .a = try self.intern(n), .b = none, .c = none },
            .interface_value => |n| key = .{ .kind = .interface_value, .flags = 0, .bits = 0, .a = try self.intern(n), .b = none, .c = none },
            .ptr => |e| key = .{ .kind = .ptr, .flags = 0, .bits = 0, .a = try self.typeId(e.*), .b = none, .c = none },
            .optional => |e| key = .{ .kind = .optional, .flags = 0, .bits = 0, .a = try self.typeId(e.*), .b = none, .c = none },
            .slice => |e| key = .{ .kind = .slice, .flags = 0, .bits = 0, .a = try self.typeId(e.*), .b = none, .c = none },
            .range => |e| key = .{ .kind = .range, .flags = 0, .bits = 0, .a = try self.typeId(e.*), .b = none, .c = none },
            .list => |e| key = .{ .kind = .list, .flags = 0, .bits = 0, .a = try self.typeId(e.*), .b = none, .c = none },
            .map => |e| key = .{ .kind = .map, .flags = 0, .bits = 0, .a = try self.typeId(e.*), .b = none, .c = none },
            .array => |arr| key = .{ .kind = .array, .flags = 0, .bits = 0, .a = try self.typeId(arr.elem.*), .b = @truncate(arr.len), .c = @truncate(arr.len >> 32) },
            .fallible => |f| key = .{ .kind = .fallible, .flags = 0, .bits = 0, .a = try self.typeId(f.ok.*), .b = try self.typeId(f.err.*), .c = none },
            .fn_ptr => |f| {
                var tmp: std.ArrayList(TypeId) = .empty;
                defer tmp.deinit(self.gpa);
                for (f.params) |p| try tmp.append(self.gpa, try self.typeId(p));
                const ret = try self.typeId(f.ret.*);
                // the parameter list is part of the key by its contents: find or add the run
                const start = try self.listRun(tmp.items);
                key = .{ .kind = .fn_ptr, .flags = @intFromBool(f.thin), .bits = 0, .a = start, .b = @intCast(tmp.items.len), .c = ret };
            },
        }
        if (self.type_ids.get(key)) |id| return id;
        const id: TypeId = @intCast(self.types.items.len);
        var ty: Type = .{ .kind = key.kind, .flags = key.flags, .bits = key.bits, .a = key.a, .b = key.b, .c = key.c };
        if (layout.ofWith(t, layout.SliceSource{ .structs = self.module.structs, .variants = self.module.variants })) |l| {
            ty.size = std.math.cast(u32, l.size) orelse none;
            ty.alignment = std.math.cast(u32, l.alignment) orelse none;
        }
        try self.types.append(self.gpa, ty);
        try self.type_ids.put(self.gpa, key, id);
        return id;
    }

    /// The start of a run of `type_lists` equal to `items`, added when there is none yet.
    fn listRun(self: *Builder, items: []const TypeId) !u32 {
        const all = self.type_lists.items;
        if (items.len == 0) return 0;
        if (all.len >= items.len) {
            var i: usize = 0;
            while (i + items.len <= all.len) : (i += 1) {
                if (std.mem.eql(TypeId, all[i..][0..items.len], items)) return @intCast(i);
            }
        }
        const start: u32 = @intCast(all.len);
        try self.type_lists.appendSlice(self.gpa, items);
        return start;
    }

    fn constId(self: *Builder, imm: ir.Imm) !ConstId {
        const c: Const = switch (imm) {
            .int => |v| blk: {
                const bits: u128 = @bitCast(v);
                break :blk .{ .kind = .int, .lo = @truncate(bits), .hi = @truncate(bits >> 64) };
            },
            .uint => |v| .{ .kind = .uint, .lo = @truncate(v), .hi = @truncate(v >> 64) },
            .float => |v| .{ .kind = .float, .lo = @bitCast(v) },
            .bool => |v| .{ .kind = .bool, .lo = @intFromBool(v) },
            .text => |s| .{ .kind = .text, .lo = try self.intern(s) },
            .rune => |r| .{ .kind = .rune, .lo = r },
            .null => .{ .kind = .null_ },
        };
        const id: ConstId = @intCast(self.consts.items.len);
        try self.consts.append(self.gpa, c);
        return id;
    }

    fn reg(self: *Builder, id: ir.RegId) !u32 {
        const e = try self.reg_index.getOrPut(self.gpa, id);
        if (!e.found_existing) {
            e.value_ptr.* = self.regs;
            self.regs += 1;
        }
        return e.value_ptr.*;
    }

    fn local(self: *Builder, name: []const u8, ty: ?ir.IrType) !u32 {
        const e = try self.local_index.getOrPut(self.gpa, name);
        if (!e.found_existing) {
            e.value_ptr.* = @intCast(self.locals.items.len - self.locals_start);
            try self.locals.append(self.gpa, .{ .name = try self.intern(name), .ty = none });
        }
        const slot = &self.locals.items[self.locals_start + e.value_ptr.*];
        if (slot.ty == none) if (ty) |t| {
            slot.ty = try self.typeId(t);
        };
        return e.value_ptr.*;
    }

    fn value(self: *Builder, v: ir.Value) BuildError!Operand {
        return switch (v) {
            .reg => |id| operand(.reg, try self.reg(id)),
            .param => |name| operand(.param, self.param_index.get(name) orelse return error.UnknownParam),
            .local => |name| operand(.local, try self.local(name, null)),
            .global => |name| operand(.global, try self.intern(name)),
            .imm => |imm| operand(.constant, try self.constId(imm)),
        };
    }

    fn optValue(self: *Builder, v: ?ir.Value) !Operand {
        return if (v) |x| try self.value(x) else none;
    }

    fn values(self: *Builder, vs: []const ir.Value) !u32 {
        const start: u32 = @intCast(self.extra.items.len);
        try self.extra.append(self.gpa, @intCast(vs.len));
        try self.extra.ensureUnusedCapacity(self.gpa, vs.len);
        for (vs) |v| try self.extra.append(self.gpa, try self.value(v));
        return start;
    }

    fn block(self: *Builder, id: ir.BlockId) !u32 {
        return self.block_index.get(id) orelse error.UnknownBlock;
    }

    fn push(self: *Builder, op: Op, sub: u8, ty: TypeId, dst: u32, a: u32, b: u32, c: u32, loc: ir.SourceLocation) !void {
        try self.op.append(self.gpa, op);
        try self.sub.append(self.gpa, sub);
        try self.ty.append(self.gpa, ty);
        try self.dst.append(self.gpa, dst);
        try self.a.append(self.gpa, a);
        try self.b.append(self.gpa, b);
        try self.c.append(self.gpa, c);
        try self.file.append(self.gpa, try self.intern(loc.file));
        try self.line.append(self.gpa, @intCast(loc.line));
        try self.col.append(self.gpa, @intCast(loc.column));
    }

    fn instr(self: *Builder, in: ir.Instr) BuildError!void {
        const ty = try self.typeId(in.ty);
        const dst: u32 = if (in.id) |id| try self.reg(id) else none;
        var op: Op = undefined;
        var sub: u8 = 0;
        var a: u32 = none;
        var b: u32 = none;
        var c: u32 = none;
        switch (in.kind) {
            .const_value => |imm| {
                op = .const_value;
                a = operand(.constant, try self.constId(imm));
            },
            .unary => |u| {
                op = .unary;
                sub = @intFromEnum(u.op);
                a = try self.value(u.value);
            },
            .binary => |bin| {
                op = .binary;
                sub = @intFromEnum(bin.op);
                a = try self.value(bin.lhs);
                b = try self.value(bin.rhs);
            },
            .cast => |cs| {
                op = .cast;
                sub = @intFromEnum(cs.kind);
                a = try self.value(cs.value);
            },
            .call => |call| {
                op = .call;
                a = try self.intern(call.callee);
                b = try self.values(call.args);
            },
            .call_indirect => |call| {
                op = .call_indirect;
                sub = @intFromBool(call.is_closure);
                a = try self.value(call.callee);
                b = try self.values(call.args);
                try self.extra.append(self.gpa, @intCast(call.param_tys.len));
                for (call.param_tys) |p| try self.extra.append(self.gpa, try self.typeId(p));
            },
            .builtin => |bi| {
                op = .builtin;
                a = try self.intern(bi.name);
                b = try self.values(bi.args);
                c = if (bi.type_arg) |t| try self.typeId(t) else none;
            },
            .inline_asm => |asm_| {
                op = .inline_asm;
                sub = @intFromBool(asm_.volatile_);
                a = try self.intern(asm_.template);
                b = try self.intern(asm_.constraints);
                c = try self.values(asm_.args);
            },
            .struct_lit => |sl| {
                op = .struct_lit;
                a = try self.intern(sl.ty_name);
                b = @intCast(self.extra.items.len);
                try self.extra.append(self.gpa, @intCast(sl.fields.len));
                for (sl.fields) |f| {
                    const name = try self.intern(f.name);
                    const v = try self.value(f.value);
                    try self.extra.appendSlice(self.gpa, &.{ name, v });
                }
            },
            .variant_lit => |vl| {
                op = .variant_lit;
                a = try self.intern(vl.type_name);
                b = try self.intern(vl.variant);
                c = try self.optValue(vl.payload);
            },
            .field, .field_addr => |f| {
                op = if (in.kind == .field) .field else .field_addr;
                a = try self.value(f.base);
                b = try self.intern(f.name);
            },
            .index, .index_addr => |ix| {
                op = if (in.kind == .index) .index else .index_addr;
                sub = @intFromBool(ix.checked);
                a = try self.value(ix.base);
                b = try self.value(ix.index);
            },
            .slice_expr => |s| {
                op = .slice_expr;
                a = try self.value(s.ptr);
                b = try self.value(s.len);
            },
            .variant_is, .variant_payload, .variant_tag => |vc| {
                op = switch (in.kind) {
                    .variant_is => .variant_is,
                    .variant_payload => .variant_payload,
                    else => .variant_tag,
                };
                a = try self.value(vc.value);
                b = try self.intern(vc.type_name);
                c = try self.intern(vc.variant);
            },
            .optional_is_some, .optional_payload, .try_is_ok, .try_ok, .try_err, .iter_init, .iter_has_next, .iter_next, .interface_data => |v| {
                op = switch (in.kind) {
                    .optional_is_some => .optional_is_some,
                    .optional_payload => .optional_payload,
                    .try_is_ok => .try_is_ok,
                    .try_ok => .try_ok,
                    .try_err => .try_err,
                    .iter_init => .iter_init,
                    .iter_has_next => .iter_has_next,
                    .iter_next => .iter_next,
                    else => .interface_data,
                };
                a = try self.value(v);
            },
            .alloc => |al| {
                op = .alloc;
                a = try self.typeId(al.ty);
                b = try self.intern(al.zone);
            },
            .alloc_slice => |al| {
                op = .alloc_slice;
                a = try self.typeId(al.elem_ty);
                b = try self.value(al.count);
                c = try self.intern(al.zone);
            },
            .zone_push => |z| {
                op = .zone_push;
                a = try self.intern(z.name);
                b = try self.intern(z.kind);
            },
            .zone_pop => |name| {
                op = .zone_pop;
                a = try self.intern(name);
            },
            .zone_free => |z| {
                op = .zone_free;
                a = try self.intern(z.zone);
                b = try self.value(z.ptr);
            },
            .at => |at| {
                op = .at;
                a = try self.value(at.value);
                b = try self.intern(at.zone);
            },
            .raw_pointer => |rp| {
                op = .raw_pointer;
                a = try self.typeId(rp.ty);
                b = try self.value(rp.address);
            },
            .interface_make => |im| {
                op = .interface_make;
                a = try self.value(im.data);
                b = try self.intern(im.vtable);
            },
            .interface_method => |im| {
                op = .interface_method;
                a = try self.value(im.value);
                b = im.index;
            },
            .closure_make => |cm| {
                op = .closure_make;
                sub = @intFromBool(cm.fn_takes_env);
                a = try self.intern(cm.fn_link);
                b = try self.value(cm.env);
            },
            .closure_env_make => |em| {
                op = .closure_env_make;
                a = @intCast(self.extra.items.len);
                try self.extra.append(self.gpa, @intCast(em.fields.len));
                for (em.fields) |f| {
                    const v = try self.value(f.value);
                    const t = try self.typeId(f.ty);
                    try self.extra.appendSlice(self.gpa, &.{ v, t });
                }
                b = try self.value(em.arena);
                c = try self.intern(em.alloc_fn);
            },
            .closure_env_load => |el| {
                op = .closure_env_load;
                a = try self.value(el.env);
                b = el.index;
                c = @intCast(self.extra.items.len);
                try self.extra.append(self.gpa, @intCast(el.fields.len));
                for (el.fields) |t| try self.extra.append(self.gpa, try self.typeId(t));
            },
            .store_local => |sl| {
                op = .store_local;
                a = operand(.local, try self.local(sl.name, in.ty));
                b = try self.value(sl.value);
            },
            .global_load => |name| {
                op = .global_load;
                a = try self.intern(name);
            },
            .global_store => |gs| {
                op = .global_store;
                a = try self.intern(gs.name);
                b = try self.value(gs.value);
            },
            .store => |st| {
                op = .store;
                a = try self.value(st.target);
                b = try self.value(st.value);
            },
        }
        try self.push(op, sub, ty, dst, a, b, c, in.location);
    }

    fn terminator(self: *Builder, term: ?ir.Terminator) BuildError!void {
        const void_ty = try self.typeId(.void);
        const nowhere: ir.SourceLocation = .{ .file = "", .line = 0, .column = 0 };
        const t = term orelse return self.push(.no_term, 0, void_ty, none, none, none, none, nowhere);
        switch (t) {
            .return_value => |v| try self.push(.ret, 0, void_ty, none, try self.optValue(v), none, none, nowhere),
            .fail => |f| try self.push(.fail, 0, void_ty, none, try self.value(f.disc), try self.optValue(f.err), none, nowhere),
            .panic => |p| try self.push(.panic, 0, void_ty, none, try self.intern(p.message), none, none, p.location),
            .branch => |to| try self.push(.br, 0, void_ty, none, try self.block(to), none, none, nowhere),
            .cond_branch => |cb| try self.push(.cond_br, 0, void_ty, none, try self.value(cb.cond), try self.block(cb.then_block), try self.block(cb.else_block), nowhere),
            .unreachable_term => try self.push(.unreachable_term, 0, void_ty, none, none, none, none, nowhere),
        }
    }

    fn function(self: *Builder, f: ir.IrFunction) BuildError!void {
        self.param_index.clearRetainingCapacity();
        self.local_index.clearRetainingCapacity();
        self.reg_index.clearRetainingCapacity();
        self.block_index.clearRetainingCapacity();
        self.regs = 0;
        self.locals_start = @intCast(self.locals.items.len);

        var flags: u32 = 0;
        if (f.inline_hint) flags |= fn_flag.inline_hint;
        if (f.no_inline) flags |= fn_flag.no_inline;
        if (f.no_return) flags |= fn_flag.no_return;
        if (f.entry) flags |= fn_flag.entry;
        if (f.naked) flags |= fn_flag.naked;
        if (f.cold) flags |= fn_flag.cold;
        if (f.weak) flags |= fn_flag.weak;
        if (f.keep) flags |= fn_flag.keep;

        const params_start: u32 = @intCast(self.params.items.len);
        for (f.params, 0..) |p, i| {
            try self.params.append(self.gpa, .{ .name = try self.intern(p.name), .ty = try self.typeId(p.ty) });
            try self.param_index.put(self.gpa, p.name, @intCast(i));
        }
        const blocks_start: u32 = @intCast(self.blocks.items.len);
        for (f.blocks, 0..) |blk, i| try self.block_index.put(self.gpa, blk.id, @intCast(i));
        for (f.blocks) |blk| {
            const first: u32 = @intCast(self.op.items.len);
            for (blk.instrs) |in| try self.instr(in);
            try self.terminator(blk.terminator);
            try self.blocks.append(self.gpa, .{
                .id = blk.id,
                .name = try self.intern(blk.name),
                .first = first,
                .len = @intCast(self.op.items.len - first),
            });
        }
        try self.functions.append(self.gpa, .{
            .name = try self.intern(f.name),
            .flags = flags,
            .extern_name = try self.optStr(f.extern_name),
            .extern_lib = try self.optStr(f.extern_lib),
            .export_sym = try self.optStr(f.export_sym),
            .section = try self.optStr(f.section),
            .link_name = try self.optStr(f.link_name),
            .ret = try self.typeId(f.return_ty),
            .err = if (f.error_ty) |e| try self.typeId(e) else none,
            .params_start = params_start,
            .params_len = @intCast(f.params.len),
            .blocks_start = blocks_start,
            .blocks_len = @intCast(f.blocks.len),
            .locals_start = self.locals_start,
            .locals_len = @intCast(self.locals.items.len - self.locals_start),
            .regs = self.regs,
        });
    }

    fn init(self: *Builder, ci: ir.ConstInit) BuildError!u32 {
        var node: Init = .{ .kind = .zero };
        switch (ci) {
            .imm => |imm| node = .{ .kind = .imm, .a = try self.constId(imm) },
            .struct_init => |si| {
                var children: std.ArrayList(u32) = .empty;
                defer children.deinit(self.gpa);
                for (si.fields) |f| {
                    try children.append(self.gpa, try self.intern(f.name));
                    try children.append(self.gpa, try self.init(f.value));
                }
                const start: u32 = @intCast(self.extra.items.len);
                try self.extra.append(self.gpa, @intCast(si.fields.len));
                try self.extra.appendSlice(self.gpa, children.items);
                node = .{ .kind = .struct_init, .a = try self.intern(si.ty_name), .b = start };
            },
            .array_init => |elems| {
                var children: std.ArrayList(u32) = .empty;
                defer children.deinit(self.gpa);
                for (elems) |e| try children.append(self.gpa, try self.init(e));
                const start: u32 = @intCast(self.extra.items.len);
                try self.extra.append(self.gpa, @intCast(elems.len));
                try self.extra.appendSlice(self.gpa, children.items);
                node = .{ .kind = .array_init, .a = start };
            },
            .zero => node = .{ .kind = .zero },
            .func_ref => |name| node = .{ .kind = .func_ref, .a = try self.intern(name) },
            .global_addr => |name| node = .{ .kind = .global_addr, .a = try self.intern(name) },
            .variant_tag => |tag| node = .{ .kind = .variant_tag, .a = tag },
            .variant => |v| node = .{ .kind = .variant, .a = v.tag, .b = try self.init(v.payload.*), .c = try self.typeId(v.payload_ty) },
            .pending => node = .{ .kind = .pending },
        }
        const id: u32 = @intCast(self.inits.items.len);
        try self.inits.append(self.gpa, node);
        return id;
    }

    fn finish(self: *Builder) !Slab {
        const g = self.gpa;
        return .{
            .file_name = try self.intern(self.module.file_name),
            .bytes = try self.bytes.toOwnedSlice(g),
            .strs = try self.strs.toOwnedSlice(g),
            .types = try self.types.toOwnedSlice(g),
            .type_lists = try self.type_lists.toOwnedSlice(g),
            .consts = try self.consts.toOwnedSlice(g),
            .instrs = .{
                .op = try self.op.toOwnedSlice(g),
                .sub = try self.sub.toOwnedSlice(g),
                .ty = try self.ty.toOwnedSlice(g),
                .dst = try self.dst.toOwnedSlice(g),
                .a = try self.a.toOwnedSlice(g),
                .b = try self.b.toOwnedSlice(g),
                .c = try self.c.toOwnedSlice(g),
                .file = try self.file.toOwnedSlice(g),
                .line = try self.line.toOwnedSlice(g),
                .col = try self.col.toOwnedSlice(g),
            },
            .extra = try self.extra.toOwnedSlice(g),
            .functions = try self.functions.toOwnedSlice(g),
            .params = try self.params.toOwnedSlice(g),
            .locals = try self.locals.toOwnedSlice(g),
            .blocks = try self.blocks.toOwnedSlice(g),
            .globals = try self.globals.toOwnedSlice(g),
            .inits = try self.inits.toOwnedSlice(g),
            .structs = try self.structs.toOwnedSlice(g),
            .fields = try self.fields.toOwnedSlice(g),
            .errors = try self.errors.toOwnedSlice(g),
            .error_cases = try self.error_cases.toOwnedSlice(g),
            .variants = try self.variants.toOwnedSlice(g),
            .variant_cases = try self.variant_cases.toOwnedSlice(g),
            .vtables = try self.vtables.toOwnedSlice(g),
            .names = try self.names.toOwnedSlice(g),
            .extern_libs_start = self.extern_libs_start,
            .extern_libs_len = self.extern_libs_len,
        };
    }

    fn deinit(self: *Builder) void {
        const g = self.gpa;
        var it = self.str_ids.keyIterator();
        while (it.next()) |k| g.free(k.*);
        self.str_ids.deinit(g);
        self.type_ids.deinit(g);
        self.param_index.deinit(g);
        self.local_index.deinit(g);
        self.reg_index.deinit(g);
        self.block_index.deinit(g);
        // (the lists were handed to the Slab, or are empty after an error and freed here)
        self.bytes.deinit(g);
        self.strs.deinit(g);
        self.types.deinit(g);
        self.type_lists.deinit(g);
        self.consts.deinit(g);
        self.op.deinit(g);
        self.sub.deinit(g);
        self.ty.deinit(g);
        self.dst.deinit(g);
        self.a.deinit(g);
        self.b.deinit(g);
        self.c.deinit(g);
        self.file.deinit(g);
        self.line.deinit(g);
        self.col.deinit(g);
        self.extra.deinit(g);
        self.functions.deinit(g);
        self.params.deinit(g);
        self.locals.deinit(g);
        self.blocks.deinit(g);
        self.globals.deinit(g);
        self.inits.deinit(g);
        self.structs.deinit(g);
        self.fields.deinit(g);
        self.errors.deinit(g);
        self.error_cases.deinit(g);
        self.variants.deinit(g);
        self.variant_cases.deinit(g);
        self.vtables.deinit(g);
        self.names.deinit(g);
    }
};

/// The Slab of `module`. The Slab owns its arrays (`Slab.deinit` with the same allocator); it
/// does not point into the IR.
pub fn build(gpa: std.mem.Allocator, module: ir.IrModule) BuildError!Slab {
    var b: Builder = .{ .gpa = gpa, .module = module };
    defer b.deinit();

    const source = layout.SliceSource{ .structs = module.structs, .variants = module.variants };
    for (module.structs) |def| {
        const fields_start: u32 = @intCast(b.fields.items.len);
        for (def.fields) |f| {
            const off: u32 = if (layout.offsetOfWith(def, f.name, source)) |o| std.math.cast(u32, o) orelse none else none;
            try b.fields.append(gpa, .{ .name = try b.intern(f.name), .ty = try b.typeId(f.ty), .offset = off });
        }
        try b.structs.append(gpa, .{
            .name = try b.intern(def.name),
            .fields_start = fields_start,
            .fields_len = @intCast(def.fields.len),
            .flags = @as(u32, @intFromBool(def.is_packed)) | (@as(u32, @intFromBool(def.is_union)) << 1),
            .alignment = def.alignment,
        });
    }
    for (module.errors) |def| {
        const start: u32 = @intCast(b.error_cases.items.len);
        for (def.variants) |case| try b.error_cases.append(gpa, .{
            .name = try b.intern(case.name),
            .payload = if (case.payload) |p| try b.typeId(p) else none,
        });
        try b.errors.append(gpa, .{ .name = try b.intern(def.name), .cases_start = start, .cases_len = @intCast(def.variants.len) });
    }
    for (module.variants) |def| {
        const start: u32 = @intCast(b.variant_cases.items.len);
        for (def.variants) |case| try b.variant_cases.append(gpa, .{
            .name = try b.intern(case.name),
            .payload = if (case.payload) |p| try b.typeId(p) else none,
            .disc = case.disc orelse none,
        });
        try b.variants.append(gpa, .{ .name = try b.intern(def.name), .cases_start = start, .cases_len = @intCast(def.variants.len) });
    }
    for (module.functions) |f| try b.function(f);
    for (module.globals) |g| try b.globals.append(gpa, .{
        .name = try b.intern(g.name),
        .ty = try b.typeId(g.ty),
        .init = try b.init(g.init),
        .mutable = @intFromBool(g.mutable),
        .export_sym = try b.optStr(g.export_sym),
    });
    for (module.vtables) |vt| {
        const start: u32 = @intCast(b.names.items.len);
        for (vt.methods) |m| try b.names.append(gpa, try b.intern(m));
        try b.vtables.append(gpa, .{ .name = try b.intern(vt.name), .methods_start = start, .methods_len = @intCast(vt.methods.len) });
    }
    b.extern_libs_start = @intCast(b.names.items.len);
    for (module.extern_libs) |lib| try b.names.append(gpa, try b.intern(lib));
    b.extern_libs_len = @intCast(module.extern_libs.len);
    return b.finish();
}

// Back to IR

pub const ToIrError = error{OutOfMemory};

/// The IR module `slab` was built from, allocated in `arena` (which must outlive it). Registers are
/// numbered from 1 in each function, as the Slab numbers them (plus one); everything else is as it
/// was.
pub fn toIr(arena: std.mem.Allocator, slab: *const Slab) ToIrError!ir.IrModule {
    var r: Rebuilder = .{ .a = arena, .s = slab, .types = try arena.alloc(?*const ir.IrType, slab.types.len) };
    @memset(r.types, null);

    const structs = try arena.alloc(ir.StructDef, slab.structs.len);
    for (slab.structs, structs) |s, *out| {
        const fields = try arena.alloc(ir.FieldDef, s.fields_len);
        for (slab.fields[s.fields_start..][0..s.fields_len], fields) |f, *fo| fo.* = .{ .name = slab.str(f.name), .ty = (try r.ty(f.ty)).* };
        out.* = .{ .name = slab.str(s.name), .fields = fields, .is_packed = s.flags & 1 != 0, .is_union = s.flags & 2 != 0, .alignment = s.alignment };
    }
    const errors = try arena.alloc(ir.ErrorDef, slab.errors.len);
    for (slab.errors, errors) |e, *out| {
        const cases = try arena.alloc(ir.ErrorCase, e.cases_len);
        for (slab.error_cases[e.cases_start..][0..e.cases_len], cases) |c, *co| co.* = .{ .name = slab.str(c.name), .payload = try r.optTy(c.payload) };
        out.* = .{ .name = slab.str(e.name), .variants = cases };
    }
    const variants = try arena.alloc(ir.VariantDef, slab.variants.len);
    for (slab.variants, variants) |v, *out| {
        const cases = try arena.alloc(ir.VariantCase, v.cases_len);
        for (slab.variant_cases[v.cases_start..][0..v.cases_len], cases) |c, *co| co.* = .{
            .name = slab.str(c.name),
            .payload = try r.optTy(c.payload),
            .disc = if (c.disc == none) null else c.disc,
        };
        out.* = .{ .name = slab.str(v.name), .variants = cases };
    }
    const functions = try arena.alloc(ir.IrFunction, slab.functions.len);
    for (slab.functions, functions) |f, *out| out.* = try r.function(f);
    const globals = try arena.alloc(ir.IrGlobal, slab.globals.len);
    for (slab.globals, globals) |g, *out| out.* = .{
        .name = slab.str(g.name),
        .ty = (try r.ty(g.ty)).*,
        .init = try r.init(g.init),
        .mutable = g.mutable != 0,
        .export_sym = r.optStr(g.export_sym),
    };
    const vtables = try arena.alloc(ir.InterfaceVTable, slab.vtables.len);
    for (slab.vtables, vtables) |vt, *out| {
        const methods = try arena.alloc([]const u8, vt.methods_len);
        for (slab.names[vt.methods_start..][0..vt.methods_len], methods) |m, *mo| mo.* = slab.str(m);
        out.* = .{ .name = slab.str(vt.name), .methods = methods };
    }
    const libs = try arena.alloc([]const u8, slab.extern_libs_len);
    for (slab.names[slab.extern_libs_start..][0..slab.extern_libs_len], libs) |l, *lo| lo.* = slab.str(l);
    return .{
        .file_name = slab.str(slab.file_name),
        .structs = structs,
        .errors = errors,
        .variants = variants,
        .functions = functions,
        .globals = globals,
        .vtables = vtables,
        .extern_libs = libs,
    };
}

const Rebuilder = struct {
    a: std.mem.Allocator,
    s: *const Slab,
    types: []?*const ir.IrType,
    // per function
    f: Function = undefined,

    fn optStr(self: *Rebuilder, id: StrId) ?[]const u8 {
        return if (id == none) null else self.s.str(id);
    }

    fn ty(self: *Rebuilder, id: TypeId) ToIrError!*const ir.IrType {
        if (self.types[id]) |t| return t;
        const t = self.s.types[id];
        const out = try self.a.create(ir.IrType);
        out.* = switch (t.kind) {
            .void => .void,
            .bool => .bool,
            .int => .{ .i = t.bits },
            .uint => .{ .u = t.bits },
            .f32 => .f32,
            .f64 => .f64,
            .byte => .byte,
            .usize => .usize,
            .isize => .isize,
            .addr => .addr,
            .text => .text,
            .rune => .rune,
            .zone => .zone,
            .unknown => .unknown,
            .opaque_type => .{ .opaque_type = self.s.str(t.a) },
            .struct_type => .{ .struct_type = self.s.str(t.a) },
            .variant_type => .{ .variant_type = self.s.str(t.a) },
            .interface_value => .{ .interface_value = self.s.str(t.a) },
            .ptr => .{ .ptr = try self.ty(t.a) },
            .optional => .{ .optional = try self.ty(t.a) },
            .slice => .{ .slice = try self.ty(t.a) },
            .range => .{ .range = try self.ty(t.a) },
            .list => .{ .list = try self.ty(t.a) },
            .map => .{ .map = try self.ty(t.a) },
            .array => .{ .array = .{ .elem = try self.ty(t.a), .len = @as(u64, t.b) | (@as(u64, t.c) << 32) } },
            .fallible => .{ .fallible = .{ .ok = try self.ty(t.a), .err = try self.ty(t.b) } },
            .fn_ptr => blk: {
                const params = try self.a.alloc(ir.IrType, t.b);
                for (self.s.type_lists[t.a..][0..t.b], params) |p, *po| po.* = (try self.ty(p)).*;
                break :blk .{ .fn_ptr = .{ .params = params, .ret = try self.ty(t.c), .thin = t.flags & 1 != 0 } };
            },
        };
        self.types[id] = out;
        return out;
    }

    fn optTy(self: *Rebuilder, id: TypeId) ToIrError!?ir.IrType {
        return if (id == none) null else (try self.ty(id)).*;
    }

    fn imm(self: *Rebuilder, id: ConstId) ir.Imm {
        const c = self.s.consts[id];
        return switch (c.kind) {
            .int => .{ .int = @bitCast(@as(u128, c.lo) | (@as(u128, c.hi) << 64)) },
            .uint => .{ .uint = @as(u128, c.lo) | (@as(u128, c.hi) << 64) },
            .float => .{ .float = @bitCast(c.lo) },
            .bool => .{ .bool = c.lo != 0 },
            .text => .{ .text = self.s.str(@intCast(c.lo)) },
            .rune => .{ .rune = @intCast(c.lo) },
            .null_ => .null,
        };
    }

    fn value(self: *Rebuilder, o: Operand) ir.Value {
        const i = indexOf(o);
        return switch (kindOf(o)) {
            .reg => .{ .reg = i + 1 },
            .param => .{ .param = self.s.str(self.s.params[self.f.params_start + i].name) },
            .local => .{ .local = self.s.str(self.s.locals[self.f.locals_start + i].name) },
            .global => .{ .global = self.s.str(i) },
            .constant => .{ .imm = self.imm(i) },
        };
    }

    fn optValue(self: *Rebuilder, o: Operand) ?ir.Value {
        return if (o == none) null else self.value(o);
    }

    fn values(self: *Rebuilder, start: u32) ToIrError![]const ir.Value {
        const n = self.s.extra[start];
        const out = try self.a.alloc(ir.Value, n);
        for (self.s.extra[start + 1 ..][0..n], out) |o, *vo| vo.* = self.value(o);
        return out;
    }

    fn blockId(self: *Rebuilder, index: u32) ir.BlockId {
        return self.s.blocks[self.f.blocks_start + index].id;
    }

    fn function(self: *Rebuilder, f: Function) ToIrError!ir.IrFunction {
        self.f = f;
        const s = self.s;
        const params = try self.a.alloc(ir.IrParam, f.params_len);
        for (s.params[f.params_start..][0..f.params_len], params) |p, *po| po.* = .{ .name = s.str(p.name), .ty = (try self.ty(p.ty)).* };
        const blocks = try self.a.alloc(ir.IrBlock, f.blocks_len);
        for (s.blocks[f.blocks_start..][0..f.blocks_len], blocks) |b, *bo| {
            const instrs = try self.a.alloc(ir.Instr, b.len - 1);
            for (instrs, 0..) |*io, k| io.* = try self.instr(b.first + @as(u32, @intCast(k)));
            bo.* = .{ .id = b.id, .name = s.str(b.name), .instrs = instrs, .terminator = try self.terminator(b.first + b.len - 1) };
        }
        return .{
            .name = s.str(f.name),
            .params = params,
            .return_ty = (try self.ty(f.ret)).*,
            .error_ty = try self.optTy(f.err),
            .blocks = blocks,
            .extern_name = self.optStr(f.extern_name),
            .extern_lib = self.optStr(f.extern_lib),
            .inline_hint = f.flags & fn_flag.inline_hint != 0,
            .no_inline = f.flags & fn_flag.no_inline != 0,
            .no_return = f.flags & fn_flag.no_return != 0,
            .entry = f.flags & fn_flag.entry != 0,
            .naked = f.flags & fn_flag.naked != 0,
            .export_sym = self.optStr(f.export_sym),
            .cold = f.flags & fn_flag.cold != 0,
            .weak = f.flags & fn_flag.weak != 0,
            .keep = f.flags & fn_flag.keep != 0,
            .section = self.optStr(f.section),
            .link_name = self.optStr(f.link_name),
        };
    }

    fn location(self: *Rebuilder, i: u32) ir.SourceLocation {
        const in = &self.s.instrs;
        return .{ .file = self.s.str(in.file[i]), .line = in.line[i], .column = in.col[i] };
    }

    fn instr(self: *Rebuilder, i: u32) ToIrError!ir.Instr {
        const s = self.s;
        const in = &s.instrs;
        const a = in.a[i];
        const b = in.b[i];
        const c = in.c[i];
        const sub = in.sub[i];
        const kind: ir.InstrKind = switch (in.op[i]) {
            .const_value => .{ .const_value = self.imm(indexOf(a)) },
            .unary => .{ .unary = .{ .op = @enumFromInt(sub), .value = self.value(a) } },
            .binary => .{ .binary = .{ .op = @enumFromInt(sub), .lhs = self.value(a), .rhs = self.value(b) } },
            .cast => .{ .cast = .{ .kind = @enumFromInt(sub), .value = self.value(a) } },
            .call => .{ .call = .{ .callee = s.str(a), .args = try self.values(b) } },
            .call_indirect => blk: {
                const args = try self.values(b);
                const after = b + 1 + s.extra[b];
                const m = s.extra[after];
                const ptys = try self.a.alloc(ir.IrType, m);
                for (s.extra[after + 1 ..][0..m], ptys) |t, *to| to.* = (try self.ty(t)).*;
                break :blk .{ .call_indirect = .{ .callee = self.value(a), .args = args, .param_tys = ptys, .is_closure = sub != 0 } };
            },
            .builtin => .{ .builtin = .{ .name = s.str(a), .args = try self.values(b), .type_arg = try self.optTy(c) } },
            .inline_asm => .{ .inline_asm = .{ .template = s.str(a), .constraints = s.str(b), .args = try self.values(c), .volatile_ = sub != 0 } },
            .struct_lit => blk: {
                const n = s.extra[b];
                const fields = try self.a.alloc(ir.StructFieldValue, n);
                for (fields, 0..) |*fo, k| fo.* = .{ .name = s.str(s.extra[b + 1 + 2 * k]), .value = self.value(s.extra[b + 2 + 2 * k]) };
                break :blk .{ .struct_lit = .{ .ty_name = s.str(a), .fields = fields } };
            },
            .variant_lit => .{ .variant_lit = .{ .type_name = s.str(a), .variant = s.str(b), .payload = self.optValue(c) } },
            .field => .{ .field = .{ .base = self.value(a), .name = s.str(b) } },
            .field_addr => .{ .field_addr = .{ .base = self.value(a), .name = s.str(b) } },
            .index => .{ .index = .{ .base = self.value(a), .index = self.value(b), .checked = sub != 0 } },
            .index_addr => .{ .index_addr = .{ .base = self.value(a), .index = self.value(b), .checked = sub != 0 } },
            .slice_expr => .{ .slice_expr = .{ .ptr = self.value(a), .len = self.value(b) } },
            .variant_is => .{ .variant_is = .{ .value = self.value(a), .type_name = s.str(b), .variant = s.str(c) } },
            .variant_payload => .{ .variant_payload = .{ .value = self.value(a), .type_name = s.str(b), .variant = s.str(c) } },
            .variant_tag => .{ .variant_tag = .{ .value = self.value(a), .type_name = s.str(b), .variant = s.str(c) } },
            .optional_is_some => .{ .optional_is_some = self.value(a) },
            .optional_payload => .{ .optional_payload = self.value(a) },
            .try_is_ok => .{ .try_is_ok = self.value(a) },
            .try_ok => .{ .try_ok = self.value(a) },
            .try_err => .{ .try_err = self.value(a) },
            .iter_init => .{ .iter_init = self.value(a) },
            .iter_has_next => .{ .iter_has_next = self.value(a) },
            .iter_next => .{ .iter_next = self.value(a) },
            .interface_data => .{ .interface_data = self.value(a) },
            .alloc => .{ .alloc = .{ .ty = (try self.ty(a)).*, .zone = s.str(b) } },
            .alloc_slice => .{ .alloc_slice = .{ .elem_ty = (try self.ty(a)).*, .count = self.value(b), .zone = s.str(c) } },
            .zone_push => .{ .zone_push = .{ .name = s.str(a), .kind = s.str(b) } },
            .zone_pop => .{ .zone_pop = s.str(a) },
            .zone_free => .{ .zone_free = .{ .zone = s.str(a), .ptr = self.value(b) } },
            .at => .{ .at = .{ .value = self.value(a), .zone = s.str(b) } },
            .raw_pointer => .{ .raw_pointer = .{ .ty = (try self.ty(a)).*, .address = self.value(b) } },
            .interface_make => .{ .interface_make = .{ .data = self.value(a), .vtable = s.str(b) } },
            .interface_method => .{ .interface_method = .{ .value = self.value(a), .index = b } },
            .closure_make => .{ .closure_make = .{ .fn_link = s.str(a), .env = self.value(b), .fn_takes_env = sub != 0 } },
            .closure_env_make => blk: {
                const n = s.extra[a];
                const fields = try self.a.alloc(ir.EnvField, n);
                for (fields, 0..) |*fo, k| fo.* = .{ .value = self.value(s.extra[a + 1 + 2 * k]), .ty = (try self.ty(s.extra[a + 2 + 2 * k])).* };
                break :blk .{ .closure_env_make = .{ .fields = fields, .arena = self.value(b), .alloc_fn = s.str(c) } };
            },
            .closure_env_load => blk: {
                const n = s.extra[c];
                const tys = try self.a.alloc(ir.IrType, n);
                for (s.extra[c + 1 ..][0..n], tys) |t, *to| to.* = (try self.ty(t)).*;
                break :blk .{ .closure_env_load = .{ .env = self.value(a), .index = b, .fields = tys } };
            },
            .store_local => .{ .store_local = .{ .name = s.str(s.locals[self.f.locals_start + indexOf(a)].name), .value = self.value(b) } },
            .global_load => .{ .global_load = s.str(a) },
            .global_store => .{ .global_store = .{ .name = s.str(a), .value = self.value(b) } },
            .store => .{ .store = .{ .target = self.value(a), .value = self.value(b) } },
            .ret, .fail, .panic, .br, .cond_br, .unreachable_term, .no_term => unreachable, // terminators end a block
        };
        return .{
            .id = if (in.dst[i] == none) null else in.dst[i] + 1,
            .ty = (try self.ty(in.ty[i])).*,
            .kind = kind,
            .location = self.location(i),
        };
    }

    fn terminator(self: *Rebuilder, i: u32) ToIrError!?ir.Terminator {
        const in = &self.s.instrs;
        const a = in.a[i];
        const b = in.b[i];
        const c = in.c[i];
        return switch (in.op[i]) {
            .ret => .{ .return_value = self.optValue(a) },
            .fail => .{ .fail = .{ .disc = self.value(a), .err = self.optValue(b) } },
            .panic => .{ .panic = .{ .message = self.s.str(a), .location = self.location(i) } },
            .br => .{ .branch = self.blockId(a) },
            .cond_br => .{ .cond_branch = .{ .cond = self.value(a), .then_block = self.blockId(b), .else_block = self.blockId(c) } },
            .unreachable_term => .unreachable_term,
            .no_term => null,
            else => unreachable,
        };
    }

    fn init(self: *Rebuilder, id: u32) ToIrError!ir.ConstInit {
        const n = self.s.inits[id];
        const s = self.s;
        return switch (n.kind) {
            .imm => .{ .imm = self.imm(n.a) },
            .struct_init => blk: {
                const count = s.extra[n.b];
                const fields = try self.a.alloc(ir.ConstFieldInit, count);
                for (fields, 0..) |*fo, k| fo.* = .{ .name = s.str(s.extra[n.b + 1 + 2 * k]), .value = try self.init(s.extra[n.b + 2 + 2 * k]) };
                break :blk .{ .struct_init = .{ .ty_name = s.str(n.a), .fields = fields } };
            },
            .array_init => blk: {
                const count = s.extra[n.a];
                const elems = try self.a.alloc(ir.ConstInit, count);
                for (elems, 0..) |*eo, k| eo.* = try self.init(s.extra[n.a + 1 + k]);
                break :blk .{ .array_init = elems };
            },
            .zero => .zero,
            .func_ref => .{ .func_ref = s.str(n.a) },
            .global_addr => .{ .global_addr = s.str(n.a) },
            .variant_tag => .{ .variant_tag = n.a },
            .variant => blk: {
                const payload = try self.a.create(ir.ConstInit);
                payload.* = try self.init(n.b);
                break :blk .{ .variant = .{ .tag = n.a, .payload = payload, .payload_ty = (try self.ty(n.c)).* } };
            },
            .pending => .pending,
        };
    }
};

/// The IR type of each of `slab`'s types, by `TypeId`, allocated in `arena`.
pub fn irTypes(arena: std.mem.Allocator, slab: *const Slab) ToIrError![]ir.IrType {
    var r: Rebuilder = .{ .a = arena, .s = slab, .types = try arena.alloc(?*const ir.IrType, slab.types.len) };
    @memset(r.types, null);
    const out = try arena.alloc(ir.IrType, slab.types.len);
    for (out, 0..) |*t, id| t.* = (try r.ty(@intCast(id))).*;
    return out;
}
