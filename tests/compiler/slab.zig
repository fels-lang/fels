const std = @import("std");
const fels = @import("fels_compiler");

// Slab, the flat IR the Obsidian backend reads (`src/slab.zig`), holds a whole program: a module
// that goes into a Slab and comes back out gives LLVM the same module, and the layouts Slab gives
// its types are LLVM's. The whole test suite runs this way with `FELS_SLAB_ROUNDTRIP=1`; these
// tests keep it checked on the fixture programs.

/// The LLVM IR of the program in `path`, compiled as `fels ir` does; with `round_trip`, from the
/// module that came back out of its Slab. Also counts Slab's layouts that differ from LLVM's.
fn irText(a: std.mem.Allocator, path: []const u8, round_trip: bool, mismatches: *usize) ![]u8 {
    const io = std.testing.io;
    var fe = try fels.pipeline_mod.compileFileWithRuntimeTarget(a, io, path, @import("builtin").os.tag, false);
    defer fe.deinit(a);
    var module = try fels.lowerFrontend(a, fe);
    try fels.ir_mod.runDefaultPasses(a, &module);
    var s: ?fels.slab_mod.Slab = null;
    defer if (s) |*x| x.deinit(std.testing.allocator);
    if (round_trip) {
        s = try fels.slab_mod.build(std.testing.allocator, module);
        module = try fels.slab_mod.toIr(a, &s.?);
    }
    var be = fels.LlvmBackend.init(a, "slab_test");
    defer be.deinit();
    try be.lower(module);
    if (s) |*x| mismatches.* += try be.slabLayoutMismatches(a, x);
    return be.getIrText(a);
}

test "slab: every fixture program comes back out of its Slab as it went in" {
    if (comptime !fels.llvm_enabled) return error.SkipZigTest;
    if (comptime @import("builtin").os.tag != .windows) return error.SkipZigTest; // the fixtures include Windows-only ones
    const io = std.testing.io;
    var checked: usize = 0;
    var mismatches: usize = 0;
    for ([_][]const u8{ "tests/fixtures/lang", "tests/fixtures/stdlib" }) |dir_path| {
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, "_app.fels")) continue;
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, entry.name });
            const before = irText(a, path, false, &mismatches) catch continue; // a fixture that needs a package or a sysroot
            const after = try irText(a, path, true, &mismatches);
            if (!std.mem.eql(u8, before, after)) {
                std.debug.print("\n{s}: the LLVM IR differs after the Slab round trip\n", .{path});
                return error.TestUnexpectedResult;
            }
            checked += 1;
        }
    }
    try std.testing.expect(checked >= 20);
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

test "slab: an operand keeps its kind and index" {
    const s = fels.slab_mod;
    for ([_]s.OperandKind{ .reg, .param, .local, .global, .constant }) |kind| {
        for ([_]u32{ 0, 1, 77, (1 << 29) - 1 }) |index| {
            const o = s.operand(kind, index);
            try std.testing.expectEqual(kind, s.kindOf(o));
            try std.testing.expectEqual(index, s.indexOf(o));
            try std.testing.expect(o != s.none);
        }
    }
}
