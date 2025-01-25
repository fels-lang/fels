const std = @import("std");
const k2 = @import("k2_compiler");

const instructions = k2.vm_instructions;
const engine = k2.vm_engine;
const compiler = k2.vm_compiler;
const Value = k2.vm_value.Value;
const Instr = instructions.Instr;

// ── Engine: hand-assembled bytecode ──────────────────────────────────────

test "engine: hand-assembled arithmetic" {
    var vm = engine.Vm.init(std.testing.allocator);
    defer vm.deinit();

    const code = [_]Instr{
        Instr.r_imm(.load_imm, 1, 10),
        Instr.r_imm(.load_imm, 2, 32),
        Instr.r_r_r(.add_i, 3, 1, 2),
        Instr.r_imm(.ret, 3, 0),
    };
    const func = instructions.BytecodeFunction{
        .name = "add",
        .instrs = &code,
        .num_regs = 4,
        .num_locals = 0,
    };

    const result = try vm.execute(func);
    try std.testing.expectEqual(@as(i128, 42), result.int);
}

test "engine: hand-assembled loop (sum 1..=5)" {
    var vm = engine.Vm.init(std.testing.allocator);
    defer vm.deinit();

    // r0=acc r1=i r2=n r3=cond r4=one
    const code = [_]Instr{
        Instr.r_imm(.load_imm, 0, 0), // 0: acc = 0
        Instr.r_imm(.load_imm, 1, 1), // 1: i = 1
        Instr.r_imm(.load_imm, 2, 5), // 2: n = 5
        Instr.r_r_r(.le_i, 3, 1, 2), // 3: cond = i <= n
        Instr.r_imm(.br_if_not, 3, 9), // 4: if !cond goto 9
        Instr.r_r_r(.add_i, 0, 0, 1), // 5: acc += i
        Instr.r_imm(.load_imm, 4, 1), // 6: one = 1
        Instr.r_r_r(.add_i, 1, 1, 4), // 7: i += 1
        Instr.with_imm(.jmp, 3), // 8: goto 3
        Instr.r_imm(.ret, 0, 0), // 9: ret acc
    };
    const func = instructions.BytecodeFunction{
        .name = "loop",
        .instrs = &code,
        .num_regs = 5,
        .num_locals = 0,
    };

    const result = try vm.execute(func);
    try std.testing.expectEqual(@as(i128, 15), result.int);
}

test "engine: zone push/alloc/pop leaves no active zones" {
    var vm = engine.Vm.init(std.testing.allocator);
    defer vm.deinit();

    const consts = [_]Value{.{ .string = "scratch" }};
    const code = [_]Instr{
        Instr.with_imm(.zone_push, 0), // push zone named consts[0]
        Instr.r_imm(.zone_alloc, 0, 4), // r0 = alloc 4 bytes
        Instr.r_imm(.zone_alloc, 1, 8), // r1 = alloc 8 bytes
        Instr.with_imm(.zone_pop, 0), // free the zone
        Instr.with_imm(.ret_void, 0),
    };
    const func = instructions.BytecodeFunction{
        .name = "zones",
        .instrs = &code,
        .num_regs = 2,
        .num_locals = 0,
        .constants = &consts,
    };

    _ = try vm.execute(func);
    try std.testing.expectEqual(@as(usize, 0), vm.zone_stack.depth());
    // testing.allocator asserts the zone's host memory was freed.
}

test "engine: zones unwind on early return" {
    var vm = engine.Vm.init(std.testing.allocator);
    defer vm.deinit();

    const consts = [_]Value{.{ .string = "z" }};
    // Push a zone, allocate, then return WITHOUT popping — the frame must
    // unwind the zone itself.
    const code = [_]Instr{
        Instr.with_imm(.zone_push, 0),
        Instr.r_imm(.zone_alloc, 0, 16),
        Instr.r_imm(.load_imm, 1, 7),
        Instr.r_imm(.ret, 1, 0),
    };
    const func = instructions.BytecodeFunction{
        .name = "leaky",
        .instrs = &code,
        .num_regs = 2,
        .num_locals = 0,
        .constants = &consts,
    };

    const result = try vm.execute(func);
    try std.testing.expectEqual(@as(i128, 7), result.int);
    try std.testing.expectEqual(@as(usize, 0), vm.zone_stack.depth());
}

// ── End-to-end: K2 source → IR → bytecode → run ──────────────────────────

/// Compile K2 source, lower to IR, compile the named function's module, and
/// invoke it with `args`. Caller owns nothing; everything is freed here.
fn runSource(
    src: []const u8,
    func_name: []const u8,
    args: []const Value,
) !Value {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try k2.compile(a, "vm_test.k2", src);
    defer fe.deinit(a);
    const ir_module = try k2.lowerFrontend(a, fe);

    var bc = try compiler.compileModule(std.testing.allocator, ir_module);
    defer bc.deinit(std.testing.allocator);

    var vm = engine.Vm.initModule(std.testing.allocator, &bc);
    defer vm.deinit();
    return vm.call(func_name, args);
}

test "e2e: function with parameters" {
    const src =
        \\add :: fn(a: i32, b: i32) -> i32 {
        \\    return a + b;
        \\}
    ;
    const result = try runSource(src, "add", &.{ .{ .int = 17 }, .{ .int = 25 } });
    try std.testing.expectEqual(@as(i128, 42), result.int);
}

test "e2e: recursion (factorial)" {
    const src =
        \\fact :: fn(n: i32) -> i32 {
        \\    if n <= 1 {
        \\        return 1;
        \\    }
        \\    return n * fact(n - 1);
        \\}
    ;
    const result = try runSource(src, "fact", &.{.{ .int = 5 }});
    try std.testing.expectEqual(@as(i128, 120), result.int);
}

test "e2e: while loop with locals" {
    const src =
        \\sumto :: fn(n: i32) -> i32 {
        \\    total := 0;
        \\    i := 1;
        \\    while i <= n {
        \\        total = total + i;
        \\        i = i + 1;
        \\    }
        \\    return total;
        \\}
    ;
    const result = try runSource(src, "sumto", &.{.{ .int = 10 }});
    try std.testing.expectEqual(@as(i128, 55), result.int);
}
