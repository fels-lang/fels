//! Size, alignment and field offsets of Fels types, worked out from IR types alone.
//!
//! The LLVM backend lowers a type and asks LLVM for its layout; the comptime VM has no
//! LLVM, yet `core::sizeof` must give the same answer in a `#run` as in the compiled
//! program, a `#align(N)` struct needs its tail padding known before its body is built,
//! and `core::offset_of` / `core::align_of` must fold at compile time. This is that one
//! computation. It follows `backend/llvm/types.zig` for the 64-bit targets (natural
//! alignment, fields in declaration order, no reordering), and returns null for a type
//! whose layout it does not model — callers refuse or fall back.
//!
//! Struct definitions come from a `source`: anything with
//! `fn structDef(self, name: []const u8) ?ir.StructDef`. `SliceSource` serves a list of
//! IR struct definitions; the IR lowering supplies its own over the sema layouts.

const std = @import("std");
const ir = @import("ir.zig");

pub const Layout = struct {
    size: u64,
    alignment: u64,
};

const max_depth = 32;

/// A source of struct definitions backed by a slice (the VM's and the backend's view).
pub const SliceSource = struct {
    structs: []const ir.StructDef,

    pub fn structDef(self: SliceSource, name: []const u8) ?ir.StructDef {
        for (self.structs) |def| {
            if (std.mem.eql(u8, def.name, name)) return def;
        }
        return null;
    }
};

/// Layout of `ty`, looking struct types up in `structs`; null when unknown.
pub fn of(ty: ir.IrType, structs: []const ir.StructDef) ?Layout {
    return ofWith(ty, SliceSource{ .structs = structs });
}

/// Layout of `ty` with struct definitions supplied by `source`.
pub fn ofWith(ty: ir.IrType, source: anytype) ?Layout {
    return ofDepth(ty, source, 0);
}

/// Byte offset of `field` within the struct `def`, or null when the field does not exist
/// or an earlier field's layout is not modelled. A field of a `#packed` struct sits
/// immediately after the previous one; otherwise at its natural alignment. In a bit-packed
/// struct (`isBitPacked`) it is the byte the field's first bit is in.
pub fn offsetOfWith(def: ir.StructDef, field: []const u8, source: anytype) ?u64 {
    // A union's fields all start at its start.
    if (def.is_union) {
        for (def.fields) |f| if (std.mem.eql(u8, f.name, field)) return 0;
        return null;
    }
    if (isBitPacked(def)) {
        var places: [64]BitPlace = undefined;
        const all = bitPlaces(def, source, &places) orelse return null;
        for (def.fields, all) |f, place| if (std.mem.eql(u8, f.name, field)) return place.bit / 8;
        return null;
    }
    var offset: u64 = 0;
    for (def.fields) |f| {
        const member = memberLayout(f.ty, source, 1) orelse return null;
        if (!def.is_packed) offset = alignUp(offset, member.alignment);
        if (std.mem.eql(u8, f.name, field)) return offset;
        offset += member.size;
    }
    return null;
}

fn ofDepth(ty: ir.IrType, source: anytype, depth: u32) ?Layout {
    if (depth > max_depth) return null;
    return switch (ty) {
        .void => .{ .size = 0, .alignment = 1 },
        .bool, .byte => scalar(1),
        .i, .u => |bits| integer(bits),
        .rune => scalar(4),
        .f32 => scalar(4),
        .f64 => scalar(8),
        .usize, .isize, .addr, .ptr, .zone => scalar(8),
        .slice, .text, .interface_value => pair(8, 8),
        .fn_ptr => |fp| if (fp.thin) scalar(8) else pair(8, 8),
        .optional => |inner| optional(inner.*, source, depth),
        .fallible => |f| fallible(f, source, depth),
        .array => |arr| blk: {
            const elem = ofDepth(arr.elem.*, source, depth + 1) orelse return null;
            break :blk .{ .size = elem.size * arr.len, .alignment = elem.alignment };
        },
        .struct_type => |name| structLayout(name, source, depth),
        else => null,
    };
}

/// A struct member: laid out as the same type anywhere else (a `fn(...)` closure is two
/// words, an `extern fn(...)` one).
fn memberLayout(ty: ir.IrType, source: anytype, depth: u32) ?Layout {
    return ofDepth(ty, source, depth);
}

fn scalar(bytes: u64) Layout {
    return .{ .size = bytes, .alignment = bytes };
}

/// Two 8-byte-aligned words (`{ ptr, i64 }`, `{ ptr, ptr }`).
fn pair(a: u64, b: u64) Layout {
    return .{ .size = a + b, .alignment = 8 };
}

/// An `iN`: stored in whole bytes, aligned to the next power of two up to 16.
fn integer(bits: u16) Layout {
    const stored: u64 = (@as(u64, bits) + 7) / 8;
    const a: u64 = std.math.ceilPowerOfTwo(u64, @max(stored, 1)) catch 16;
    const alignment = @min(a, 16);
    return .{ .size = alignUp(stored, alignment), .alignment = alignment };
}

fn optional(inner: ir.IrType, source: anytype, depth: u32) ?Layout {
    // `?*T` is a nullable pointer, not a tagged pair.
    if (inner == .ptr) return scalar(8);
    // Otherwise `{ i1, T }`; a `void` payload is an `i8` placeholder.
    const payload = if (inner == .void)
        Layout{ .size = 1, .alignment = 1 }
    else
        ofDepth(inner, source, depth + 1) orelse return null;
    return record(&.{ .{ .size = 1, .alignment = 1 }, payload }, false);
}

fn fallible(f: ir.FallibleType, source: anytype, depth: u32) ?Layout {
    // `{ T, i32 }`, with an `i8` placeholder when the success type is void.
    const ok = if (f.ok.* == .void)
        Layout{ .size = 1, .alignment = 1 }
    else
        ofDepth(f.ok.*, source, depth + 1) orelse return null;
    return record(&.{ ok, .{ .size = 4, .alignment = 4 } }, false);
}

/// Where a field of a bit-packed struct sits: its first bit and how many bits it takes. An
/// integer takes its width; any other field its whole bytes, from a whole byte.
pub const BitPlace = struct {
    bit: u64,
    bits: u64,
    /// An integer, read and written by its bits; otherwise a field of whole bytes.
    int: bool,
};

/// The width of an integer field type in bits, or null when `ty` is no integer.
pub fn intBits(ty: ir.IrType) ?u64 {
    return switch (ty) {
        .i, .u => |bits| bits,
        .byte => 8,
        .usize, .isize => 64,
        else => null,
    };
}

/// Whether `def` is laid out bit by bit: a `#packed` struct with an integer field whose
/// width is no whole number of bytes (`u1`–`u7`, `i3`). Every other `#packed` struct lies
/// byte by byte, as before.
pub fn isBitPacked(def: ir.StructDef) bool {
    if (!def.is_packed or def.is_union) return false;
    for (def.fields) |f| if (intBits(f.ty)) |bits| if (bits % 8 != 0) return true;
    return false;
}

/// The place of each field of the bit-packed struct `def`, in `out`; null when a field's
/// layout is not modelled, or a field that is no integer starts inside a byte (the IR
/// refuses that struct when it is declared).
pub fn bitPlaces(def: ir.StructDef, source: anytype, out: []BitPlace) ?[]BitPlace {
    if (def.fields.len > out.len) return null;
    var bit: u64 = 0;
    for (def.fields, 0..) |f, i| {
        if (intBits(f.ty)) |bits| {
            out[i] = .{ .bit = bit, .bits = bits, .int = true };
            bit += bits;
            continue;
        }
        if (bit % 8 != 0) return null;
        const member = memberLayout(f.ty, source, 1) orelse return null;
        out[i] = .{ .bit = bit, .bits = member.size * 8, .int = false };
        bit += member.size * 8;
    }
    return out[0..def.fields.len];
}

/// The bits the fields of a bit-packed struct take, together.
pub fn bitsUsed(places: []const BitPlace) u64 {
    var end: u64 = 0;
    for (places) |p| end = @max(end, p.bit + p.bits);
    return end;
}

fn structLayout(name: []const u8, source: anytype, depth: u32) ?Layout {
    const def = source.structDef(name) orelse return null;
    if (isBitPacked(def)) {
        var places: [64]BitPlace = undefined;
        const all = bitPlaces(def, source, &places) orelse return null;
        return applyAlign(.{ .size = (bitsUsed(all) + 7) / 8, .alignment = 1 }, def);
    }
    var members: [64]Layout = undefined;
    // Larger than any plausible C struct; refuse rather than guess.
    if (def.fields.len > members.len) return null;
    for (def.fields, 0..) |field, i| {
        members[i] = memberLayout(field.ty, source, depth + 1) orelse return null;
    }
    if (def.is_union) return applyAlign(unionRecord(members[0..def.fields.len]), def);
    return applyAlign(record(members[0..def.fields.len], def.is_packed), def);
}

/// The effect of `#align(N)`: the struct is aligned to at least N and its size is
/// rounded up to a multiple of its alignment (as C's `alignas` does). A packed struct
/// keeps alignment 1 in LLVM, so only its size is rounded here.
pub fn applyAlign(base: Layout, def: ir.StructDef) Layout {
    if (def.alignment == 0) return base;
    const n: u64 = def.alignment;
    return .{
        .size = alignUp(base.size, n),
        .alignment = if (def.is_packed) base.alignment else @max(base.alignment, n),
    };
}

/// Lay `members` out in order — each at its natural alignment, or back to back when
/// `packed_` — and round the total up to the strictest alignment.
fn record(members: []const Layout, packed_: bool) Layout {
    var offset: u64 = 0;
    var alignment: u64 = 1;
    for (members) |m| {
        if (!packed_) {
            offset = alignUp(offset, m.alignment);
            alignment = @max(alignment, m.alignment);
        }
        offset += m.size;
    }
    return .{ .size = alignUp(offset, alignment), .alignment = alignment };
}

/// A union of `members`: the size of the largest, rounded up to the strictest alignment.
fn unionRecord(members: []const Layout) Layout {
    var size: u64 = 0;
    var alignment: u64 = 1;
    for (members) |m| {
        size = @max(size, m.size);
        alignment = @max(alignment, m.alignment);
    }
    return .{ .size = alignUp(size, alignment), .alignment = alignment };
}

fn alignUp(value: u64, alignment: u64) u64 {
    return (value + alignment - 1) / alignment * alignment;
}

/// Is `n` a valid `#align` argument: a power of two.
pub fn isValidAlign(n: u64) bool {
    return n != 0 and (n & (n - 1)) == 0;
}

test "layout: natural struct padding matches C" {
    const u8_ty: ir.IrType = .{ .u = 8 };
    const u16_ty: ir.IrType = .{ .u = 16 };
    const u32_ty: ir.IrType = .{ .u = 32 };
    const u64_ty: ir.IrType = .{ .u = 64 };
    const fields = [_]ir.FieldDef{
        .{ .name = "a", .ty = u8_ty },
        .{ .name = "b", .ty = u32_ty },
        .{ .name = "c", .ty = u64_ty },
        .{ .name = "d", .ty = u16_ty },
    };
    const defs = [_]ir.StructDef{.{ .name = "S", .fields = &fields, .is_packed = false }};
    const l = of(.{ .struct_type = "S" }, &defs).?;
    try std.testing.expectEqual(@as(u64, 24), l.size);
    try std.testing.expectEqual(@as(u64, 8), l.alignment);
    try std.testing.expectEqual(@as(?u64, 0), offsetOfWith(defs[0], "a", SliceSource{ .structs = &defs }));
    try std.testing.expectEqual(@as(?u64, 4), offsetOfWith(defs[0], "b", SliceSource{ .structs = &defs }));
    try std.testing.expectEqual(@as(?u64, 8), offsetOfWith(defs[0], "c", SliceSource{ .structs = &defs }));
    try std.testing.expectEqual(@as(?u64, 16), offsetOfWith(defs[0], "d", SliceSource{ .structs = &defs }));
    try std.testing.expectEqual(@as(?u64, null), offsetOfWith(defs[0], "nope", SliceSource{ .structs = &defs }));

    const packed_defs = [_]ir.StructDef{.{ .name = "S", .fields = &fields, .is_packed = true }};
    const p = of(.{ .struct_type = "S" }, &packed_defs).?;
    try std.testing.expectEqual(@as(u64, 15), p.size);
    try std.testing.expectEqual(@as(u64, 1), p.alignment);
    try std.testing.expectEqual(@as(?u64, 13), offsetOfWith(packed_defs[0], "d", SliceSource{ .structs = &packed_defs }));
}

test "layout: a #packed struct with sub-byte fields is laid out bit by bit" {
    const fields = [_]ir.FieldDef{
        .{ .name = "enable", .ty = .{ .u = 1 } },
        .{ .name = "mode", .ty = .{ .u = 3 } },
        .{ .name = "level", .ty = .{ .u = 8 } },
        .{ .name = "rest", .ty = .{ .u = 4 } },
        .{ .name = "tail", .ty = .{ .u = 16 } },
    };
    const defs = [_]ir.StructDef{.{ .name = "R", .fields = &fields, .is_packed = true }};
    const l = of(.{ .struct_type = "R" }, &defs).?;
    try std.testing.expectEqual(@as(u64, 4), l.size); // 32 bits
    try std.testing.expectEqual(@as(u64, 1), l.alignment);
    try std.testing.expectEqual(@as(?u64, 0), offsetOfWith(defs[0], "level", SliceSource{ .structs = &defs }));
    try std.testing.expectEqual(@as(?u64, 2), offsetOfWith(defs[0], "tail", SliceSource{ .structs = &defs }));
    // Without `#packed`, or with no sub-byte field, nothing changes.
    const plain = [_]ir.StructDef{.{ .name = "R", .fields = &fields, .is_packed = false }};
    try std.testing.expectEqual(@as(u64, 6), of(.{ .struct_type = "R" }, &plain).?.size);
}

test "layout: #align rounds size and raises alignment" {
    const u32_ty: ir.IrType = .{ .u = 32 };
    const fields = [_]ir.FieldDef{.{ .name = "a", .ty = u32_ty }};
    const defs = [_]ir.StructDef{.{ .name = "A", .fields = &fields, .is_packed = false, .alignment = 16 }};
    const l = of(.{ .struct_type = "A" }, &defs).?;
    try std.testing.expectEqual(@as(u64, 16), l.size);
    try std.testing.expectEqual(@as(u64, 16), l.alignment);
}
