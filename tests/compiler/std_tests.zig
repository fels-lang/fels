/// The standard library's `#test` files (tests/fixtures/stdlib/*_tests.fels), run by `fels test`:
/// natively, and on the comptime VM, so both give the same answers.
const std = @import("std");
const builtin = @import("builtin");
const fels = @import("fels_compiler");

const io = std.testing.io;

const files = [_][]const u8{
    "tests/fixtures/stdlib/csv_tests.fels",
    "tests/fixtures/stdlib/date_tests.fels",
    "tests/fixtures/stdlib/float_tests.fels",
    "tests/fixtures/stdlib/heap_tests.fels",
    "tests/fixtures/stdlib/process_tests.fels",
    "tests/fixtures/stdlib/sort_tests.fels",
    "tests/fixtures/stdlib/parse_tests.fels",
    "tests/fixtures/stdlib/text_tests.fels",
    "tests/fixtures/stdlib/utf8_tests.fels",
    "tests/fixtures/stdlib/bufio_tests.fels",
    "tests/fixtures/stdlib/hash_tests.fels",
    "tests/fixtures/stdlib/crypto_tests.fels",
    "tests/fixtures/stdlib/fmt_tests.fels",
    "tests/fixtures/stdlib/encoding_tests.fels",
    "tests/fixtures/stdlib/containers_tests.fels",
    "tests/fixtures/stdlib/numbers_tests.fels",
    "tests/fixtures/stdlib/json_write_tests.fels",
    "tests/fixtures/stdlib/url_tests.fels",
    "tests/fixtures/stdlib/log_tests.fels",
};

/// Files whose tests reach the OS (folders, the environment, the command line), which
/// compile-time code may not: they run natively only.
const native_files = [_][]const u8{
    // JSON values are enums with payloads in an arena, which the comptime VM cannot store yet
    "tests/fixtures/stdlib/json_tests.fels",
    // AutoHashMap hashes a key's bytes through a pointer, which the comptime VM cannot
    "tests/fixtures/stdlib/map_tests.fels",
    "tests/fixtures/stdlib/os_tests.fels",
    // compile-time code may not change std.log's global level
    "tests/fixtures/stdlib/log_global_tests.fels",
};

fn runAll(comptime_only: bool) !void {
    // The test programs go to .fels-cache/test in the project folder: one under .zig-cache.
    const project = ".zig-cache/std_tests";
    std.Io.Dir.cwd().createDirPath(io, project) catch {};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const summary = try fels.test_cmd.run(std.testing.allocator, io, &out.writer, .{
        .project_dir = project,
        .paths = if (comptime_only) &files else &(files ++ native_files),
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
