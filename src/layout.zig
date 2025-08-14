//! Size and alignment of Gabbro types, worked out from IR types alone.
//!
//! The LLVM backend lowers a type and asks LLVM for its layout; the comptime VM has no
//! LLVM, yet `core::sizeof` must give the same answer in a `#run` as in the compiled
//! program, and a `#align(N)` struct needs its tail padding known before its body is
//! built. This is that one computation. It follows `backend/llvm/types.zig` for the
//! 64-bit targets (natural alignment, no field reordering), and returns null for a type
//! whose layout it does not model — callers fall back or refuse.

const std = @import("std");
const ir = @import("ir.zig");

pub const Layout = struct {
    size: u64,
    alignment: u64,
};

const max_depth = 32;

/// Layout of `ty`, looking struct types up in `structs`; null when unknown.
pub fn of(ty: ir.IrType, structs: []const ir.StructDef) ?Layout {
    return ofDepth(ty, structs, 0);
}

fn ofDepth(ty: ir.IrType, structs: []const ir.StructDef, depth: u32) ?Layout {
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
        .optional => |inner| optional(inner.*, structs, depth),
        .fallible => |f| fallible(f, structs, depth),
        .array => |arr| blk: {
            const elem = ofDepth(arr.elem.*, structs, depth + 1) orelse return null;
            break :blk .{ .size = elem.size * arr.len, .alignment = elem.alignment };
        },
        .struct_type => |name| structLayout(name, structs, depth),
        else => null,
    };
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

fn optional(inner: ir.IrType, structs: []const ir.StructDef, depth: u32) ?Layout {
    // `?*T` is a nullable pointer, not a tagged pair.
    if (inner == .ptr) return scalar(8);
    // Otherwise `{ i1, T }`; a `void` payload is an `i8` placeholder.
    const payload = if (inner == .void)
        Layout{ .size = 1, .alignment = 1 }
    else
        ofDepth(inner, structs, depth + 1) orelse return null;
    return record(&.{ .{ .size = 1, .alignment = 1 }, payload }, false);
}

fn fallible(f: ir.FallibleType, structs: []const ir.StructDef, depth: u32) ?Layout {
    // `{ T, i32 }`, with an `i8` placeholder when the success type is void.
    const ok = if (f.ok.* == .void)
        Layout{ .size = 1, .alignment = 1 }
    else
        ofDepth(f.ok.*, structs, depth + 1) orelse return null;
    return record(&.{ ok, .{ .size = 4, .alignment = 4 } }, false);
}

fn structLayout(name: []const u8, structs: []const ir.StructDef, depth: u32) ?Layout {
    for (structs) |def| {
        if (!std.mem.eql(u8, def.name, name)) continue;
        var members: [64]Layout = undefined;
        // Larger than any plausible C struct; refuse rather than guess.
        if (def.fields.len > members.len) return null;
        for (def.fields, 0..) |field, i| {
            // A `fn(...)` field is always a thin pointer in a struct.
            members[i] = if (field.ty == .fn_ptr)
                scalar(8)
            else
                ofDepth(field.ty, structs, depth + 1) orelse return null;
        }
        const base = record(members[0..def.fields.len], def.is_packed);
        return applyAlign(base, def);
    }
    return null;
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

    const packed_defs = [_]ir.StructDef{.{ .name = "S", .fields = &fields, .is_packed = true }};
    const p = of(.{ .struct_type = "S" }, &packed_defs).?;
    try std.testing.expectEqual(@as(u64, 15), p.size);
    try std.testing.expectEqual(@as(u64, 1), p.alignment);
}

test "layout: #align rounds size and raises alignment" {
    const u32_ty: ir.IrType = .{ .u = 32 };
    const fields = [_]ir.FieldDef{.{ .name = "a", .ty = u32_ty }};
    const defs = [_]ir.StructDef{.{ .name = "A", .fields = &fields, .is_packed = false, .alignment = 16 }};
    const l = of(.{ .struct_type = "A" }, &defs).?;
    try std.testing.expectEqual(@as(u64, 16), l.size);
    try std.testing.expectEqual(@as(u64, 16), l.alignment);
}
