/// `fels test`: the #test functions of a project's files run on the comptime VM, file by file.
/// Nothing is generated or linked, so these run without LLVM.
const std = @import("std");
const fels = @import("fels_compiler");
const test_cmd = fels.test_cmd;

const io = std.testing.io;

fn write(dir: []const u8, rel: []const u8, data: []const u8) !void {
    var buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, rel });
    if (std.fs.path.dirname(path)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// A library `mathx` in `.zig-cache/<name>`: fels.pkg, and src/mathx.fels with a passing and a
/// failing test.
fn library(comptime name: []const u8) ![]const u8 {
    const dir = comptime libDir(name);
    std.Io.Dir.cwd().deleteTree(io, ".zig-cache/" ++ name) catch {};
    try write(dir, "fels.pkg", "#package mathx \"0.1.0\";\n");
    try write(dir, "src/mathx.fels",
        \\pub clamp :: fn(x: i32, lo: i32, hi: i32) -> i32 {
        \\    if x < lo { return lo; }
        \\    if x > hi { return hi; }
        \\    return x;
        \\}
        \\
        \\pub lerp :: fn(a: i32, b: i32, t: i32) -> i32 {
        \\    return a + (b - a) * t / 100;
        \\}
        \\
        \\#test
        \\clamp_works :: fn(t: *Test) {
        \\    t.eq(clamp(5, 0, 10), 5);
        \\    t.eq(clamp(-5, 0, 10), 0);
        \\    t.eq(clamp(50, 0, 10), 10);
        \\}
        \\
        \\#test
        \\lerp_works :: fn(t: *Test) {
        \\    t.eq(lerp(0, 10, 50), 6);
        \\}
        \\
    );
    return dir;
}

fn libDir(comptime name: []const u8) []const u8 {
    return ".zig-cache/" ++ name ++ "/mathx";
}

/// Run `fels test` and return its summary and report (on the testing allocator).
fn runTests(opts: test_cmd.Options) !struct { summary: test_cmd.Summary, text: []u8 } {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const summary = try test_cmd.run(std.testing.allocator, io, &out.writer, opts);
    return .{ .summary = summary, .text = try out.toOwnedSlice() };
}

fn expectHas(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("expected to find:\n{s}\nin:\n{s}\n", .{ part, text });
        return error.TestUnexpectedResult;
    }
}

test "fels test: the tests of each file run, a failing one says why" {
    const dir = try library("tc_basic");
    // Imports the library by its own package name, and runs only its own test.
    try write(dir, "src/more.fels",
        \\#import mathx;
        \\
        \\#test
        \\clamps_through_the_package :: fn(t: *Test) {
        \\    t.eq(mathx::clamp(3, 0, 2), 2);
        \\}
        \\
    );
    const r = try runTests(.{ .project_dir = dir });
    defer std.testing.allocator.free(r.text);
    try std.testing.expectEqual(@as(u32, 2), r.summary.passed);
    try std.testing.expectEqual(@as(u32, 1), r.summary.failed);
    try std.testing.expectEqual(@as(u32, 0), r.summary.broken);
    try std.testing.expect(!r.summary.ok());
    try expectHas(r.text, "/src/mathx.fels\n  \u{2713} clamp_works\n  \u{2717} lerp_works: t.eq: values are not equal\n");
    try expectHas(r.text, "/src/more.fels\n  \u{2713} clamps_through_the_package\n");
    try std.testing.expect(std.mem.endsWith(u8, r.text, "\n2 passed, 1 failed\n"));
}

test "fels test: a file that does not compile is reported and counts as failed" {
    const dir = try library("tc_broken");
    try write(dir, "src/mathx.fels",
        \\pub one :: fn() -> i32 { return 1; }
        \\#test
        \\one_is_one :: fn(t: *Test) { t.eq(one(), 1); }
        \\
    );
    try write(dir, "src/broken.fels", "#import mathx;\nvalue :: fn() -> i32 { return mathx::nothing(); }\n");
    const r = try runTests(.{ .project_dir = dir });
    defer std.testing.allocator.free(r.text);
    try std.testing.expectEqual(@as(u32, 1), r.summary.passed);
    try std.testing.expectEqual(@as(u32, 1), r.summary.broken);
    try std.testing.expect(!r.summary.ok());
    try expectHas(r.text, "/src/broken.fels\n  \u{2717} does not compile\n");
    try std.testing.expect(std.mem.endsWith(u8, r.text, "\n1 passed, 0 failed, 1 file has errors\n"));
}

test "fels test: no #test functions is not a failure" {
    const dir = try library("tc_none");
    try write(dir, "src/mathx.fels", "pub one :: fn() -> i32 { return 1; }\n");
    const r = try runTests(.{ .project_dir = dir });
    defer std.testing.allocator.free(r.text);
    try std.testing.expect(r.summary.ok());
    try std.testing.expectEqualStrings("no #test functions found\n", r.text);
}

test "fels test: given files and folders, without the folders a walk skips" {
    const dir = comptime libDir("tc_paths");
    _ = try library("tc_paths");
    const ok_test = "#import mathx;\n#test\nworks :: fn(t: *Test) { t.eq(mathx::clamp(1, 0, 2), 1); }\n";
    const bad_test = "#test\nfails :: fn(t: *Test) { t.expect(false); }\n";
    try write(dir, "examples/demo.fels", ok_test);
    try write(dir, "examples/deep/more.fels", ok_test);
    // Never entered by a walk: build output, vendored packages, hidden folders. A build.fels
    // is a build script, not a test.
    try write(dir, "examples/zig-out/x.fels", bad_test);
    try write(dir, "examples/vendor/x.fels", bad_test);
    try write(dir, "examples/dist/x.fels", bad_test);
    try write(dir, "examples/.hidden/x.fels", bad_test);
    try write(dir, "examples/build.fels", bad_test);

    // The library's own tests are not run: only the given folder's files, each with its own.
    const examples = dir ++ "/examples";
    const r = try runTests(.{ .project_dir = dir, .paths = &.{ examples, examples ++ "/demo.fels" } });
    defer std.testing.allocator.free(r.text);
    try std.testing.expectEqual(@as(u32, 2), r.summary.passed);
    try std.testing.expectEqual(@as(u32, 0), r.summary.failed);
    try std.testing.expect(r.summary.ok());

    // A given file runs even where a walk would not look.
    const v = try runTests(.{ .project_dir = dir, .paths = &.{examples ++ "/vendor/x.fels"} });
    defer std.testing.allocator.free(v.text);
    try std.testing.expectEqual(@as(u32, 1), v.summary.failed);
    try expectHas(v.text, "  \u{2717} fails: t.expect: condition was false\n");

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.BadPath, test_cmd.run(std.testing.allocator, io, &out.writer, .{ .project_dir = dir, .paths = &.{dir ++ "/nosuch.fels"} }));
    try expectHas(out.written(), "cannot find");
}

test "fels test: without src/ the project folder is tested, and a project without fels.pkg works" {
    const dir = ".zig-cache/tc_flat";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try write(dir, "util.fels", "pub twice :: fn(x: i32) -> i32 { return x * 2; }\n");
    try write(dir, "util_test.fels", "#import util;\n#test\ntwice_doubles :: fn(t: *Test) { t.eq(util::twice(4), 8); }\n");
    const r = try runTests(.{ .project_dir = dir });
    defer std.testing.allocator.free(r.text);
    try std.testing.expectEqual(@as(u32, 1), r.summary.passed);
    try std.testing.expect(r.summary.ok());
    try expectHas(r.text, "/util_test.fels\n  \u{2713} twice_doubles\n");
}
