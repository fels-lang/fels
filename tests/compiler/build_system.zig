/// The `fels build` build system: runs build.fels scripts on the comptime VM and checks the
/// plan they record. Nothing is compiled or linked, so these run without LLVM.
const std = @import("std");
const fels = @import("fels_compiler");
const builtin = @import("builtin");
const build = fels.build_driver;

/// Write `src` as `<dir>/build.fels` and load its plan with the `-D` `options`.
fn loadPlan(comptime dir: []const u8, src: []const u8, options: []const []const u8) !build.BuildPlan {
    const io = std.testing.io;
    std.Io.Dir.cwd().createDirPath(io, ".zig-cache/" ++ dir) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ".zig-cache/" ++ dir ++ "/build.fels", .data = src });
    return build.loadPlan(std.testing.allocator, io, ".zig-cache/" ++ dir ++ "/build.fels", options);
}

const options_script =
    \\#import std.build.{ Build };
    \\build :: fn(b: Build) {
    \\    fast := b.option_bool("fast", false, "build with optimizations");
    \\    threads := b.option_int("threads", 4, "worker threads");
    \\    name := b.option_string("name", "hello", "output name");
    \\    backend := b.option_choice("backend", "gl|vulkan|d3d", "gl", "renderer");
    \\    exe := b.executable(name, "main.fels");
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
        \\    b.executable(mode, "main.fels");
        \\}
    ;
    try std.testing.expectError(error.ScriptError, loadPlan("bs_opt_choice_default", src, &.{}));
}

test "build: the short option forms declare their options too" {
    const src =
        \\#import std.build.{ Build };
        \\build :: fn(b: Build) {
        \\    exe := b.executable(b.option_str("name", "x"), "main.fels");
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
        \\    util := b.static("util", "util.fels");
        \\    app := b.executable("app", "main.fels");
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
        \\    tool := b.executable("tool", "tool.fels");
        \\    app := b.executable("app", "main.fels");
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
        \\    b.executable("app", "main.fels");
        \\    b.install_prefix("pkg");
        \\    b.install_file("README.md", "doc/README.md");
        \\    b.install_dir("assets", "share/assets");
        \\}
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/build.fels", .data = src });
    try build.run(std.testing.allocator, io, dir ++ "/build.fels", .{ .target = "install", .quiet = true });

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
        \\    b.executable("app", "main.fels");
        \\}
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/build.fels", .data = src });
    try std.testing.expectError(error.UnknownTarget, build.run(std.testing.allocator, io, dir ++ "/build.fels", .{ .target = "install", .quiet = true }));
}

test "build: define records constants as Fels source, a later define wins" {
    const src =
        \\#import std.build.{ Build };
        \\build :: fn(b: Build) {
        \\    app := b.executable("app", "main.fels");
        \\    app.define("NAME", "say \"hi\"\n");
        \\    app.define_int("LEVEL", -3);
        \\    app.define_bool("FAST", true);
        \\    app.define_int("LEVEL", 7);
        \\    app.add_module("mathlib", "deps/mathlib");
        \\}
    ;
    var plan = try loadPlan("bs_define", src, &.{});
    defer plan.deinit();
    const d = plan.artifacts.items[0].defines.items;
    try std.testing.expectEqual(@as(usize, 3), d.len);
    try std.testing.expectEqualStrings("\"say \\\"hi\\\"\\n\"", d[0].value);
    try std.testing.expectEqualStrings("LEVEL", d[1].name);
    try std.testing.expectEqualStrings("7", d[1].value);
    try std.testing.expectEqualStrings("true", d[2].value);
    const m = plan.artifacts.items[0].modules.items;
    try std.testing.expectEqualStrings("mathlib", m[0].name);
    try std.testing.expectEqualStrings("deps/mathlib", m[0].dir);
}

test "build: a define or module name that is not a name is an error" {
    const define_src =
        \\#import std.build.{ Build };
        \\build :: fn(b: Build) {
        \\    app := b.executable("app", "main.fels");
        \\    app.define("MY-NAME", "x");
        \\}
    ;
    try std.testing.expectError(error.ScriptError, loadPlan("bs_define_bad", define_src, &.{}));
    const module_src =
        \\#import std.build.{ Build };
        \\build :: fn(b: Build) {
        \\    app := b.executable("app", "main.fels");
        \\    app.add_module("std", "mystd");
        \\}
    ;
    try std.testing.expectError(error.ScriptError, loadPlan("bs_module_bad", module_src, &.{}));
}

/// Write `src` as `<dir>/build.fels` (after clearing `dir`) and run `target` with it.
fn runTarget(comptime dir: []const u8, src: []const u8, target: []const u8) !void {
    const io = std.testing.io;
    const path = ".zig-cache/" ++ dir;
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    std.Io.Dir.cwd().createDirPath(io, path) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path ++ "/build.fels", .data = src });
    return build.run(std.testing.allocator, io, path ++ "/build.fels", .{ .target = target, .quiet = true });
}

fn expectFile(path: []const u8, want: []const u8) !void {
    const gpa = std.testing.allocator;
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .unlimited);
    defer gpa.free(data);
    try std.testing.expectEqualStrings(want, data);
}

test "build: a step runs the steps it comes after, then its file actions in order" {
    const src =
        \\#import std.build.{ Build };
        \\build :: fn(b: Build) {
        \\    b.executable("app", "main.fels");
        \\    gen := b.step("gen", "write the inputs");
        \\    gen.write_file("in/a.txt", "a");
        \\    gen.write_file("in/sub/b.txt", "b");
        \\    pack := b.step("pack", "copy them");
        \\    pack.after(gen);
        \\    pack.copy_dir("in", "out/in");
        \\    pack.copy_file("in/a.txt", "out/a-copy.txt");
        \\    pack.remove("in");
        \\}
    ;
    try runTarget("bs_step_files", src, "pack");
    try expectFile(".zig-cache/bs_step_files/out/in/a.txt", "a");
    try expectFile(".zig-cache/bs_step_files/out/in/sub/b.txt", "b");
    try expectFile(".zig-cache/bs_step_files/out/a-copy.txt", "a");
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, ".zig-cache/bs_step_files/in", .{}));
}

test "build: a command gets its arguments, working directory and environment" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const src =
        \\#import std.build.{ Build };
        \\build :: fn(b: Build) {
        \\    b.executable("app", "main.fels");
        \\    prep := b.step("prep", "");
        \\    prep.write_file("work/keep.txt", "");
        \\    cmd := b.command("say", "cmd");
        \\    cmd.arg("/c");
        \\    cmd.arg("echo %GREETING%>said.txt");
        \\    cmd.cwd("work");
        \\    cmd.env("GREETING", "hello");
        \\}
    ;
    // `say` runs in work/, which `prep` creates; run it first.
    const io = std.testing.io;
    try runTarget("bs_step_cmd", src, "prep");
    try build.run(std.testing.allocator, io, ".zig-cache/bs_step_cmd/build.fels", .{ .target = "say", .quiet = true });
    try expectFile(".zig-cache/bs_step_cmd/work/said.txt", "hello\r\n");
}

test "build: a command that fails stops the build" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const src =
        \\#import std.build.{ Build };
        \\build :: fn(b: Build) {
        \\    b.executable("app", "main.fels");
        \\    bad := b.command("fail", "cmd");
        \\    bad.arg("/c");
        \\    bad.arg("exit 3");
        \\}
    ;
    try std.testing.expectError(error.StepFailed, runTarget("bs_step_fail", src, "fail"));
}

test "build: the default step runs for a bare fels build" {
    const src =
        \\#import std.build.{ Build };
        \\build :: fn(b: Build) {
        \\    b.executable("app", "main.fels");
        \\    notes := b.step("notes", "");
        \\    notes.write_file("notes.txt", "ran");
        \\    b.default_step(notes);
        \\}
    ;
    const io = std.testing.io;
    const dir = ".zig-cache/bs_step_default";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/build.fels", .data = src });
    try build.run(std.testing.allocator, io, dir ++ "/build.fels", .{ .quiet = true });
    try expectFile(dir ++ "/notes.txt", "ran");
}

test "build: two steps of the same name are an error, a step after itself too" {
    const twice =
        \\#import std.build.{ Build };
        \\build :: fn(b: Build) {
        \\    b.executable("app", "main.fels");
        \\    b.step("gen", "");
        \\    b.step("gen", "");
        \\}
    ;
    try std.testing.expectError(error.ScriptError, loadPlan("bs_step_twice", twice, &.{}));
    const cycle =
        \\#import std.build.{ Build };
        \\build :: fn(b: Build) {
        \\    b.executable("app", "main.fels");
        \\    a := b.step("a", "");
        \\    c := b.step("c", "");
        \\    a.after(c);
        \\    c.after(a);
        \\}
    ;
    try std.testing.expectError(error.DependencyCycle, runTarget("bs_step_cycle", cycle, "a"));
}

test "build: target, sysroot, strip and host_os" {
    const src =
        \\#import std.build.{ Build };
        \\build :: fn(b: Build) {
        \\    app := b.executable("app", "main.fels");
        \\    app.target(.linux_gnu);
        \\    app.sysroot("sysroot");
        \\    app.strip();
        \\    if b.host_os() == .windows { app.version("on-windows"); }
        \\    if b.host_os() == .linux { app.version("on-linux"); }
        \\}
    ;
    var plan = try loadPlan("bs_target", src, &.{});
    defer plan.deinit();
    const app = plan.artifacts.items[0];
    try std.testing.expectEqual(std.Target.Os.Tag.linux, app.target_os);
    try std.testing.expect(app.target_gnu);
    try std.testing.expectEqualStrings("sysroot", app.sysroot);
    try std.testing.expect(app.strip);
    const want = if (builtin.os.tag == .windows) "on-windows" else "on-linux";
    try std.testing.expectEqualStrings(want, app.version.?);
}

test "build: a library for Linux is not supported yet, and says so" {
    const src =
        \\#import std.build.{ Build };
        \\build :: fn(b: Build) {
        \\    lib := b.static("util", "util.fels");
        \\    lib.target(.linux);
        \\}
    ;
    try std.testing.expectError(error.ScriptError, loadPlan("bs_target_lib", src, &.{}));
}

test "build: a build script can print" {
    const src =
        \\#import std.build.{ Build };
        \\#import std.io.{ println };
        \\build :: fn(b: Build) {
        \\    println("configuring");
        \\    b.executable("app", "main.fels");
        \\}
    ;
    var plan = try loadPlan("bs_print", src, &.{});
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.artifacts.items.len);
}
