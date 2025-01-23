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

// ── Jai-style #system_library / #foreign ─────────────────────────────────────

test "#system_library: standalone declaration is collected into IrModule.extern_libs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\#system_library("raylib");
        \\#system_library("kernel32"); // always linked; should be skipped/deduped
        \\
        \\#extern("raylib", "InitWindow")
        \\InitWindow :: fn(width: i32, height: i32, title: *const u8);
        \\
        \\use_it :: fn() {
        \\    InitWindow(800, 450, "hi".ptr);
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "syslib.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    // "raylib" should appear exactly once (deduped between #system_library and #extern),
    // and "kernel32" should be skipped entirely (always linked by the backend).
    var raylib_count: usize = 0;
    for (m.extern_libs) |lib| {
        try std.testing.expect(!std.mem.eql(u8, lib, "kernel32"));
        if (std.mem.eql(u8, lib, "raylib")) raylib_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), raylib_count);
}

test "#foreign: alias for #extern binds external functions and contributes to extern_libs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\#foreign("raylib", "WindowShouldClose")
        \\WindowShouldClose :: fn() -> bool;
        \\
        \\use_it :: fn() -> bool {
        \\    return WindowShouldClose();
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "foreign.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "WindowShouldClose")) break f;
    } else return error.FunctionNotFound;
    try std.testing.expectEqualStrings("WindowShouldClose", fn_.extern_name.?);

    var found_raylib = false;
    for (m.extern_libs) |lib| {
        if (std.mem.eql(u8, lib, "raylib")) found_raylib = true;
    }
    try std.testing.expect(found_raylib);
}

// ── Distinct types ────────────────────────────────────────────────────────────

test "distinct integer type: lowers to underlying integer type in IR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\UserId :: distinct i32;
        \\
        \\make_user :: fn(raw: i32) -> UserId {
        \\    return raw as UserId;
        \\}
        \\
        \\unwrap :: fn(id: UserId) -> i32 {
        \\    return id as i32;
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "distinct_int.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    // `make_user` return type and `unwrap` param must be i32, not a struct_type.
    const make_fn = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "make_user")) break f;
    } else return error.FunctionNotFound;
    try std.testing.expectEqual(k2.ir_mod.IrType{ .i = 32 }, make_fn.return_ty);

    const unwrap_fn = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "unwrap")) break f;
    } else return error.FunctionNotFound;
    try std.testing.expectEqual(k2.ir_mod.IrType{ .i = 32 }, unwrap_fn.params[0].ty);
}

test "distinct pointer type: *opaque-based handle lowers to ptr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\RawHandle :: distinct *opaque;
        \\
        \\#extern("kernel32", "GetStdHandle")
        \\GetStdHandle :: fn(id: i32) -> RawHandle;
        \\
        \\stdout :: fn() -> RawHandle {
        \\    return GetStdHandle(-11);
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "distinct_ptr.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "stdout")) break f;
    } else return error.FunctionNotFound;
    // RawHandle is distinct *opaque — underlying is a pointer, should lower to ptr.
    try std.testing.expect(fn_.return_ty == .ptr);
}

test "distinct type in struct field lowers to underlying type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\EntityId :: distinct u32;
        \\
        \\Entity :: struct {
        \\    id:    EntityId,
        \\    alive: bool,
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "distinct_field.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    const s = for (m.structs) |s| {
        if (std.mem.eql(u8, s.name, "Entity")) break s;
    } else return error.StructNotFound;
    // EntityId is distinct u32 — the field must lower to u32, not struct_type.
    try std.testing.expectEqual(k2.ir_mod.IrType{ .u = 32 }, s.fields[0].ty);
    try std.testing.expectEqual(k2.ir_mod.IrType.bool, s.fields[1].ty);
}

// ── Opaque types ──────────────────────────────────────────────────────────────

test "opaque type: *Opaque parameter lowers to ptr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Context :: opaque;
        \\
        \\process :: fn(ctx: *Context) -> i32 {
        \\    return 0;
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "opaque_ptr.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "process")) break f;
    } else return error.FunctionNotFound;
    // *Context should lower to ptr (opaque pointer in LLVM 15+).
    try std.testing.expect(fn_.params[0].ty == .ptr);
}

// ── Atomic types ──────────────────────────────────────────────────────────────

test "atomic field: struct with atomic u32 fields lowers to regular u32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Counter :: struct {
        \\    value: atomic u32,
        \\    padding: u32,
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "atomic_field.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    const s = for (m.structs) |s| {
        if (std.mem.eql(u8, s.name, "Counter")) break s;
    } else return error.StructNotFound;
    // `atomic u32` strips the qualifier in the IR; field type must be u32.
    try std.testing.expectEqual(k2.ir_mod.IrType{ .u = 32 }, s.fields[0].ty);
    try std.testing.expectEqual(k2.ir_mod.IrType{ .u = 32 }, s.fields[1].ty);
}

test "atomic_load and atomic_store: parse, type-check, and lower to IR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Flag :: struct { ready: atomic u32 }
        \\
        \\set_ready :: fn(f: *Flag) {
        \\    atomic_store(&f.ready, 1u32, .release);
        \\}
        \\
        \\spin :: fn(f: *Flag) -> u32 {
        \\    while atomic_load(&f.ready, .acquire) == 0u32 {}
        \\    return atomic_load(&f.ready, .acquire);
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "atomic_ops.k2", src);
    defer fe.deinit(arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), fe.diagnostics().len);
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}
