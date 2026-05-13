//! fels.pkg: a package's name and version, and the packages it uses, as `#` directives.
//!
//!     #package mygame "0.1.0";
//!     #license "MIT";
//!
//!     #use raylib from "github.com/raysan5/raylib" version "^5.0"
//!         may ffi("opengl32", "gdi32", "winmm");
//!     #use mathlib from "../mathlib";
//!
//! A package that others use says what its compile-time code needs (`#needs ffi("user32");`)
//! and where its imports start (`#root "src";`). The user grants capabilities with `may`.

const std = @import("std");
const directives = @import("directives.zig");

pub const Problem = directives.Problem;
pub const Error = directives.Error;

/// The capabilities fels knows. `ffi` lets compile-time code call into host libraries; with
/// arguments, only into those. `read` lets it read files (`#embed`): with arguments, the files
/// below those folders of the package; without, the files of the package's folder.
pub const known_caps = [_][]const u8{ "ffi", "read" };

pub const Cap = struct {
    name: []const u8,
    /// The libraries `ffi` may call into, or the folders `read` may read; empty means any
    /// library, or the package's whole folder.
    args: []const []const u8 = &.{},
};

pub const Use = struct {
    name: []const u8,
    /// A path (starting with `.` or `/`, or a drive) or a git location.
    source: []const u8,
    /// A version range (`^5.0`, `~1.2`, `1.4.0`) or a git branch or commit; null means the
    /// newest version.
    version: ?[]const u8 = null,
    may: []const Cap = &.{},
    /// Byte offset of the `#use`, for messages.
    at: u32 = 0,
    /// Byte offset just after its `;` (`fels remove` cuts from `at` to here).
    end: u32 = 0,

    pub fn isPath(self: Use) bool {
        return isPathSource(self.source);
    }
};

pub fn isPathSource(source: []const u8) bool {
    if (source.len == 0) return false;
    if (source[0] == '.' or source[0] == '/' or source[0] == '\\') return true;
    return source.len >= 3 and source[1] == ':' and (source[2] == '/' or source[2] == '\\');
}

pub const Manifest = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    license: ?[]const u8 = null,
    description: ?[]const u8 = null,
    /// The folder imports of this package start in, relative to fels.pkg.
    root: ?[]const u8 = null,
    needs: []const Cap = &.{},
    uses: []const Use = &.{},

    pub fn find(self: Manifest, name: []const u8) ?Use {
        for (self.uses) |u| if (std.mem.eql(u8, u.name, name)) return u;
        return null;
    }
};

/// Parse fels.pkg. Strings and slices live in `arena`. On `error.Invalid`, `problem` says why.
pub fn parse(arena: std.mem.Allocator, source: []const u8, problem: *Problem) Error!Manifest {
    var c = directives.Cursor.init(arena, source, problem);
    var m: Manifest = .{};
    var uses: std.ArrayList(Use) = .empty;
    var needs: std.ArrayList(Cap) = .empty;

    while (try c.directive()) |d| {
        const word = c.text(d);
        if (std.mem.eql(u8, word, "package")) {
            m.name = try c.name("the package name");
            m.version = try c.string("its version");
        } else if (std.mem.eql(u8, word, "license")) {
            m.license = try c.string("the license");
        } else if (std.mem.eql(u8, word, "description")) {
            m.description = try c.string("the description");
        } else if (std.mem.eql(u8, word, "root")) {
            m.root = try c.string("the folder imports start in");
        } else if (std.mem.eql(u8, word, "needs")) {
            try caps(&c, &needs);
        } else if (std.mem.eql(u8, word, "use")) {
            var u: Use = .{ .at = c.hash_at, .name = undefined, .source = undefined };
            const name_tok = c.peek();
            u.name = try c.name("the name the package is imported by");
            for (uses.items) |other| if (std.mem.eql(u8, other.name, u.name))
                return c.fail(name_tok, "`{s}` is used twice", .{u.name});
            if (!c.isWord("from")) return c.fail(c.peek(), "expected `from \"<where>\"` after `#use {s}`", .{u.name});
            _ = c.next();
            u.source = try c.string("where the package comes from");
            if (c.isWord("version")) {
                _ = c.next();
                u.version = try c.string("the version");
            }
            if (c.isWord("may")) {
                _ = c.next();
                var may: std.ArrayList(Cap) = .empty;
                try caps(&c, &may);
                u.may = try may.toOwnedSlice(arena);
            }
            try uses.append(arena, u);
        } else {
            return c.fail(d, "unknown directive `#{s}`; fels.pkg has #package, #license, #description, #root, #needs and #use", .{word});
        }
        const semi = try c.expect(.semicolon, "`;` at the end of the directive");
        if (std.mem.eql(u8, word, "use")) uses.items[uses.items.len - 1].end = semi.start + 1;
    }
    m.uses = try uses.toOwnedSlice(arena);
    m.needs = try needs.toOwnedSlice(arena);
    return m;
}

/// `ffi("a", "b"), ffi` — one or more capabilities separated by commas.
fn caps(c: *directives.Cursor, out: *std.ArrayList(Cap)) Error!void {
    while (true) {
        const t = c.peek();
        const name = try c.name("a capability");
        const known = for (known_caps) |k| {
            if (std.mem.eql(u8, k, name)) break true;
        } else false;
        if (!known) return c.fail(t, "unknown capability `{s}`; fels knows `ffi` and `read`", .{name});
        const is_read = std.mem.eql(u8, name, "read");
        var args: std.ArrayList([]const u8) = .empty;
        if (c.peek().kind == .l_paren) {
            _ = c.next();
            while (true) {
                const at = c.peek();
                const arg = try c.string(if (is_read) "a folder of the package" else "a library name");
                // A package reads its own files: a folder of it, never one outside it.
                if (is_read and (std.fs.path.isAbsolute(arg) or std.mem.indexOf(u8, arg, "..") != null))
                    return c.fail(at, "`read(\"{s}\")` names a folder outside the package; it takes folders of the package, as `read(\"data\")`", .{arg});
                try args.append(c.arena, arg);
                if (c.peek().kind != .comma) break;
                _ = c.next();
            }
            _ = try c.expect(.r_paren, "`)`");
        }
        try out.append(c.arena, .{ .name = name, .args = try args.toOwnedSlice(c.arena) });
        if (c.peek().kind != .comma) return;
        _ = c.next();
    }
}

/// Whether `granted` covers `need`: the same capability, with every library `need` names (a
/// grant without libraries covers any). For `read`, a folder covers itself and the folders
/// below it.
pub fn covers(granted: []const Cap, need: Cap) bool {
    const folders = std.mem.eql(u8, need.name, "read");
    for (granted) |g| {
        if (!std.mem.eql(u8, g.name, need.name)) continue;
        if (g.args.len == 0) return true;
        if (need.args.len == 0) continue; // needs any library, granted only some
        const all = for (need.args) |lib| {
            const found = for (g.args) |ga| {
                if (if (folders) folderWithin(lib, ga) else std.ascii.eqlIgnoreCase(ga, lib)) break true;
            } else false;
            if (!found) break false;
        } else true;
        if (all) return true;
    }
    return false;
}

/// Whether the folder `inner` is `outer` or below it, both relative to a package, with `/`
/// and `\\` alike and the ends' slashes ignored.
pub fn folderWithin(inner: []const u8, outer: []const u8) bool {
    const i = std.mem.trim(u8, inner, "/\\");
    const o = std.mem.trim(u8, outer, "/\\");
    if (o.len == 0 or (o.len == 1 and o[0] == '.')) return true;
    if (i.len < o.len) return false;
    for (o, i[0..o.len]) |oc, ic| {
        const a = if (oc == '\\') '/' else std.ascii.toLower(oc);
        const b = if (ic == '\\') '/' else std.ascii.toLower(ic);
        if (a != b) return false;
    }
    return i.len == o.len or i[o.len] == '/' or i[o.len] == '\\';
}

/// A capability written as in fels.pkg: `ffi("a", "b")`.
pub fn formatCap(a: std.mem.Allocator, cap: Cap) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, cap.name);
    if (cap.args.len != 0) {
        try out.append(a, '(');
        for (cap.args, 0..) |arg, i| {
            if (i != 0) try out.appendSlice(a, ", ");
            try out.print(a, "\"{s}\"", .{arg});
        }
        try out.append(a, ')');
    }
    return out.toOwnedSlice(a);
}

test "fels.pkg: the package, its uses and their capabilities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var problem: Problem = .{};
    const src =
        \\// my game
        \\#package mygame "0.1.0";
        \\#license "MIT";
        \\#root "src";
        \\#needs ffi("kernel32");
        \\
        \\#use raylib from "github.com/raysan5/raylib" version "^5.0"
        \\    may ffi("opengl32", "gdi32");
        \\#use mathlib from "../mathlib";
    ;
    const m = try parse(arena.allocator(), src, &problem);
    try std.testing.expectEqualStrings("mygame", m.name.?);
    try std.testing.expectEqualStrings("0.1.0", m.version.?);
    try std.testing.expectEqualStrings("src", m.root.?);
    try std.testing.expectEqualStrings("kernel32", m.needs[0].args[0]);
    try std.testing.expectEqual(@as(usize, 2), m.uses.len);
    const rl = m.find("raylib").?;
    try std.testing.expect(!rl.isPath());
    try std.testing.expectEqualStrings("^5.0", rl.version.?);
    try std.testing.expectEqualStrings("gdi32", rl.may[0].args[1]);
    try std.testing.expect(m.find("mathlib").?.isPath());
    try std.testing.expect(m.find("mathlib").?.version == null);
    try std.testing.expectEqualStrings("#use mathlib from \"../mathlib\";", src[m.find("mathlib").?.at..m.find("mathlib").?.end]);
}

test "fels.pkg: mistakes are reported where they are" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Case = struct { src: []const u8, line: usize, msg: []const u8 };
    for ([_]Case{
        .{ .src = "#use a \"x\";", .line = 1, .msg = "expected `from" },
        .{ .src = "#package p \"1\";\n#use a from \"./a\" may net;", .line = 2, .msg = "unknown capability `net`" },
        .{ .src = "#use a from \"./a\";\n#use a from \"./b\";", .line = 2, .msg = "`a` is used twice" },
        .{ .src = "#import x;", .line = 1, .msg = "unknown directive `#import`" },
        .{ .src = "#use a from \"./a\"", .line = 1, .msg = "expected `;`" },
    }) |case| {
        var problem: Problem = .{};
        try std.testing.expectError(error.Invalid, parse(arena.allocator(), case.src, &problem));
        try std.testing.expectEqual(case.line, directives.location(case.src, problem.at).line);
        try std.testing.expect(std.mem.startsWith(u8, problem.msg, case.msg));
    }
}

test "fels.pkg: a grant covers a need" {
    const any: Cap = .{ .name = "ffi" };
    const gl: Cap = .{ .name = "ffi", .args = &.{"opengl32"} };
    const gl_gdi: Cap = .{ .name = "ffi", .args = &.{ "OpenGL32", "gdi32" } };
    try std.testing.expect(covers(&.{any}, gl));
    try std.testing.expect(covers(&.{gl_gdi}, gl));
    try std.testing.expect(!covers(&.{gl}, gl_gdi));
    try std.testing.expect(!covers(&.{gl}, any));
    try std.testing.expect(!covers(&.{}, gl));
}

test "read grants folders of the package, and a folder covers the ones below it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var problem: Problem = .{};
    const m = try parse(arena.allocator(), "#use words from \"../words\" may read(\"data\"), ffi(\"user32\");\n", &problem);
    const caps_of = m.uses[0].may;
    try std.testing.expect(covers(caps_of, .{ .name = "read", .args = &.{"data"} }));
    try std.testing.expect(covers(caps_of, .{ .name = "read", .args = &.{"data/sub"} }));
    try std.testing.expect(!covers(caps_of, .{ .name = "read", .args = &.{"database"} }));
    try std.testing.expect(!covers(caps_of, .{ .name = "read", .args = &.{"other"} }));
    try std.testing.expect(covers(&.{.{ .name = "read" }}, .{ .name = "read", .args = &.{"any/where"} }));
    try std.testing.expectError(error.Invalid, parse(arena.allocator(), "#use w from \"../w\" may read(\"../secrets\");\n", &problem));
}
