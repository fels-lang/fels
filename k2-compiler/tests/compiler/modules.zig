const std = @import("std");
const k2 = @import("k2_compiler");

// Multi-file tests use compileMulti with pre-loaded sources, so they exercise
// module resolution without filesystem access.

test "modules: compileMulti with two source files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const math_src =
        \\pub add      :: fn(a: i32, b: i32) -> i32 { return a + b; }
        \\pub multiply :: fn(a: i32, b: i32) -> i32 { return a * b; }
    ;
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

    try std.testing.expectEqual(@as(usize, 4), fe.module.items.len);

    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
    try std.testing.expectEqual(@as(usize, 3), m.functions.len);
}

test "modules: public symbols from imported file are visible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const utils =
        \\MAX :: 100;
        \\pub clamp :: fn(x: i32) -> bool { return x < MAX; }
    ;
    const app =
        \\#import utils;
        \\check :: fn(v: i32) -> bool { return clamp(v); }
    ;

    var fe = try k2.compileMulti(arena.allocator(), &.{
        .{ .file_name = "utils.k2", .source = utils },
        .{ .file_name = "app.k2", .source = app },
    });
    defer fe.deinit(arena.allocator());

    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}

test "modules: compile parses imports without resolving them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\#import std.io;
        \\hello :: fn() -> i32 { return 42; }
    ;
    var fe = try k2.compile(arena.allocator(), "hello.k2", src);
    defer fe.deinit(arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), fe.module.items.len);
}

test "modules: selective import exposes only selected public names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const math_src =
        \\pub add :: fn(a: i32, b: i32) -> i32 { return a + b; }
        \\pub multiply :: fn(a: i32, b: i32) -> i32 { return a * b; }
    ;
    const app_src =
        \\#import math.{add};
        \\run :: fn() -> i32 { return add(1, 2); }
    ;

    var fe = try k2.compileMulti(arena.allocator(), &.{
        .{ .file_name = "math.k2", .source = math_src },
        .{ .file_name = "app.k2", .source = app_src },
    });
    defer fe.deinit(arena.allocator());
}

test "modules: unselected and private names are not visible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const dependency =
        \\private_value :: fn() -> i32 { return 1; }
        \\pub public_value :: fn() -> i32 { return private_value(); }
        \\pub other_value :: fn() -> i32 { return 2; }
    ;
    const private_use =
        \\#import dependency;
        \\run :: fn() -> i32 { return private_value(); }
    ;
    const unselected_use =
        \\#import dependency.{public_value};
        \\run :: fn() -> i32 { return other_value(); }
    ;

    try std.testing.expectError(error.SemanticFailed, k2.compileMulti(arena.allocator(), &.{
        .{ .file_name = "dependency.k2", .source = dependency },
        .{ .file_name = "private_use.k2", .source = private_use },
    }));
    try std.testing.expectError(error.SemanticFailed, k2.compileMulti(arena.allocator(), &.{
        .{ .file_name = "dependency.k2", .source = dependency },
        .{ .file_name = "unselected_use.k2", .source = unselected_use },
    }));
}

test "modules: selective imports reject missing and private declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const dependency =
        \\hidden :: fn() -> i32 { return 1; }
        \\pub #inline shown :: fn() -> i32 { return hidden(); }
    ;

    try std.testing.expectError(error.SemanticFailed, k2.compileMulti(arena.allocator(), &.{
        .{ .file_name = "dependency.k2", .source = dependency },
        .{ .file_name = "private.k2", .source = "#import dependency.{hidden};" },
    }));
    try std.testing.expectError(error.SemanticFailed, k2.compileMulti(arena.allocator(), &.{
        .{ .file_name = "dependency.k2", .source = dependency },
        .{ .file_name = "missing.k2", .source = "#import dependency.{missing};" },
    }));
}

test "modules: missing modules are errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.IoError, k2.compileMulti(arena.allocator(), &.{
        .{ .file_name = "app.k2", .source = "#import missing;" },
    }));
}

test "modules: std root resolves independently of importing directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try k2.compileMulti(arena.allocator(), &.{
        .{ .file_name = "std/io.k2", .source = "pub write_stdout :: fn() {}" },
        .{ .file_name = "app/main.k2", .source = "#import std.io.{write_stdout}; run :: fn() { write_stdout(); }" },
    });
    defer fe.deinit(arena.allocator());
}

test "modules: public constants and types respect visibility" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const dependency =
        \\pub LIMIT :: 4;
        \\pub Value :: struct { item: i32, }
        \\Hidden :: struct { item: i32, }
    ;
    const app =
        \\#import dependency.{LIMIT, Value};
        \\limit :: fn() -> i32 { return LIMIT; }
        \\read :: fn(value: *Value) -> i32 { return value.item; }
    ;

    var fe = try k2.compileMulti(arena.allocator(), &.{
        .{ .file_name = "dependency.k2", .source = dependency },
        .{ .file_name = "app.k2", .source = app },
    });
    defer fe.deinit(arena.allocator());
}

test "modules: compileFile resolves local imports from disk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try k2.compileFile(
        arena.allocator(),
        std.testing.io,
        "tests/fixtures/modules/main.k2",
    );
    defer fe.deinit(arena.allocator());

    const module = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(module);
}

test "modules: compileMulti normalizes logical module paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try k2.compileMulti(arena.allocator(), &.{
        .{ .file_name = ".\\app\\dependency.k2", .source = "pub answer :: fn() -> i32 { return 42; }" },
        .{ .file_name = "./app/main.k2", .source = "#import dependency.{answer}; run :: fn() -> i32 { return answer(); }" },
    });
    defer fe.deinit(arena.allocator());
}

test "modules: configured std root loads std.mem" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try k2.compileFile(
        arena.allocator(),
        std.testing.io,
        "tests/fixtures/stdlib/mem_app.k2",
    );
    defer fe.deinit(arena.allocator());

    const module = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(module);
}

test "modules: configured std root loads std.io" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try k2.compileFileWithRuntime(
        arena.allocator(),
        std.testing.io,
        "tests/fixtures/stdlib/io_app.k2",
    );
    defer fe.deinit(arena.allocator());

    const module = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(module);
}

test "modules: imported self functions are extension methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const helpers =
        \\pub doubled :: fn(self: i32) -> i32 { return self * 2; }
        \\pub add :: fn(self: i32, value: i32) -> i32 { return self + value; }
    ;
    const app =
        \\#import helpers.{doubled, add};
        \\run :: fn() -> i32 { return 20.doubled().add(2); }
    ;

    var fe = try k2.compileMulti(arena.allocator(), &.{
        .{ .file_name = "helpers.k2", .source = helpers },
        .{ .file_name = "app.k2", .source = app },
    });
    defer fe.deinit(arena.allocator());

    const module = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(module);
}

test "modules: unimported self functions are not extension methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.SemanticFailed, k2.compileMulti(arena.allocator(), &.{
        .{ .file_name = "helpers.k2", .source = "pub doubled :: fn(self: i32) -> i32 { return self * 2; }" },
        .{ .file_name = "app.k2", .source = "run :: fn() -> i32 { return 20.doubled(); }" },
    }));
}

test "modules: generic extension methods retain explicit type arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const helpers =
        \\pub first_or :: fn($T: type, self: []const T, fallback: T) -> T {
        \\    if self.len == 0usize { return fallback; }
        \\    return self[0];
        \\}
    ;
    const app =
        \\#import helpers.{first_or};
        \\run :: fn() -> i32 {
        \\    values: [1]i32 = .{ 42 };
        \\    return values[:].first_or(i32, 0);
        \\}
    ;

    var fe = try k2.compileMulti(arena.allocator(), &.{
        .{ .file_name = "helpers.k2", .source = helpers },
        .{ .file_name = "app.k2", .source = app },
    });
    defer fe.deinit(arena.allocator());

    const module = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(module);
}
