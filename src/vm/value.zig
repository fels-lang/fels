const std = @import("std");
const ir = @import("../ir.zig");
const sema = @import("../sema.zig");

/// Index of a zone (arena) on the VM's zone stack. See `zones.zig`.
pub const ZoneId = u32;

/// A runtime value inside the comptime VM.
///
/// Scalars live inline; aggregates and pointers refer into zone-backed memory
/// by `(zone, offset)` rather than a raw host pointer. Addressing aggregates by
/// offset (not pointer) keeps the VM relocatable — a zone's backing buffer may
/// be reallocated as it grows without invalidating existing values — and makes
/// freeing a whole zone trivially correct.
///
/// NOTE (Tier A): the aggregate variants below are defined so the value model is
/// complete, but the engine does not yet read/write through them. Scalars,
/// `ptr`, and zone allocation are live; struct/slice/variant loads are Tier C.
pub const Value = union(enum) {
    void,
    /// All signed integer widths. The width is carried by the IR type at the
    /// instruction, not the value; arithmetic happens in i128 then re-narrows.
    int: i128,
    /// All unsigned integer widths (and runes).
    uint: u128,
    float: f64,
    bool: bool,
    /// Pointer into zone-backed memory.
    ptr: Ptr,
    /// Slice: pointer + element count into zone-backed memory.
    slice: Slice,
    /// Interned string (lives in the host/AST arena, not a zone).
    string: []const u8,
    struct_ref: Ref,
    variant: Variant,
    /// First-class type value (for `$T` parameters / reflection).
    type_val: sema.Ty,
    /// Index into the VM module's function table.
    fn_ref: u32,
    null_ptr,
    /// A raw host pointer — a real process address, with the byte size of the
    /// pointee so loads/stores know their width. Produced by `ptr_from_int` and
    /// `field_addr` on a host struct; lets the comptime VM run byte-addressed code
    /// like `std.heap.Arena` (which `VirtualAlloc`s real memory) exactly as at
    /// runtime. Distinct from the cell `ptr` so the engine dispatches per kind.
    host_ptr: HostPtr,
    /// A slice over raw host memory: a real address + element count + byte stride.
    host_buf: HostBuf,

    pub const Ptr = struct { zone: ZoneId, offset: u32 };
    pub const Slice = struct { zone: ZoneId, offset: u32, len: usize };
    pub const Ref = struct { zone: ZoneId, offset: u32 };
    pub const Variant = struct { tag: u32, payload_zone: ZoneId, payload_offset: u32 };
    pub const HostPtr = struct { addr: usize, size: u32 };
    pub const HostBuf = struct { addr: usize, len: usize, stride: u32 };

    /// Lift an IR immediate into a VM value.
    pub fn fromImm(imm: ir.Imm) Value {
        return switch (imm) {
            .int => |v| .{ .int = v },
            .uint => |v| .{ .uint = v },
            .float => |v| .{ .float = v },
            .bool => |b| .{ .bool = b },
            .text => |t| .{ .string = t },
            .rune => |r| .{ .uint = r },
            .null => .null_ptr,
        };
    }

    /// Lower a VM value back into an IR immediate, for splicing a `#run` result
    /// back into the IR. Returns null for values with no immediate form
    /// (pointers, aggregates, types).
    pub fn toImm(self: Value) ?ir.Imm {
        return switch (self) {
            .int => |v| .{ .int = v },
            .uint => |v| .{ .uint = v },
            .float => |v| .{ .float = v },
            .bool => |b| .{ .bool = b },
            .string => |s| .{ .text = s },
            .null_ptr => .null,
            else => null,
        };
    }

    /// Interpret an integer-like value as i128 for arithmetic. Booleans count as
    /// 0/1. Unsigned values that exceed i128 wrap by bit pattern.
    pub fn asI128(self: Value) ?i128 {
        return switch (self) {
            .int => |v| v,
            .uint => |v| std.math.cast(i128, v) orelse @as(i128, @bitCast(v)),
            .bool => |b| @intFromBool(b),
            else => null,
        };
    }

    pub fn asF64(self: Value) ?f64 {
        return switch (self) {
            .float => |v| v,
            .int => |v| @floatFromInt(v),
            .uint => |v| @floatFromInt(v),
            else => null,
        };
    }

    /// Branch condition test.
    pub fn truthy(self: Value) bool {
        return switch (self) {
            .bool => |b| b,
            .int => |v| v != 0,
            .uint => |v| v != 0,
            .null_ptr => false,
            else => false,
        };
    }
};
