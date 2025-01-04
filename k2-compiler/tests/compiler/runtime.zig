const std = @import("std");
const k2  = @import("k2_compiler");

test "runtime: @panic and assert are available via compileWithRuntime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // User code that calls @panic and assert — both come from the embedded runtime.
    const src =
        \\main :: fn() -> i32 {
        \\    assert(1 + 1 == 2);
        \\    assert_msg(true, "always ok");
        \\    return 0;
        \\}
    ;
    // compile() alone would fail ("unknown function `assert`")
    var fe = try k2.compileWithRuntime(arena.allocator(), "main.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    // assert, assert_msg, @panic, write_stdout, write_stderr should all be present
    const fn_names = [_][]const u8{ "assert", "assert_msg", "@panic", "write_stdout", "write_stderr" };
    for (fn_names) |name| {
        const found = for (m.functions) |f| {
            if (std.mem.eql(u8, f.name, name)) break true;
        } else false;
        if (!found) {
            std.debug.print("missing runtime function: {s}\n", .{name});
            return error.MissingRuntimeFunction;
        }
    }
}

test "runtime: compile() without runtime — assert not available" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\use :: fn() { assert(true); }
    ;
    // compile() has no runtime → assert is unknown → SemanticFailed
    try std.testing.expectError(error.SemanticFailed,
        k2.compile(arena.allocator(), "bare.k2", src));
}

test "runtime: write_stdout is available for programs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\main :: fn() -> i32 {
        \\    write_stdout("Hello, K2!\n");
        \\    return 0;
        \\}
    ;
    var fe = try k2.compileWithRuntime(arena.allocator(), "hello.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}

test "runtime: @panic is #noreturn — CFG allows body without return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // validate :: fn with early @panic — should pass CFG (all paths return or panic)
    const src =
        \\validate :: fn(x: i32) -> i32 {
        \\    if x < 0 {
        \\        @panic("negative input");
        \\        // no return needed — @panic is #noreturn
        \\    }
        \\    return x;
        \\}
    ;
    var fe = try k2.compileWithRuntime(arena.allocator(), "validate.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}
