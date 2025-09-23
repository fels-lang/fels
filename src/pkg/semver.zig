//! Versions (`1.4.2`, `v1.4.2`, `2.0.0-rc.1`) and version ranges (`^1.4`, `~1.4`, `=1.4.2`,
//! `*`). A bare version is a caret range, as in Cargo: `1.4` means `^1.4`.

const std = @import("std");

pub const Version = struct {
    major: u32,
    minor: u32 = 0,
    patch: u32 = 0,
    /// The pre-release part after `-` (empty for a release).
    pre: []const u8 = "",

    /// `1`, `1.4`, `1.4.2`, with an optional leading `v` and a `-pre` part. Build metadata
    /// after `+` is ignored.
    pub fn parse(text: []const u8) ?Version {
        var t = text;
        if (t.len > 0 and (t[0] == 'v' or t[0] == 'V')) t = t[1..];
        if (std.mem.indexOfScalar(u8, t, '+')) |i| t = t[0..i];
        var pre: []const u8 = "";
        if (std.mem.indexOfScalar(u8, t, '-')) |i| {
            pre = t[i + 1 ..];
            t = t[0..i];
            if (pre.len == 0) return null;
        }
        var parts = std.mem.splitScalar(u8, t, '.');
        var nums: [3]u32 = .{ 0, 0, 0 };
        var count: usize = 0;
        while (parts.next()) |p| {
            if (count == 3 or p.len == 0) return null;
            nums[count] = std.fmt.parseInt(u32, p, 10) catch return null;
            count += 1;
        }
        if (count == 0) return null;
        return .{ .major = nums[0], .minor = nums[1], .patch = nums[2], .pre = pre };
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        inline for (.{ "major", "minor", "patch" }) |f| {
            const o = std.math.order(@field(a, f), @field(b, f));
            if (o != .eq) return o;
        }
        // A pre-release comes before its release.
        if (a.pre.len == 0 and b.pre.len == 0) return .eq;
        if (a.pre.len == 0) return .gt;
        if (b.pre.len == 0) return .lt;
        return std.mem.order(u8, a.pre, b.pre);
    }

    pub fn format(self: Version, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
        if (self.pre.len != 0) try w.print("-{s}", .{self.pre});
    }
};

pub const Range = struct {
    /// The lowest version that matches.
    min: Version,
    /// The first version that no longer matches; null for no upper bound.
    below: ?Version,
    /// `=1.4.2`: only that version (pre-releases included).
    exact: bool = false,

    /// `^1.4`, `~1.4`, `=1.4.2`, `1.4` (caret) or `*`. Null when `text` is not a range (then
    /// it names a git branch or commit).
    pub fn parse(text: []const u8) ?Range {
        if (std.mem.eql(u8, text, "*")) return .{ .min = .{ .major = 0 }, .below = null };
        if (text.len == 0) return null;
        const op = text[0];
        const rest = if (op == '^' or op == '~' or op == '=') text[1..] else text;
        const v = Version.parse(rest) orelse return null;
        const parts = std.mem.count(u8, stripPre(rest), ".") + 1;
        return switch (op) {
            '=' => .{ .min = v, .below = null, .exact = true },
            '~' => .{ .min = v, .below = if (parts == 1)
                .{ .major = v.major + 1 }
            else
                .{ .major = v.major, .minor = v.minor + 1 } },
            // Caret: the leftmost non-zero part may not change.
            else => .{ .min = v, .below = if (v.major != 0 or parts == 1)
                .{ .major = v.major + 1 }
            else if (v.minor != 0 or parts == 2)
                .{ .major = 0, .minor = v.minor + 1 }
            else
                .{ .major = 0, .minor = 0, .patch = v.patch + 1 } },
        };
    }

    pub fn matches(self: Range, v: Version) bool {
        if (self.exact) return v.order(self.min) == .eq and std.mem.eql(u8, v.pre, self.min.pre);
        // Pre-releases only match a range that names one.
        if (v.pre.len != 0 and self.min.pre.len == 0) return false;
        if (v.order(self.min) == .lt) return false;
        if (self.below) |b| if (v.order(b) != .lt) return false;
        return true;
    }
};

fn stripPre(t: []const u8) []const u8 {
    const v = if (t.len > 0 and (t[0] == 'v' or t[0] == 'V')) t[1..] else t;
    return v[0 .. std.mem.indexOfAny(u8, v, "-+") orelse v.len];
}

/// The newest of `versions` that `range` matches, as an index.
pub fn newest(range: Range, versions: []const Version) ?usize {
    var best: ?usize = null;
    for (versions, 0..) |v, i| {
        if (!range.matches(v)) continue;
        if (best == null or v.order(versions[best.?]) == .gt) best = i;
    }
    return best;
}

test "semver: versions parse and order" {
    const v = Version.parse("v1.4.2").?;
    try std.testing.expectEqual(@as(u32, 1), v.major);
    try std.testing.expectEqual(@as(u32, 2), v.patch);
    try std.testing.expectEqualStrings("rc.1", Version.parse("2.0.0-rc.1+abc").?.pre);
    try std.testing.expectEqual(@as(u32, 0), Version.parse("3").?.minor);
    try std.testing.expect(Version.parse("main") == null);
    try std.testing.expect(Version.parse("1.2.3.4") == null);
    try std.testing.expect(Version.parse("1..2") == null);
    try std.testing.expectEqual(std.math.Order.lt, Version.parse("2.0.0-rc.1").?.order(Version.parse("2.0.0").?));
    try std.testing.expectEqual(std.math.Order.gt, Version.parse("1.10.0").?.order(Version.parse("1.9.9").?));
}

test "semver: ranges match the versions they should" {
    const Case = struct { range: []const u8, yes: []const []const u8, no: []const []const u8 };
    for ([_]Case{
        .{ .range = "^1.4", .yes = &.{ "1.4.0", "1.9.3" }, .no = &.{ "1.3.9", "2.0.0", "1.5.0-rc.1" } },
        .{ .range = "1.4", .yes = &.{"1.4.7"}, .no = &.{"2.0.0"} },
        .{ .range = "^0.3", .yes = &.{"0.3.9"}, .no = &.{ "0.4.0", "0.2.9" } },
        .{ .range = "^0.0.3", .yes = &.{"0.0.3"}, .no = &.{"0.0.4"} },
        .{ .range = "~1.4", .yes = &.{"1.4.9"}, .no = &.{"1.5.0"} },
        .{ .range = "~1", .yes = &.{"1.9.0"}, .no = &.{"2.0.0"} },
        .{ .range = "=1.4.2", .yes = &.{"v1.4.2"}, .no = &.{ "1.4.3", "1.4.2-rc.1" } },
        .{ .range = "*", .yes = &.{ "0.0.1", "9.0.0" }, .no = &.{"1.0.0-beta"} },
        .{ .range = "^2.0.0-rc.1", .yes = &.{ "2.0.0-rc.2", "2.0.0" }, .no = &.{"3.0.0"} },
    }) |c| {
        const r = Range.parse(c.range).?;
        for (c.yes) |y| try std.testing.expect(r.matches(Version.parse(y).?));
        for (c.no) |n| try std.testing.expect(!r.matches(Version.parse(n).?));
    }
    try std.testing.expect(Range.parse("main") == null);
    try std.testing.expect(Range.parse("3f2a91c") == null);
}

test "semver: the newest matching version" {
    const vs = [_]Version{ Version.parse("1.2.0").?, Version.parse("1.10.0").?, Version.parse("2.0.0").?, Version.parse("1.11.0-rc.1").? };
    try std.testing.expectEqual(@as(?usize, 1), newest(Range.parse("^1.2").?, &vs));
    try std.testing.expectEqual(@as(?usize, null), newest(Range.parse("^3").?, &vs));
}
