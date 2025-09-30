//! Resolving the packages a project uses, with the packages they use: one version of each
//! package, from fels.lock where it has one, checked out into the cache when missing, and
//! each with the capabilities it was granted.

const std = @import("std");
const manifest_mod = @import("manifest.zig");
const lock_mod = @import("lock.zig");
const semver = @import("semver.zig");
const fetch = @import("fetch.zig");
const directives = @import("directives.zig");

const Manifest = manifest_mod.Manifest;
const Cap = manifest_mod.Cap;
const Use = manifest_mod.Use;

pub const ResolveError = error{ PackageError, OutOfMemory };

pub const Package = struct {
    name: []const u8,
    source: []const u8,
    /// The version as shown: a tag's version, a branch, or `path`.
    version: []const u8,
    /// The package's folder (where its fels.pkg is).
    dir: []const u8,
    /// The folder `#import <name>.x` reads from.
    import_dir: []const u8,
    /// What its compile-time code may do.
    caps: []const Cap,
    manifest: Manifest,
};

pub const Options = struct {
    /// The package cache (`fetch.cacheDir`).
    cache: []const u8,
    /// Packages to resolve again instead of taking fels.lock's commit; empty with
    /// `update_all` false means none.
    update: []const []const u8 = &.{},
    update_all: bool = false,
    /// Hash every git package's files and compare with fels.lock (`fels fetch --verify`).
    verify: bool = false,
    /// Never run git: a git package must be in fels.lock and in the cache (`--offline`, and
    /// the language server).
    offline: bool = false,
    /// A package that cannot be had (offline, not fetched yet; a missing folder) is left out
    /// and named in `Result.missing` instead of stopping (the language server).
    skip_missing: bool = false,
};

pub const Result = struct {
    packages: []Package,
    /// fels.lock as it should be now: what was resolved, nothing else.
    lock: lock_mod.Lock,
    /// Whether that differs from the fels.lock that was read.
    lock_changed: bool,
    /// Packages left out with `skip_missing`.
    missing: []const []const u8 = &.{},

    pub fn find(self: Result, name: []const u8) ?Package {
        for (self.packages) |p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }
};

/// Who uses a package: for messages and for the capabilities it can pass on.
const Consumer = struct {
    /// The fels.pkg the `#use` is in, and its text (for the line number).
    pkg_path: []const u8,
    pkg_source: []const u8,
    dir: []const u8,
    /// Null for the project itself, which may grant anything.
    caps: ?[]const Cap,
};

const Pending = struct { use: Use, from: Consumer };

/// Read the fels.pkg in `dir`; null when there is none.
pub fn readManifest(a: std.mem.Allocator, io: std.Io, dir: []const u8) ResolveError!?struct { m: Manifest, path: []const u8, source: []const u8 } {
    const path = std.fs.path.join(a, &.{ dir, "fels.pkg" }) catch return error.OutOfMemory;
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch return null;
    var problem: directives.Problem = .{};
    const m = manifest_mod.parse(a, source, &problem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => {
            const loc = directives.location(source, problem.at);
            std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ path, loc.line, loc.col, problem.msg });
            return error.PackageError;
        },
    };
    return .{ .m = m, .path = path, .source = source };
}

fn report(from: Consumer, use: Use, comptime fmt: []const u8, args: anytype) ResolveError {
    const loc = directives.location(from.pkg_source, use.at);
    std.debug.print("{s}:{d}:{d}: error: ", .{ from.pkg_path, loc.line, loc.col });
    std.debug.print(fmt ++ "\n", args);
    return error.PackageError;
}

fn wantsUpdate(opts: Options, name: []const u8) bool {
    if (opts.update_all) return true;
    for (opts.update) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The capabilities a package gets: what the `#use` line grants, no more than its consumer
/// holds (the project itself may grant anything).
fn narrow(a: std.mem.Allocator, granted: []const Cap, holder: ?[]const Cap) ![]const Cap {
    const have = holder orelse return granted;
    var out: std.ArrayList(Cap) = .empty;
    for (granted) |g| {
        if (manifest_mod.covers(have, g)) {
            try out.append(a, g);
            continue;
        }
        // Keep the libraries both name.
        for (have) |h| {
            if (!std.mem.eql(u8, h.name, g.name)) continue;
            const libs = if (g.args.len == 0) h.args else blk: {
                var both: std.ArrayList([]const u8) = .empty;
                for (g.args) |lib| for (h.args) |hl| if (std.ascii.eqlIgnoreCase(lib, hl)) try both.append(a, lib);
                break :blk try both.toOwnedSlice(a);
            };
            if (libs.len != 0) try out.append(a, .{ .name = g.name, .args = libs });
        }
    }
    return out.toOwnedSlice(a);
}

/// Where a git package's version comes from: fels.lock, or the repository's tags/branches.
fn pickCommit(
    a: std.mem.Allocator,
    io: std.Io,
    use: Use,
    from: Consumer,
    old: ?lock_mod.Entry,
    opts: Options,
) (ResolveError || error{NotLocked})!struct { version: []const u8, commit: []const u8 } {
    const range: ?semver.Range = if (use.version) |v| semver.Range.parse(v) else semver.Range.parse("*");
    if (old) |e| keep: {
        if (wantsUpdate(opts, use.name) or !std.mem.eql(u8, e.source, use.source)) break :keep;
        // The locked version must still be what fels.pkg asks for.
        if (range) |r| {
            const v = semver.Version.parse(e.version) orelse break :keep;
            if (!r.matches(v)) break :keep;
        } else if (!std.mem.eql(u8, e.version, use.version.?)) break :keep;
        return .{ .version = e.version, .commit = e.commit };
    }
    if (opts.offline) return error.NotLocked;

    const url = fetch.gitUrl(a, use.source) catch return error.OutOfMemory;
    if (range) |r| {
        const tags = fetch.listTags(a, io, url) catch return report(from, use, "cannot list the versions of `{s}` ({s})", .{ use.name, url });
        if (tags.len == 0 and use.version == null) {
            // No version tags: the default branch.
            const commit = fetch.resolveRef(a, io, url, "HEAD") catch return report(from, use, "cannot read `{s}` ({s})", .{ use.name, url });
            return .{ .version = "HEAD", .commit = commit };
        }
        const versions = a.alloc(semver.Version, tags.len) catch return error.OutOfMemory;
        for (tags, versions) |t, *v| v.* = t.version;
        const i = semver.newest(r, versions) orelse
            return report(from, use, "`{s}` has no version that matches \"{s}\" ({d} version tags in {s})", .{ use.name, use.version orelse "*", tags.len, url });
        return .{ .version = std.fmt.allocPrint(a, "{f}", .{tags[i].version}) catch return error.OutOfMemory, .commit = tags[i].commit };
    }
    const commit = fetch.resolveRef(a, io, url, use.version.?) catch return report(from, use, "cannot find \"{s}\" in `{s}` ({s})", .{ use.version.?, use.name, url });
    return .{ .version = use.version.?, .commit = commit };
}

/// Resolve every package the project in `root_dir` uses.
pub fn resolve(
    a: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    root_pkg_path: []const u8,
    root_source: []const u8,
    root: Manifest,
    old_lock: lock_mod.Lock,
    opts: Options,
) ResolveError!Result {
    var packages: std.ArrayList(Package) = .empty;
    var missing: std.ArrayList([]const u8) = .empty;
    var lock: lock_mod.Lock = .{};
    var queue: std.ArrayList(Pending) = .empty;
    const project: Consumer = .{ .pkg_path = root_pkg_path, .pkg_source = root_source, .dir = root_dir, .caps = null };
    for (root.uses) |u| queue.append(a, .{ .use = u, .from = project }) catch return error.OutOfMemory;

    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const use = queue.items[qi].use;
        const from = queue.items[qi].from;
        const granted = narrow(a, use.may, from.caps) catch return error.OutOfMemory;

        if (std.mem.eql(u8, use.name, "std") or std.mem.eql(u8, use.name, "build_options"))
            return report(from, use, "`{s}` cannot be a package name; it is fels's own", .{use.name});

        // A package used a second time: the same place and a version that fits.
        if (for (packages.items) |*p| {
            if (std.mem.eql(u8, p.name, use.name)) break p;
        } else null) |p| {
            const same = if (use.isPath())
                std.mem.eql(u8, p.dir, std.fs.path.resolve(a, &.{ from.dir, use.source }) catch return error.OutOfMemory)
            else
                std.mem.eql(u8, p.source, use.source);
            if (!same) return report(from, use, "`{s}` comes from \"{s}\" here, but another package uses `{s}` from \"{s}\"", .{ use.name, use.source, p.name, p.source });
            if (use.version) |want| if (semver.Range.parse(want)) |r| if (semver.Version.parse(p.version)) |have| {
                if (!r.matches(have)) return report(from, use, "`{s}` \"{s}\" is wanted here, but version {s} was chosen for another package that uses it; fels uses one version of each package", .{ use.name, want, p.version });
            };
            // Each grant counts: the package's code runs once, for everyone that uses it.
            p.caps = std.mem.concat(a, Cap, &.{ p.caps, granted }) catch return error.OutOfMemory;
            continue;
        }

        var pkg: Package = .{ .name = use.name, .source = use.source, .version = "path", .dir = undefined, .import_dir = undefined, .caps = granted, .manifest = .{} };
        if (use.isPath()) {
            pkg.dir = std.fs.path.resolve(a, &.{ from.dir, use.source }) catch return error.OutOfMemory;
            if (!fetch.exists(io, pkg.dir)) {
                if (opts.skip_missing) {
                    missing.append(a, use.name) catch return error.OutOfMemory;
                    continue;
                }
                return report(from, use, "the folder of `{s}` does not exist: {s}", .{ use.name, pkg.dir });
            }
        } else {
            const old = old_lock.find(use.name);
            const picked = pickCommit(a, io, use, from, old, opts) catch |err| switch (err) {
                error.NotLocked => {
                    if (opts.skip_missing) {
                        missing.append(a, use.name) catch return error.OutOfMemory;
                        continue;
                    }
                    return report(from, use, "`{s}` is not in fels.lock, and this build may not fetch; run `fels fetch` first", .{use.name});
                },
                else => |e| return e,
            };
            pkg.version = picked.version;
            pkg.dir = fetch.packageDir(a, opts.cache, use.name, picked.commit) catch return error.OutOfMemory;
            const fresh = !fetch.exists(io, pkg.dir);
            if (fresh and opts.offline) {
                if (opts.skip_missing) {
                    missing.append(a, use.name) catch return error.OutOfMemory;
                    continue;
                }
                return report(from, use, "`{s}` {s} is not in the package cache, and this build may not fetch; run `fels fetch` first", .{ use.name, picked.version });
            }
            if (fresh) {
                std.debug.print("  fetching {s} {s}\n", .{ use.name, picked.version });
                const url = fetch.gitUrl(a, use.source) catch return error.OutOfMemory;
                fetch.checkout(a, io, url, picked.commit, pkg.dir) catch
                    return report(from, use, "cannot fetch `{s}` {s} from {s}", .{ use.name, picked.version, url });
            }
            const same_commit = if (old) |e| std.mem.eql(u8, e.commit, picked.commit) else false;
            var hash: []const u8 = if (same_commit) old.?.hash else "";
            if (fresh or opts.verify or !same_commit) {
                const got = fetch.hashTree(a, io, pkg.dir) catch return report(from, use, "cannot read the files of `{s}` in {s}", .{ use.name, pkg.dir });
                if (same_commit and !std.mem.eql(u8, got, old.?.hash))
                    return report(from, use, "the files of `{s}` {s} do not match fels.lock\n  in fels.lock: {s}\n  in {s}: {s}\n  If the cache was changed, delete that folder and build again. If the package itself changed, `fels update {s}` takes the new files.", .{ use.name, picked.version, old.?.hash, pkg.dir, got, use.name });
                hash = got;
            }
            lock.put(a, .{ .name = use.name, .source = use.source, .version = picked.version, .commit = picked.commit, .hash = hash }) catch return error.OutOfMemory;
        }

        const read = try readManifest(a, io, pkg.dir);
        if (read) |r| pkg.manifest = r.m;
        // What its compile-time code needs must be granted.
        for (pkg.manifest.needs) |need| {
            if (manifest_mod.covers(granted, need)) continue;
            const want = manifest_mod.formatCap(a, need) catch return error.OutOfMemory;
            return report(from, use, "`{s}` {s} needs {s} at compile time, which is not granted to it\n  To allow it, add `may {s}` to this #use line.{s}", .{
                use.name,
                pkg.version,
                want,
                want,
                if (from.caps != null) " The package that uses it can only pass on what it was granted itself." else "",
            });
        }
        const root_rel = pkg.manifest.root orelse if (fetch.exists(io, std.fs.path.join(a, &.{ pkg.dir, "src" }) catch return error.OutOfMemory)) "src" else ".";
        pkg.import_dir = std.fs.path.resolve(a, &.{ pkg.dir, root_rel }) catch return error.OutOfMemory;
        packages.append(a, pkg) catch return error.OutOfMemory;

        if (read) |r| {
            const consumer: Consumer = .{ .pkg_path = r.path, .pkg_source = r.source, .dir = pkg.dir, .caps = granted };
            for (r.m.uses) |u| queue.append(a, .{ .use = u, .from = consumer }) catch return error.OutOfMemory;
        }
    }

    // Left-out packages keep their fels.lock line.
    for (missing.items) |name| if (old_lock.find(name)) |e| lock.put(a, e) catch return error.OutOfMemory;
    return .{ .packages = packages.items, .lock = lock, .lock_changed = !sameLock(old_lock, lock), .missing = missing.items };
}

fn sameLock(x: lock_mod.Lock, y: lock_mod.Lock) bool {
    if (x.entries.items.len != y.entries.items.len) return false;
    for (y.entries.items) |e| {
        const o = x.find(e.name) orelse return false;
        inline for (.{ "source", "version", "commit", "hash" }) |f|
            if (!std.mem.eql(u8, @field(o, f), @field(e, f))) return false;
    }
    return true;
}

test "resolve: capabilities narrow down the chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gl_gdi: Cap = .{ .name = "ffi", .args = &.{ "opengl32", "gdi32" } };
    const gl_net: Cap = .{ .name = "ffi", .args = &.{ "opengl32", "ws2_32" } };
    // The project grants freely.
    try std.testing.expectEqual(@as(usize, 1), (try narrow(a, &.{gl_net}, null)).len);
    // A package passes on only what it holds.
    const passed = try narrow(a, &.{gl_net}, &.{gl_gdi});
    try std.testing.expectEqual(@as(usize, 1), passed.len);
    try std.testing.expectEqual(@as(usize, 1), passed[0].args.len);
    try std.testing.expectEqualStrings("opengl32", passed[0].args[0]);
    // Any library, from a holder of some: those some.
    const any = try narrow(a, &.{.{ .name = "ffi" }}, &.{gl_gdi});
    try std.testing.expectEqual(@as(usize, 2), any[0].args.len);
    try std.testing.expectEqual(@as(usize, 0), (try narrow(a, &.{gl_gdi}, &.{})).len);
}
