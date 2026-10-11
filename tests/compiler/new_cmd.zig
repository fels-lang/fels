/// `fels new` and `fels init`: each template makes a project whose tests pass and that builds.
/// Without LLVM the tests run on the comptime VM and nothing is built.
const std = @import("std");
const builtin = @import("builtin");
const fels = @import("fels_compiler");
const new_cmd = fels.new_cmd;

const io = std.testing.io;
const native = fels.llvm_enabled and builtin.os.tag == .windows;

fn options(dir: []const u8, name: []const u8, template: new_cmd.Template) new_cmd.Options {
    return .{ .dir = dir, .name = name, .template = template, .git = false, .year = 2026, .author = "Ana Example" };
}

fn read(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
}

fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn expectHas(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("expected to find:\n{s}\nin:\n{s}\n", .{ part, text });
        return error.TestUnexpectedResult;
    }
}

/// Make a project from `template` in `.zig-cache/<label>/<name>`, run its tests, build it and
/// run what it built (`bin/<exe>`).
fn checkTemplate(comptime label: []const u8, name: []const u8, template: new_cmd.Template, exe: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/" ++ label ++ "/{s}", .{name});
    std.Io.Dir.cwd().deleteTree(io, ".zig-cache/" ++ label) catch {};

    var out: std.Io.Writer.Allocating = .init(a);
    _ = try new_cmd.create(a, io, &out.writer, options(dir, name, template));

    // The tests the template brings pass: natively, or on the comptime VM, where a test that
    // calls C is skipped.
    var report: std.Io.Writer.Allocating = .init(a);
    const summary = try fels.test_cmd.run(std.testing.allocator, io, &report.writer, .{
        .project_dir = dir,
        .comptime_only = !native,
        .llvm_bin = fels.llvm_path ++ "/bin",
        .lib_paths = if (fels.windows_sdk_lib_path.len != 0) &.{fels.windows_sdk_lib_path} else &.{},
    });
    if (!summary.ok() or summary.passed + summary.skipped == 0) {
        std.debug.print("{s}\n", .{report.written()});
        return error.TestUnexpectedResult;
    }
    if (!native) return;

    const lib_paths: []const []const u8 = if (fels.windows_sdk_lib_path.len != 0) &.{fels.windows_sdk_lib_path} else &.{};
    try fels.build_driver.run(a, io, try std.fmt.allocPrint(a, "{s}/build.fels", .{dir}), .{
        .quiet = true,
        .llvm_bin = fels.llvm_path ++ "/bin",
        .lib_paths = lib_paths,
    });
    const program = try std.fmt.allocPrint(a, "{s}/bin/{s}", .{ dir, exe });
    const r = try std.process.run(a, io, .{ .argv = &.{program} });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
}

test "fels new: the app template's tests pass, and it builds and runs" {
    try checkTemplate("nc_app", "hello", .app, "hello.exe");
}

test "fels new: the lib template's tests pass, and its example imports it and runs" {
    try checkTemplate("nc_lib", "mathx", .lib, "demo.exe");
}

test "fels new: the cbind template's tests call C, and its example runs" {
    try checkTemplate("nc_cbind", "clib", .cbind, "demo.exe");
}

test "fels new: the name, the year and the author fill the files, with the license asked for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    std.Io.Dir.cwd().deleteTree(io, ".zig-cache/nc_fill") catch {};
    var out: std.Io.Writer.Allocating = .init(a);

    const created = try new_cmd.create(a, io, &out.writer, options(".zig-cache/nc_fill/mit", "mathx", .lib));
    try std.testing.expectEqualStrings("src/mathx.fels", created.written[2]);
    try std.testing.expectEqualStrings(
        "#package mathx \"0.1.0\";\n#license \"MIT\";\n#description \"What mathx does, in one line.\";\n",
        try read(a, ".zig-cache/nc_fill/mit/fels.pkg"),
    );
    try expectHas(try read(a, ".zig-cache/nc_fill/mit/LICENSE"), "MIT License\n\nCopyright (c) 2026 Ana Example\n");
    try expectHas(try read(a, ".zig-cache/nc_fill/mit/examples/demo.fels"), "#import mathx;\n");
    try expectHas(try read(a, ".zig-cache/nc_fill/mit/README.md"), "fels add mathx github.com/<you>/mathx\n");

    var apache = options(".zig-cache/nc_fill/apache", "tool", .app);
    apache.license = .apache;
    _ = try new_cmd.create(a, io, &out.writer, apache);
    try expectHas(try read(a, ".zig-cache/nc_fill/apache/fels.pkg"), "#license \"Apache-2.0\";\n");
    try expectHas(try read(a, ".zig-cache/nc_fill/apache/LICENSE"), "Apache License\n                           Version 2.0, January 2004\n");

    var none = options(".zig-cache/nc_fill/none", "tool", .app);
    none.license = .none;
    _ = try new_cmd.create(a, io, &out.writer, none);
    try std.testing.expectEqualStrings("#package tool \"0.1.0\";\n", try read(a, ".zig-cache/nc_fill/none/fels.pkg"));
    try std.testing.expect(!exists(".zig-cache/nc_fill/none/LICENSE"));
}

test "fels new needs a new folder; fels init keeps the files that are there" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = ".zig-cache/nc_init";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/README.md", .data = "# mine\n" });

    var out: std.Io.Writer.Allocating = .init(a);
    try std.testing.expectError(error.Exists, new_cmd.create(a, io, &out.writer, options(dir, "tool", .app)));
    try expectHas(out.written(), "exists and is not empty");

    var at_home = options(dir, "tool", .app);
    at_home.init = true;
    const created = try new_cmd.create(a, io, &out.writer, at_home);
    try std.testing.expectEqual(@as(usize, 1), created.kept.len);
    try std.testing.expectEqualStrings("README.md", created.kept[0]);
    try std.testing.expectEqualStrings("# mine\n", try read(a, dir ++ "/README.md"));
    try std.testing.expect(exists(dir ++ "/src/main.fels"));

    // Once there is a fels.pkg, the folder is a project.
    try std.testing.expectError(error.Exists, new_cmd.create(a, io, &out.writer, at_home));
    try expectHas(out.written(), "has a fels.pkg already");
}

test "fels new: a folder name becomes the package name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("mathx", (try new_cmd.identifier(a, "mathx")).?);
    try std.testing.expectEqualStrings("my_lib", (try new_cmd.identifier(a, "my-lib")).?);
    try std.testing.expectEqualStrings("a_b_c", (try new_cmd.identifier(a, "a.b c")).?);
    try std.testing.expectEqualStrings("_x9", (try new_cmd.identifier(a, "_x9")).?);
    try std.testing.expect((try new_cmd.identifier(a, "9lives")) == null);
    try std.testing.expect((try new_cmd.identifier(a, "caf\u{e9}")) == null);
    try std.testing.expect((try new_cmd.identifier(a, "")) == null);
}
