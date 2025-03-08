const std = @import("std");
const value = @import("value.zig");

const ZoneId = value.ZoneId;
const Value = value.Value;

pub const ZoneError = error{
    NoActiveZone,
    ZoneUnderflow,
    OutOfBounds,
    OutOfMemory,
};

/// A single arena. Storage is an array of `Value` *cells* rather than raw
/// bytes — a comptime VM manipulates values, not machine representations, so
/// aggregates are blocks of cells (one per field / element) and pointers are
/// `(zone, cell-offset)`. Cells are addressed by index, never by host pointer,
/// so growing the backing array never invalidates an outstanding `Value.ptr`.
const Arena = struct {
    name: []const u8,
    cells: std.ArrayList(Value) = .empty,

    fn deinit(self: *Arena, allocator: std.mem.Allocator) void {
        self.cells.deinit(allocator);
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

    /// Reserve `count` zeroed (`.void`) cells in the top zone, returning a
    /// pointer to the first one.
    pub fn alloc(self: *ZoneStack, count: usize) ZoneError!Value {
        if (self.arenas.items.len == 0) return error.NoActiveZone;
        const zone_id: ZoneId = @intCast(self.arenas.items.len - 1);
        const top = &self.arenas.items[zone_id];
        const start = top.cells.items.len;
        try top.cells.appendNTimes(self.allocator, .void, @max(count, 1));
        return .{ .ptr = .{ .zone = zone_id, .offset = @intCast(start) } };
    }

    pub fn getCell(self: *const ZoneStack, zone: ZoneId, offset: u32) ZoneError!Value {
        if (zone >= self.arenas.items.len) return error.OutOfBounds;
        const cells = self.arenas.items[zone].cells.items;
        if (offset >= cells.len) return error.OutOfBounds;
        return cells[offset];
    }

    pub fn setCell(self: *ZoneStack, zone: ZoneId, offset: u32, val: Value) ZoneError!void {
        if (zone >= self.arenas.items.len) return error.OutOfBounds;
        const cells = self.arenas.items[zone].cells.items;
        if (offset >= cells.len) return error.OutOfBounds;
        cells[offset] = val;
    }
};

test "zone alloc returns cell offsets and pop frees memory" {
    var zs = ZoneStack.init(std.testing.allocator);
    defer zs.deinit();

    const z = try zs.push("scratch");
    try std.testing.expectEqual(@as(ZoneId, 0), z);

    const p1 = try zs.alloc(2); // 2 cells at offset 0
    const p2 = try zs.alloc(3); // 3 cells at offset 2
    try std.testing.expectEqual(@as(u32, 0), p1.ptr.offset);
    try std.testing.expectEqual(@as(u32, 2), p2.ptr.offset);

    try zs.setCell(0, 0, .{ .int = 42 });
    try std.testing.expectEqual(@as(i128, 42), (try zs.getCell(0, 0)).int);

    try zs.pop();
    try std.testing.expectEqual(@as(usize, 0), zs.depth());
    // std.testing.allocator asserts no leaks at deinit.
}

test "nested zones unwind via popTo" {
    var zs = ZoneStack.init(std.testing.allocator);
    defer zs.deinit();

    const watermark = zs.depth();
    _ = try zs.push("a");
    _ = try zs.alloc(4);
    _ = try zs.push("b");
    _ = try zs.alloc(8);
    try std.testing.expectEqual(@as(usize, 2), zs.depth());

    zs.popTo(watermark);
    try std.testing.expectEqual(@as(usize, 0), zs.depth());
}
