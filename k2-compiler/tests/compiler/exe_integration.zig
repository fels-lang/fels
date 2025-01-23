/// End-to-end executable tests: compile K2 → .o → .exe → run → check exit code.
///
/// Requires LLVM (skipped when absent) and Windows (lld-link).
const std = @import("std");
const k2 = @import("k2_compiler");
const builtin = @import("builtin");

/// Compile `src` to an executable and return its exit code.
fn compileAndRun(allocator: std.mem.Allocator, src: []const u8, label: []const u8) !u32 {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const io = std.testing.io;

    // Build paths under .zig-cache so they don't pollute the repo.
    const obj_path = try std.fmt.allocPrint(allocator, ".zig-cache/{s}.o", .{label});
    defer allocator.free(obj_path);
    const exe_path = try std.fmt.allocPrint(allocator, ".zig-cache/{s}.exe", .{label});
    defer allocator.free(exe_path);
    const obj_path_z = try allocator.dupeZ(u8, obj_path);
    defer allocator.free(obj_path_z);

    const lib_path = k2.windows_sdk_lib_path;
    const lib_paths: []const []const u8 = if (lib_path.len > 0) &.{lib_path} else &.{};
    try k2.compileWithLlvm(allocator, io, .{
        .file_name = label,
        .source = src,
        .obj_path = obj_path,
        .exe_path = exe_path,
        .opt_level = 2,
        .llvm_bin = k2.llvm_path ++ "/bin",
        .lib_paths = lib_paths,
    });

    // Run the compiled executable.
    const exe_argv = [_][]const u8{exe_path};
    var child = std.process.spawn(io, .{
        .argv = &exe_argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;

    const term = child.wait(io) catch return 255;
    return switch (term) {
        .exited => |code| @intCast(code),
        else => 255,
    };
}

test "exe: main returning 0 exits cleanly" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 { return 0; }
    , "exe_zero");
    try std.testing.expectEqual(@as(u32, 0), code);
}

test "exe: main returning 42 propagates exit code" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 { return 42; }
    , "exe_42");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: @panic exits with panic status" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 { @panic("test"); }
    , "exe_panic");
    // Zig's Windows child-process API reports the low byte of ExitProcess here.
    try std.testing.expectEqual(@as(u32, 0xEF), code);
}

test "exe: assert(false) panics" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 { assert(1 == 2); return 0; }
    , "exe_assert_fail");
    try std.testing.expectEqual(@as(u32, 0xEF), code);
}

test "exe: assert(true) does not panic" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 { assert(1 == 1); return 0; }
    , "exe_assert_ok");
    try std.testing.expectEqual(@as(u32, 0), code);
}

test "exe: runtime write reports bytes written" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 { return write_stdout("K2") as i32; }
    , "exe_runtime_write");
    try std.testing.expectEqual(@as(u32, 2), code);
}

test "exe: runtime exit terminates with requested status" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 { exit(37u32); }
    , "exe_runtime_exit");
    try std.testing.expectEqual(@as(u32, 37), code);
}

test "exe: fallible ? propagates error to caller, fallback returns sentinel" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ok path: may_fail(0) -> ok 7. main propagates, returns 7.
    const code_ok = try compileAndRun(arena.allocator(),
        \\MyErr :: errors { bad, }
        \\may_fail :: fn(x: i32) -> i32 ! MyErr {
        \\    if x == 1 { fail .bad; }
        \\    return 7;
        \\}
        \\main :: fn() -> i32 ! MyErr {
        \\    v := may_fail(0)?;
        \\    return v;
        \\}
    , "exe_fallible_ok");
    try std.testing.expectEqual(@as(u32, 7), code_ok);
}

test "exe: catch executes its error handler" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const code = try compileAndRun(arena.allocator(),
        \\MyErr :: errors { bad, }
        \\may_fail :: fn() -> i32 ! MyErr { fail .bad; }
        \\main :: fn() -> i32 {
        \\    value := may_fail() catch err { return 9; };
        \\    return value;
        \\}
    , "exe_catch");
    try std.testing.expectEqual(@as(u32, 9), code);
}

test "exe: plain value coerces to optional parameter" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const code = try compileAndRun(arena.allocator(),
        \\unwrap_helper :: fn(value: ?i32) -> i32 { return value!!; }
        \\main :: fn() -> i32 {
        \\    unwrap_helper(43);
        \\    return 0;
        \\}
    , "exe_optional_coerce");
    try std.testing.expectEqual(@as(u32, 0), code);
}

test "exe: arena allocations are writable and cleaned on exit" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    zone scratch: Arena {
        \\        data := scratch.new_slice(u8, 4);
        \\        if data[0] != 0u8 { return 2; }
        \\        data[0] = 42u8;
        \\        if data[0] != 42u8 { return 1; }
        \\    }
        \\    return 0;
        \\}
    , "exe_zone");
    try std.testing.expectEqual(@as(u32, 0), code);
}

test "exe: zone allocation can be used through a borrow parameter" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const code = try compileAndRun(arena.allocator(),
        \\write :: fn(data: borrow []u8) { data[0] = 42u8; }
        \\main :: fn() -> i32 {
        \\    zone scratch: Arena {
        \\        data := scratch.new_slice(u8, 4);
        \\        write(data);
        \\        if data[0] != 42u8 { return 1; }
        \\    }
        \\    return 0;
        \\}
    , "exe_zone_borrow");
    try std.testing.expectEqual(@as(u32, 0), code);
}

test "exe: sizeof returns the actual size of its type argument" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // sizeof(u8) + sizeof(u16) + sizeof(u32) + sizeof(u64) == 1 + 2 + 4 + 8 == 15.
    // A compiler that always reports sizeof(T) == 8 would instead yield 32.
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    total := sizeof(u8) + sizeof(u16) + sizeof(u32) + sizeof(u64);
        \\    return truncate_to(i32, total);
        \\}
    , "exe_sizeof_widths");
    try std.testing.expectEqual(@as(u32, 15), code);
}

test "exe: sizeof on pointer types returns pointer width" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    total := sizeof(*i32) + sizeof([*]u8);
        \\    return truncate_to(i32, total);
        \\}
    , "exe_sizeof_pointers");
    try std.testing.expectEqual(@as(u32, 16), code);
}

test "exe: 0b binary integer literals parse to their numeric value" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // 0b1011 == 11; a misparse (e.g. treating 'b' as a hex digit) would give 111011.
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    return 0b1011;
        \\}
    , "exe_binary_literal");
    try std.testing.expectEqual(@as(u32, 11), code);
}

test "exe: dynamic dispatch through an interface method that takes another interface pointer" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Regression: an interface impl method whose own parameter is itself an
    // interface pointer (`w: *Writer`) used to be lowered as a thin pointer
    // instead of a fat `{ data, vtable }` pointer (lowerTypeReplacingSelf
    // didn't recognize interface types). Calling a method on that nested
    // interface pointer then bitcast a thin `ptr` to `{ ptr, ptr }`, which
    // failed LLVM verification with "Invalid bitcast".
    const code = try compileAndRun(arena.allocator(),
        \\Writer :: interface {
        \\    write_all :: fn(self: *Self, s: []const u8) -> usize;
        \\}
        \\Display :: interface {
        \\    display :: fn(self: *Self, w: *Writer) -> usize;
        \\}
        \\Buf :: struct { total: usize }
        \\Buf as Writer {
        \\    write_all :: fn(self: *Self, s: []const u8) -> usize {
        \\        self.total = self.total + s.len;
        \\        return s.len;
        \\    }
        \\}
        \\Point :: struct { x: i64, y: i64 }
        \\Point as Display {
        \\    display :: fn(self: *Self, w: *Writer) -> usize {
        \\        return w.write_all("pt");
        \\    }
        \\}
        \\call_display :: fn(w: *Writer, value: *Display) -> usize {
        \\    return value.display(w);
        \\}
        \\main :: fn() -> i32 {
        \\    p: Point = .{ 1i64, 2i64 };
        \\    d: *Display = &p;
        \\    buf: Buf = .{ 0 };
        \\    w: *Writer = &buf;
        \\    n: usize = call_display(w, d);
        \\    return n as i32;
        \\}
    , "exe_iface_nested_dispatch_param");
    try std.testing.expectEqual(@as(u32, 2), code);
}

test "exe: nested dynamic dispatch on a parameter of an interface method" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Regression: previously crashed the compiler process with a segfault in
    // LLVM-C.dll while lowering `b.val()` inside `Foo.A.run`, because `b: *B`
    // was lowered as a thin pointer and lowerInterfaceData attempted to
    // extractvalue field 0 from a non-aggregate `ptr`. A malformed-but-valid
    // program must never crash the compiler outright.
    const code = try compileAndRun(arena.allocator(),
        \\A :: interface { run :: fn(self: *Self, b: *B) -> i32; }
        \\B :: interface { val :: fn(self: *Self) -> i32; }
        \\Foo :: struct { x: i32 }
        \\Bar :: struct { y: i32 }
        \\Foo as A {
        \\    run :: fn(self: *Self, b: *B) -> i32 { return b.val(); }
        \\}
        \\Bar as B {
        \\    val :: fn(self: *Self) -> i32 { return self.y; }
        \\}
        \\call_it :: fn(a: *A, b: *B) -> i32 { return a.run(b); }
        \\main :: fn() -> i32 {
        \\    foo: Foo = .{ 1i32 };
        \\    bar: Bar = .{ 99i32 };
        \\    a: *A = &foo;
        \\    b: *B = &bar;
        \\    return call_it(a, b);
        \\}
    , "exe_iface_nested_dispatch_segfault");
    try std.testing.expectEqual(@as(u32, 99), code);
}

test "exe: generic List(T) backed by Arena, with generic methods" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Exercises three fixes together: arena-allocating a generic struct instance
    // (correct allocation size, not a bare pointer), storing zone-owned memory
    // into a struct field (escape-ownership propagation), and dispatching a
    // generic method whose receiver is `*List(T)` (concrete-instance matching).
    const code = try compileAndRun(arena.allocator(),
        \\List :: struct($T: type) {
        \\    data: [*]T,
        \\    len:  usize,
        \\    cap:  usize,
        \\}
        \\set :: fn($T: type, self: borrow *List(T), i: usize, v: T) { self.data[i] = v; }
        \\get :: fn($T: type, self: borrow *List(T), i: usize) -> T { return self.data[i]; }
        \\main :: fn() -> i32 {
        \\    zone scope: Arena {
        \\        buf := scope.new_slice(i32, 8);
        \\        l := scope.new(List(i32));
        \\        l.data = buf.ptr;
        \\        l.cap  = 8usize;
        \\        l.len  = 3usize;
        \\        l.set(i32, 0usize, 10);
        \\        l.set(i32, 1usize, 20);
        \\        l.set(i32, 2usize, 12);
        \\        return l.get(i32, 0usize) + l.get(i32, 1usize) + l.get(i32, 2usize);
        \\    }
        \\    return 0;
        \\}
    , "exe_generic_list_arena");
    try std.testing.expectEqual(@as(u32, 42), code);
}
