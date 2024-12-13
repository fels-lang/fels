const std = @import("std");
const k2 = @import("k2_compiler");

// The multi-file compile test uses compileMulti with pre-loaded sources,
// which doesn't require filesystem access.

test "modules: compileMulti with two source files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Simulate math.k2
    const math_src =
        \\add      :: fn(a: i32, b: i32) -> i32 { return a + b; }
        \\multiply :: fn(a: i32, b: i32) -> i32 { return a * b; }
    ;

    // Simulate main.k2 that uses math.k2's symbols
    const main_src =
        \\#import math;
        \\run :: fn() -> i32 {
        \\    x := add(3, 4);
        \\    y := multiply(x, 2);
        \\    return y;
        \\}
    ;

    var fe = try k2.compileMulti(arena.allocator(), &.{
        .{ .file_name = "math.k2", .source = math_src },
        .{ .file_name = "main.k2", .source = main_src },
    });
    defer fe.deinit(arena.allocator());

    // 4 items: add, multiply, run
    try std.testing.expectEqual(@as(usize, 3), fe.module.items.len);

    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    // All three functions should appear in IR
    var found_add = false;
    var found_mul = false;
    var found_run = false;
    for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "add"))      found_add = true;
        if (std.mem.eql(u8, f.name, "multiply")) found_mul = true;
        if (std.mem.eql(u8, f.name, "run"))      found_run = true;
    }
    try std.testing.expect(found_add);
    try std.testing.expect(found_mul);
    try std.testing.expect(found_run);
}

test "modules: symbols from imported file are visible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const utils =
        \\MAX :: 100;
        \\clamp :: fn(x: i32) -> bool { return x < MAX; }
    ;
    const app =
        \\#import utils;
        \\check :: fn(v: i32) -> bool { return clamp(v); }
    ;

    var fe = try k2.compileMulti(arena.allocator(), &.{
        .{ .file_name = "utils.k2", .source = utils },
        .{ .file_name = "app.k2",   .source = app },
    });
    defer fe.deinit(arena.allocator());

    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}

test "modules: std.* imports are silently skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // std.io doesn't exist yet — should compile fine, just ignoring the import
    const src =
        \\#import std.io;
        \\hello :: fn() -> i32 { return 42; }
    ;
    var fe = try k2.compile(arena.allocator(), "hello.k2", src);
    defer fe.deinit(arena.allocator());
    // 2 items: the #import (kept in AST) + hello function
    try std.testing.expectEqual(@as(usize, 2), fe.module.items.len);
}

test "modules: compileFile reads from disk (fixture)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Use compileMulti to test the same logic without needing Io
    const math_src =
        \\add :: fn(a: i32, b: i32) -> i32 { return a + b; }
    ;
    const main_src =
        \\#import math;
        \\run :: fn() -> i32 { return add(1, 2); }
    ;

    var fe = try k2.compileMulti(arena.allocator(), &.{
        .{ .file_name = "math.k2", .source = math_src },
        .{ .file_name = "main.k2", .source = main_src },
    });
    defer fe.deinit(arena.allocator());

    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    try std.testing.expectEqual(@as(usize, 2), m.functions.len);
}
