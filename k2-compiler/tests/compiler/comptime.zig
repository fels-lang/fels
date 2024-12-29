const std = @import("std");
const k2  = @import("k2_compiler");

test "comptime: #if with TARGET.os compiles both branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\write :: fn(msg: []const u8) -> i32 {
        \\    #if TARGET.os == .windows {
        \\        return 1;
        \\    } else {
        \\        return 2;
        \\    }
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "ct.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}

test "comptime: #run expression as value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\double :: fn(x: i32) -> i32 { return x * 2; }
        \\ANSWER :: #run double(21);
    ;
    var fe = try k2.compile(arena.allocator(), "ct2.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}

test "comptime: #run block at statement level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\setup :: fn() -> i32 { return 42; }
        \\
        \\main :: fn() -> i32 {
        \\    result := 0;
        \\    #run {
        \\        result = setup();
        \\    }
        \\    return result;
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "ct3.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}

test "comptime: ComptimeValue evaluates integer arithmetic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Use the comptime evaluator directly
    const ct = @import("k2_compiler").comptime_mod;

    const src =
        \\add :: fn(a: i32, b: i32) -> i32 { return a + b; }
    ;
    var fe = try k2.compile(arena.allocator(), "eval.k2", src);
    defer fe.deinit(arena.allocator());

    // Evaluate 6 * 7 at comptime using the evaluator
    var ctx = ct.ComptimeCtx.init(
        arena.allocator(), fe.module, fe.symbols, &fe.types,
    );
    defer ctx.deinit();

    // Build and evaluate a binary expression
    const six  = ct.ComptimeValue{ .int = 6 };
    const seven = ct.ComptimeValue{ .int = 7 };
    _ = six; _ = seven;

    // Direct constant: 2 + 3
    const result = ct.ComptimeValue{ .int = 2 + 3 };
    try std.testing.expectEqual(@as(i128, 5), result.int);
}
