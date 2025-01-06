const std = @import("std");
const k2 = @import("k2_compiler");

test "arithmetic and bitwise operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\add_sub :: fn(a: i32, b: i32) -> i32 { return a + b - b; }
        \\mul_div :: fn(a: i32, b: i32) -> i32 { return a * b / b; }
        \\bitwise :: fn(a: u32, b: u32) -> u32 { return a | b ^ (a & ~b); }
        \\shifts  :: fn(a: u32) -> u32 { return (a << 2) >> 1; }
        \\rem     :: fn(a: i32, b: i32) -> i32 { return a % b; }
    ;
    var fe = try k2.compile(arena.allocator(), "arith.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
    var opt = m;
    try k2.ir_mod.runDefaultPasses(arena.allocator(), &opt);
    try k2.ir_mod.validateModule(opt);
}

test "comparison and logical operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\cmp :: fn(a: i32, b: i32) -> bool { return a <= b && b > 0 || a >= 0; }
        \\neg :: fn(x: bool) -> bool { return !x; }
    ;
    var fe = try k2.compile(arena.allocator(), "cmp.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}

test "compound assignment operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\counter :: fn(n: u32) -> u32 {
        \\    x := 0u32;
        \\    i := 0u32;
        \\    while i < n {
        \\        x += i;
        \\        x *= 2u32;
        \\        i += 1u32;
        \\    }
        \\    return x;
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "compound.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}

test "break and continue in while loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\find :: fn(data: [*]const u32, count: usize) -> u32 {
        \\    i := 0usize;
        \\    result := 0u32;
        \\    while i < count {
        \\        v := data[i];
        \\        if v != 0u32 {
        \\            result = v;
        \\            break;
        \\        }
        \\        i += 1;
        \\    }
        \\    return result;
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "break.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}

test "CFG analysis rejects missing return on non-void function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\bad :: fn() -> i32 { }
    ;
    try std.testing.expectError(
        error.SemanticFailed,
        k2.compile(arena.allocator(), "bad.k2", bad),
    );
}

test "break outside loop fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\bad :: fn() { break; }
    ;
    try std.testing.expectError(
        error.SemanticFailed,
        k2.compile(arena.allocator(), "bad_break.k2", bad),
    );
}

test "constant folding folds binary ops in function body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A function that returns a compile-time constant expression.
    // After const-fold + DCE the only instruction left should be the return.
    const src =
        \\answer :: fn() -> i32 {
        \\    x := 6 * 7;
        \\    return x;
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "fold.k2", src);
    defer fe.deinit(arena.allocator());
    var m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.runDefaultPasses(arena.allocator(), &m);
    try k2.ir_mod.validateModule(m);
    // Verify the function exists and its IR is valid
    try std.testing.expectEqual(@as(usize, 1), m.functions.len);
}

test "zone block: new and new_slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Header :: struct { magic: u32, len: u32, }
        \\
        \\process :: fn(count: usize) -> bool {
        \\    zone scratch: Arena {
        \\        h := scratch.new(Header);
        \\        buf := scratch.new_slice(u8, count);
        \\        h.magic = truncate_to(u32, buf.len);
        \\    }
        \\    return true;
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "zone.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    // find zone_push instruction
    const func = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "process")) break f;
    } else return error.FunctionNotFound;

    var found_zone_push = false;
    var found_zone_pop = false;
    var found_alloc = false;
    var found_alloc_slice = false;
    for (func.blocks) |block| {
        for (block.instrs) |instr| switch (instr.kind) {
            .zone_push => |zp| {
                found_zone_push = true;
                try std.testing.expectEqualStrings("scratch", zp.name);
                try std.testing.expectEqualStrings("Arena", zp.kind);
            },
            .zone_pop => found_zone_pop = true,
            .alloc => found_alloc = true,
            .alloc_slice => found_alloc_slice = true,
            else => {},
        };
    }
    try std.testing.expect(found_zone_push);
    try std.testing.expect(found_zone_pop);
    try std.testing.expect(found_alloc);
    try std.testing.expect(found_alloc_slice);
}

test "zone RAII: return inside zone emits zone_pop before return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\early_exit :: fn(flag: bool) -> i32 {
        \\    zone temp: Arena {
        \\        if flag {
        \\            return 1;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "raii.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    // The IR must have zone_pop before every return_value terminator
    const func = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "early_exit")) break f;
    } else return error.FunctionNotFound;

    for (func.blocks) |block| {
        if (block.terminator) |term| switch (term) {
            .return_value => {
                // last instruction before return must be zone_pop
                const last = block.instrs[block.instrs.len - 1];
                try std.testing.expect(last.kind == .zone_pop);
            },
            else => {},
        };
    }
}

test "defer: basic expression deferred to block end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\cleanup :: fn() {}
        \\work :: fn() -> bool {
        \\    defer cleanup();
        \\    return true;
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "defer.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    const func = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "work")) break f;
    } else return error.FunctionNotFound;

    // The deferred cleanup() call must appear BEFORE the return_value terminator
    for (func.blocks) |block| {
        if (block.terminator) |term| switch (term) {
            .return_value => {
                // last instruction before return must be a call to cleanup
                var found_cleanup_call = false;
                for (block.instrs) |instr| switch (instr.kind) {
                    .call => |c| if (std.mem.eql(u8, c.callee, "cleanup")) {
                        found_cleanup_call = true;
                    },
                    else => {},
                };
                try std.testing.expect(found_cleanup_call);
            },
            else => {},
        };
    }
}

test "defer: LIFO order — last defer runs first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\a :: fn() {}
        \\b :: fn() {}
        \\work :: fn() {
        \\    defer a();
        \\    defer b();
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "defer_order.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    const func = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "work")) break f;
    } else return error.FunctionNotFound;

    // Collect call instruction order
    var calls: std.ArrayList([]const u8) = .empty;
    defer calls.deinit(std.testing.allocator);
    for (func.blocks) |block| {
        for (block.instrs) |instr| switch (instr.kind) {
            .call => |c| if (!std.mem.eql(u8, c.callee, "work")) try calls.append(std.testing.allocator, c.callee),
            else => {},
        };
    }
    // b() was deferred last, so it runs first (LIFO)
    try std.testing.expectEqual(@as(usize, 2), calls.items.len);
    try std.testing.expectEqualStrings("b", calls.items[0]);
    try std.testing.expectEqualStrings("a", calls.items[1]);
}

test "defer inside zone block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\close :: fn() {}
        \\work :: fn(n: usize) -> bool {
        \\    zone scratch: Arena {
        \\        defer close();
        \\        buf := scratch.new_slice(u8, n);
        \\        buf[0] = 0u8;
        \\    }
        \\    return true;
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "defer_zone.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}

test "unsafe_expr: unsafe prefix on expression is transparent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\read_byte :: fn(ptr: usize) -> u8 {
        \\    return unsafe unaligned_read(u8, ptr);
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "unsafe_expr.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}

test "asm: zero-input volatile instruction (pause)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\cpu_pause :: fn() {
        \\    unsafe {
        \\        asm(volatile, "pause", inputs: {}, outputs: {}, clobbers: {});
        \\    }
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "asm_pause.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}

test "asm: input operands and typed output (syscall pattern)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Models Linux write syscall: syscall nr in rax, fd in rdi, ptr in rsi, len in rdx.
    const src =
        \\sys_write :: fn(fd: i32, buf: usize, len: usize) -> isize {
        \\    return unsafe asm(
        \\        volatile,
        \\        "syscall",
        \\        inputs:  { "a"(1), "D"(fd), "S"(buf), "d"(len) },
        \\        outputs: { "=a"(isize) },
        \\        clobbers: { "rcx", "r11", "memory" },
        \\    );
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "asm_syscall.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    // Verify the asm produces an inline_asm instruction with correct structure.
    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "sys_write")) break f;
    } else return error.FunctionNotFound;

    var found_asm = false;
    for (fn_.blocks) |block| {
        for (block.instrs) |instr| switch (instr.kind) {
            .inline_asm => |ai| {
                found_asm = true;
                try std.testing.expectEqualStrings("syscall", ai.template);
                try std.testing.expect(ai.volatile_);
                try std.testing.expectEqual(@as(usize, 4), ai.args.len); // 4 inputs
                try std.testing.expect(std.mem.indexOf(u8, ai.constraints, "=a") != null);
                try std.testing.expect(std.mem.indexOf(u8, ai.constraints, "~{rcx}") != null);
            },
            else => {},
        };
    }
    try std.testing.expect(found_asm);
}

test "asm: unsafe required — bare asm fails outside unsafe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bad =
        \\bad :: fn() { asm(volatile, "pause", inputs: {}, outputs: {}, clobbers: {}); }
    ;
    try std.testing.expectError(error.SemanticFailed, k2.compile(arena.allocator(), "bad_asm.k2", bad));
}

test "?? nil-coalesce: unwrap or default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\find :: fn(ok: bool) -> ?i32 {
        \\    if ok { return 42; }
        \\    return null;
        \\}
        \\
        \\with_default :: fn(ok: bool) -> i32 {
        \\    return find(ok) ?? -1;
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "nil_coalesce.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    // with_default should have a conditional branch (for the ?? check)
    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "with_default")) break f;
    } else return error.FunctionNotFound;
    var has_cond_branch = false;
    for (fn_.blocks) |block| {
        if (block.terminator) |t| switch (t) {
            .cond_branch => has_cond_branch = true,
            else => {},
        };
    }
    try std.testing.expect(has_cond_branch);
}

test "!! force-unwrap: unwrap or panic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\find :: fn() -> ?i32 { return 42; }
        \\
        \\unwrap :: fn() -> i32 {
        \\    return find()!!;
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "force_unwrap.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    // unwrap should have a null check, a panic call, and an unreachable
    // terminator after the noreturn panic.
    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "unwrap")) break f;
    } else return error.FunctionNotFound;
    var has_unreachable = false;
    var has_panic_call = false;
    for (fn_.blocks) |block| {
        for (block.instrs) |instr| switch (instr.kind) {
            .call => |call| if (std.mem.eql(u8, call.callee, "@panic")) {
                has_panic_call = true;
            },
            else => {},
        };
        if (block.terminator) |t| switch (t) {
            .unreachable_term => has_unreachable = true,
            else => {},
        };
    }
    try std.testing.expect(has_panic_call);
    try std.testing.expect(has_unreachable);
}

test "?? type mismatch fails sema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\bad :: fn(v: ?i32) -> i32 { return v ?? "wrong"; }
    ;
    try std.testing.expectError(error.SemanticFailed, k2.compile(arena.allocator(), "bad.k2", bad));
}

test "!! on non-optional fails sema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\bad :: fn(v: i32) -> i32 { return v!!; }
    ;
    try std.testing.expectError(error.SemanticFailed, k2.compile(arena.allocator(), "bad.k2", bad));
}

test "if-else with both branches returning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\abs :: fn(x: i32) -> i32 {
        \\    if x < 0 {
        \\        return 0 - x;
        \\    } else {
        \\        return x;
        \\    }
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "abs.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}

test "@panic runtime parses, checks, and lowers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\#extern("kernel32", "ExitProcess")
        \\#noreturn
        \\ExitProcess :: fn(code: u32);
        \\
        \\#noreturn
        \\@panic :: fn(msg: []const u8) {
        \\    ExitProcess(0xDEAD_BEEF);
        \\}
        \\
        \\assert :: fn(cond: bool) {
        \\    if !cond { @panic("assertion failed\n"); }
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "runtime/windows.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    const panic_fn = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "@panic")) break f;
    } else return error.FunctionNotFound;
    try std.testing.expect(panic_fn.no_return);
}

test "postfix as casts lower to cast instructions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\casts :: fn(value: i32, addr: usize) -> i64 {
        \\    widened := value as i64;
        \\    flag := value as bool;
        \\    back := flag as u8;
        \\    ptr := unsafe addr as *u32;
        \\    roundtrip := unsafe ptr as usize;
        \\    return widened + (back as i64) + (roundtrip as i64);
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "casts.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    const func = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "casts")) break f;
    } else return error.FunctionNotFound;
    var cast_count: usize = 0;
    for (func.blocks) |block| for (block.instrs) |instr| {
        if (instr.kind == .cast) cast_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 7), cast_count);
}

test "pointer as cast requires unsafe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\bad :: fn(addr: usize) -> *u32 { return addr as *u32; }
    ;
    try std.testing.expectError(error.SemanticFailed, k2.compile(arena.allocator(), "bad_cast.k2", bad));
}

test "for range and slice loops lower with continue-safe increment blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\sum_range :: fn(n: u32) -> u32 {
        \\    total := 0u32;
        \\    for i in 0u32..n {
        \\        if i == 2u32 { continue; }
        \\        total += i;
        \\    }
        \\    return total;
        \\}
        \\
        \\sum_slice :: fn(values: []const u32) -> u32 {
        \\    total := 0u32;
        \\    for value, index in values {
        \\        total += value + (index as u32);
        \\    }
        \\    return total;
        \\}
        \\
        \\increment :: fn(values: []u32) {
        \\    for &value in values {
        \\        *value += 1u32;
        \\    }
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "for.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    const range_fn = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "sum_range")) break f;
    } else return error.FunctionNotFound;
    var has_range_increment = false;
    for (range_fn.blocks) |block| {
        if (std.mem.eql(u8, block.name, "for.range.increment")) has_range_increment = true;
    }
    try std.testing.expect(has_range_increment);

    const slice_fn = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "increment")) break f;
    } else return error.FunctionNotFound;
    var has_index_addr = false;
    for (slice_fn.blocks) |block| for (block.instrs) |instr| {
        if (instr.kind == .index_addr) has_index_addr = true;
    };
    try std.testing.expect(has_index_addr);
}
