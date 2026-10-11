/// The standard library's `#test` files (tests/fixtures/stdlib/*_tests.fels), run by `fels test`:
/// natively, and on the comptime VM, so both give the same answers.
const std = @import("std");
const builtin = @import("builtin");
const fels = @import("fels_compiler");

const io = std.testing.io;

const files = [_][]const u8{
    "tests/fixtures/stdlib/csv_tests.fels",
    "tests/fixtures/stdlib/date_tests.fels",
    "tests/fixtures/stdlib/heap_tests.fels",
};

fn runAll(comptime_only: bool) !void {
    // The test programs go to .fels-cache/test in the project folder: one under .zig-cache.
    const project = ".zig-cache/std_tests";
    std.Io.Dir.cwd().createDirPath(io, project) catch {};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const summary = try fels.test_cmd.run(std.testing.allocator, io, &out.writer, .{
        .project_dir = project,
        .paths = &files,
        .comptime_only = comptime_only,
        .llvm_bin = fels.llvm_path ++ "/bin",
        .lib_paths = if (fels.windows_sdk_lib_path.len != 0) &.{fels.windows_sdk_lib_path} else &.{},
    });
    if (!summary.ok() or summary.skipped != 0 or summary.passed == 0) {
        std.debug.print("{s}\n", .{out.written()});
        return error.TestUnexpectedResult;
    }
}

test "std: the #test files of the standard library pass on the comptime VM" {
    try runAll(true);
}

test "std: the #test files of the standard library pass natively" {
    if (comptime !fels.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    try runAll(false);
}
