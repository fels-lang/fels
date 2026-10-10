/// The `gabbro build` build system: runs build.gab scripts on the comptime VM and checks the
/// plan they record. Nothing is compiled or linked, so these run without LLVM.
const std = @import("std");
const gabbro = @import("gabbro_compiler");
const build = gabbro.build_driver;

/// Write `src` as `<dir>/build.gab` and load its plan with the `-D` `options`.
fn loadPlan(comptime dir: []const u8, src: []const u8, options: []const []const u8) !build.BuildPlan {
    const io = std.testing.io;
    std.Io.Dir.cwd().createDirPath(io, ".zig-cache/" ++ dir) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ".zig-cache/" ++ dir ++ "/build.gab", .data = src });
    return build.loadPlan(std.testing.allocator, io, ".zig-cache/" ++ dir ++ "/build.gab", options);
}

const options_script =
    \\#import std.build.{ Build };
    \\build :: fn(b: Build) {
    \\    fast := b.option_bool("fast", false, "build with optimizations");
    \\    threads := b.option_int("threads", 4, "worker threads");
    \\    name := b.option_string("name", "hello", "output name");
    \\    backend := b.option_choice("backend", "gl|vulkan|d3d", "gl", "renderer");
    \\    exe := b.executable(name, "main.gab");
    \\    if fast { exe.release_fast(); }
    \\    if threads == 16 { exe.output(backend); }
    \\}
;

test "build: typed options take their defaults" {
    var plan = try loadPlan("bs_opt_default", options_script, &.{});
    defer plan.deinit();
    const exe = plan.artifacts.items[0];
    try std.testing.expectEqualStrings("hello", exe.name);
    try std.testing.expectEqual(@as(u2, 0), exe.opt);
    try std.testing.expect(exe.out_path == null);

    // Declared in order, with the defaults shown by `--list`.
    const d = plan.declared.items;
    try std.testing.expectEqual(@as(usize, 4), d.len);
    try std.testing.expectEqualStrings("fast", d[0].name);
    try std.testing.expectEqualStrings("false", d[0].default);
    try std.testing.expectEqualStrings("build with optimizations", d[0].help);
    try std.testing.expectEqual(build.OptionKind.int, d[1].kind);
    try std.testing.expectEqualStrings("4", d[1].default);
    try std.testing.expectEqualStrings("hello", d[2].default);
    try std.testing.expectEqualStrings("gl|vulkan|d3d", d[3].choices);
}

test "build: typed options read -D values" {
    var plan = try loadPlan("bs_opt_values", options_script, &.{ "fast", "threads=0x10", "name=app", "backend=vulkan" });
    defer plan.deinit();
    const exe = plan.artifacts.items[0];
    try std.testing.expectEqualStrings("app", exe.name);
    try std.testing.expectEqual(@as(u2, 2), exe.opt);
    try std.testing.expectEqualStrings("vulkan", exe.out_path.?);
}

test "build: a bool option takes true and false words, the last -D wins" {
    var plan = try loadPlan("bs_opt_bool", options_script, &.{ "fast=on", "fast=no" });
    defer plan.deinit();
    try std.testing.expectEqual(@as(u2, 0), plan.artifacts.items[0].opt);
}

test "build: an undeclared -D option is an error" {
    try std.testing.expectError(error.ScriptError, loadPlan("bs_opt_unknown", options_script, &.{"thread=3"}));
}

test "build: an option value of the wrong kind is an error" {
    try std.testing.expectError(error.ScriptError, loadPlan("bs_opt_int", options_script, &.{"threads=many"}));
    try std.testing.expectError(error.ScriptError, loadPlan("bs_opt_bool_bad", options_script, &.{"fast=maybe"}));
    try std.testing.expectError(error.ScriptError, loadPlan("bs_opt_choice", options_script, &.{"backend=metal"}));
}

test "build: a choice default that is not one of the choices is an error" {
    const src =
        \\#import std.build.{ Build };
        \\build :: fn(b: Build) {
        \\    mode := b.option_choice("mode", "a|b", "c", "");
        \\    b.executable(mode, "main.gab");
        \\}
    ;
    try std.testing.expectError(error.ScriptError, loadPlan("bs_opt_choice_default", src, &.{}));
}

test "build: the short option forms declare their options too" {
    const src =
        \\#import std.build.{ Build };
        \\build :: fn(b: Build) {
        \\    exe := b.executable(b.option_str("name", "x"), "main.gab");
        \\    if b.option("fast") { exe.release_fast(); }
        \\}
    ;
    var plan = try loadPlan("bs_opt_short", src, &.{ "fast", "name=y" });
    defer plan.deinit();
    try std.testing.expectEqualStrings("y", plan.artifacts.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), plan.declared.items.len);
}

test "build: link_artifact records the library to link" {
    const src =
        \\#import std.build.{ Build };
        \\build :: fn(b: Build) {
        \\    util := b.static("util", "util.gab");
        \\    app := b.executable("app", "main.gab");
        \\    app.link_artifact(util);
        \\}
    ;
    var plan = try loadPlan("bs_link_artifact", src, &.{});
    defer plan.deinit();
    try std.testing.expectEqualSlices(usize, &.{0}, plan.artifacts.items[1].link_artifacts.items);
}

test "build: link_artifact of an executable is an error" {
    const src =
        \\#import std.build.{ Build };
        \\build :: fn(b: Build) {
        \\    tool := b.executable("tool", "tool.gab");
        \\    app := b.executable("app", "main.gab");
        \\    app.link_artifact(tool);
        \\}
    ;
    try std.testing.expectError(error.ScriptError, loadPlan("bs_link_exe", src, &.{}));
}

test "build: install copies files and folders into the prefix" {
    const io = std.testing.io;
    const dir = ".zig-cache/bs_install";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    std.Io.Dir.cwd().createDirPath(io, dir ++ "/assets/sub") catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/README.md", .data = "readme" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/assets/a.txt", .data = "a" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/assets/sub/b.txt", .data = "b" });
    const src =
        \\#import std.build.{ Build };
        \\build :: fn(b: Build) {
        \\    b.executable("app", "main.gab");
        \\    b.install_prefix("pkg");
        \\    b.install_file("README.md", "doc/README.md");
        \\    b.install_dir("assets", "share/assets");
        \\}
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/build.gab", .data = src });
    try build.run(std.testing.allocator, io, dir ++ "/build.gab", .{ .target = "install", .quiet = true });

    const gpa = std.testing.allocator;
    for ([_][2][]const u8{
        .{ dir ++ "/pkg/doc/README.md", "readme" },
        .{ dir ++ "/pkg/share/assets/a.txt", "a" },
        .{ dir ++ "/pkg/share/assets/sub/b.txt", "b" },
    }) |f| {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, f[0], gpa, .unlimited);
        defer gpa.free(data);
        try std.testing.expectEqualStrings(f[1], data);
    }
}

test "build: install with nothing to install is an error" {
    const io = std.testing.io;
    const dir = ".zig-cache/bs_install_none";
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const src =
        \\#import std.build.{ Build };
        \\build :: fn(b: Build) {
        \\    b.executable("app", "main.gab");
        \\}
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/build.gab", .data = src });
    try std.testing.expectError(error.UnknownTarget, build.run(std.testing.allocator, io, dir ++ "/build.gab", .{ .target = "install", .quiet = true }));
}
