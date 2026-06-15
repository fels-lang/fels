/// Obsidian, the debug backend written in Fels (obsidian/): its own `#test` files, run natively by
/// `fels test`. The encoder's tests (obsidian/x64_tests.fels) check every instruction it writes
/// against llvm-mc's encoding of it.
const std = @import("std");
const builtin = @import("builtin");
const fels = @import("fels_compiler");

const io = std.testing.io;

const files = [_][]const u8{
    "obsidian/x64_tests.fels",
};

test "obsidian: the encoder writes what llvm-mc writes" {
    if (comptime !fels.llvm_enabled) return error.SkipZigTest;
    // (the comptime VM cannot run them: a pointer to a struct field that is a struct, as a Vec
    // in Code is, reads out of bounds there)
    const project = ".zig-cache/obsidian_tests";
    std.Io.Dir.cwd().createDirPath(io, project) catch {};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const summary = try fels.test_cmd.run(std.testing.allocator, io, &out.writer, .{
        .project_dir = project,
        .paths = &files,
        .llvm_bin = fels.llvm_path ++ "/bin",
        .lib_paths = if (fels.windows_sdk_lib_path.len != 0) &.{fels.windows_sdk_lib_path} else &.{},
    });
    if (!summary.ok() or summary.skipped != 0 or summary.passed == 0) {
        std.debug.print("{s}\n", .{out.written()});
        return error.TestUnexpectedResult;
    }
}
