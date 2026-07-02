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
    try expectHas(r.text, "\n\nTest Summary: 2 passed, 1 failed \u{00b7} ");
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
    try expectHas(r.text, "\n\nTest Summary: 1 passed, 1 file has errors \u{00b7} ");
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
    try expectHas(r.text, if (builtin.os.tag == .windows)
        "  \u{00b7} asks_the_os: skipped (comptime FFI to `"
    else
        "  \u{00b7} asks_the_os: skipped (the comptime VM cannot run `sys_getpid`)");
    try expectHas(r.text, "  \u{00b7} counts: skipped (compile-time code cannot modify a global)\n");
    try expectHas(r.text, "\n\nTest Summary: 1 passed, 2 skipped \u{00b7} ");
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
    try expectHas(r.text, "\n\nTest Summary: 2 passed, 1 failed \u{00b7} ");
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

test "fels test: a type of another module is a type argument" {
    const dir = ".zig-cache/tc_scoped_type_arg";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try write(dir, "fels.pkg", "#package app \"0.1.0\";\n");
    try write(dir, "src/shapes.fels", "pub Point :: struct { x: i32, y: i32 }\n");
    // `first(shapes::Point, ...)` was "expected a type argument".
    try write(dir, "src/main.fels",
        \\#import shapes;
        \\
        \\first :: fn($T: type, xs: []T) -> T { return xs[0]; }
        \\
        \\#test
        \\a_qualified_type_as_an_argument :: fn(t: *Test) {
        \\    pts: [2]shapes::Point = .{ .{ 3, 4 }, .{ 5, 6 } };
        \\    p := first(shapes::Point, pts[:]);
        \\    t.eq(p.x, 3);
        \\    t.eq(p.y, 4);
        \\}
        \\
    );
    const vm = try runTests(.{ .project_dir = dir });
    defer std.testing.allocator.free(vm.text);
    try expectHas(vm.text, "  \u{2713} a_qualified_type_as_an_argument\n");
    if (comptime !fels.llvm_enabled) return;
    if (comptime builtin.os.tag != .windows) return;
    const native = try runNative(.{ .project_dir = dir });
    defer std.testing.allocator.free(native.text);
    try expectHas(native.text, "  \u{2713} a_qualified_type_as_an_argument\n");
}

// Two modules that each declare a `Point` (with a method), a private `State` and a `Kind`.
fn sameNameModules(comptime dir: []const u8) !void {
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try write(dir, "fels.pkg", "#package app \"0.1.0\";\n");
    try write(dir, "src/a.fels",
        \\pub Point :: struct {
        \\    x: i32,
        \\    y: i32,
        \\    pub sum :: fn(self: Self) -> i32 { return self.x + self.y; }
        \\}
        \\State :: struct { n: i32 }
        \\pub Kind :: enum { one, two }
        \\pub make :: fn() -> Point { s: State = .{ 3 }; p: Point = .{ s.n, 4 }; return p; }
        \\pub kind :: fn() -> Kind { return .two; }
        \\
    );
    try write(dir, "src/b.fels",
        \\pub Point :: struct {
        \\    x: f64,
        \\    pub twice :: fn(self: Self) -> f64 { return self.x * 2.0; }
        \\}
        \\State :: struct { name: []const u8, n: i64 }
        \\pub Kind :: enum { red, green, blue }
        \\pub make :: fn() -> Point { s: State = .{ "b", 5i64 }; p: Point = .{ s.n as f64 }; return p; }
        \\
    );
}

test "fels test: types of the same name in different modules" {
    // Each was "duplicate top-level declaration": types of all modules shared one namespace.
    const dir = ".zig-cache/tc_same_type_name";
    try sameNameModules(dir);
    try write(dir, "src/main.fels",
        \\#import app.a;
        \\#import app.b;
        \\
        \\#test
        \\points_states_and_kinds :: fn(t: *Test) {
        \\    t.eq(a::make().sum(), 7);
        \\    t.expect(b::make().twice() == 10.0);
        \\    t.expect(a::kind() == a::Kind.two);
        \\    k: b::Kind = .blue;
        \\    t.expect(k == .blue);
        \\}
        \\
    );
    // The comptime VM compiles the modules (it cannot run the test: methods on a returned
    // struct are beyond it), so nothing fails or breaks there.
    const vm = try runTests(.{ .project_dir = dir });
    defer std.testing.allocator.free(vm.text);
    try std.testing.expectEqual(@as(u32, 0), vm.summary.failed);
    try std.testing.expectEqual(@as(u32, 0), vm.summary.broken);
    if (comptime !fels.llvm_enabled) return;
    if (comptime builtin.os.tag != .windows) return;
    const native = try runNative(.{ .project_dir = dir });
    defer std.testing.allocator.free(native.text);
    try expectHas(native.text, "  \u{2713} points_states_and_kinds\n");
}

test "fels test: natively, a generic of each module's type, and a type named like one of std" {
    if (comptime !fels.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const dir = ".zig-cache/tc_same_type_name_native";
    try sameNameModules(dir);
    // `Reader` is an interface of std.io, which std.fs imports.
    try write(dir, "src/main.fels",
        \\#import app.a;
        \\#import app.b;
        \\#import std.vec as vec;
        \\#import std.heap as heap;
        \\#import std.fs as fs;
        \\
        \\Reader :: struct { n: i32 }
        \\
        \\#test
        \\a_vec_of_each_point :: fn(t: *Test) {
        \\    h := heap::make();
        \\    v := vec::make(a::Point, &h);
        \\    v.push(a::make());
        \\    w := vec::make(b::Point, &h);
        \\    w.push(b::make());
        \\    t.eq(v.items()[0].y, 4);
        \\    t.expect(w.items()[0].x == 5.0);
        \\    h.deinit();
        \\}
        \\
        \\#test
        \\a_reader_of_our_own :: fn(t: *Test) {
        \\    r: Reader = .{ 3 };
        \\    t.expect(!fs::exists("no such file"));
        \\    t.eq(r.n, 3);
        \\}
        \\
    );
    const native = try runNative(.{ .project_dir = dir });
    defer std.testing.allocator.free(native.text);
    try expectHas(native.text, "  \u{2713} a_vec_of_each_point\n");
    try expectHas(native.text, "  \u{2713} a_reader_of_our_own\n");
}

test "fels test: natively, a struct holding a generic of its module's type named like another's" {
    // Strata: `Vec(Holding)` in a struct of one module and a `pub Holding` in another. The
    // field's type was the instance of the bare name while the value was the instance of the
    // qualified one: an invalid insertvalue in LLVM.
    if (comptime !fels.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const dir = ".zig-cache/tc_same_type_name_field";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try write(dir, "fels.pkg", "#package app \"0.1.0\";\n");
    try write(dir, "src/a.fels",
        \\#import std.heap.{ Arena };
        \\#import std.vec as vec;
        \\#import std.vec.{ Vec };
        \\
        \\Item :: struct { x: i32 }
        \\State :: struct { items: Vec(Item), done: bool }
        \\
        \\pub count :: fn(a: *Arena) -> i32 {
        \\    st: State = .{ vec::make(Item, a), false };
        \\    it: Item = .{ 3 };
        \\    st.items.push(it);
        \\    return st.items.items()[0].x;
        \\}
        \\
    );
    try write(dir, "src/b.fels",
        \\pub Item :: struct { y: i64, z: i64 }
        \\pub make :: fn() -> Item { out: Item = .{ 5i64, 6i64 }; return out; }
        \\
    );
    try write(dir, "src/use_tests.fels",
        \\#import std.heap as heap;
        \\#import app.a;
        \\#import app.b;
        \\
        \\#test
        \\both_items :: fn(t: *Test) {
        \\    h := heap::make();
        \\    t.eq(a::count(&h), 3);
        \\    t.eq(b::make().y, 5i64);
        \\    h.deinit();
        \\}
        \\
    );
    const native = try runNative(.{ .project_dir = dir });
    defer std.testing.allocator.free(native.text);
    try expectHas(native.text, "  \u{2713} both_items\n");
}

test "fels test: a match on an enum named like a type of another module" {
    // Strata: an enum `Mark` next to std.heap's struct `Mark`. The match named the enum by its
    // bare name, not by the qualified one the IR knows it by, and took no arm (`unreachable`).
    const dir = ".zig-cache/tc_same_name_enum_match";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try write(dir, "fels.pkg", "#package app \"0.1.0\";\n");
    try write(dir, "src/a.fels",
        \\pub Mark :: enum { unknown, point, comma }
        \\
        \\pub after :: fn(m: Mark, c: u8) -> Mark {
        \\    if m != .unknown { return m; }
        \\    if c == 44u8 { return .comma; }
        \\    if c == 46u8 { return .point; }
        \\    return .unknown;
        \\}
        \\
        \\pub code :: fn(m: Mark) -> i32 {
        \\    match m {
        \\        .comma => { return 2; }
        \\        .point => { return 1; }
        \\        .unknown => { return 0; }
        \\    }
        \\}
        \\
    );
    try write(dir, "src/b.fels",
        \\pub Mark :: struct { at: usize }
        \\pub make :: fn() -> Mark { out: Mark = .{ 4usize }; return out; }
        \\
    );
    try write(dir, "src/use_tests.fels",
        \\#import app.a;
        \\#import app.b;
        \\
        \\#test
        \\marks :: fn(t: *Test) {
        \\    m: a::Mark = .unknown;
        \\    m = a::after(m, 46u8);
        \\    t.expect(m == .point);
        \\    t.eq(a::code(m), 1);
        \\    t.eq(a::code(.comma), 2);
        \\    t.eq(b::make().at, 4usize);
        \\}
        \\
    );
    const vm = try runTests(.{ .project_dir = dir });
    defer std.testing.allocator.free(vm.text);
    try expectHas(vm.text, "  \u{2713} marks\n");
    if (comptime !fels.llvm_enabled) return;
    if (comptime builtin.os.tag != .windows) return;
    const native = try runNative(.{ .project_dir = dir });
    defer std.testing.allocator.free(native.text);
    try expectHas(native.text, "  \u{2713} marks\n");
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

// A struct-valued field points at a block of its own on the comptime VM. Its address was the
// field's cell, one level too high: reading through `&o.inner` ran past `o`, and a method of
// the field (`c.bytes.push`, whose receiver is `&c.bytes`) failed with OutOfBounds.
const nested_field_source =
    \\#import std.heap as heap;
    \\#import std.vec as vec;
    \\#import std.vec.{ Vec };
    \\
    \\Inner :: struct { a: u32, b: u32 }
    \\Outer :: struct { x: u32, inner: Inner }
    \\Named :: struct { name: []const u8, inner: Inner }
    \\Buf :: struct { n: u32, bytes: Vec(u8) }
    \\
    \\get_b :: fn(p: *Inner) -> u32 { return p.b; }
    \\set_b :: fn(p: *Inner, v: u32) { p.b = v; }
    \\put :: fn(p: *Inner, v: Inner) { *p = v; }
    \\
    \\#test
    \\a_pointer_to_a_nested_struct :: fn(t: *Test) {
    \\    o: Outer = .{ .x = 1, .inner = .{ .a = 2, .b = 3 } };
    \\    p := &o.inner;
    \\    t.eq(p.b, 3u32);
    \\    p.a = 4u32;
    \\    o.inner.b = 5u32;
    \\    t.eq(o.inner.a, 4u32);
    \\    t.eq(p.b, 5u32);
    \\    t.eq(o.x, 1u32);
    \\}
    \\
    \\#test
    \\after_a_slice_field :: fn(t: *Test) {
    \\    n: Named = .{ .name = "nine", .inner = .{ .a = 2, .b = 3 } };
    \\    set_b(&n.inner, 9u32);
    \\    t.eq(get_b(&n.inner), 9u32);
    \\    t.eq(n.name.len, 4usize);
    \\}
    \\
    \\#test
    \\a_whole_struct_through_the_pointer :: fn(t: *Test) {
    \\    o: Outer = .{ .x = 1, .inner = .{ .a = 2, .b = 3 } };
    \\    put(&o.inner, .{ .a = 7, .b = 8 });
    \\    t.eq(o.inner.a, 7u32);
    \\    t.eq(o.inner.b, 8u32);
    \\    o.inner = .{ .a = 5, .b = 6 };
    \\    t.eq(o.inner.b, 6u32);
    \\    t.eq(o.x, 1u32);
    \\}
    \\
    \\#test
    \\methods_of_a_vec_field :: fn(t: *Test) {
    \\    h := heap::make();
    \\    c: Buf = .{ .n = 0, .bytes = vec::make(u8, &h) };
    \\    c.bytes.push(1u8);
    \\    c.bytes.push(2u8);
    \\    t.eq(c.bytes.len(), 2usize);
    \\    t.expect(c.bytes.cap() >= 2usize);
    \\    t.eq(c.bytes.get(1usize), 2u8);
    \\    h.deinit();
    \\}
    \\
;

test "fels test: on the comptime VM, a pointer to a struct-valued field reads and writes the field" {
    const dir = ".zig-cache/tc_nested_field_ptr";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try write(dir, "fels.pkg", "#package app \"0.1.0\";\n");
    try write(dir, "src/main.fels", nested_field_source);
    const vm = try runTests(.{ .project_dir = dir });
    defer std.testing.allocator.free(vm.text);
    try expectHas(vm.text, "  \u{2713} a_pointer_to_a_nested_struct\n  \u{2713} after_a_slice_field\n");
    try expectHas(vm.text, "  \u{2713} a_whole_struct_through_the_pointer\n  \u{2713} methods_of_a_vec_field\n");
    try std.testing.expectEqual(@as(u32, 4), vm.summary.passed);
    try std.testing.expect(vm.summary.ok());
    if (comptime !fels.llvm_enabled) return;
    if (comptime builtin.os.tag != .windows) return;
    const native = try runNative(.{ .project_dir = dir });
    defer std.testing.allocator.free(native.text);
    try std.testing.expectEqual(@as(u32, 4), native.summary.passed);
    try std.testing.expect(native.summary.ok());
}

// The same for an array field, an element that is a struct, and an enum field: each is a block
// of its own, which its address is, except where a slice starts.
const aggregate_element_source =
    \\Inner :: struct { a: u32, b: u32 }
    \\Kind :: enum { red, green, blue }
    \\Tagged :: struct { n: u32, k: Kind }
    \\Table :: struct { n: u32, vals: [3]u32, items: [2]Inner }
    \\
    \\set_b :: fn(p: *Inner, v: u32) { p.b = v; }
    \\put :: fn(p: *Inner, v: Inner) { *p = v; }
    \\second :: fn(t: *Table) -> u32 { return t.vals[1]; }
    \\paint :: fn(k: *Kind) { *k = .blue; }
    \\
    \\#test
    \\an_array_field_through_a_pointer :: fn(t: *Test) {
    \\    tb: Table = .{ .n = 1, .vals = .{ 4, 5, 6 }, .items = .{ .{ .a = 1, .b = 2 }, .{ .a = 3, .b = 4 } } };
    \\    t.eq(second(&tb), 5u32);
    \\    s := tb.vals[1..3];
    \\    t.eq(s[1], 6u32);
    \\    p := &tb;
    \\    p.items[1].b = 40u32;
    \\    t.eq(tb.items[1].b, 40u32);
    \\    t.eq(tb.n, 1u32);
    \\}
    \\
    \\#test
    \\a_pointer_to_an_element :: fn(t: *Test) {
    \\    arr: [2]Inner = .{ .{ .a = 1, .b = 2 }, .{ .a = 3, .b = 4 } };
    \\    set_b(&arr[0], 9u32);
    \\    put(&arr[1], .{ .a = 7, .b = 8 });
    \\    t.eq(arr[0].b, 9u32);
    \\    t.eq(arr[1].a, 7u32);
    \\    s := arr[1..];
    \\    t.eq(s[0].b, 8u32);
    \\}
    \\
    \\#test
    \\a_pointer_to_an_enum_field :: fn(t: *Test) {
    \\    g: Tagged = .{ .n = 1, .k = .green };
    \\    paint(&g.k);
    \\    t.expect(g.k == .blue);
    \\    k: Kind = .red;
    \\    paint(&k);
    \\    t.expect(k == .blue);
    \\}
    \\
;

test "fels test: on the comptime VM, a pointer to an array field, a struct element or an enum field" {
    const dir = ".zig-cache/tc_aggregate_element_ptr";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try write(dir, "fels.pkg", "#package app \"0.1.0\";\n");
    try write(dir, "src/main.fels", aggregate_element_source);
    const vm = try runTests(.{ .project_dir = dir });
    defer std.testing.allocator.free(vm.text);
    try expectHas(vm.text, "  \u{2713} an_array_field_through_a_pointer\n  \u{2713} a_pointer_to_an_element\n");
    try expectHas(vm.text, "  \u{2713} a_pointer_to_an_enum_field\n");
    try std.testing.expectEqual(@as(u32, 3), vm.summary.passed);
    try std.testing.expect(vm.summary.ok());
    if (comptime !fels.llvm_enabled) return;
    if (comptime builtin.os.tag != .windows) return;
    const native = try runNative(.{ .project_dir = dir });
    defer std.testing.allocator.free(native.text);
    try std.testing.expectEqual(@as(u32, 3), native.summary.passed);
    try std.testing.expect(native.summary.ok());
}

// On the comptime VM a struct value is a pointer to its block, and a copy of the value was a
// copy of the pointer: a write to the copy changed the original. A copy now has blocks of its
// own, its fields that are structs, its elements and its payload too.
const value_copy_source =
    \\Inner :: struct { a: u32, b: u32 }
    \\Outer :: struct { x: u32, inner: Inner }
    \\Deep :: struct { o: Outer, items: [2]Inner }
    \\Shape :: enum { none, box: Inner }
    \\
    \\put :: fn(p: *Outer, v: Outer) { *p = v; }
    \\
    \\#test
    \\local_copy :: fn(t: *Test) {
    \\    a: Inner = .{ .a = 1, .b = 2 };
    \\    b := a;
    \\    b.a = 5u32;
    \\    t.eq(a.a, 1u32);
    \\    t.eq(b.a, 5u32);
    \\}
    \\
    \\#test
    \\field_from_local :: fn(t: *Test) {
    \\    i: Inner = .{ .a = 1, .b = 2 };
    \\    o: Outer = .{ .x = 0, .inner = i };
    \\    o.inner.a = 5u32;
    \\    t.eq(i.a, 1u32);
    \\    arr: [2]Inner = .{ i, i };
    \\    arr[0].a = 6u32;
    \\    t.eq(arr[1].a, 1u32);
    \\    t.eq(i.a, 1u32);
    \\}
    \\
    \\#test
    \\a_copy_is_deep :: fn(t: *Test) {
    \\    d: Deep = .{ .o = .{ .x = 1, .inner = .{ .a = 1, .b = 2 } }, .items = .{ .{ .a = 3, .b = 4 }, .{ .a = 5, .b = 6 } } };
    \\    e := d;
    \\    e.o.inner.b = 20u32;
    \\    e.items[1].b = 60u32;
    \\    t.eq(d.o.inner.b, 2u32);
    \\    t.eq(d.items[1].b, 6u32);
    \\    t.eq(e.items[1].b, 60u32);
    \\}
    \\
    \\#test
    \\a_field_or_an_element_read_is_a_copy :: fn(t: *Test) {
    \\    o: Outer = .{ .x = 1, .inner = .{ .a = 1, .b = 2 } };
    \\    x := o.inner;
    \\    x.b = 9u32;
    \\    t.eq(o.inner.b, 2u32);
    \\    arr: [2]Inner = .{ .{ .a = 1, .b = 2 }, .{ .a = 3, .b = 4 } };
    \\    y := arr[1];
    \\    y.a = 30u32;
    \\    t.eq(arr[1].a, 3u32);
    \\    for v in arr {
    \\        v.a = v.a + 100u32;
    \\    }
    \\    t.eq(arr[0].a, 1u32);
    \\}
    \\
    \\#test
    \\an_assignment_writes_where_pointers_look :: fn(t: *Test) {
    \\    o: Outer = .{ .x = 1, .inner = .{ .a = 1, .b = 2 } };
    \\    i: Inner = .{ .a = 3, .b = 4 };
    \\    p := &o.inner;
    \\    o.inner = i;
    \\    o.inner.a = 8u32;
    \\    t.eq(i.a, 3u32);
    \\    t.eq(p.a, 8u32);
    \\    a: Inner = .{ .a = 1, .b = 2 };
    \\    q := &a;
    \\    a = i;
    \\    i.b = 40u32;
    \\    t.eq(q.b, 4u32);
    \\}
    \\
    \\#test
    \\a_whole_struct_through_a_pointer_is_deep :: fn(t: *Test) {
    \\    a: Outer = .{ .x = 1, .inner = .{ .a = 1, .b = 2 } };
    \\    b: Outer = .{ .x = 3, .inner = .{ .a = 3, .b = 4 } };
    \\    put(&a, b);
    \\    b.inner.a = 30u32;
    \\    t.eq(a.inner.a, 3u32);
    \\}
    \\
    \\#test
    \\an_enum_payload :: fn(t: *Test) {
    \\    i: Inner = .{ .a = 1, .b = 2 };
    \\    s: Shape = .box(i);
    \\    i.a = 50u32;
    \\    s2 := s;
    \\    match s2 {
    \\        .box |v| => { t.eq(v.a, 1u32); },
    \\        .none => { t.expect(false); },
    \\    }
    \\}
    \\
;

test "fels test: on the comptime VM, a copy of a struct, an array or an enum value is a value of its own" {
    const dir = ".zig-cache/tc_value_copy";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try write(dir, "fels.pkg", "#package app \"0.1.0\";\n");
    try write(dir, "src/main.fels", value_copy_source);
    const vm = try runTests(.{ .project_dir = dir });
    defer std.testing.allocator.free(vm.text);
    try expectHas(vm.text, "  \u{2713} local_copy\n  \u{2713} field_from_local\n  \u{2713} a_copy_is_deep\n");
    try expectHas(vm.text, "  \u{2713} a_field_or_an_element_read_is_a_copy\n  \u{2713} an_assignment_writes_where_pointers_look\n");
    try expectHas(vm.text, "  \u{2713} a_whole_struct_through_a_pointer_is_deep\n  \u{2713} an_enum_payload\n");
    try std.testing.expectEqual(@as(u32, 7), vm.summary.passed);
    try std.testing.expect(vm.summary.ok());
    if (comptime !fels.llvm_enabled) return;
    if (comptime builtin.os.tag != .windows) return;
    const native = try runNative(.{ .project_dir = dir });
    defer std.testing.allocator.free(native.text);
    try std.testing.expectEqual(@as(u32, 7), native.summary.passed);
    try std.testing.expect(native.summary.ok());
}

// The same across calls: what a function returns, and a param it changes.
const value_copy_call_source =
    \\Inner :: struct { a: u32, b: u32 }
    \\Outer :: struct { x: u32, inner: Inner }
    \\
    \\get_inner :: fn(o: *Outer) -> Inner { return o.inner; }
    \\pass_through :: fn(i: Inner) -> Inner { return i; }
    \\bump :: fn(i: Inner) -> u32 { i.a = i.a + 10u32; return i.a; }
    \\wrap :: fn(i: Inner) -> Outer { return .{ .x = 0, .inner = i }; }
    \\
    \\#test
    \\a_returned_field :: fn(t: *Test) {
    \\    o: Outer = .{ .x = 1, .inner = .{ .a = 1, .b = 2 } };
    \\    x := get_inner(&o);
    \\    x.a = 9u32;
    \\    t.eq(o.inner.a, 1u32);
    \\}
    \\
    \\#test
    \\a_returned_param :: fn(t: *Test) {
    \\    i: Inner = .{ .a = 1, .b = 2 };
    \\    j := pass_through(i);
    \\    j.a = 9u32;
    \\    t.eq(i.a, 1u32);
    \\    o := wrap(i);
    \\    o.inner.b = 4u32;
    \\    t.eq(i.b, 2u32);
    \\}
    \\
    \\#test
    \\a_param_the_callee_changes :: fn(t: *Test) {
    \\    i: Inner = .{ .a = 1, .b = 2 };
    \\    t.eq(bump(i), 11u32);
    \\    t.eq(i.a, 1u32);
    \\}
    \\
;

test "fels test: on the comptime VM, a struct value returned or passed is a copy" {
    const dir = ".zig-cache/tc_value_copy_call";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try write(dir, "fels.pkg", "#package app \"0.1.0\";\n");
    try write(dir, "src/main.fels", value_copy_call_source);
    const vm = try runTests(.{ .project_dir = dir });
    defer std.testing.allocator.free(vm.text);
    try expectHas(vm.text, "  \u{2713} a_returned_field\n  \u{2713} a_returned_param\n  \u{2713} a_param_the_callee_changes\n");
    try std.testing.expectEqual(@as(u32, 3), vm.summary.passed);
    try std.testing.expect(vm.summary.ok());
    if (comptime !fels.llvm_enabled) return;
    if (comptime builtin.os.tag != .windows) return;
    const native = try runNative(.{ .project_dir = dir });
    defer std.testing.allocator.free(native.text);
    try std.testing.expectEqual(@as(u32, 3), native.summary.passed);
    try std.testing.expect(native.summary.ok());
}

// A local that only reads a value which does not change shares it rather than copying it. These
// are the cases where sharing would show: the shared value returned, passed to a callee that
// changes its param, or its source changed after it.
const value_share_source =
    \\Inner :: struct { a: u32, b: u32 }
    \\Outer :: struct { x: u32, inner: Inner }
    \\Shape :: enum { none, box: Inner }
    \\
    \\payload_of :: fn(s: Shape) -> Inner {
    \\    match s {
    \\        .box |v| => { return v; },
    \\        .none => { return .{ .a = 0, .b = 0 }; },
    \\    }
    \\}
    \\bump :: fn(i: Inner) -> u32 { i.a = i.a + 10u32; return i.a; }
    \\first :: fn(arr: [2]Inner) -> Inner { x := arr[0]; return x; }
    \\inner_of :: fn(o: Outer) -> Inner { y := o.inner; z := y; return z; }
    \\
    \\#test
    \\a_shared_value_returned :: fn(t: *Test) {
    \\    s: Shape = .box(.{ .a = 1, .b = 2 });
    \\    x := payload_of(s);
    \\    x.a = 9u32;
    \\    t.eq(payload_of(s).a, 1u32);
    \\    o: Outer = .{ .x = 1, .inner = .{ .a = 1, .b = 2 } };
    \\    r := inner_of(o);
    \\    r.b = 20u32;
    \\    t.eq(o.inner.b, 2u32);
    \\    arr: [2]Inner = .{ .{ .a = 1, .b = 2 }, .{ .a = 3, .b = 4 } };
    \\    f := first(arr);
    \\    f.a = 10u32;
    \\    t.eq(arr[0].a, 1u32);
    \\}
    \\
    \\#test
    \\a_shared_value_passed_on :: fn(t: *Test) {
    \\    i: Inner = .{ .a = 1, .b = 2 };
    \\    j := i;
    \\    t.eq(bump(j), 11u32);
    \\    t.eq(j.a, 1u32);
    \\}
    \\
    \\#test
    \\a_source_changed_after :: fn(t: *Test) {
    \\    o: Outer = .{ .x = 1, .inner = .{ .a = 1, .b = 2 } };
    \\    x := o.inner;
    \\    o.inner.a = 5u32;
    \\    t.eq(x.a, 1u32);
    \\    arr: [3]u32 = .{ 1, 2, 3 };
    \\    s := 0u32;
    \\    for v in arr {
    \\        arr[2] = 100u32;
    \\        s = s + v;
    \\    }
    \\    t.eq(s, 6u32);
    \\}
    \\
;

test "fels test: on the comptime VM, a local that only reads a value shares it where no copy would differ" {
    const dir = ".zig-cache/tc_value_share";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try write(dir, "fels.pkg", "#package app \"0.1.0\";\n");
    try write(dir, "src/main.fels", value_share_source);
    const vm = try runTests(.{ .project_dir = dir });
    defer std.testing.allocator.free(vm.text);
    try expectHas(vm.text, "  \u{2713} a_shared_value_returned\n  \u{2713} a_shared_value_passed_on\n  \u{2713} a_source_changed_after\n");
    try std.testing.expectEqual(@as(u32, 3), vm.summary.passed);
    try std.testing.expect(vm.summary.ok());
    if (comptime !fels.llvm_enabled) return;
    if (comptime builtin.os.tag != .windows) return;
    const native = try runNative(.{ .project_dir = dir });
    defer std.testing.allocator.free(native.text);
    try std.testing.expectEqual(@as(u32, 3), native.summary.passed);
    try std.testing.expect(native.summary.ok());
}

// A global that is a struct or an array is static data, built in the static zone the first
// time it is read. `fels test` put the `*Test` argument in a zone of its own before the call,
// and the VM opened its static zone only on an empty zone stack, so every read failed with
// NoActiveZone.
const global_aggregate_source =
    \\Inner :: struct { a: u32, b: u32 }
    \\Table :: struct { n: u32, vals: [3]u32, inner: Inner }
    \\
    \\G: Inner = .{ .a = 1, .b = 2 };
    \\PRIMES: [4]u32 = .{ 2, 3, 5, 7 };
    \\T: Table = .{ .n = 3, .vals = .{ 4, 5, 6 }, .inner = .{ .a = 7, .b = 8 } };
    \\
    \\second_of_g :: fn() -> u32 { return G.b; }
    \\
    \\#test
    \\a_struct_global :: fn(t: *Test) {
    \\    t.eq(G.a, 1u32);
    \\    t.eq(second_of_g(), 2u32);
    \\    g := G;
    \\    t.eq(g.b, 2u32);
    \\}
    \\
    \\#test
    \\an_array_global :: fn(t: *Test) {
    \\    t.eq(PRIMES[2], 5u32);
    \\    t.eq(PRIMES.len, 4usize);
    \\    s := PRIMES[1..];
    \\    t.eq(s[2], 7u32);
    \\}
    \\
    \\#test
    \\a_struct_global_with_an_array_and_a_struct :: fn(t: *Test) {
    \\    t.eq(T.vals[1], 5u32);
    \\    t.eq(T.inner.b, 8u32);
    \\    p := &T.inner;
    \\    t.eq(p.a, 7u32);
    \\}
    \\
;

test "fels test: on the comptime VM, a test reads a global that is a struct or an array" {
    const dir = ".zig-cache/tc_global_aggregate";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try write(dir, "fels.pkg", "#package app \"0.1.0\";\n");
    try write(dir, "src/main.fels", global_aggregate_source);
    const vm = try runTests(.{ .project_dir = dir });
    defer std.testing.allocator.free(vm.text);
    try expectHas(vm.text, "  \u{2713} a_struct_global\n  \u{2713} an_array_global\n");
    try expectHas(vm.text, "  \u{2713} a_struct_global_with_an_array_and_a_struct\n");
    try std.testing.expectEqual(@as(u32, 3), vm.summary.passed);
    try std.testing.expect(vm.summary.ok());
    if (comptime !fels.llvm_enabled) return;
    if (comptime builtin.os.tag != .windows) return;
    const native = try runNative(.{ .project_dir = dir });
    defer std.testing.allocator.free(native.text);
    try std.testing.expectEqual(@as(u32, 3), native.summary.passed);
    try std.testing.expect(native.summary.ok());
}
