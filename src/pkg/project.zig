//! A project's packages: read fels.pkg and fels.lock in a folder, resolve, and write
//! fels.lock when it changed. `fels build`, `fetch`, `update` and `add` go through here.

const std = @import("std");
const manifest_mod = @import("manifest.zig");
const lock_mod = @import("lock.zig");
const resolve_mod = @import("resolve.zig");
const fetch = @import("fetch.zig");
const directives = @import("directives.zig");
const semver = @import("semver.zig");

pub const Result = resolve_mod.Result;
pub const Package = resolve_mod.Package;
pub const Error = resolve_mod.ResolveError;

pub const Options = struct {
    update: []const []const u8 = &.{},
    update_all: bool = false,
    verify: bool = false,
    /// Never run git (`--offline`).
    offline: bool = false,
    /// Stop when fels.lock would change (`--frozen`, for CI).
    frozen: bool = false,
    /// Leave out packages that cannot be had, and do not write fels.lock (the language server).
    skip_missing: bool = false,
};

/// Resolve the packages of the project in `dir`; null when it has no fels.pkg.
pub fn load(
    a: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    env: ?*const std.process.Environ.Map,
    opts: Options,
) Error!?Result {
    const read = try resolve_mod.readManifest(a, io, dir) orelse return null;
    const lock_path = std.fs.path.join(a, &.{ dir, "fels.lock" }) catch return error.OutOfMemory;
    var old: lock_mod.Lock = .{};
    if (std.Io.Dir.cwd().readFileAlloc(io, lock_path, a, .unlimited)) |text| {
        var problem: directives.Problem = .{};
        old = lock_mod.parse(a, text, &problem) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => {
                const loc = directives.location(text, problem.at);
                std.debug.print("{s}:{d}:{d}: error: {s}\n  Delete fels.lock and run `fels fetch` to write it again.\n", .{ lock_path, loc.line, loc.col, problem.msg });
                return error.PackageError;
            },
        };
    } else |_| {}

    const cache = fetch.cacheDir(a, env) catch return error.OutOfMemory;
    const vendor_path = std.fs.path.join(a, &.{ dir, "vendor" }) catch return error.OutOfMemory;
    const result = try resolve_mod.resolve(a, io, dir, read.path, read.source, read.m, old, .{
        .vendor_dir = if (fetch.exists(io, vendor_path)) vendor_path else null,
        .cache = cache,
        .update = opts.update,
        .update_all = opts.update_all,
        .verify = opts.verify,
        .offline = opts.offline or opts.skip_missing,
        .skip_missing = opts.skip_missing,
    });
    if (result.lock_changed and opts.frozen) {
        std.debug.print("{s}: error: fels.lock would change (fels.pkg asks for something it does not have); run `fels fetch` and commit fels.lock\n", .{lock_path});
        return error.PackageError;
    }
    if (result.lock_changed and !opts.skip_missing) {
        const text = lock_mod.write(a, result.lock) catch return error.OutOfMemory;
        if (result.lock.entries.items.len == 0) {
            std.Io.Dir.cwd().deleteFile(io, lock_path) catch {};
        } else std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lock_path, .data = text }) catch {
            std.debug.print("fels: cannot write {s}\n", .{lock_path});
            return error.PackageError;
        };
    }
    return result;
}

/// One line per package: `raylib 5.5.0  github.com/raysan5/raylib  may ffi("opengl32")`.
pub fn printPackages(a: std.mem.Allocator, packages: []const Package) void {
    for (packages) |p| {
        std.debug.print("  {s: <16} {s: <10} {s}", .{ p.name, p.version, p.source });
        if (p.caps.len != 0) {
            std.debug.print("  may", .{});
            for (p.caps, 0..) |c, i| {
                const text = manifest_mod.formatCap(a, c) catch c.name;
                std.debug.print("{s} {s}", .{ if (i == 0) "" else ",", text });
            }
        }
        std.debug.print("\n", .{});
    }
}

/// `fels fetch [--verify]`: get every package fels.pkg uses and write fels.lock.
pub fn cmdFetch(a: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, args: []const []const u8) u8 {
    var verify = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--verify")) verify = true else {
            std.debug.print("fels fetch: unknown argument '{s}'\n", .{arg});
            return 1;
        }
    }
    const result = load(a, io, ".", env, .{ .verify = verify }) catch return 1;
    const r = result orelse {
        std.debug.print("fels fetch: no fels.pkg in the current directory\n", .{});
        return 1;
    };
    printPackages(a, r.packages);
    if (verify) std.debug.print("the files of every git package match fels.lock\n", .{});
    return 0;
}

/// A package whose version `fels update` changed; `from` is empty for one new to fels.lock.
pub const Change = struct { name: []const u8, from: []const u8, to: []const u8 };

/// fels.lock in `dir` as it is, before anything resolves: empty when there is none or it
/// does not read.
pub fn readLock(a: std.mem.Allocator, io: std.Io, dir: []const u8) lock_mod.Lock {
    const lock_path = std.fs.path.join(a, &.{ dir, "fels.lock" }) catch return .{};
    const text = std.Io.Dir.cwd().readFileAlloc(io, lock_path, a, .unlimited) catch return .{};
    var problem: directives.Problem = .{};
    return lock_mod.parse(a, text, &problem) catch .{};
}

/// The packages of `after` whose version is not the one `locked` had.
pub fn changes(a: std.mem.Allocator, locked: lock_mod.Lock, after: Result) error{OutOfMemory}![]const Change {
    var out: std.ArrayList(Change) = .empty;
    for (after.packages) |p| {
        const from = if (locked.find(p.name)) |e| e.version else "";
        if (std.mem.eql(u8, from, p.version)) continue;
        try out.append(a, .{ .name = p.name, .from = from, .to = p.version });
    }
    return out.items;
}

/// `fels update [name...]`: take the newest versions fels.pkg allows (of all packages, or
/// the named ones) and write them to fels.lock. What changed is told against fels.lock as it
/// was, so a version that a changed range in fels.pkg brought counts too.
pub fn cmdUpdate(a: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, args: []const []const u8) u8 {
    const locked = readLock(a, io, ".");
    const before = load(a, io, ".", env, .{}) catch return 1;
    const old = before orelse {
        std.debug.print("fels update: no fels.pkg in the current directory\n", .{});
        return 1;
    };
    for (args) |name| if (old.find(name) == null) {
        std.debug.print("fels update: fels.pkg does not use a package named '{s}'\n", .{name});
        return 1;
    };
    const after = (load(a, io, ".", env, .{ .update = args, .update_all = args.len == 0 }) catch return 1).?;
    const changed = changes(a, locked, after) catch return 1;
    for (changed) |c| {
        if (c.from.len == 0) {
            std.debug.print("  {s}: {s} (new)\n", .{ c.name, c.to });
        } else std.debug.print("  {s}: {s} -> {s}\n", .{ c.name, c.from, c.to });
    }
    if (changed.len == 0) std.debug.print("everything is at the newest version fels.pkg allows\n", .{});
    return 0;
}

/// `fels add <name> <source> [version] [--may <caps>]`: add a `#use` line to fels.pkg (and
/// create fels.pkg if there is none), then fetch the package. fels.pkg stays as it was
/// when that fails.
pub fn cmdAdd(a: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, args: []const []const u8) u8 {
    var positional: std.ArrayList([]const u8) = .empty;
    var may: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--may") and i + 1 < args.len) {
            i += 1;
            may = args[i];
        } else positional.append(a, args[i]) catch return 1;
    }
    if (positional.items.len < 2 or positional.items.len > 3) {
        std.debug.print(
            \\usage: fels add <name> <source> [version] [--may <capabilities>]
            \\  fels add raylib github.com/raysan5/raylib ^5.0 --may 'ffi("opengl32")'
            \\  fels add mathlib ../mathlib
            \\
        , .{});
        return 1;
    }
    const name = positional.items[0];
    const version: ?[]const u8 = if (positional.items.len == 3) positional.items[2] else null;
    const p = add(a, io, env, ".", name, positional.items[1], version, may) catch return 1;
    std.debug.print("added {s} {s}\n", .{ p.name, p.version });
    return 0;
}

/// Add `#use <name> from "<source>"` to the fels.pkg in `dir` (creating it when there is
/// none) and resolve. Without a `version`, a package that resolves to a version tag gets the
/// range of that version (`^0.4` for 0.4.2, `^1.2` for 1.2.0), so a later `fels update` does not
/// bring a version that breaks it. On failure fels.pkg is left as it was.
pub fn add(
    a: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    dir: []const u8,
    name: []const u8,
    source: []const u8,
    version: ?[]const u8,
    may: ?[]const u8,
) Error!Package {
    const path = std.fs.path.join(a, &.{ dir, "fels.pkg" }) catch return error.OutOfMemory;
    const cwd = std.Io.Dir.cwd();
    const before: ?[]const u8 = cwd.readFileAlloc(io, path, a, .unlimited) catch null;
    var text: std.ArrayList(u8) = .empty;
    if (before) |b| {
        text.appendSlice(a, b) catch return error.OutOfMemory;
        if (b.len != 0 and b[b.len - 1] != '\n') text.append(a, '\n') catch return error.OutOfMemory;
    } else {
        // A new fels.pkg, named after the folder.
        const here = std.fs.path.resolve(a, &.{ std.process.currentPathAlloc(io, a) catch ".", dir }) catch return error.OutOfMemory;
        text.print(a, "#package {s} \"0.1.0\";\n\n", .{packageName(a, std.fs.path.basename(here))}) catch return error.OutOfMemory;
    }
    text.print(a, "#use {s} from \"{s}\"", .{ name, source }) catch return error.OutOfMemory;
    if (version) |v| text.print(a, " version \"{s}\"", .{v}) catch return error.OutOfMemory;
    const after_name = text.items.len;
    if (may) |m| text.print(a, "\n    may {s}", .{m}) catch return error.OutOfMemory;
    text.appendSlice(a, ";\n") catch return error.OutOfMemory;

    cwd.writeFile(io, .{ .sub_path = path, .data = text.items }) catch {
        std.debug.print("fels add: cannot write {s}\n", .{path});
        return error.PackageError;
    };
    const result = load(a, io, dir, env, .{}) catch |err| {
        // Put fels.pkg back as it was.
        if (before) |b| cwd.writeFile(io, .{ .sub_path = path, .data = b }) catch {} else cwd.deleteFile(io, path) catch {};
        std.debug.print("fels add: fels.pkg was not changed\n", .{});
        return err;
    };
    const p = result.?.find(name).?;
    if (version == null) if (semver.Version.parse(p.version)) |v| if (v.pre.len == 0) {
        // The range goes in after the source; the version resolved stays in fels.lock.
        var with_range: std.ArrayList(u8) = .empty;
        with_range.appendSlice(a, text.items[0..after_name]) catch return error.OutOfMemory;
        with_range.print(a, " version \"^{d}.{d}\"", .{ v.major, v.minor }) catch return error.OutOfMemory;
        with_range.appendSlice(a, text.items[after_name..]) catch return error.OutOfMemory;
        cwd.writeFile(io, .{ .sub_path = path, .data = with_range.items }) catch {};
    };
    return p;
}

/// `fels remove <name>...`: take the `#use` lines out of fels.pkg and the packages that are no
/// longer used out of fels.lock.
pub fn cmdRemove(a: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, args: []const []const u8) u8 {
    if (args.len == 0) {
        std.debug.print("usage: fels remove <name>...\n", .{});
        return 1;
    }
    remove(a, io, env, ".", args) catch return 1;
    for (args) |name| std.debug.print("removed {s}\n", .{name});
    return 0;
}

/// Remove the `#use` lines of `names` from the fels.pkg in `dir`, then resolve so fels.lock
/// keeps only what is still used.
pub fn remove(a: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, dir: []const u8, names: []const []const u8) Error!void {
    const read = try resolve_mod.readManifest(a, io, dir) orelse {
        std.debug.print("fels remove: no fels.pkg in {s}\n", .{dir});
        return error.PackageError;
    };
    var text = read.source;
    // From the last line to the first, so the earlier offsets stay right.
    var cuts: std.ArrayList(manifest_mod.Use) = .empty;
    for (names) |name| {
        const u = read.m.find(name) orelse {
            std.debug.print("fels remove: fels.pkg does not use a package named '{s}'\n", .{name});
            return error.PackageError;
        };
        cuts.append(a, u) catch return error.OutOfMemory;
    }
    std.mem.sort(manifest_mod.Use, cuts.items, {}, struct {
        fn gt(_: void, x: manifest_mod.Use, y: manifest_mod.Use) bool {
            return x.at > y.at;
        }
    }.gt);
    for (cuts.items) |u| {
        var end: usize = u.end;
        // The line break after it goes too.
        if (end < text.len and text[end] == '\r') end += 1;
        if (end < text.len and text[end] == '\n') end += 1;
        text = std.mem.concat(a, u8, &.{ text[0..u.at], text[end..] }) catch return error.OutOfMemory;
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = read.path, .data = text }) catch {
        std.debug.print("fels remove: cannot write {s}\n", .{read.path});
        return error.PackageError;
    };
    _ = try load(a, io, dir, env, .{});
}

/// `fels why <name>`: where a package comes from, who uses it, and what it may do.
pub fn cmdWhy(a: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, args: []const []const u8) u8 {
    if (args.len != 1) {
        std.debug.print("usage: fels why <name>\n", .{});
        return 1;
    }
    const r = (load(a, io, ".", env, .{ .offline = true }) catch return 1) orelse {
        std.debug.print("fels why: no fels.pkg in the current directory\n", .{});
        return 1;
    };
    const p = r.find(args[0]) orelse {
        std.debug.print("fels why: no package named '{s}' is used, directly or through another package\n", .{args[0]});
        return 1;
    };
    std.debug.print("{s} {s}  {s}\n  in {s}{s}\n", .{ p.name, p.version, p.source, p.dir, if (p.vendored) " (vendored)" else "" });
    for (p.used_by) |via| {
        std.debug.print("  used by {s}", .{via.by});
        if (via.version) |v| std.debug.print(": version \"{s}\"", .{v});
        if (via.may.len != 0) {
            std.debug.print("{s} may", .{if (via.version != null) "," else ":"});
            for (via.may, 0..) |c, i| std.debug.print("{s} {s}", .{ if (i == 0) "" else ",", manifest_mod.formatCap(a, c) catch c.name });
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("  its compile-time code may:", .{});
    if (p.caps.len == 0) std.debug.print(" nothing (it runs pure)", .{});
    for (p.caps, 0..) |c, i| std.debug.print("{s} {s}", .{ if (i == 0) "" else ",", manifest_mod.formatCap(a, c) catch c.name });
    std.debug.print("\n", .{});
    return 0;
}

/// `fels vendor`: copy every git package into `vendor/<name>`. Builds then take them from there,
/// without git and without the package cache; commit `vendor/` for builds that cannot fetch.
pub fn cmdVendor(a: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, args: []const []const u8) u8 {
    if (args.len != 0) {
        std.debug.print("usage: fels vendor\n", .{});
        return 1;
    }
    const n = vendor(a, io, env, ".") catch return 1;
    std.debug.print("{d} package(s) in vendor/\n", .{n});
    return 0;
}

/// Copy the git packages of the project in `dir` into `<dir>/vendor`. Returns how many.
pub fn vendor(a: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, dir: []const u8) Error!usize {
    // Resolve against the cache, not an older vendor/ (it is replaced).
    const vendor_dir = std.fs.path.join(a, &.{ dir, "vendor" }) catch return error.OutOfMemory;
    std.Io.Dir.cwd().deleteTree(io, vendor_dir) catch {};
    const r = (try load(a, io, dir, env, .{})) orelse {
        std.debug.print("fels vendor: no fels.pkg in {s}\n", .{dir});
        return error.PackageError;
    };
    var count: usize = 0;
    for (r.packages) |p| {
        if (manifest_mod.isPathSource(p.source)) continue;
        const dest = std.fs.path.join(a, &.{ vendor_dir, p.name }) catch return error.OutOfMemory;
        fetch.copyTree(a, io, p.dir, dest) catch {
            std.debug.print("fels vendor: cannot copy {s} to {s}\n", .{ p.dir, dest });
            return error.PackageError;
        };
        std.debug.print("  vendor/{s}  {s} {s}\n", .{ p.name, p.name, p.version });
        count += 1;
    }
    return count;
}

/// A folder name as a package name: letters, digits and `_`.
fn packageName(a: std.mem.Allocator, folder: []const u8) []const u8 {
    const out = a.dupe(u8, folder) catch return "app";
    for (out) |*c| if (!std.ascii.isAlphanumeric(c.*)) {
        c.* = '_';
    };
    if (out.len == 0 or std.ascii.isDigit(out[0])) return "app";
    return out;
}
