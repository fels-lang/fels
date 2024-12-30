const std = @import("std");
const k2  = @import("k2_compiler");

// ── Sub-byte integers ─────────────────────────────────────────────────────────

test "u1-u7 as struct fields in packed struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\#packed
        \\ControlReg :: struct {
        \\    enable:   u1,
        \\    mode:     u3,
        \\    reserved: u3,
        \\    flag:     u1,
        \\}
        \\
        \\make_reg :: fn(en: u1, m: u3) -> ControlReg {
        \\    r: ControlReg = .{ en, m, 0u3, 0u1 };
        \\    return r;
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "subbyte.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    // The struct should have 4 fields
    const s = for (m.structs) |s| {
        if (std.mem.eql(u8, s.name, "ControlReg")) break s;
    } else return error.StructNotFound;
    try std.testing.expectEqual(@as(usize, 4), s.fields.len);

    // u1 field should have bit-width 1 in IR
    try std.testing.expectEqual(k2.ir_mod.IrType{ .u = 1 }, s.fields[0].ty);
    try std.testing.expectEqual(k2.ir_mod.IrType{ .u = 3 }, s.fields[1].ty);
}

test "u4 field: 4-bit integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Nibble :: struct { lo: u4, hi: u4 }
        \\pack :: fn(lo: u4, hi: u4) -> Nibble {
        \\    return .{ lo, hi };
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "nibble.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}

test "i1-i7 signed sub-byte integers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\#packed
        \\SignedFlags :: struct {
        \\    delta: i3,   // signed 3-bit: -4..3
        \\    valid: i1,   // signed 1-bit: -1..0
        \\    pad:   u4,
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "signed_bits.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    const s = for (m.structs) |s| {
        if (std.mem.eql(u8, s.name, "SignedFlags")) break s;
    } else return error.StructNotFound;
    try std.testing.expectEqual(k2.ir_mod.IrType{ .i = 3 }, s.fields[0].ty);
    try std.testing.expectEqual(k2.ir_mod.IrType{ .i = 1 }, s.fields[1].ty);
}

// ── New attributes ────────────────────────────────────────────────────────────

test "#noreturn: function with noreturn attribute" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // #noreturn function doesn't need to have all paths return
    const src =
        \\#extern("kernel32", "ExitProcess")
        \\ExitProcess :: fn(code: u32);
        \\
        \\#noreturn
        \\panic :: fn(msg: []const u8) {
        \\    ExitProcess(1u32);
        \\    // no return statement — allowed because #noreturn
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "noreturn.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    // The function should have the no_return flag set
    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "panic")) break f;
    } else return error.FunctionNotFound;
    try std.testing.expect(fn_.no_return);
}

test "#noinline: function with noinline attribute" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\#noinline
        \\cold_path :: fn(x: i32) -> i32 {
        \\    return x * 2;
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "noinline.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "cold_path")) break f;
    } else return error.FunctionNotFound;
    try std.testing.expect(fn_.no_inline);
}

test "#export: function marked for export" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\#export("k2_add")
        \\add :: fn(a: i32, b: i32) -> i32 { return a + b; }
        \\
        \\#export
        \\multiply :: fn(a: i32, b: i32) -> i32 { return a * b; }
    ;
    var fe = try k2.compile(arena.allocator(), "export.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    const add_fn = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "add")) break f;
    } else return error.FunctionNotFound;
    try std.testing.expectEqualStrings("k2_add", add_fn.export_sym.?);

    const mul_fn = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "multiply")) break f;
    } else return error.FunctionNotFound;
    try std.testing.expect(mul_fn.export_sym != null);
}

test "#deprecated: calling deprecated function emits warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\#deprecated("use write_stdout instead")
        \\old_print :: fn(msg: []const u8) {}
        \\
        \\use :: fn() {
        \\    old_print("hello");   // should trigger warning
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "deprecated.k2", src);
    defer fe.deinit(arena.allocator());

    // Compile succeeds, but diagnostics contain a warning
    try std.testing.expectEqual(@as(usize, 1), fe.diagnostics().len);
    try std.testing.expectEqual(k2.DiagKind.warning, fe.diagnostics()[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, fe.diagnostics()[0].message, "deprecated") != null);
}
