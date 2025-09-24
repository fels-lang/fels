//! A project's packages: read gabbro.pkg and gabbro.lock in a folder, resolve, and write
//! gabbro.lock when it changed. `gabbro build`, `fetch`, `update` and `add` go through here.

const std = @import("std");
const manifest_mod = @import("manifest.zig");
const lock_mod = @import("lock.zig");
const resolve_mod = @import("resolve.zig");
const fetch = @import("fetch.zig");
const directives = @import("directives.zig");

pub const Result = resolve_mod.Result;
pub const Package = resolve_mod.Package;
pub const Error = resolve_mod.ResolveError;

pub const Options = struct {
    update: []const []const u8 = &.{},
    update_all: bool = false,
    verify: bool = false,
};

/// Resolve the packages of the project in `dir`; null when it has no gabbro.pkg.
pub fn load(
    a: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    env: ?*const std.process.Environ.Map,
    opts: Options,
) Error!?Result {
    const read = try resolve_mod.readManifest(a, io, dir) orelse return null;
    const lock_path = std.fs.path.join(a, &.{ dir, "gabbro.lock" }) catch return error.OutOfMemory;
    var old: lock_mod.Lock = .{};
    if (std.Io.Dir.cwd().readFileAlloc(io, lock_path, a, .unlimited)) |text| {
        var problem: directives.Problem = .{};
        old = lock_mod.parse(a, text, &problem) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => {
                const loc = directives.location(text, problem.at);
                std.debug.print("{s}:{d}:{d}: error: {s}\n  Delete gabbro.lock and run `gabbro fetch` to write it again.\n", .{ lock_path, loc.line, loc.col, problem.msg });
                return error.PackageError;
            },
        };
    } else |_| {}

    const cache = fetch.cacheDir(a, env) catch return error.OutOfMemory;
    const result = try resolve_mod.resolve(a, io, dir, read.path, read.source, read.m, old, .{
        .cache = cache,
        .update = opts.update,
        .update_all = opts.update_all,
        .verify = opts.verify,
    });
    if (result.lock_changed) {
        const text = lock_mod.write(a, result.lock) catch return error.OutOfMemory;
        if (result.lock.entries.items.len == 0) {
            std.Io.Dir.cwd().deleteFile(io, lock_path) catch {};
        } else std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lock_path, .data = text }) catch {
            std.debug.print("gabbro: cannot write {s}\n", .{lock_path});
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

/// `gabbro fetch [--verify]`: get every package gabbro.pkg uses and write gabbro.lock.
pub fn cmdFetch(a: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, args: []const []const u8) u8 {
    var verify = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--verify")) verify = true else {
            std.debug.print("gabbro fetch: unknown argument '{s}'\n", .{arg});
            return 1;
        }
    }
    const result = load(a, io, ".", env, .{ .verify = verify }) catch return 1;
    const r = result orelse {
        std.debug.print("gabbro fetch: no gabbro.pkg in the current directory\n", .{});
        return 1;
    };
    printPackages(a, r.packages);
    if (verify) std.debug.print("the files of every git package match gabbro.lock\n", .{});
    return 0;
}

/// `gabbro update [name...]`: take the newest versions gabbro.pkg allows (of all packages, or
/// the named ones) and write them to gabbro.lock.
pub fn cmdUpdate(a: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map, args: []const []const u8) u8 {
    const before = load(a, io, ".", env, .{}) catch return 1;
    const old = before orelse {
        std.debug.print("gabbro update: no gabbro.pkg in the current directory\n", .{});
        return 1;
    };
    for (args) |name| if (old.find(name) == null) {
        std.debug.print("gabbro update: gabbro.pkg does not use a package named '{s}'\n", .{name});
        return 1;
    };
    const after = (load(a, io, ".", env, .{ .update = args, .update_all = args.len == 0 }) catch return 1).?;
    var changed: usize = 0;
    for (after.packages) |p| {
        const was = old.find(p.name) orelse continue;
        if (std.mem.eql(u8, was.version, p.version)) continue;
        std.debug.print("  {s}: {s} -> {s}\n", .{ p.name, was.version, p.version });
        changed += 1;
    }
    if (changed == 0) std.debug.print("everything is at the newest version gabbro.pkg allows\n", .{});
    return 0;
}

/// `gabbro add <name> <source> [version] [--may <caps>]`: add a `#use` line to gabbro.pkg (and
/// create gabbro.pkg if there is none), then fetch the package. gabbro.pkg stays as it was
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
            \\usage: gabbro add <name> <source> [version] [--may <capabilities>]
            \\  gabbro add raylib github.com/raysan5/raylib ^5.0 --may 'ffi("opengl32")'
            \\  gabbro add mathlib ../mathlib
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

/// Add `#use <name> from "<source>"` to the gabbro.pkg in `dir` (creating it when there is
/// none) and resolve. On failure gabbro.pkg is left as it was.
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
    const path = std.fs.path.join(a, &.{ dir, "gabbro.pkg" }) catch return error.OutOfMemory;
    const cwd = std.Io.Dir.cwd();
    const before: ?[]const u8 = cwd.readFileAlloc(io, path, a, .unlimited) catch null;
    var text: std.ArrayList(u8) = .empty;
    if (before) |b| {
        text.appendSlice(a, b) catch return error.OutOfMemory;
        if (b.len != 0 and b[b.len - 1] != '\n') text.append(a, '\n') catch return error.OutOfMemory;
    } else {
        // A new gabbro.pkg, named after the folder.
        const here = std.fs.path.resolve(a, &.{ std.process.currentPathAlloc(io, a) catch ".", dir }) catch return error.OutOfMemory;
        text.print(a, "#package {s} \"0.1.0\";\n\n", .{packageName(a, std.fs.path.basename(here))}) catch return error.OutOfMemory;
    }
    text.print(a, "#use {s} from \"{s}\"", .{ name, source }) catch return error.OutOfMemory;
    if (version) |v| text.print(a, " version \"{s}\"", .{v}) catch return error.OutOfMemory;
    if (may) |m| text.print(a, "\n    may {s}", .{m}) catch return error.OutOfMemory;
    text.appendSlice(a, ";\n") catch return error.OutOfMemory;

    cwd.writeFile(io, .{ .sub_path = path, .data = text.items }) catch {
        std.debug.print("gabbro add: cannot write {s}\n", .{path});
        return error.PackageError;
    };
    const result = load(a, io, dir, env, .{}) catch |err| {
        // Put gabbro.pkg back as it was.
        if (before) |b| cwd.writeFile(io, .{ .sub_path = path, .data = b }) catch {} else cwd.deleteFile(io, path) catch {};
        std.debug.print("gabbro add: gabbro.pkg was not changed\n", .{});
        return err;
    };
    return result.?.find(name).?;
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
