/// The package manager: gabbro.pkg, gabbro.lock, git packages from a local repository, path
/// packages, capabilities. Needs git; the test that builds a program needs LLVM too.
const std = @import("std");
const builtin = @import("builtin");
const gabbro = @import("gabbro_compiler");
const project = gabbro.pkg.project;

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
    arena: std.heap.ArenaAllocator,
    base: []const u8,
    /// `file:///.../mathlib`.
    url: []const u8,
    project: []const u8,
    env: std.process.Environ.Map,

    fn init(comptime name: []const u8) !?Setup {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const base = ".zig-cache/" ++ name;
        std.Io.Dir.cwd().deleteTree(io, base) catch {};
        const repo = base ++ "/mathlib";
        try write(repo, "gabbro.pkg", "#package mathlib \"1.0.0\";\n");
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
        try env.put("GABBRO_PKG_DIR", try std.fs.path.join(a, &.{ cwd, base, "cache" }));
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
    }

    fn mem(self: *Setup) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Write the project's gabbro.pkg: `#package app`, then `lines` with `URL` replaced.
    fn pkg(self: *Setup, lines: []const u8) !void {
        const text = try std.mem.replaceOwned(u8, self.mem(), lines, "URL", self.url);
        try write(self.project, "gabbro.pkg", try std.fmt.allocPrint(self.mem(), "#package app \"0.1.0\";\n{s}", .{text}));
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

test "packages: a git package at the newest version its range allows, recorded in gabbro.lock" {
    var s = (try Setup.init("pk_newest")) orelse return error.SkipZigTest;
    defer s.deinit();
    try s.pkg("#use mathlib from \"URL\" version \"^1.0\";\n");
    const r = try s.load(.{});
    const m = r.find("mathlib").?;
    try std.testing.expectEqualStrings("1.1.0", m.version);
    try std.testing.expect(std.mem.endsWith(u8, m.import_dir, "src"));
    const answer = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(s.mem(), &.{ m.import_dir, "mathlib.fels" }), s.mem(), .unlimited);
    try std.testing.expectEqualStrings("pub ANSWER :: 5;\n", answer);
    const lock = try std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(s.mem(), "{s}/gabbro.lock", .{s.project}), s.mem(), .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, lock, "version \"1.1.0\"") != null);
}

test "packages: gabbro.lock keeps a version until update, or until the range no longer allows it" {
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
    try write(helpers, "gabbro.pkg", try std.fmt.allocPrint(s.mem(), "#package helpers \"0.1.0\";\n#use mathlib from \"{s}\" version \"^1.0\";\n", .{s.url}));
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
    try write(repo, "gabbro.pkg", "#package mathlib \"1.4.0\";\n#needs ffi(\"user32\");\n");
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
    try write(helpers, "gabbro.pkg", try std.fmt.allocPrint(s.mem(), "#use mathlib from \"{s}\" version \"^1.4\" may ffi(\"user32\");\n", .{s.url}));
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

test "packages: gabbro add writes gabbro.pkg, and leaves it as it was when that fails" {
    var s = (try Setup.init("pk_add")) orelse return error.SkipZigTest;
    defer s.deinit();
    const p = try project.add(s.mem(), io, &s.env, s.project, "mathlib", s.url, "~1.0", null);
    try std.testing.expectEqualStrings("1.0.0", p.version); // ~1.0 allows only 1.0.x
    const pkg_path = try std.fmt.allocPrint(s.mem(), "{s}/gabbro.pkg", .{s.project});
    const text = try std.Io.Dir.cwd().readFileAlloc(io, pkg_path, s.mem(), .unlimited);
    try std.testing.expect(std.mem.startsWith(u8, text, "#package app \"0.1.0\";"));
    try std.testing.expect(std.mem.indexOf(u8, text, "version \"~1.0\";") != null);

    // A version that does not exist: gabbro.pkg stays as it was.
    try std.testing.expectError(error.PackageError, project.add(s.mem(), io, &s.env, s.project, "other", s.url, "^9.0", null));
    try std.testing.expectEqualStrings(text, try std.Io.Dir.cwd().readFileAlloc(io, pkg_path, s.mem(), .unlimited));
}

test "packages: a package's #run gets the capability gabbro.pkg grants, and no more" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = ".zig-cache/pk_vm_caps";
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    // A path package whose compile-time code calls into user32.
    try write(base ++ "/screen", "gabbro.pkg", "#package screen \"0.1.0\";\n#needs ffi(\"user32\");\n");
    try write(base ++ "/screen", "screen.fels",
        \\#extern("user32", "GetSystemMetrics")
        \\metrics :: fn(index: i32) -> i32;
        \\WIDTH :: #run metrics(0);
        \\pub known :: fn() -> i32 { if WIDTH > 0 { return 7; } return 1; }
        \\
    );
    try write(base ++ "/app", "main.fels", "#import screen;\nmain :: fn() -> i32 { return screen::known(); }\n");
    try write(base ++ "/app", "build.fels", "#import std.build.{ Build };\nbuild :: fn(b: Build) {\n    b.executable(\"app\", \"main.fels\");\n}\n");
    const lp = gabbro.windows_sdk_lib_path;
    const lib_paths: []const []const u8 = if (lp.len > 0) &.{lp} else &.{};
    const opts: gabbro.build_driver.RunOptions = .{ .quiet = true, .llvm_bin = gabbro.llvm_path ++ "/bin", .lib_paths = lib_paths };

    // Granted: the #run reaches user32.
    try write(base ++ "/app", "gabbro.pkg", "#use screen from \"../screen\" may ffi(\"user32\");\n");
    try gabbro.build_driver.run(a, io, base ++ "/app/build.fels", opts);
    var child = try std.process.spawn(io, .{ .argv = &.{base ++ "/app/app.exe"}, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    switch (try child.wait(io)) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 7), code),
        else => return error.TestUnexpectedResult,
    }

    // Not declared in #needs, so not checked up front: the VM still refuses the call.
    try write(base ++ "/screen", "gabbro.pkg", "#package screen \"0.1.0\";\n");
    try write(base ++ "/app", "gabbro.pkg", "#use screen from \"../screen\";\n");
    try std.testing.expectError(error.CompileFailed, gabbro.build_driver.run(a, io, base ++ "/app/build.fels", opts));
}
