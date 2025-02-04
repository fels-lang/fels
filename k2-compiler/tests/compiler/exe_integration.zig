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

test "exe: error payload recovered via catch binding" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\EP :: errors { code: i32 }
        \\risky :: fn(x: i32) -> i32 ! EP { if x < 0 { fail .code { 77 }; } return x; }
        \\main :: fn() -> i32 {
        \\    return risky(-1) catch e {
        \\        if e == .code |c| { return c; }
        \\        return -1;
        \\    };
        \\}
    , "exe_errpayload");
    try std.testing.expectEqual(@as(u32, 77), code);
}

test "exe: #insert literal #quote splices and runs" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The spliced statements run in the enclosing scope: they read and mutate
    // `x` (5), so the program must exit 105.
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    x := 5;
        \\    #insert #quote {
        \\        x = x + 100;
        \\    };
        \\    return x;
        \\}
    , "exe_insert_quote");
    try std.testing.expectEqual(@as(u32, 105), code);
}

test "exe: block macro splices an argument body twice" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `twice` splices its `$body` argument block twice; the caller's body
    // increments n, so n goes 0 → 2.
    const code = try compileAndRun(arena.allocator(),
        \\twice :: macro(body: Code) -> Code {
        \\    return #quote {
        \\        $body;
        \\        $body;
        \\    };
        \\}
        \\main :: fn() -> i32 {
        \\    n := 0;
        \\    #insert twice(#quote { n = n + 1; });
        \\    return n;
        \\}
    , "exe_macro_twice");
    try std.testing.expectEqual(@as(u32, 2), code);
}

test "exe: macro local is hygienic (no capture of caller's name)" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The macro introduces its own `tmp`; the caller also has a `tmp`. Hygiene
    // must keep them distinct, so the caller's tmp (=9) is returned unchanged
    // while the macro computes with its own tmp.
    const code = try compileAndRun(arena.allocator(),
        \\stash :: macro(e: Code) -> Code {
        \\    return #quote {
        \\        tmp := $(e) + 1;
        \\        marker = tmp;
        \\    };
        \\}
        \\main :: fn() -> i32 {
        \\    tmp := 9;
        \\    marker := 0;
        \\    #insert stash(#quote(40));
        \\    return tmp + marker;
        \\}
    , "exe_macro_hygiene");
    // caller tmp (9) untouched + marker (41) = 50
    try std.testing.expectEqual(@as(u32, 50), code);
}

test "exe: #for unrolls a comptime loop, baking the index" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Unrolls to total = 0 + 1 + 2 + 3 = 6.
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    total := 0;
        \\    #for i in 0..4 {
        \\        total = total + $(i);
        \\    }
        \\    return total;
        \\}
    , "exe_comptime_for");
    try std.testing.expectEqual(@as(u32, 6), code);
}

test "exe: #for generatively initializes an array" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Emits arr[0]=0; arr[1]=1; arr[2]=4; arr[3]=9 → sum 14.
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    arr: [4]i32 = .{ 0, 0, 0, 0 };
        \\    #for i in 0..4 {
        \\        arr[$(i)] = $(i) * $(i);
        \\    }
        \\    return arr[0] + arr[1] + arr[2] + arr[3];
        \\}
    , "exe_comptime_for_array");
    try std.testing.expectEqual(@as(u32, 14), code);
}

test "exe: generative macro unrolls a parameterized #for" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The macro's #for bound is its own argument (5) → 0+1+2+3+4 = 10.
    const code = try compileAndRun(arena.allocator(),
        \\sumup :: macro(n: Code) -> Code {
        \\    return #quote {
        \\        #for i in 0..$(n) {
        \\            acc = acc + $(i);
        \\        }
        \\    };
        \\}
        \\main :: fn() -> i32 {
        \\    acc := 0;
        \\    #insert sumup(#quote(5));
        \\    return acc;
        \\}
    , "exe_macro_for");
    try std.testing.expectEqual(@as(u32, 10), code);
}

test "exe: #insert #run gen() — VM-generated code compiled into the binary" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // gen() runs on the comptime VM, its AstBlock is reified and spliced into
    // main, then LLVM compiles the spliced code. gen itself (comptime-only,
    // returns AstBlock) is excluded from the binary.
    const code = try compileAndRun(arena.allocator(),
        \\gen :: fn() -> AstBlock {
        \\    return #quote {
        \\        x = x + 40;
        \\        x = x + 2;
        \\    };
        \\}
        \\main :: fn() -> i32 {
        \\    x := 0;
        \\    #insert #run gen();
        \\    return x;
        \\}
    , "exe_gen_insert");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: generated while-loop with conditional compiles and runs" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A generator emits a while-loop + if; the spliced code is compiled by LLVM.
    const code = try compileAndRun(arena.allocator(),
        \\gen :: fn() -> AstBlock {
        \\    return #quote {
        \\        i := 0;
        \\        while i < 9 {
        \\            sum = sum + i;
        \\            i = i + 1;
        \\        }
        \\        if sum > 100 { sum = 0; }
        \\    };
        \\}
        \\main :: fn() -> i32 {
        \\    sum := 0;
        \\    #insert #run gen();
        \\    return sum;
        \\}
    , "exe_gen_loop");
    // 0+1+...+8 = 36
    try std.testing.expectEqual(@as(u32, 36), code);
}

test "exe: generated for-range loop + typed local compiles and runs" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The generator declares a typed local and a `for`-range loop; `total` is
    // declared inside the generated code and used after the splice (tolerant
    // pass 1). 0+1+2+3+4 = 10.
    const code = try compileAndRun(arena.allocator(),
        \\gen :: fn() -> AstBlock {
        \\    return #quote {
        \\        total: i32 = 0;
        \\        for i in 0..=4 { total = total + i; }
        \\    };
        \\}
        \\main :: fn() -> i32 {
        \\    #insert #run gen();
        \\    return total;
        \\}
    , "exe_gen_for");
    try std.testing.expectEqual(@as(u32, 10), code);
}

test "exe: generated match + cast compiles and runs" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\gen :: fn() -> AstBlock {
        \\    return #quote {
        \\        match k {
        \\            0 => r = 30;
        \\            else => r = 0;
        \\        }
        \\        big: i64 = r as i64;
        \\        r = big as i32;
        \\    };
        \\}
        \\main :: fn() -> i32 {
        \\    k := 0;
        \\    r := 0;
        \\    #insert #run gen();
        \\    return r;
        \\}
    , "exe_gen_match");
    try std.testing.expectEqual(@as(u32, 30), code);
}

test "exe: comptime FFI calls kernel32 at build time" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `mul_div` resolves to kernel32!MulDiv and is CALLED on the comptime VM:
    // MulDiv(10, 6, 1) = 60 is computed during compilation and baked in.
    const code = try compileAndRun(arena.allocator(),
        \\#extern("kernel32", "MulDiv")
        \\mul_div :: fn(a: i32, b: i32, c: i32) -> i32;
        \\RESULT :: #run mul_div(10, 6, 1);
        \\main :: fn() -> i32 { return RESULT; }
    , "exe_ffi_muldiv");
    try std.testing.expectEqual(@as(u32, 60), code);
}

test "exe: comptime FFI marshals a string argument" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\#extern("kernel32", "lstrlenA")
        \\str_len :: fn(s: []const u8) -> i32;
        \\LEN :: #run str_len("hello, world");
        \\main :: fn() -> i32 { return LEN; }
    , "exe_ffi_strlen");
    try std.testing.expectEqual(@as(u32, 12), code);
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

test "exe: fallible return type works inside generics" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Regression: a generic `fn(...) -> T ! Err` miscompiled — the instantiation
    // hardcoded error_ty=null and never set current_return_ty, so `fail`/`?`/`catch`
    // were lowered against a non-fallible signature (LLVM icmp i64/i32 mismatch, or
    // an extractAggregateField ICE in a `?`-propagating caller). `caller(i32,30)`
    // returns 30 via `?`; `checked(i32,5,true)` fails and the catch returns 30+7=37.
    const code = try compileAndRun(arena.allocator(),
        \\GErr :: errors { bad, }
        \\checked :: fn($T: type, x: T, fail_it: bool) -> T ! GErr {
        \\    if fail_it { fail .bad; }
        \\    return x;
        \\}
        \\caller :: fn($T: type, x: T) -> T ! GErr {
        \\    v := checked(T, x, false)?;
        \\    return v;
        \\}
        \\main :: fn() -> i32 {
        \\    a := caller(i32, 30) catch e { return 1; };
        \\    b := checked(i32, 5, true) catch e { return a + 7; };
        \\    return a + b;
        \\}
    , "exe_generic_fallible");
    try std.testing.expectEqual(@as(u32, 37), code);
}

test "exe: sizeof(T) and slice_from_raw_parts(T) work inside generics" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Regression: a type parameter `T` used in `sizeof(T)` / `slice_from_raw_parts(T)`
    // inside a generic body used to ICE (the builtin's type arg was lowered as a
    // value and `firstTypeArg` couldn't resolve a type param). Now both resolve to
    // the concrete instantiation. elem_bytes(i32)=4; the slice sums to 15 → 19.
    const code = try compileAndRun(arena.allocator(),
        \\elem_bytes :: fn($T: type) -> usize { return sizeof(T); }
        \\mkslice :: fn($T: type, p: *T, n: usize) -> []T {
        \\    return unsafe slice_from_raw_parts(T, p, n);
        \\}
        \\main :: fn() -> i32 {
        \\    arr: [3]i32 = .{ 5, 9, 1 };
        \\    full := arr[:];
        \\    s := mkslice(i32, full.ptr, 3usize);
        \\    es := elem_bytes(i32);
        \\    return s[0] + s[1] + s[2] + (es as i32);
        \\}
    , "exe_generic_sizeof_slice");
    try std.testing.expectEqual(@as(u32, 19), code);
}

test "exe: usize const wider than 32 bits keeps its full width" {
    if (comptime !k2.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Regression: `inferConstType` emitted EVERY integer `const` as an i32 global
    // regardless of its type suffix, so a `usize`/`u64` const was an undersized
    // i32 global. A later i64 load then read 4 bytes of the value plus 4 bytes of
    // adjacent memory into the high word — corrupting any address built through
    // ptr_from_int / slice_from_raw_parts (segfaults in std.heap). With the fix
    // the high 32 bits survive: (0x5_0000_0000 >> 32) == 5; an i32 global would
    // truncate the low word to 0 and yield 0/garbage.
    const code = try compileAndRun(arena.allocator(),
        \\VAL :: 0x500000000usize;
        \\main :: fn() -> i32 { return (VAL >> 32usize) as i32; }
    , "exe_usize_const_width");
    try std.testing.expectEqual(@as(u32, 5), code);
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
