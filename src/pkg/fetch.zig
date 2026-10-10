//! Getting git packages: the versions a repository has (its tags), a checkout of one commit
//! into the package cache, and the content hash that fels.lock records.
//!
//! The cache is `%LOCALAPPDATA%\fels\pkg` on Windows and `~/.cache/fels/pkg` elsewhere
//! (`$FELS_PKG_DIR` overrides it). Each package version is a folder without `.git`, named
//! `<name>-<commit>`, and is not changed after it was checked out.

const std = @import("std");
const semver = @import("semver.zig");

pub const FetchError = error{ GitFailed, NotFound, HashMismatch, OutOfMemory, CacheFailed };

/// Where packages are kept.
pub fn cacheDir(a: std.mem.Allocator, env: ?*const std.process.Environ.Map) ![]const u8 {
    if (env) |e| {
        if (e.get("FELS_PKG_DIR")) |d| return a.dupe(u8, d);
        if (@import("builtin").os.tag == .windows) {
            if (e.get("LOCALAPPDATA")) |d| return std.fs.path.join(a, &.{ d, "fels", "pkg" });
        }
        if (e.get("XDG_CACHE_HOME")) |d| return std.fs.path.join(a, &.{ d, "fels", "pkg" });
        if (e.get("HOME")) |d| return std.fs.path.join(a, &.{ d, ".cache", "fels", "pkg" });
        if (e.get("USERPROFILE")) |d| return std.fs.path.join(a, &.{ d, ".cache", "fels", "pkg" });
    }
    return a.dupe(u8, ".fels-pkg");
}

/// The URL git fetches: `github.com/a/b` becomes `https://github.com/a/b`; a URL, `git@...`
/// or `file://...` stays as it is.
pub fn gitUrl(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, source, "://") != null or std.mem.startsWith(u8, source, "git@"))
        return a.dupe(u8, source);
    return std.fmt.allocPrint(a, "https://{s}", .{source});
}

pub const Tag = struct {
    name: []const u8,
    version: semver.Version,
    commit: []const u8,
};

/// Run git and return its standard output, or report its error output.
fn git(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8) FetchError![]const u8 {
    const r = std.process.run(a, io, .{
        .argv = argv,
        .cwd = if (cwd) |d| .{ .path = d } else .inherit,
    }) catch |err| {
        std.debug.print("fels: cannot run git ({s}); is git installed and on PATH?\n", .{@errorName(err)});
        return error.GitFailed;
    };
    switch (r.term) {
        .exited => |code| if (code == 0) return r.stdout,
        else => {},
    }
    std.debug.print("fels: `{s}` failed:\n{s}", .{ std.mem.join(a, " ", argv) catch "git", r.stderr });
    return error.GitFailed;
}

/// The tags of the repository that are versions, each with the commit it points to.
pub fn listTags(a: std.mem.Allocator, io: std.Io, url: []const u8) FetchError![]Tag {
    const out = try git(a, io, &.{ "git", "ls-remote", "--tags", url }, null);
    var tags: std.ArrayList(Tag) = .empty;
    var lines = std.mem.tokenizeAny(u8, out, "\r\n");
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const commit = line[0..tab];
        var ref = line[tab + 1 ..];
        if (!std.mem.startsWith(u8, ref, "refs/tags/")) continue;
        ref = ref["refs/tags/".len..];
        // An annotated tag is listed twice; the `^{}` line has the commit it points to.
        const peeled = std.mem.endsWith(u8, ref, "^{}");
        if (peeled) ref = ref[0 .. ref.len - 3];
        const v = semver.Version.parse(ref) orelse continue;
        const existing = for (tags.items) |*t| {
            if (std.mem.eql(u8, t.name, ref)) break t;
        } else null;
        if (existing) |t| {
            if (peeled) t.commit = commit;
        } else try tags.append(a, .{ .name = ref, .version = v, .commit = commit });
    }
    return tags.toOwnedSlice(a);
}

/// The commit a branch or tag points to, or `ref` itself when it is a full commit hash.
pub fn resolveRef(a: std.mem.Allocator, io: std.Io, url: []const u8, ref: []const u8) FetchError![]const u8 {
    if (ref.len == 40 and isHex(ref)) return ref;
    const out = try git(a, io, &.{ "git", "ls-remote", url, ref }, null);
    var lines = std.mem.tokenizeAny(u8, out, "\r\n");
    var found: ?[]const u8 = null;
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const name = line[tab + 1 ..];
        // Prefer the peeled commit of an annotated tag.
        if (std.mem.endsWith(u8, name, "^{}")) return line[0..tab];
        if (found == null) found = line[0..tab];
    }
    if (found) |c| return c;
    std.debug.print("fels: {s} has no branch, tag or commit `{s}` (a commit must be written in full)\n", .{ url, ref });
    return error.NotFound;
}

fn isHex(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// The cache folder of `name` at `commit`.
pub fn packageDir(a: std.mem.Allocator, cache: []const u8, name: []const u8, commit: []const u8) ![]const u8 {
    const folder = try std.fmt.allocPrint(a, "{s}-{s}", .{ name, commit[0..@min(commit.len, 12)] });
    return std.fs.path.join(a, &.{ cache, folder });
}

pub fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Check `commit` of `url` out into `dest` (without `.git`). Does nothing when `dest` exists.
pub fn checkout(a: std.mem.Allocator, io: std.Io, url: []const u8, commit: []const u8, dest: []const u8) FetchError!void {
    if (exists(io, dest)) return;
    const tmp = std.fmt.allocPrint(a, "{s}.tmp", .{dest}) catch return error.OutOfMemory;
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, tmp) catch {};
    cwd.createDirPath(io, tmp) catch return error.CacheFailed;
    errdefer cwd.deleteTree(io, tmp) catch {};
    _ = try git(a, io, &.{ "git", "init", "-q" }, tmp);
    _ = try git(a, io, &.{ "git", "fetch", "-q", "--depth", "1", url, commit }, tmp);
    // The repository's bytes as they are: without this, a user's core.autocrlf turns LF into
    // CRLF and the content hash differs from machine to machine.
    _ = try git(a, io, &.{ "git", "-c", "advice.detachedHead=false", "-c", "core.autocrlf=false", "-c", "core.eol=lf", "checkout", "-q", "FETCH_HEAD" }, tmp);
    const dot_git = std.fs.path.join(a, &.{ tmp, ".git" }) catch return error.OutOfMemory;
    cwd.deleteTree(io, dot_git) catch return error.CacheFailed;
    cwd.rename(tmp, cwd, dest, io) catch return error.CacheFailed;
}

/// `sha256-<hex>` over every file below `dir`: their paths (with `/`) in sorted order, and
/// their bytes. The same files give the same hash on every machine.
pub fn hashTree(a: std.mem.Allocator, io: std.Io, dir_path: []const u8) FetchError![]const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return error.NotFound;
    defer dir.close(io);
    var walker = dir.walk(a) catch return error.OutOfMemory;
    defer walker.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    while (walker.next(io) catch return error.CacheFailed) |entry| {
        if (entry.kind != .file) continue;
        const rel = a.dupe(u8, entry.path) catch return error.OutOfMemory;
        for (rel) |*c| if (c.* == '\\') {
            c.* = '/';
        };
        files.append(a, rel) catch return error.OutOfMemory;
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);

    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (files.items) |rel| {
        const data = dir.readFileAlloc(io, rel, a, .unlimited) catch return error.CacheFailed;
        defer a.free(data);
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, &len, data.len, .little);
        h.update(rel);
        h.update(&.{0});
        h.update(&len);
        h.update(data);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.allocPrint(a, "sha256-{x}", .{&digest}) catch return error.OutOfMemory;
}

test "fetch: git URLs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("https://github.com/a/b", try gitUrl(a, "github.com/a/b"));
    try std.testing.expectEqualStrings("file:///c/x", try gitUrl(a, "file:///c/x"));
    try std.testing.expectEqualStrings("git@github.com:a/b", try gitUrl(a, "git@github.com:a/b"));
}

test "fetch: the hash of a folder depends on its files, not on the order they were written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const base = ".zig-cache/pkg_hash";
    cwd.deleteTree(io, base) catch {};
    for ([_][]const u8{ "one", "two" }) |side| {
        const d = try std.fmt.allocPrint(a, "{s}/{s}", .{ base, side });
        try cwd.createDirPath(io, try std.fmt.allocPrint(a, "{s}/src", .{d}));
        const order: []const []const u8 = if (std.mem.eql(u8, side, "one")) &.{ "a.fels", "src/b.fels" } else &.{ "src/b.fels", "a.fels" };
        for (order) |f| try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ d, f }), .data = f });
    }
    const h1 = try hashTree(a, io, base ++ "/one");
    const h2 = try hashTree(a, io, base ++ "/two");
    try std.testing.expectEqualStrings(h1, h2);
    try std.testing.expect(std.mem.startsWith(u8, h1, "sha256-"));
    try cwd.writeFile(io, .{ .sub_path = base ++ "/two/a.fels", .data = "changed" });
    try std.testing.expect(!std.mem.eql(u8, h1, try hashTree(a, io, base ++ "/two")));
}
