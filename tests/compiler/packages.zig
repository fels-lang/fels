/// The package manager: fels.pkg, fels.lock, git packages from a local repository, path
/// packages, capabilities. Needs git; the test that builds a program needs LLVM too.
const std = @import("std");
const builtin = @import("builtin");
const fels = @import("fels_compiler");
const project = fels.pkg.project;

const io = std.testing.io;

/// Run git in `dir`; false when git is missing or fails.
fn git(a: std.mem.Allocator, dir: []const u8, args: []const []const u8) bool {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{ "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "core.autocrlf=false" }) catch return false;
    argv.appendSlice(a, args) catch return false;
    const r = std.process.run(a, io, .{ .argv = argv.items, .cwd = .{ .path = dir } }) catch return false;
    return r.term == .exited and r.term.exited == 0;
}

fn write(dir: []const u8, rel: []const u8, data: []const u8) !void {
    var buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, rel });
    if (std.fs.path.dirname(path)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// A test setup: a folder with a git repository `mathlib` (tags v1.0.0, v1.1.0 as an annotated
/// tag, v2.0.0), a package cache, and a project folder.
const Setup = struct {
    /// On the heap: the environment map keeps a pointer to it.
    arena: *std.heap.ArenaAllocator,
    base: []const u8,
    /// `file:///.../mathlib`.
    url: []const u8,
    project: []const u8,
    env: std.process.Environ.Map,

    fn init(comptime name: []const u8) !?Setup {
        const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(std.testing.allocator);
        errdefer {
            arena.deinit();
            std.testing.allocator.destroy(arena);
        }
        const a = arena.allocator();
        const base = ".zig-cache/" ++ name;
        std.Io.Dir.cwd().deleteTree(io, base) catch {};
        const repo = base ++ "/mathlib";
        try write(repo, "fels.pkg", "#package mathlib \"1.0.0\";\n");
        try write(repo, "src/mathlib.fels", "pub ANSWER :: 4;\n");
        try write(repo, "src/ops.fels", "pub triple :: fn(x: i32) -> i32 { return x * 3; }\n");
        if (!git(a, repo, &.{ "init", "-q" })) return null; // no git: skip
        if (!git(a, repo, &.{ "add", "-A" }) or !git(a, repo, &.{ "commit", "-qm", "1.0" }) or !git(a, repo, &.{ "tag", "v1.0.0" })) return error.GitFailed;
        try write(repo, "src/mathlib.fels", "pub ANSWER :: 5;\n");
        if (!git(a, repo, &.{ "commit", "-qam", "1.1" }) or !git(a, repo, &.{ "tag", "-a", "v1.1.0", "-m", "1.1" })) return error.GitFailed;
        try write(repo, "src/mathlib.fels", "pub ANSWER :: 6;\n");
        if (!git(a, repo, &.{ "commit", "-qam", "2.0" }) or !git(a, repo, &.{ "tag", "v2.0.0" })) return error.GitFailed;

        const cwd = try std.process.currentPathAlloc(io, a);
        const abs = try std.fs.path.join(a, &.{ cwd, repo });
        for (abs) |*c| if (c.* == '\\') {
            c.* = '/';
        };
        var env = std.process.Environ.Map.init(a);
        try env.put("FELS_PKG_DIR", try std.fs.path.join(a, &.{ cwd, base, "cache" }));
        const proj = base ++ "/app";
        try std.Io.Dir.cwd().createDirPath(io, proj);
        return .{
            .arena = arena,
            .base = base,
            .url = try std.fmt.allocPrint(a, "file:///{s}", .{std.mem.trimStart(u8, abs, "/")}),
            .project = proj,
            .env = env,
        };
    }

    fn deinit(self: *Setup) void {
        self.arena.deinit();
        std.testing.allocator.destroy(self.arena);
    }

    fn mem(self: *Setup) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Write the project's fels.pkg: `#package app`, then `lines` with `URL` replaced.
    fn pkg(self: *Setup, lines: []const u8) !void {
        const text = try std.mem.replaceOwned(u8, self.mem(), lines, "URL", self.url);
        try write(self.project, "fels.pkg", try std.fmt.allocPrint(self.mem(), "#package app \"0.1.0\";\n{s}", .{text}));
    }

    fn load(self: *Setup, opts: project.Options) !project.Result {
        return (try project.load(self.mem(), io, self.project, &self.env, opts)).?;
    }

    fn tag(self: *Setup, comptime v: []const u8, answer: []const u8) !void {
        const repo = try std.fmt.allocPrint(self.mem(), "{s}/mathlib", .{self.base});
        try write(repo, "src/mathlib.fels", answer);
        if (!git(self.mem(), repo, &.{ "commit", "-qam", v }) or !git(self.mem(), repo, &.{ "tag", "v" ++ v })) return error.GitFailed;
    }
};

test "packages: a git package at the newest version its range allows, recorded in fels.lock" {
    var s = (try Setup.init("pk_newest")) orelse return error.SkipZigTest;
    defer s.deinit();
    try s.pkg("#use mathlib from \"URL\" version \"^1.0\";\n");
    const r = try s.load(.{});
    const m = r.find("mathlib").?;
    try std.testing.expectEqualStrings("1.1.0", m.version);
    try std.testing.expect(std.mem.endsWith(u8, m.import_dir, "src"));
    const answer = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(s.mem(), &.{ m.import_dir, "mathlib.fels" }), s.mem(), .unlimited);
    try std.testing.expectEqualStrings("pub ANSWER :: 5;\n", answer);
    const lock = try std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(s.mem(), "{s}/fels.lock", .{s.project}), s.mem(), .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, lock, "version \"1.1.0\"") != null);
}

test "packages: fels.lock keeps a version until update, or until the range no longer allows it" {
    var s = (try Setup.init("pk_lock")) orelse return error.SkipZigTest;
    defer s.deinit();
    try s.pkg("#use mathlib from \"URL\" version \"^1.0\";\n");
    _ = try s.load(.{});
    try s.tag("1.3.0", "pub ANSWER :: 7;\n");
    try std.testing.expectEqualStrings("1.1.0", (try s.load(.{})).find("mathlib").?.version);
    try std.testing.expectEqualStrings("1.3.0", (try s.load(.{ .update = &.{"mathlib"} })).find("mathlib").?.version);
    try s.pkg("#use mathlib from \"URL\" version \"^2.0\";\n");
    try std.testing.expectEqualStrings("2.0.0", (try s.load(.{})).find("mathlib").?.version);
}

test "packages: a path package and what it uses come along, one version of each" {
    var s = (try Setup.init("pk_path")) orelse return error.SkipZigTest;
    defer s.deinit();
    const helpers = try std.fmt.allocPrint(s.mem(), "{s}/helpers", .{s.base});
    try write(helpers, "fels.pkg", try std.fmt.allocPrint(s.mem(), "#package helpers \"0.1.0\";\n#use mathlib from \"{s}\" version \"^1.0\";\n", .{s.url}));
    try write(helpers, "helpers.fels", "pub twice :: fn(x: i32) -> i32 { return x * 2; }\n");
    try s.pkg("#use helpers from \"../helpers\";\n");
    const r = try s.load(.{});
    try std.testing.expectEqual(@as(usize, 2), r.packages.len);
    try std.testing.expectEqualStrings("path", r.find("helpers").?.version);
    try std.testing.expectEqualStrings("1.1.0", r.find("mathlib").?.version);

    // The project wants ^2 of the same package: there is no version both can use.
    try s.pkg("#use helpers from \"../helpers\";\n#use mathlib from \"URL\" version \"^2.0\";\n");
    try std.testing.expectError(error.PackageError, s.load(.{}));
}

test "packages: what a package needs at compile time must be granted, and can only be passed on" {
    var s = (try Setup.init("pk_caps")) orelse return error.SkipZigTest;
    defer s.deinit();
    const repo = try std.fmt.allocPrint(s.mem(), "{s}/mathlib", .{s.base});
    try write(repo, "fels.pkg", "#package mathlib \"1.4.0\";\n#needs ffi(\"user32\");\n");
    try s.tag("1.4.0", "pub ANSWER :: 8;\n");

    try s.pkg("#use mathlib from \"URL\" version \"^1.4\";\n");
    try std.testing.expectError(error.PackageError, s.load(.{}));
    try s.pkg("#use mathlib from \"URL\" version \"^1.4\" may ffi(\"kernel32\");\n");
    try std.testing.expectError(error.PackageError, s.load(.{}));
    try s.pkg("#use mathlib from \"URL\" version \"^1.4\" may ffi(\"user32\", \"gdi32\");\n");
    const r = try s.load(.{});
    try std.testing.expectEqualStrings("user32", r.find("mathlib").?.caps[0].args[0]);

    // Through a path package that was granted less, it is not enough.
    const helpers = try std.fmt.allocPrint(s.mem(), "{s}/helpers", .{s.base});
    try write(helpers, "fels.pkg", try std.fmt.allocPrint(s.mem(), "#use mathlib from \"{s}\" version \"^1.4\" may ffi(\"user32\");\n", .{s.url}));
    try s.pkg("#use helpers from \"../helpers\" may ffi(\"gdi32\");\n");
    try std.testing.expectError(error.PackageError, s.load(.{}));
}

test "packages: a changed file in the cache is found" {
    var s = (try Setup.init("pk_verify")) orelse return error.SkipZigTest;
    defer s.deinit();
    try s.pkg("#use mathlib from \"URL\" version \"=1.0.0\";\n");
    const m = (try s.load(.{})).find("mathlib").?;
    try write(m.import_dir, "mathlib.fels", "pub ANSWER :: 99;\n");
    _ = try s.load(.{}); // a build does not hash every time
    try std.testing.expectError(error.PackageError, s.load(.{ .verify = true }));
}

test "packages: fels add writes fels.pkg, and leaves it as it was when that fails" {
    var s = (try Setup.init("pk_add")) orelse return error.SkipZigTest;
    defer s.deinit();
    const p = try project.add(s.mem(), io, &s.env, s.project, "mathlib", s.url, "~1.0", null);
    try std.testing.expectEqualStrings("1.0.0", p.version); // ~1.0 allows only 1.0.x
    const pkg_path = try std.fmt.allocPrint(s.mem(), "{s}/fels.pkg", .{s.project});
    const text = try std.Io.Dir.cwd().readFileAlloc(io, pkg_path, s.mem(), .unlimited);
    try std.testing.expect(std.mem.startsWith(u8, text, "#package app \"0.1.0\";"));
    try std.testing.expect(std.mem.indexOf(u8, text, "version \"~1.0\";") != null);

    // A version that does not exist: fels.pkg stays as it was.
    try std.testing.expectError(error.PackageError, project.add(s.mem(), io, &s.env, s.project, "other", s.url, "^9.0", null));
    try std.testing.expectEqualStrings(text, try std.Io.Dir.cwd().readFileAlloc(io, pkg_path, s.mem(), .unlimited));
}

test "packages: a package's #run gets the capability fels.pkg grants, and no more" {
    if (comptime !fels.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".zig-cache/pk_vm_caps";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    // A path package whose compile-time code calls into user32.
    try write(base ++ "/screen", "fels.pkg", "#package screen \"0.1.0\";\n#needs ffi(\"user32\");\n");
    try write(base ++ "/screen", "screen.fels",
        \\#extern("user32", "GetSystemMetrics")
        \\metrics :: fn(index: i32) -> i32;
        \\WIDTH :: #run metrics(0);
        \\pub known :: fn() -> i32 { if WIDTH > 0 { return 7; } return 1; }
        \\
    );
    try write(base ++ "/app", "main.fels", "#import screen;\nmain :: fn() -> i32 { return screen::known(); }\n");
    try write(base ++ "/app", "build.fels", "#import std.build.{ Build };\nbuild :: fn(b: Build) {\n    b.executable(\"app\", \"main.fels\");\n}\n");
    const lp = fels.windows_sdk_lib_path;
    const lib_paths: []const []const u8 = if (lp.len > 0) &.{lp} else &.{};
    const opts: fels.build_driver.RunOptions = .{ .quiet = true, .llvm_bin = fels.llvm_path ++ "/bin", .lib_paths = lib_paths };

    // Granted: the #run reaches user32.
    try write(base ++ "/app", "fels.pkg", "#use screen from \"../screen\" may ffi(\"user32\");\n");
    try fels.build_driver.run(a, io, base ++ "/app/build.fels", opts);
    var child = try std.process.spawn(io, .{ .argv = &.{base ++ "/app/app.exe"}, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    switch (try child.wait(io)) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 7), code),
        else => return error.TestUnexpectedResult,
    }

    // Not declared in #needs, so not checked up front: the VM still refuses the call.
    try write(base ++ "/screen", "fels.pkg", "#package screen \"0.1.0\";\n");
    try write(base ++ "/app", "fels.pkg", "#use screen from \"../screen\";\n");
    try std.testing.expectError(error.CompileFailed, fels.build_driver.run(a, io, base ++ "/app/build.fels", opts));
}

test "packages: the language server resolves fels.pkg, and says when a package is not fetched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".zig-cache/pk_lsp";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try write(base ++ "/helpers", "helpers.fels", "pub twice :: fn(x: i32) -> i32 { return x * 2; }\n");
    try write(base ++ "/app", "build.fels", "#import std.build.{ Build };\nbuild :: fn(b: Build) {\n    b.executable(\"app\", \"main.fels\");\n}\n");
    // `remote` is a git package that was never fetched: no fels.lock, an empty cache.
    try write(base ++ "/app", "fels.pkg",
        \\#use helpers from "../helpers";
        \\#use remote from "github.com/nobody/remote" version "^1.0";
        \\
    );
    try write(base ++ "/app", "main.fels", "#import helpers;\n#import remote;\nmain :: fn() -> i32 { return helpers::twice(2); }\n");

    var env = std.process.Environ.Map.init(a);
    try env.put("FELS_PKG_DIR", base ++ "/cache");
    var buf: [64]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&buf);
    var server: fels.lsp_mod.Server = .{ .gpa = std.testing.allocator, .io = io, .out = &out.writer, .environ = &env };
    defer {
        var it = server.projects.iterator();
        while (it.next()) |e| {
            std.testing.allocator.free(e.key_ptr.*);
            e.value_ptr.*.arena.deinit();
            std.testing.allocator.destroy(e.value_ptr.*);
        }
        server.projects.deinit(std.testing.allocator);
    }

    const pkgs = server.packagesFor(base ++ "/app").?;
    try std.testing.expectEqual(@as(usize, 1), pkgs.roots.len);
    try std.testing.expectEqualStrings("remote", pkgs.missing[0]);
    // Asked again with unchanged files: the same entry, resolved once.
    try std.testing.expectEqual(pkgs, server.packagesFor(base ++ "/app").?);

    var an = try fels.pipeline_mod.analyzeFile(std.testing.allocator, base ++ "/app/main.fels", server.analysisOptions(base ++ "/app"));
    defer an.deinit();
    var not_fetched: usize = 0;
    for (an.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "not fetched yet; run `fels fetch`") != null) {
            not_fetched += 1;
        } else {
            std.debug.print("unexpected: {s}\n", .{d.message});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), not_fetched);
}

test "packages: a project with #package imports its own package by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".zig-cache/pk_self";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};

    // src/ is the import folder, as for a package.
    try write(base ++ "/mathx", "fels.pkg", "#package mathx \"0.1.0\";\n");
    try write(base ++ "/mathx", "src/mathx.fels", "pub ONE :: 1;\n");
    const self = (try project.load(a, io, base ++ "/mathx", null, .{})).?.self_root.?;
    try std.testing.expectEqualStrings("mathx", self.name);
    try std.testing.expect(std.mem.endsWith(u8, self.dir, "src"));

    // #root names it.
    try write(base ++ "/rooted", "fels.pkg", "#package rooted \"0.1.0\";\n#root \"lib\";\n");
    try std.testing.expect(std.mem.endsWith(u8, (try project.load(a, io, base ++ "/rooted", null, .{})).?.self_root.?.dir, "lib"));

    // Without #package: nothing new.
    try write(base ++ "/app", "fels.pkg", "#use mathx from \"../mathx\";\n");
    const app = (try project.load(a, io, base ++ "/app", null, .{})).?;
    try std.testing.expect(app.self_root == null);
    try std.testing.expectEqual(@as(usize, 1), app.packages.len);

    // A #use of the project's own name is a mistake.
    try write(base ++ "/twice", "fels.pkg", "#package mathx \"0.2.0\";\n#use mathx from \"../mathx\";\n");
    try std.testing.expectError(error.PackageError, project.load(a, io, base ++ "/twice", null, .{}));
}

test "packages: the language server resolves a library's own package name" {
    const base = ".zig-cache/pk_lsp_self";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    // A library: fels.pkg and no build.fels.
    try write(base ++ "/mathx", "fels.pkg", "#package mathx \"0.1.0\";\n");
    try write(base ++ "/mathx", "src/mathx.fels", "pub clamp :: fn(x: i32, hi: i32) -> i32 { if x > hi { return hi; } return x; }\n");
    try write(base ++ "/mathx", "src/consts.fels", "pub LIMIT :: 9;\n");
    try write(base ++ "/mathx", "examples/demo.fels", "#import mathx;\n#import mathx.consts;\nmain :: fn() -> i32 { return mathx::clamp(12, consts::LIMIT); }\n");

    var buf: [64]u8 = undefined;
    var out = std.Io.Writer.Discarding.init(&buf);
    var server: fels.lsp_mod.Server = .{ .gpa = std.testing.allocator, .io = io, .out = &out.writer };
    defer {
        var it = server.projects.iterator();
        while (it.next()) |e| {
            std.testing.allocator.free(e.key_ptr.*);
            e.value_ptr.*.arena.deinit();
            std.testing.allocator.destroy(e.value_ptr.*);
        }
        server.projects.deinit(std.testing.allocator);
    }

    // fels.pkg marks the project folder.
    const root = server.findProjectRoot(base ++ "/mathx/examples/demo.fels").?;
    defer std.testing.allocator.free(root);
    try std.testing.expectEqualStrings(base ++ "/mathx", root);
    const pkgs = server.packagesFor(root).?;
    try std.testing.expectEqualStrings("mathx", pkgs.roots[0].name);

    var an = try fels.pipeline_mod.analyzeFile(std.testing.allocator, base ++ "/mathx/examples/demo.fels", server.analysisOptions(root));
    defer an.deinit();
    for (an.diagnostics) |d| std.debug.print("unexpected: {s}\n", .{d.message});
    try std.testing.expectEqual(@as(usize, 0), an.diagnostics.len);
}

test "packages: offline takes fels.lock and the cache, frozen stops when fels.lock would change" {
    var s = (try Setup.init("pk_offline")) orelse return error.SkipZigTest;
    defer s.deinit();
    try s.pkg("#use mathlib from \"URL\" version \"^1.0\";\n");
    _ = try s.load(.{});
    try std.testing.expectEqualStrings("1.1.0", (try s.load(.{ .offline = true })).find("mathlib").?.version);
    try std.testing.expectEqualStrings("1.1.0", (try s.load(.{ .frozen = true })).find("mathlib").?.version);

    // fels.pkg now asks for a version fels.lock does not have.
    try s.pkg("#use mathlib from \"URL\" version \"^2.0\";\n");
    try std.testing.expectError(error.PackageError, s.load(.{ .offline = true }));
    try std.testing.expectError(error.PackageError, s.load(.{ .frozen = true }));
    try std.testing.expectEqualStrings("2.0.0", (try s.load(.{})).find("mathlib").?.version);
    try std.testing.expectEqualStrings("2.0.0", (try s.load(.{ .frozen = true })).find("mathlib").?.version);
}

test "packages: remove takes a package out of fels.pkg and fels.lock" {
    var s = (try Setup.init("pk_remove")) orelse return error.SkipZigTest;
    defer s.deinit();
    try s.pkg("#use mathlib from \"URL\" version \"^1.0\";\n// keep this comment\n");
    _ = try s.load(.{});
    try project.remove(s.mem(), io, &s.env, s.project, &.{"mathlib"});
    const pkg_text = try std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(s.mem(), "{s}/fels.pkg", .{s.project}), s.mem(), .unlimited);
    try std.testing.expectEqualStrings("#package app \"0.1.0\";\n// keep this comment\n", pkg_text);
    // Nothing is locked any more, so fels.lock is gone.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, try std.fmt.allocPrint(s.mem(), "{s}/fels.lock", .{s.project}), .{}));
    try std.testing.expectError(error.PackageError, project.remove(s.mem(), io, &s.env, s.project, &.{"mathlib"}));
}

test "packages: every use of a package is recorded, with what it asked for" {
    var s = (try Setup.init("pk_why")) orelse return error.SkipZigTest;
    defer s.deinit();
    const helpers = try std.fmt.allocPrint(s.mem(), "{s}/helpers", .{s.base});
    try write(helpers, "fels.pkg", try std.fmt.allocPrint(s.mem(), "#use mathlib from \"{s}\" version \"~1.1\";\n", .{s.url}));
    try s.pkg("#use mathlib from \"URL\" version \"^1.0\" may ffi(\"user32\");\n#use helpers from \"../helpers\";\n");
    const m = (try s.load(.{})).find("mathlib").?;
    try std.testing.expectEqual(@as(usize, 2), m.used_by.len);
    try std.testing.expectEqualStrings("this project", m.used_by[0].by);
    try std.testing.expectEqualStrings("user32", m.used_by[0].may[0].args[0]);
    try std.testing.expectEqualStrings("helpers", m.used_by[1].by);
    try std.testing.expectEqualStrings("~1.1", m.used_by[1].version.?);
}

test "packages: vendor copies the git packages, and builds take them from there" {
    var s = (try Setup.init("pk_vendor")) orelse return error.SkipZigTest;
    defer s.deinit();
    try s.pkg("#use mathlib from \"URL\" version \"^1.0\";\n");
    try std.testing.expectEqual(@as(usize, 1), try project.vendor(s.mem(), io, &s.env, s.project));
    // A new, empty cache and no git: the package still resolves, from vendor/.
    try s.env.put("FELS_PKG_DIR", try std.fmt.allocPrint(s.mem(), "{s}/empty-cache", .{s.base}));
    const m = (try s.load(.{ .offline = true, .verify = true })).find("mathlib").?;
    try std.testing.expect(m.vendored);
    try std.testing.expectEqualStrings("1.1.0", m.version);
    try std.testing.expect(std.mem.indexOf(u8, m.import_dir, "vendor") != null);
}

test "packages: a package's build.fels provides the library its bindings link" {
    if (comptime !fels.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".zig-cache/pk_provides";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    const lp = fels.windows_sdk_lib_path;
    const lib_paths: []const []const u8 = if (lp.len > 0) &.{lp} else &.{};
    const opts: fels.build_driver.RunOptions = .{ .quiet = true, .llvm_bin = fels.llvm_path ++ "/bin", .lib_paths = lib_paths };

    // A static library, built once and shipped inside the package as lib/mylib.lib.
    try write(base ++ "/make", "mylib_impl.fels", "#export(\"mylib_add\")\nadd :: fn(x: i32, y: i32) -> i32 { return x + y; }\n");
    try write(base ++ "/make", "build.fels", "#import std.build.{ Build };\nbuild :: fn(b: Build) {\n    lib := b.static(\"mylib\", \"mylib_impl.fels\");\n    lib.out_dir(\"../mylib/lib\");\n}\n");
    try fels.build_driver.run(a, io, base ++ "/make/build.fels", opts);

    // The package: bindings, and a build.fels that tells its users where the library is.
    try write(base ++ "/mylib", "fels.pkg", "#package mylib \"1.0.0\";\n");
    try write(base ++ "/mylib", "mylib.fels", "#extern(\"mylib\", \"mylib_add\")\npub add :: fn(x: i32, y: i32) -> i32;\n");
    try write(base ++ "/mylib", "build.fels", "#import std.build.{ Build };\nbuild :: fn(b: Build) {\n    b.provide_lib_path(\"lib\");\n}\n");

    try write(base ++ "/app", "fels.pkg", "#use mylib from \"../mylib\";\n");
    try write(base ++ "/app", "main.fels", "#import mylib;\nmain :: fn() -> i32 { return mylib::add(20, 22); }\n");
    try write(base ++ "/app", "build.fels", "#import std.build.{ Build };\nbuild :: fn(b: Build) {\n    b.executable(\"app\", \"main.fels\");\n}\n");
    try fels.build_driver.run(a, io, base ++ "/app/build.fels", opts);
    var child = try std.process.spawn(io, .{ .argv = &.{base ++ "/app/app.exe"}, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    switch (try child.wait(io)) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 42), code),
        else => return error.TestUnexpectedResult,
    }

    // Without the provided folder the library is not found.
    try write(base ++ "/mylib", "build.fels", "#import std.build.{ Build };\nbuild :: fn(b: Build) {\n}\n");
    try std.testing.expectError(error.CompileFailed, fels.build_driver.run(a, io, base ++ "/app/build.fels", opts));
}
