//! fels.lock: the exact commit and content hash of every git package, written by
//! `fels fetch`, `fels add` and `fels update`. Builds use what it says, so they do not
//! change when a new version is tagged, and a hash mismatch stops the build.
//!
//!     #lock raylib from "github.com/raysan5/raylib" version "5.5.0"
//!         commit "c1ab645ca298a2801097931d1079b10ff7eb9df8" hash "sha256-9f2c...";

const std = @import("std");
const directives = @import("directives.zig");

pub const Problem = directives.Problem;
pub const Error = directives.Error;

pub const Entry = struct {
    name: []const u8,
    source: []const u8,
    /// The tag's version, or the branch or commit asked for.
    version: []const u8,
    commit: []const u8,
    hash: []const u8,
};

pub const Lock = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub fn find(self: Lock, name: []const u8) ?Entry {
        for (self.entries.items) |e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }

    /// Add `entry`, replacing one of the same name.
    pub fn put(self: *Lock, arena: std.mem.Allocator, entry: Entry) !void {
        for (self.entries.items) |*e| if (std.mem.eql(u8, e.name, entry.name)) {
            e.* = entry;
            return;
        };
        try self.entries.append(arena, entry);
    }

    pub fn remove(self: *Lock, name: []const u8) void {
        for (self.entries.items, 0..) |e, i| if (std.mem.eql(u8, e.name, name)) {
            _ = self.entries.orderedRemove(i);
            return;
        };
    }
};

pub fn parse(arena: std.mem.Allocator, source: []const u8, problem: *Problem) Error!Lock {
    var c = directives.Cursor.init(arena, source, problem);
    var lock: Lock = .{};
    while (try c.directive()) |d| {
        if (!std.mem.eql(u8, c.text(d), "lock")) return c.fail(d, "fels.lock has only #lock lines", .{});
        var e: Entry = undefined;
        e.name = try c.name("the package name");
        inline for (.{ .{ "from", "source" }, .{ "version", "version" }, .{ "commit", "commit" }, .{ "hash", "hash" } }) |kw| {
            if (!c.isWord(kw[0])) return c.fail(c.peek(), "expected `" ++ kw[0] ++ "`", .{});
            _ = c.next();
            @field(e, kw[1]) = try c.string(kw[0]);
        }
        _ = try c.expect(.semicolon, "`;`");
        try lock.entries.append(arena, e);
    }
    return lock;
}

/// fels.lock's text, entries sorted by name so the file only changes where a package does.
pub fn write(a: std.mem.Allocator, lock: Lock) ![]u8 {
    const sorted = try a.dupe(Entry, lock.entries.items);
    defer a.free(sorted);
    std.mem.sort(Entry, sorted, {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "// Written by fels fetch, add and update. Do not edit.\n");
    for (sorted) |e| {
        try out.print(a, "\n#lock {s} from \"{s}\" version \"{s}\"\n    commit \"{s}\" hash \"{s}\";\n", .{ e.name, e.source, e.version, e.commit, e.hash });
    }
    return out.toOwnedSlice(a);
}

test "fels.lock: written and read back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lock: Lock = .{};
    try lock.put(a, .{ .name = "zlib", .source = "github.com/x/zlib", .version = "1.3.1", .commit = "abc", .hash = "sha256-1" });
    try lock.put(a, .{ .name = "raylib", .source = "github.com/raysan5/raylib", .version = "5.5.0", .commit = "def", .hash = "sha256-2" });
    try lock.put(a, .{ .name = "zlib", .source = "github.com/x/zlib", .version = "1.3.2", .commit = "fed", .hash = "sha256-3" });
    const text = try write(a, lock);
    // Sorted by name, and the second zlib replaced the first.
    try std.testing.expect(std.mem.indexOf(u8, text, "raylib").? < std.mem.indexOf(u8, text, "zlib").?);
    var problem: Problem = .{};
    const back = try parse(a, text, &problem);
    try std.testing.expectEqual(@as(usize, 2), back.entries.items.len);
    try std.testing.expectEqualStrings("1.3.2", back.find("zlib").?.version);
    try std.testing.expectEqualStrings("def", back.find("raylib").?.commit);
}
