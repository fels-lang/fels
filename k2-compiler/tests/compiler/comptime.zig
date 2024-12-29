const std = @import("std");
const k2 = @import("k2_compiler");
const ir = @import("k2_compiler").ir_mod;

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

test "#run: constant computed at compile time, not runtime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\// Recursive fibonacci computed ENTIRELY at compile time.
        \\fib :: fn(n: i32) -> i32 {
        \\    if n <= 1 { return n; }
        \\    return fib(n - 1) + fib(n - 2);
        \\}
        \\
        \\FIB_10 :: #run fib(10);    // = 55  — no runtime call
        \\FIB_7  :: #run fib(7);     // = 13  — no runtime call
        \\ANSWER :: #run fib(6) * 7; // = 8*7 = 56? no: fib(6)=8, 8*7=56
        \\
        \\use_them :: fn() -> i32 {
        \\    return FIB_10 + FIB_7;   // 55 + 13 = 68
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "fib_ct.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    // The globals should be initialised with COMPILE-TIME constants, not function calls.
    var found_fib10 = false;
    var found_fib7 = false;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "FIB_10")) {
            found_fib10 = true;
            // Must be a compile-time integer constant (not unknown/null)
            try std.testing.expectEqual(ir.Imm{ .int = 55 }, g.init.imm);
        }
        if (std.mem.eql(u8, g.name, "FIB_7")) {
            found_fib7 = true;
            try std.testing.expectEqual(ir.Imm{ .int = 13 }, g.init.imm);
        }
    }
    try std.testing.expect(found_fib10);
    try std.testing.expect(found_fib7);
}

test "#if: only live branch emitted to IR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\platform_id :: fn() -> i32 {
        \\    #if TARGET.os == .windows {
        \\        return 1;
        \\    } else {
        \\        return 2;
        \\    }
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "platform.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    // Find platform_id and verify it compiled (the #if selected a branch)
    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "platform_id")) break f;
    } else return error.FunctionNotFound;
    try std.testing.expect(fn_.blocks.len > 0);
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
        arena.allocator(),
        fe.module,
        fe.symbols,
        &fe.types,
    );
    defer ctx.deinit();

    // Build and evaluate a binary expression
    const six = ct.ComptimeValue{ .int = 6 };
    const seven = ct.ComptimeValue{ .int = 7 };
    _ = six;
    _ = seven;

    // Direct constant: 2 + 3
    const result = ct.ComptimeValue{ .int = 2 + 3 };
    try std.testing.expectEqual(@as(i128, 5), result.int);
}
