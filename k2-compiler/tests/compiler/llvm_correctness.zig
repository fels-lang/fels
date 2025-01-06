const std = @import("std");
const k2 = @import("k2_compiler");

test "LLVM lowering selects signed, unsigned, and floating-point operations" {
    if (comptime !k2.llvm_enabled) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\unsigned_ops :: fn(a: u32, b: u32) -> bool {
        \\    q := a / b;
        \\    r := a % b;
        \\    s := a >> b;
        \\    return 1u32 < q + r + s;
        \\}
        \\signed_ops :: fn(a: i32, b: i32) -> bool {
        \\    q := a / b;
        \\    r := a % b;
        \\    s := a >> b;
        \\    return q + r + s < b;
        \\}
        \\float_ops :: fn(a: f32, b: f32) -> bool {
        \\    value := ((a + b) - b) * b / b % b;
        \\    return value < b;
        \\}
    ;

    var fe = try k2.compile(arena.allocator(), "llvm_ops.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);

    var backend = k2.LlvmBackend.init(arena.allocator(), "llvm_ops");
    defer backend.deinit();
    try backend.lower(module);
    const llvm_ir = try backend.getIrText(arena.allocator());

    inline for (.{
        "udiv i32",
        "urem i32",
        "lshr i32",
        "icmp ult i32",
        "sdiv i32",
        "srem i32",
        "ashr i32",
        "icmp slt i32",
        "fadd float",
        "fsub float",
        "fmul float",
        "fdiv float",
        "frem float",
        "fcmp olt float",
    }) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, llvm_ir, expected) != null);
    }
}

test "LLVM force unwrap calls the embedded runtime panic" {
    if (comptime !k2.llvm_enabled) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\unwrap :: fn(value: ?i32) -> i32 {
        \\    return value!!;
        \\}
    ;

    var fe = try k2.compileWithRuntime(arena.allocator(), "force_unwrap.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);

    var backend = k2.LlvmBackend.init(arena.allocator(), "force_unwrap");
    defer backend.deinit();
    try backend.lower(module);
    const llvm_ir = try backend.getIrText(arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "@panic") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "attempted to unwrap an empty optional") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "force_unwrap.k2:2:12") != null);
}

test "LLVM panic lowering synthesizes the runtime declaration when absent" {
    if (comptime !k2.llvm_enabled) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\unwrap :: fn(value: ?i32) -> i32 {
        \\    return value!!;
        \\}
    ;

    var fe = try k2.compile(arena.allocator(), "standalone_unwrap.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);

    var backend = k2.LlvmBackend.init(arena.allocator(), "standalone_unwrap");
    defer backend.deinit();
    try backend.lower(module);
    const llvm_ir = try backend.getIrText(arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "declare void") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "@panic") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "standalone_unwrap.k2:2:12") != null);
}

test "LLVM lowering reads and writes fields through struct pointers" {
    if (comptime !k2.llvm_enabled) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Pair :: struct {
        \\    left: i32,
        \\    right: i32,
        \\}
        \\read_right :: fn(pair: *Pair) -> i32 {
        \\    return pair.right;
        \\}
        \\write_left :: fn(pair: *Pair, value: i32) {
        \\    pair.left = value;
        \\}
    ;

    var fe = try k2.compile(arena.allocator(), "pointer_fields.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);

    var backend = k2.LlvmBackend.init(arena.allocator(), "pointer_fields");
    defer backend.deinit();
    try backend.lower(module);
    const llvm_ir = try backend.getIrText(arena.allocator());

    try std.testing.expect(std.mem.count(u8, llvm_ir, "getelementptr") >= 2);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "load i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "store i32") != null);
}
