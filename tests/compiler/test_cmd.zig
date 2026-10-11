/// `fels test`: the #test functions of a project's files run, file by file. The tests of the
/// comptime VM lane (`comptime_only`) need no LLVM; the native ones build and run programs.
const std = @import("std");
const builtin = @import("builtin");
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

const Result = struct { summary: test_cmd.Summary, text: []u8 };

/// Run `fels test` on the comptime VM and return its summary and report (on the testing
/// allocator).
fn runTests(opts: test_cmd.Options) !Result {
    var vm_opts = opts;
    vm_opts.comptime_only = true;
    return runWith(vm_opts);
}

/// Run `fels test` with native test programs.
fn runNative(opts: test_cmd.Options) !Result {
    var native = opts;
    native.llvm_bin = fels.llvm_path ++ "/bin";
    native.lib_paths = if (fels.windows_sdk_lib_path.len != 0) &.{fels.windows_sdk_lib_path} else &.{};
    return runWith(native);
}

fn runWith(opts: test_cmd.Options) !Result {
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

test "fels test: on the comptime VM, a test named like a function of another file runs" {
    const dir = try library("tc_same_name");
    try write(dir, "src/mathx.fels", "pub helper :: fn() -> i32 { return 1; }\n");
    try write(dir, "src/more.fels",
        \\#import mathx;
        \\
        \\#test
        \\helper :: fn(t: *Test) {
        \\    t.eq(mathx::helper(), 1);
        \\}
        \\
    );
    const r = try runTests(.{ .project_dir = dir });
    defer std.testing.allocator.free(r.text);
    try expectHas(r.text, "/src/more.fels\n  \u{2713} helper\n");
    try std.testing.expectEqual(@as(u32, 1), r.summary.passed);
    try std.testing.expectEqual(@as(u32, 0), r.summary.skipped);
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
    try std.testing.expectError(error.BadPath, test_cmd.run(std.testing.allocator, io, &out.writer, .{ .project_dir = dir, .paths = &.{dir ++ "/nosuch.fels"}, .comptime_only = true }));
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

test "fels test: on the comptime VM, a test that needs the running program is skipped" {
    const dir = ".zig-cache/tc_skip";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try write(dir, "src/app.fels",
        \\counter: i32 = 0;
        \\
        \\#test
        \\asks_the_os :: fn(t: *Test) {
        \\    t.expect(os_pid() > 0i64);
        \\}
        \\
        \\#test
        \\counts :: fn(t: *Test) {
        \\    counter += 1;
        \\    t.eq(counter, 1);
        \\}
        \\
        \\#test
        \\adds :: fn(t: *Test) {
        \\    t.eq(1 + 1, 2);
        \\}
        \\
    );
    const r = try runTests(.{ .project_dir = dir });
    defer std.testing.allocator.free(r.text);
    try std.testing.expectEqual(@as(u32, 1), r.summary.passed);
    try std.testing.expectEqual(@as(u32, 2), r.summary.skipped);
    try std.testing.expect(r.summary.ok());
    try expectHas(r.text, "  - asks_the_os: skipped (comptime FFI to `");
    try expectHas(r.text, "  - counts: skipped (the comptime VM cannot run `counts`)\n");
    try std.testing.expect(std.mem.endsWith(u8, r.text, "\n1 passed, 0 failed, 2 skipped\n"));
}

/// An app: `main`, a function, and tests that print, write a file, fail.
const app_source =
    \\#import std.io;
    \\#import std.io.{ Writer };
    \\#import std.fs;
    \\
    \\double :: fn(x: i32) -> i32 { return x * 2; }
    \\
    \\main :: fn() -> i32 {
    \\    io::println("the app runs");
    \\    return 0;
    \\}
    \\
    \\#test
    \\doubles :: fn(t: *Test) {
    \\    t.eq(double(4), 8);
    \\}
    \\
    \\#test
    \\writes_a_file :: fn(t: *Test) {
    \\    f := fs::create("out.txt") catch err { t.fatal("cannot create out.txt"); return; };
    \\    w: *Writer = &f;
    \\    w.write_all("hi") catch err { t.fatal("cannot write"); return; };
    \\    (&f).close();
    \\    t.expect(fs::exists("out.txt"));
    \\}
    \\
    \\#test
    \\prints_and_fails :: fn(t: *Test) {
    \\    io::println("double(2) is computed");
    \\    t.eq(double(2), 5);
    \\    t.expect(double(1) == 3);
    \\}
    \\
;

test "fels test: natively, an app's tests write files, and a failing one shows what it printed" {
    if (comptime !fels.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const dir = ".zig-cache/tc_native";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try write(dir, "fels.pkg", "#package app \"0.1.0\";\n");
    try write(dir, "src/main.fels", app_source);
    const r = try runNative(.{ .project_dir = dir });
    defer std.testing.allocator.free(r.text);
    try std.testing.expectEqual(@as(u32, 2), r.summary.passed);
    try std.testing.expectEqual(@as(u32, 1), r.summary.failed);
    try std.testing.expectEqual(@as(u32, 0), r.summary.broken);
    try expectHas(r.text, "/src/main.fels\n  \u{2713} doubles\n  \u{2713} writes_a_file\n");
    try expectHas(r.text, "  \u{2717} prints_and_fails: t.eq: values are not equal\n      t.expect: condition was false\n      | double(2) is computed\n");
    // The test program runs in the project folder, and the app's own `main` does not run.
    std.Io.Dir.cwd().access(io, dir ++ "/out.txt", .{}) catch return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, r.text, "the app runs") == null);
    try std.testing.expect(std.mem.endsWith(u8, r.text, "\n2 passed, 1 failed\n"));
}

// `a.alloc_bytes(4)` is std.heap's method on Arena. A free `alloc_bytes(n: i32)` in the program
// made it "no visible method", and once found, the call went to the free one.
const same_name_source =
    \\#import std.heap as heap;
    \\
    \\alloc_bytes :: fn(n: i32) -> i32 { return n + 1; }
    \\
    \\#test
    \\the_method_and_the_function_both_answer :: fn(t: *Test) {
    \\    a := heap::make();
    \\    b := a.alloc_bytes(4usize);
    \\    b[3] = 7u8;
    \\    t.eq(b.len, 4usize);
    \\    t.eq(alloc_bytes(b[3] as i32), 8);
    \\    a.deinit();
    \\}
    \\
;

test "fels test: a free function does not hide a method of the same name from another module" {
    const dir = ".zig-cache/tc_method_same_name";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try write(dir, "fels.pkg", "#package app \"0.1.0\";\n");
    try write(dir, "src/main.fels", same_name_source);
    const vm = try runTests(.{ .project_dir = dir });
    defer std.testing.allocator.free(vm.text);
    try expectHas(vm.text, "  \u{2713} the_method_and_the_function_both_answer\n");
    if (comptime !fels.llvm_enabled) return;
    if (comptime builtin.os.tag != .windows) return;
    const native = try runNative(.{ .project_dir = dir });
    defer std.testing.allocator.free(native.text);
    try expectHas(native.text, "  \u{2713} the_method_and_the_function_both_answer\n");
}

test "fels test: natively, a file without tests compiles as it is and is not an error" {
    if (comptime !fels.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const dir = ".zig-cache/tc_native_none";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try write(dir, "fels.pkg", "#package mathx \"0.1.0\";\n");
    try write(dir, "src/mathx.fels", "pub clamp :: fn(x: i32, lo: i32, hi: i32) -> i32 {\n    if x < lo { return lo; }\n    if x > hi { return hi; }\n    return x;\n}\n");
    const r = try runNative(.{ .project_dir = dir });
    defer std.testing.allocator.free(r.text);
    try std.testing.expect(r.summary.ok());
    try std.testing.expectEqualStrings("no #test functions found\n", r.text);

    // Next to a file with tests.
    try write(dir, "src/more.fels", "#import mathx;\n#test\nclamps :: fn(t: *Test) { t.eq(mathx::clamp(9, 0, 5), 5); }\n");
    const m = try runNative(.{ .project_dir = dir });
    defer std.testing.allocator.free(m.text);
    try std.testing.expectEqual(@as(u32, 1), m.summary.passed);
    try std.testing.expect(m.summary.ok());
}

test "fels test: natively, a crash and t.fatal end only their own test" {
    if (comptime !fels.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const dir = ".zig-cache/tc_crash";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try write(dir, "src/crash.fels",
        \\#test
        \\first :: fn(t: *Test) {
        \\    t.eq(1, 1);
        \\}
        \\
        \\#test
        \\out_of_bounds :: fn(t: *Test) {
        \\    xs: [3]i32 = .{ 1, 2, 3 };
        \\    i: usize = 5usize;
        \\    t.eq(xs[i], 1);
        \\}
        \\
        \\#test
        \\gives_up :: fn(t: *Test) {
        \\    t.fatal("no config file");
        \\    t.eq(1, 2);
        \\}
        \\
        \\#test
        \\last :: fn(t: *Test) {
        \\    t.eq(2, 2);
        \\}
        \\
    );
    const r = try runNative(.{ .project_dir = dir });
    defer std.testing.allocator.free(r.text);
    try std.testing.expectEqual(@as(u32, 2), r.summary.passed);
    try std.testing.expectEqual(@as(u32, 2), r.summary.failed);
    try expectHas(r.text, "  \u{2713} first\n  \u{2717} out_of_bounds: panic: index out of bounds");
    try expectHas(r.text, "  \u{2717} gives_up: no config file\n  \u{2713} last\n");
}
