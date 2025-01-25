const std = @import("std");
const value = @import("value.zig");

const ZoneId = value.ZoneId;

pub const ZoneError = error{
    NoActiveZone,
    ZoneUnderflow,
    OutOfMemory,
};

/// A single arena: a growable, host-backed bump-allocation buffer.
///
/// Allocations are addressed by byte offset into `data`, never by host pointer,
/// so growing `data` (which may relocate it) does not invalidate any
/// previously-handed-out `Value.ptr`.
const Arena = struct {
    name: []const u8,
    data: std.ArrayList(u8) = .empty,

    fn deinit(self: *Arena, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
    }
};

/// The VM's stack of active zones. `zone_push` enters a new arena; `zone_pop`
/// (or `popTo`, on function unwind) frees the entire top arena at once — this is
/// what gives comptime execution its zero-leak, bounded-footprint property.
pub const ZoneStack = struct {
    allocator: std.mem.Allocator,
    arenas: std.ArrayList(Arena) = .empty,

    pub fn init(allocator: std.mem.Allocator) ZoneStack {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ZoneStack) void {
        for (self.arenas.items) |*arena| arena.deinit(self.allocator);
        self.arenas.deinit(self.allocator);
    }

    /// Number of active zones. Used as a watermark by call frames so a function
    /// return can unwind exactly the zones it opened.
    pub fn depth(self: *const ZoneStack) usize {
        return self.arenas.items.len;
    }

    /// Enter a new zone, returning its id (its index on the stack).
    pub fn push(self: *ZoneStack, name: []const u8) ZoneError!ZoneId {
        try self.arenas.append(self.allocator, .{ .name = name });
        return @intCast(self.arenas.items.len - 1);
    }

    /// Exit the top zone, freeing all of its memory.
    pub fn pop(self: *ZoneStack) ZoneError!void {
        if (self.arenas.items.len == 0) return error.ZoneUnderflow;
        var arena = self.arenas.pop().?;
        arena.deinit(self.allocator);
    }

    /// Unwind down to `watermark` zones (used on function return / error).
    pub fn popTo(self: *ZoneStack, watermark: usize) void {
        while (self.arenas.items.len > watermark) {
            var arena = self.arenas.pop().?;
            arena.deinit(self.allocator);
        }
    }

    /// Bump-allocate `size` zeroed bytes (aligned to `alignment`) in the top
    /// zone, returning a pointer value into it.
    pub fn alloc(self: *ZoneStack, size: usize, alignment: usize) ZoneError!value.Value {
        if (self.arenas.items.len == 0) return error.NoActiveZone;
        const zone_id: ZoneId = @intCast(self.arenas.items.len - 1);
        const top = &self.arenas.items[zone_id];
        const start = std.mem.alignForward(usize, top.data.items.len, @max(alignment, 1));
        try top.data.resize(self.allocator, start + size);
        @memset(top.data.items[start .. start + size], 0);
        return .{ .ptr = .{ .zone = zone_id, .offset = @intCast(start) } };
    }

    /// Raw byte view of a region — for aggregate load/store (Tier C).
    pub fn bytes(self: *ZoneStack, zone: ZoneId, offset: u32, len: usize) []u8 {
        return self.arenas.items[zone].data.items[offset .. offset + len];
    }
};

test "zone push/alloc/pop frees all memory" {
    var zs = ZoneStack.init(std.testing.allocator);
    defer zs.deinit();

    const z = try zs.push("scratch");
    try std.testing.expectEqual(@as(ZoneId, 0), z);
    try std.testing.expectEqual(@as(usize, 1), zs.depth());

    const p1 = try zs.alloc(4, 4);
    const p2 = try zs.alloc(8, 8);
    try std.testing.expectEqual(@as(value.ZoneId, 0), p1.ptr.zone);
    try std.testing.expectEqual(@as(u32, 0), p1.ptr.offset);
    // second alloc is aligned past the first
    try std.testing.expectEqual(@as(u32, 8), p2.ptr.offset);

    try zs.pop();
    try std.testing.expectEqual(@as(usize, 0), zs.depth());
    // std.testing.allocator asserts no leaks at deinit.
}

test "nested zones unwind via popTo" {
    var zs = ZoneStack.init(std.testing.allocator);
    defer zs.deinit();

    const watermark = zs.depth();
    _ = try zs.push("a");
    _ = try zs.alloc(16, 8);
    _ = try zs.push("b");
    _ = try zs.alloc(32, 8);
    try std.testing.expectEqual(@as(usize, 2), zs.depth());

    zs.popTo(watermark);
    try std.testing.expectEqual(@as(usize, 0), zs.depth());
}
