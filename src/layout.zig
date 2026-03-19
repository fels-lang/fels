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
/// immediately after the previous one; otherwise at its natural alignment. Sub-byte
/// fields (`u1`–`u7`) are not bit-packed: each occupies a whole byte.
pub fn offsetOfWith(def: ir.StructDef, field: []const u8, source: anytype) ?u64 {
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

fn structLayout(name: []const u8, source: anytype, depth: u32) ?Layout {
    const def = source.structDef(name) orelse return null;
    var members: [64]Layout = undefined;
    // Larger than any plausible C struct; refuse rather than guess.
    if (def.fields.len > members.len) return null;
    for (def.fields, 0..) |field, i| {
        members[i] = memberLayout(field.ty, source, depth + 1) orelse return null;
    }
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

test "layout: #align rounds size and raises alignment" {
    const u32_ty: ir.IrType = .{ .u = 32 };
    const fields = [_]ir.FieldDef{.{ .name = "a", .ty = u32_ty }};
    const defs = [_]ir.StructDef{.{ .name = "A", .fields = &fields, .is_packed = false, .alignment = 16 }};
    const l = of(.{ .struct_type = "A" }, &defs).?;
    try std.testing.expectEqual(@as(u64, 16), l.size);
    try std.testing.expectEqual(@as(u64, 16), l.alignment);
}
