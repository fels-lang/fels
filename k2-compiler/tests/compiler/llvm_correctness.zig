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

test "LLVM lowering accepts full-width u64 constants" {
    if (comptime !k2.llvm_enabled) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\sign_bit :: fn() -> u64 {
        \\    return 0x8000000000000000u64;
        \\}
    ;

    var fe = try k2.compile(arena.allocator(), "full_width_u64.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);

    var backend = k2.LlvmBackend.init(arena.allocator(), "full_width_u64");
    defer backend.deinit();
    try backend.lower(module);
    const llvm_ir = try backend.getIrText(arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "i64 -9223372036854775808") != null);
}

test "LLVM lowering applies #align to struct allocas" {
    if (comptime !k2.llvm_enabled) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\#align(64)
        \\Aligned :: struct {
        \\    x: i32,
        \\    y: i32,
        \\}
        \\
        \\use_aligned :: fn() -> i32 {
        \\    local: Aligned = .{ 3i32, 4i32 };
        \\    return local.x;
        \\}
    ;

    var fe = try k2.compile(arena.allocator(), "align_struct.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);

    var backend = k2.LlvmBackend.init(arena.allocator(), "align_struct");
    defer backend.deinit();
    try backend.lower(module);
    const llvm_ir = try backend.getIrText(arena.allocator());

    // The alloca backing the #align(64) struct local must carry the alignment
    // from the attribute, not the type's natural ABI alignment.
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "alloca %Aligned, align 64") != null);
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

test "LLVM optional equality compares presence instead of aggregate values" {
    if (comptime !k2.llvm_enabled) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\has_value :: fn(value: ?i32) -> bool { return value != null; }
        \\is_empty :: fn(value: ?i32) -> bool { return null == value; }
    ;

    var fe = try k2.compile(arena.allocator(), "optional_equality.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);

    var backend = k2.LlvmBackend.init(arena.allocator(), "optional_equality");
    defer backend.deinit();
    try backend.lower(module);
    const llvm_ir = try backend.getIrText(arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "extractvalue") != null);
}

test "LLVM optional payload is coerced to its declared integer width" {
    if (comptime !k2.llvm_enabled) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\parse :: fn() -> ?u16 {
        \\    value := 0u16;
        \\    value = (value << 4) | 1u16;
        \\    return value;
        \\}
    ;

    var fe = try k2.compile(arena.allocator(), "optional_payload_width.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);

    var backend = k2.LlvmBackend.init(arena.allocator(), "optional_payload_width");
    defer backend.deinit();
    try backend.lower(module);
    const llvm_ir = try backend.getIrText(arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "trunc i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "insertvalue { i1, i16 }") != null);
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

test "LLVM error/fallible ABI: fail and return lower to { ok, i32 } struct" {
    if (comptime !k2.llvm_enabled) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\NetError :: errors { timeout, http: u16, }
        \\
        \\connect :: fn(host: []const u8) -> i32 ! NetError {
        \\    if host.len == 0 {
        \\        fail .timeout;
        \\    }
        \\    return 42;
        \\}
        \\
        \\caller :: fn(host: []const u8) -> i32 ! NetError {
        \\    v := connect(host)?;
        \\    return v;
        \\}
    ;

    var fe = try k2.compile(arena.allocator(), "fallible.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);

    var backend = k2.LlvmBackend.init(arena.allocator(), "fallible");
    defer backend.deinit();
    try backend.lower(module);
    const llvm_ir = try backend.getIrText(arena.allocator());

    // Return type must be { i32, i32 } — ok-value + discriminant.
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "{ i32, i32 }") != null);
    // Successful return wraps with insertvalue index 1 = 0.
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "insertvalue") != null);
    // fail emits a non-zero discriminant and returns.
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "ret { i32, i32 }") != null);
    // try_context emits a conditional branch on the discriminant.
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "propagate_err") != null);
}

test "LLVM fallible return coerces to its declared integer width" {
    if (comptime !k2.llvm_enabled) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\ParseError :: errors { invalid, }
        \\parse :: fn(value: u16) -> u16 ! ParseError {
        \\    result := (value << 4u16) | 1u16;
        \\    return result;
        \\}
    ;

    var fe = try k2.compile(arena.allocator(), "fallible_width.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);

    var backend = k2.LlvmBackend.init(arena.allocator(), "fallible_width");
    defer backend.deinit();
    try backend.lower(module);
    const llvm_ir = try backend.getIrText(arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "insertvalue { i16, i32 }") != null);
}

test "LLVM debug: division by zero inserts a runtime check" {
    if (comptime !k2.llvm_enabled) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\divide :: fn(a: i32, b: i32) -> i32 { return a / b; }
    ;

    var fe = try k2.compile(arena.allocator(), "div_check.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);

    var backend = k2.LlvmBackend.init(arena.allocator(), "div_check");
    defer backend.deinit();
    // opt_level=0 (debug) — checks should be present.
    try backend.lower(module);
    try backend.emitObject(".zig-cache/div_check_test.o", 0);
    const llvm_ir = try backend.getIrText(arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "check_fail") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "check_ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "division by zero") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "div_check.k2:1:") != null);
}

test "LLVM debug: integer overflow inserts a located runtime check" {
    if (comptime !k2.llvm_enabled) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\add :: fn(a: i32, b: i32) -> i32 { return a + b; }
        \\multiply :: fn(a: u32, b: u32) -> u32 { return a * b; }
    ;

    var fe = try k2.compile(arena.allocator(), "overflow.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);

    var backend = k2.LlvmBackend.init(arena.allocator(), "overflow");
    defer backend.deinit();
    try backend.lower(module);
    const llvm_ir = try backend.getIrText(arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "llvm.sadd.with.overflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "llvm.umul.with.overflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "integer overflow at overflow.k2:1:") != null);
}

test "LLVM release: division omits debug runtime check" {
    if (comptime !k2.llvm_enabled) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\divide :: fn(a: i32, b: i32) -> i32 { return a / b; }
    ;

    var fe = try k2.compile(arena.allocator(), "div_release.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);

    var backend = k2.LlvmBackend.init(arena.allocator(), "div_release");
    defer backend.deinit();
    backend.setOptLevel(2);
    try backend.lower(module);
    const llvm_ir = try backend.getIrText(arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "check_fail") == null);
}

test "LLVM debug: shift overflow inserts a runtime check" {
    if (comptime !k2.llvm_enabled) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\shift_it :: fn(a: u32, b: u32) -> u32 { return a << b; }
    ;

    var fe = try k2.compile(arena.allocator(), "shift_check.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);

    var backend = k2.LlvmBackend.init(arena.allocator(), "shift_check");
    defer backend.deinit();
    try backend.lower(module);
    const llvm_ir = try backend.getIrText(arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "check_fail") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "shift amount exceeds bit width") != null);
}

test "LLVM debug: slice bounds check inserts a runtime check" {
    if (comptime !k2.llvm_enabled) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\get :: fn(data: []const u8, i: usize) -> u8 { return data[i]; }
    ;

    var fe = try k2.compile(arena.allocator(), "bounds.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);

    var backend = k2.LlvmBackend.init(arena.allocator(), "bounds");
    defer backend.deinit();
    try backend.lower(module);
    const llvm_ir = try backend.getIrText(arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "check_fail") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "index out of bounds") != null);
}

test "LLVM debug: array bounds check uses static array length" {
    if (comptime !k2.llvm_enabled) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\get :: fn(data: [4]u8, i: usize) -> u8 { return data[i]; }
    ;

    var fe = try k2.compile(arena.allocator(), "array_bounds.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);

    var backend = k2.LlvmBackend.init(arena.allocator(), "array_bounds");
    defer backend.deinit();
    try backend.lower(module);
    const llvm_ir = try backend.getIrText(arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "index out of bounds at array_bounds.k2:1:") != null);
}

test "LLVM float casts emit correct instructions" {
    if (comptime !k2.llvm_enabled) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\f_to_i :: fn(x: f32) -> i32  { return x as i32; }
        \\i_to_f :: fn(x: i32) -> f32  { return x as f32; }
        \\f32_to_f64 :: fn(x: f32) -> f64 { return x as f64; }
        \\f64_to_f32 :: fn(x: f64) -> f32 { return x as f32; }
        \\u_to_f :: fn(x: u32) -> f32 { return x as f32; }
        \\f_to_u :: fn(x: f32) -> u32 { return x as u32; }
        \\widen_u :: fn(x: u8) -> u32 { return x as u32; }
    ;

    var fe = try k2.compile(arena.allocator(), "float_casts.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);

    var backend = k2.LlvmBackend.init(arena.allocator(), "float_casts");
    defer backend.deinit();
    try backend.lower(module);
    const llvm_ir = try backend.getIrText(arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "fptosi") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "sitofp") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "fpext") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "fptrunc") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "uitofp") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "fptoui") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "zext") != null);
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

test "LLVM zones allocate from and drain the process heap" {
    if (comptime !k2.llvm_enabled) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\work :: fn(count: usize) -> i32 {
        \\    zone scratch: Arena {
        \\        data := scratch.new_slice(u8, count);
        \\        data[0] = 7u8;
        \\    }
        \\    return 0;
        \\}
    ;

    var fe = try k2.compile(arena.allocator(), "zones.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);

    var backend = k2.LlvmBackend.init(arena.allocator(), "zones");
    defer backend.deinit();
    try backend.lower(module);
    const llvm_ir = try backend.getIrText(arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "@HeapAlloc") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "@HeapFree") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "zone_pop_free") != null);
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "zone allocation failed at zones.k2:") != null);
}

test "LLVM borrow parameters erase to their underlying ABI type" {
    if (comptime !k2.llvm_enabled) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\touch :: fn(data: borrow []u8) { data[0] = 1u8; }
    ;
    var fe = try k2.compile(arena.allocator(), "borrow_abi.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);

    var backend = k2.LlvmBackend.init(arena.allocator(), "borrow_abi");
    defer backend.deinit();
    try backend.lower(module);
    const llvm_ir = try backend.getIrText(arena.allocator());

    // `touch` is module-private, so it gets `internal` linkage — match on the
    // signature rather than the linkage keyword.
    try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "@touch({ ptr, i64 }") != null);
}
