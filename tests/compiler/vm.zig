const std = @import("std");
const fels = @import("fels_compiler");

const instructions = fels.vm_instructions;
const engine = fels.vm_engine;
const compiler = fels.vm_compiler;
const Value = fels.vm_value.Value;
const Instr = instructions.Instr;

// Engine: hand-assembled bytecode

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

test "engine: narrow wraps a value to a width and signedness" {
    var vm = engine.Vm.init(std.testing.allocator);
    defer vm.deinit();

    const Case = struct { v: i64, bits: i64, signed: bool, want: i128 };
    const cases = [_]Case{
        .{ .v = 300, .bits = 8, .signed = false, .want = 44 },
        .{ .v = -1, .bits = 32, .signed = false, .want = 0xFFFF_FFFF },
        .{ .v = 0xFFFF_FFFF, .bits = 32, .signed = true, .want = -1 },
        .{ .v = 128, .bits = 8, .signed = true, .want = -128 },
        .{ .v = 127, .bits = 8, .signed = true, .want = 127 },
        .{ .v = 5, .bits = 1, .signed = false, .want = 1 },
        .{ .v = -1, .bits = 64, .signed = false, .want = 0xFFFF_FFFF_FFFF_FFFF },
        .{ .v = -1, .bits = 128, .signed = false, .want = -1 }, // 128 bits: nothing to drop
    };
    for (cases) |c| {
        const flag: i64 = if (c.signed) 0x100 else 0;
        const code = [_]Instr{
            Instr.r_imm(.load_imm, 0, c.v),
            .{ .op = .narrow, .a = 1, .b = 0, .imm = c.bits | flag },
            Instr.r_imm(.ret, 1, 0),
        };
        const func = instructions.BytecodeFunction{ .name = "narrow", .instrs = &code, .num_regs = 2, .num_locals = 0 };
        const result = try vm.execute(func);
        try std.testing.expectEqual(c.want, result.int);
    }
}

test "engine: zone_fill sets a run of cells and leaves the rest" {
    var vm = engine.Vm.init(std.testing.allocator);
    defer vm.deinit();

    // Five cells; fill the three from cell 1 with 7.
    const prefix = [_]Instr{
        Instr.r_imm(.zone_alloc, 0, 5),
        Instr.r_imm(.load_imm, 1, 7),
        Instr.r_r_imm(.field_addr, 2, 0, 1),
        .{ .op = .zone_fill, .a = 2, .b = 1, .imm = 3 },
    };
    const expect = [_]struct { cell: i64, filled: bool }{
        .{ .cell = 0, .filled = false },
        .{ .cell = 1, .filled = true },
        .{ .cell = 3, .filled = true },
        .{ .cell = 4, .filled = false },
    };
    inline for (expect) |e| {
        const code = prefix ++ [_]Instr{
            Instr.r_r_imm(.load_cell, 3, 0, e.cell),
            Instr.r_imm(.ret, 3, 0),
        };
        const func = instructions.BytecodeFunction{ .name = "fill", .instrs = &code, .num_regs = 4, .num_locals = 0 };
        const result = try vm.execute(func);
        if (e.filled) {
            try std.testing.expectEqual(@as(i128, 7), result.int);
        } else {
            try std.testing.expect(result == .void);
        }
    }
}

test "engine: block_at reads the block a cell points at, and keeps a host address" {
    var vm = engine.Vm.init(std.testing.allocator);
    defer vm.deinit();

    // Cell 1 of an outer block points at an inner block [void, 6].
    const nested = [_]Instr{
        Instr.r_imm(.zone_alloc, 0, 2),
        Instr.r_imm(.zone_alloc, 1, 2),
        Instr.r_imm(.load_imm, 2, 6),
        Instr.r_r_imm(.store_cell, 1, 2, 1),
        Instr.r_r_imm(.store_cell, 0, 1, 1),
        Instr.r_r_imm(.field_addr, 3, 0, 1),
        .{ .op = .block_at, .a = 4, .b = 3 },
        Instr.r_r_imm(.load_cell, 5, 4, 1),
        Instr.r_imm(.ret, 5, 0),
    };
    const nested_fn = instructions.BytecodeFunction{ .name = "nested", .instrs = &nested, .num_regs = 6, .num_locals = 0 };
    try std.testing.expectEqual(@as(i128, 6), (try vm.execute(nested_fn)).int);

    // In host memory an aggregate is inline: its address is the one block_at was given.
    const host = [_]Instr{
        Instr.r_imm(.load_imm, 0, 4096),
        Instr.r_r_imm(.host_ptr_make, 1, 0, 16),
        .{ .op = .block_at, .a = 2, .b = 1 },
        Instr.r_imm(.ret, 2, 0),
    };
    const host_fn = instructions.BytecodeFunction{ .name = "host", .instrs = &host, .num_regs = 3, .num_locals = 0 };
    try std.testing.expectEqual(@as(usize, 4096), (try vm.execute(host_fn)).host_ptr.addr);
}

test "engine: copy_cells copies a block, overlapping or not, and stores what is no block" {
    var vm = engine.Vm.init(std.testing.allocator);
    defer vm.deinit();

    // r0 = [1, 2, 3, void]; r1 = [void, void].
    const prefix = [_]Instr{
        Instr.r_imm(.zone_alloc, 0, 4),
        Instr.r_imm(.zone_alloc, 1, 2),
        Instr.r_imm(.load_imm, 2, 1),
        Instr.r_r_imm(.store_cell, 0, 2, 0),
        Instr.r_imm(.load_imm, 2, 2),
        Instr.r_r_imm(.store_cell, 0, 2, 1),
        Instr.r_imm(.load_imm, 2, 3),
        Instr.r_r_imm(.store_cell, 0, 2, 2),
        Instr.r_r_imm(.field_addr, 3, 0, 1),
    };
    // Shape 0 is two cells, shape 1 three.
    const shapes = [_]instructions.Shape{ .{ .cells = 2 }, .{ .cells = 3 } };
    const Case = struct { copy: Instr, block: u32, cell: i64, want: i128 };
    const cases = [_]Case{
        // Two cells of r0 into r1.
        .{ .copy = .{ .op = .copy_cells, .a = 1, .b = 0, .imm = 0 }, .block = 1, .cell = 1, .want = 2 },
        // r0's first three cells one cell on, over themselves: [1, 1, 2, 3].
        .{ .copy = .{ .op = .copy_cells, .a = 3, .b = 0, .imm = 1 }, .block = 0, .cell = 3, .want = 3 },
        .{ .copy = .{ .op = .copy_cells, .a = 3, .b = 0, .imm = 1 }, .block = 0, .cell = 1, .want = 1 },
        // And back: [2, 3, 3, void].
        .{ .copy = .{ .op = .copy_cells, .a = 0, .b = 3, .imm = 0 }, .block = 0, .cell = 0, .want = 2 },
        .{ .copy = .{ .op = .copy_cells, .a = 0, .b = 3, .imm = 0 }, .block = 0, .cell = 1, .want = 3 },
        // An integer is no block: it is stored in the destination's first cell.
        .{ .copy = .{ .op = .copy_cells, .a = 1, .b = 2, .imm = 0 }, .block = 1, .cell = 0, .want = 3 },
    };
    inline for (cases) |c| {
        const code = prefix ++ [_]Instr{
            c.copy,
            Instr.r_r_imm(.load_cell, 4, c.block, c.cell),
            Instr.r_imm(.ret, 4, 0),
        };
        const func = instructions.BytecodeFunction{ .name = "copy", .instrs = &code, .num_regs = 5, .num_locals = 0, .shapes = &shapes };
        try std.testing.expectEqual(c.want, (try vm.execute(func)).int);
    }
}

test "engine: a static is built on first read, shared, and read-only" {
    // Global 0 is a two-cell block [10, 20] built by its own function.
    const init_code = [_]Instr{
        Instr.r_imm(.zone_alloc, 0, 2),
        Instr.r_imm(.load_imm, 1, 10),
        Instr.r_r_imm(.store_cell, 0, 1, 0),
        Instr.r_imm(.load_imm, 1, 20),
        Instr.r_r_imm(.store_cell, 0, 1, 1),
        Instr.r_imm(.ret, 0, 0),
    };
    const globals = [_]instructions.BytecodeGlobal{.{
        .name = "G",
        .init = .{ .name = "G", .instrs = &init_code, .num_regs = 2, .num_locals = 0 },
    }};

    // read: G[1]. twice: G read twice, then the second block's cell 0 + the first's cell 1.
    // write: G[0] = 5.
    const read_code = [_]Instr{
        Instr.r_imm(.load_global, 0, 0),
        Instr.r_r_imm(.load_cell, 1, 0, 1),
        Instr.r_imm(.ret, 1, 0),
    };
    const twice_code = [_]Instr{
        Instr.r_imm(.load_global, 0, 0),
        Instr.r_imm(.load_global, 1, 0),
        Instr.r_r_imm(.load_cell, 2, 1, 0),
        Instr.r_r_imm(.load_cell, 3, 0, 1),
        Instr.r_r_r(.add_i, 4, 2, 3),
        Instr.r_imm(.ret, 4, 0),
    };
    const write_code = [_]Instr{
        Instr.r_imm(.load_global, 0, 0),
        Instr.r_imm(.load_imm, 1, 5),
        Instr.r_r_imm(.store_cell, 0, 1, 0),
        Instr.r_imm(.ret, 1, 0),
    };
    var functions = [_]instructions.BytecodeFunction{
        .{ .name = "read", .instrs = &read_code, .num_regs = 2, .num_locals = 0 },
        .{ .name = "twice", .instrs = &twice_code, .num_regs = 5, .num_locals = 0 },
        .{ .name = "write", .instrs = &write_code, .num_regs = 2, .num_locals = 0 },
    };
    const module = instructions.BytecodeModule{ .functions = &functions, .globals = &globals };

    var vm = engine.Vm.initModule(std.testing.allocator, &module);
    defer vm.deinit();

    const read = try vm.call("read", &.{});
    try std.testing.expectEqual(@as(i128, 20), read.int);
    // The static is forgotten with the zone it lived in: the next run builds it afresh.
    try std.testing.expect(vm.statics[0] == null);

    const twice = try vm.call("twice", &.{});
    try std.testing.expectEqual(@as(i128, 30), twice.int);

    // A write into static data stops the run, and says why.
    try std.testing.expectError(error.Trap, vm.call("write", &.{}));
    try std.testing.expect(vm.compiler_error_msg != null);
    try std.testing.expect(std.mem.indexOf(u8, vm.compiler_error_msg.?, "cannot modify a global") != null);
}

test "engine: a static is built once however often it is read" {
    const init_code = [_]Instr{
        Instr.r_imm(.zone_alloc, 0, 3),
        Instr.r_imm(.ret, 0, 0),
    };
    const globals = [_]instructions.BytecodeGlobal{.{
        .name = "G",
        .init = .{ .name = "G", .instrs = &init_code, .num_regs = 1, .num_locals = 0 },
    }};
    const reads_code = [_]Instr{
        Instr.r_imm(.load_global, 0, 0),
        Instr.r_imm(.load_global, 1, 0),
        Instr.r_imm(.load_global, 2, 0),
        Instr.r_imm(.ret, 2, 0),
    };
    var functions = [_]instructions.BytecodeFunction{
        .{ .name = "reads", .instrs = &reads_code, .num_regs = 3, .num_locals = 0 },
    };
    const module = instructions.BytecodeModule{ .functions = &functions, .globals = &globals };

    var vm = engine.Vm.initModule(std.testing.allocator, &module);
    defer vm.deinit();
    // Keep the zones so the static zone can be looked at afterwards.
    const result = try vm.executeKeepZones(functions[0]);
    // One block of three cells in the static zone (zone 0), not three.
    try std.testing.expectEqual(@as(u32, 0), result.ptr.zone);
    try std.testing.expectEqual(@as(usize, 3), vm.zone_stack.arenas.items[0].cells.items.len);
}

// End-to-end: Fels source → IR → bytecode → run

/// Compile Fels source, lower to IR, compile the named function's module, and
/// invoke it with `args`. Caller owns nothing; everything is freed here.
fn runSource(
    src: []const u8,
    func_name: []const u8,
    args: []const Value,
) !Value {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try fels.compile(a, "vm_test.fels", src);
    defer fe.deinit(a);
    const ir_module = try fels.lowerFrontend(a, fe);

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

test "e2e: #run calls a function, folded to a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\square :: fn(x: i32) -> i32 { return x * x; }
        \\ANSWER :: #run square(7);
    ;
    var fe = try fels.compile(a, "run.fels", src);
    defer fe.deinit(a);
    const m = try fels.lowerFrontend(a, fe);

    const g = for (m.globals) |gg| {
        if (std.mem.eql(u8, gg.name, "ANSWER")) break gg;
    } else return error.GlobalNotFound;
    try std.testing.expectEqual(@as(i128, 49), g.init.imm.int);
}

fn globalInt(m: anytype, name: []const u8) !i128 {
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, name)) return switch (g.init.imm) {
            .int => |v| v,
            .uint => |v| @intCast(v),
            else => error.NotAnInt,
        };
    }
    return error.GlobalNotFound;
}

test "e2e: #run sizeof folds scalar, struct, and array sizes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\Point :: struct { x: i32, y: i32 }
        \\SI :: #run core::sizeof(i32);
        \\SP :: #run core::sizeof(Point);
        \\SA :: #run core::sizeof([4]i32);
    ;
    var fe = try fels.compile(a, "sz.fels", src);
    defer fe.deinit(a);
    const m = try fels.lowerFrontend(a, fe);

    try std.testing.expectEqual(@as(i128, 4), try globalInt(m, "SI"));
    try std.testing.expectEqual(@as(i128, 8), try globalInt(m, "SP"));
    try std.testing.expectEqual(@as(i128, 16), try globalInt(m, "SA"));
}

test "e2e: #run enum match folds to a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\Dir :: enum { north, south, east, west }
        \\rank :: fn(d: Dir) -> i32 {
        \\    match d {
        \\        .north => return 1;
        \\        .south => return 2;
        \\        .east  => return 3;
        \\        .west  => return 4;
        \\        else   => return 0;
        \\    }
        \\}
        \\R :: #run rank(Dir.east);
    ;
    var fe = try fels.compile(a, "enum.fels", src);
    defer fe.deinit(a);
    const m = try fels.lowerFrontend(a, fe);
    try std.testing.expectEqual(@as(i128, 3), try globalInt(m, "R"));
}

test "e2e: #run optionals (?? coalesce and !! unwrap)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\some_or :: fn() -> i32 {
        \\    x: ?i32 = 5;
        \\    return x ?? 99;
        \\}
        \\none_or :: fn() -> i32 {
        \\    x: ?i32 = null;
        \\    return x ?? 99;
        \\}
        \\unwrapped :: fn() -> i32 {
        \\    x: ?i32 = 7;
        \\    return x!!;
        \\}
        \\SOME :: #run some_or();
        \\NONE :: #run none_or();
        \\UNW  :: #run unwrapped();
    ;
    var fe = try fels.compile(a, "opt.fels", src);
    defer fe.deinit(a);
    const m = try fels.lowerFrontend(a, fe);
    try std.testing.expectEqual(@as(i128, 5), try globalInt(m, "SOME"));
    try std.testing.expectEqual(@as(i128, 99), try globalInt(m, "NONE"));
    try std.testing.expectEqual(@as(i128, 7), try globalInt(m, "UNW"));
}

test "e2e: #run interface dynamic dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\Shape :: interface { area :: fn(self: *Self) -> i32; }
        \\Square :: struct { side: i32 }
        \\Square as Shape {
        \\    area :: fn(self: *Self) -> i32 { return self.side * self.side; }
        \\}
        \\compute :: fn(s: *Shape) -> i32 { return s.area(); }
        \\go :: fn() -> i32 {
        \\    sq: Square = .{ 5 };
        \\    s: *Shape = &sq;
        \\    return compute(s);
        \\}
        \\AREA :: #run go();
    ;
    var fe = try fels.compile(a, "iface.fels", src);
    defer fe.deinit(a);
    const m = try fels.lowerFrontend(a, fe);
    try std.testing.expectEqual(@as(i128, 25), try globalInt(m, "AREA"));
}

test "e2e: #run fallible with catch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\NetError :: errors { boom }
        \\risky :: fn(x: i32) -> i32 ! NetError {
        \\    if x < 0 {
        \\        fail .boom;
        \\    }
        \\    return x * 2;
        \\}
        \\safe :: fn(x: i32) -> i32 {
        \\    data := risky(x) catch e {
        \\        return -1;
        \\    };
        \\    return data;
        \\}
        \\OKV :: #run safe(5);
        \\BADV :: #run safe(-3);
    ;
    var fe = try fels.compile(a, "fallible.fels", src);
    defer fe.deinit(a);
    const m = try fels.lowerFrontend(a, fe);
    try std.testing.expectEqual(@as(i128, 10), try globalInt(m, "OKV"));
    try std.testing.expectEqual(@as(i128, -1), try globalInt(m, "BADV"));
}

test "e2e: #run a catch that yields a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\Oops :: errors { a, b }
        \\num :: fn(n: i32) -> i32 ! Oops { if n < 0 { fail .a; } if n > 100 { fail .b; } return n * 2; }
        \\calc :: fn() -> i32 {
        \\    v := num(-1) catch e { yield 7; };
        \\    u := num(500) catch e { if e == .a { yield 1; } else { yield 2; } };
        \\    w := num(3) catch e { yield 0; };
        \\    s := 0;
        \\    for i in 0..3 { s += num(i - 1) catch e { for j in 0..10 { if j == 4 { yield j; } } yield 50; }; }
        \\    return v * 1000 + u * 100 + w * 10 + s;
        \\}
        \\X :: #run calc();
    ;
    var fe = try fels.compile(a, "yield_vm.fels", src);
    defer fe.deinit(a);
    const m = try fels.lowerFrontend(a, fe);
    try std.testing.expectEqual(@as(i128, 7266), try globalInt(m, "X"));
}

test "e2e: #run compares errors held in parameters, fields and copies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\E :: errors { first, second, third }
        \\Box :: struct { err: E, n: i32 }
        \\num :: fn(n: i32) -> i32 ! E { if n < 0 { fail .second; } if n > 9 { fail .third; } return n; }
        \\code :: fn(e: E) -> i32 { if e == .first { return 1; } if e == .second { return 2; } return 3; }
        \\give :: fn(n: i32) -> E { if n == 0 { return .first; } return .third; }
        \\calc :: fn() -> i32 {
        \\    v := num(-1) catch e { b: Box = .{ e, 3 }; k := b.err; yield code(k) * 100; };
        \\    return v + code(give(0)) * 10 + code(give(1));
        \\}
        \\X :: #run calc();
    ;
    var fe = try fels.compile(a, "error_compare_vm.fels", src);
    defer fe.deinit(a);
    const m = try fels.lowerFrontend(a, fe);
    try std.testing.expectEqual(@as(i128, 213), try globalInt(m, "X"));
}

test "e2e: #run passes a fallible on with return inner()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The VM wrapped the callee's fallible as the success value, so the caller read a fallible
    // where its value goes and the `#run` could not be evaluated.
    const src =
        \\E :: errors { bad }
        \\inner :: fn(k: i32) -> i32 ! E { if k == 1 { fail .bad; } return k; }
        \\forward :: fn(k: i32) -> i32 ! E { return inner(k); }
        \\loose :: fn(k: i32) -> i32 ! { return forward(k); }
        \\calc :: fn() -> i32 { return (forward(3) ?? 0) + (forward(1) ?? 50) + (loose(1) catch e { yield if e == .bad { 400 } else { 0 }; }); }
        \\X :: #run calc();
    ;
    var fe = try fels.compile(a, "tail_forward_vm.fels", src);
    defer fe.deinit(a);
    const m = try fels.lowerFrontend(a, fe);
    try std.testing.expectEqual(@as(i128, 453), try globalInt(m, "X"));
}

test "e2e: #run reads an error's payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\PE :: errors { plain, big: i64, word: []const u8 }
        \\Holder :: struct { tag: i32, err: PE }
        \\nothing :: fn(k: i32) -> void ! PE { if k == 1 { fail .big(77i64); } }
        \\inner :: fn(k: i32) -> i32 ! PE { if k == 1 { fail .word("abcd"); } if k == 2 { fail .big(9i64); } return k; }
        \\twice :: fn(k: i32) -> i32 ! PE { v := inner(k)?; return v * 2; }
        \\size :: fn(e: PE) -> i64 { return match e { .big |n| => n, .word |s| => s.len as i64, .plain => 0i64 }; }
        \\calc :: fn() -> i64 {
        \\    t := 0i64;
        \\    nothing(1) catch e { if e == .big |n| { t += n; } };
        \\    a := twice(1) catch e { yield size(e) as i32; };
        \\    holder: Holder = .{ 1, .plain };
        \\    b := twice(2) catch e { holder.err = e; yield 0; };
        \\    return t + a as i64 * 100i64 + size(holder.err) * 10000i64;
        \\}
        \\X :: #run calc();
    ;
    var fe = try fels.compile(a, "error_payload_vm.fels", src);
    defer fe.deinit(a);
    const m = try fels.lowerFrontend(a, fe);
    try std.testing.expectEqual(@as(i128, 77 + 400 + 90000), try globalInt(m, "X"));
}

test "e2e: float arithmetic" {
    const src =
        \\favg :: fn(a: f64, b: f64) -> f64 {
        \\    return (a + b) / 2.0;
        \\}
    ;
    const result = try runSource(src, "favg", &.{ .{ .float = 3.0 }, .{ .float = 5.0 } });
    try std.testing.expectEqual(@as(f64, 4.0), result.float);
}

test "e2e: float comparison" {
    const src =
        \\fmax :: fn(a: f64, b: f64) -> f64 {
        \\    if a > b {
        \\        return a;
        \\    }
        \\    return b;
        \\}
    ;
    const hi = try runSource(src, "fmax", &.{ .{ .float = 3.5 }, .{ .float = 2.25 } });
    try std.testing.expectEqual(@as(f64, 3.5), hi.float);
    const lo = try runSource(src, "fmax", &.{ .{ .float = 1.0 }, .{ .float = 9.0 } });
    try std.testing.expectEqual(@as(f64, 9.0), lo.float);
}

test "e2e: struct construct and field read" {
    const src =
        \\Point :: struct { x: i32, y: i32 }
        \\
        \\sum :: fn(a: i32, b: i32) -> i32 {
        \\    p: Point = .{ a, b };
        \\    return p.x + p.y;
        \\}
    ;
    const result = try runSource(src, "sum", &.{ .{ .int = 17 }, .{ .int = 25 } });
    try std.testing.expectEqual(@as(i128, 42), result.int);
}

test "e2e: struct field mutation" {
    const src =
        \\Point :: struct { x: i32, y: i32 }
        \\
        \\bump :: fn() -> i32 {
        \\    p: Point = .{ 1, 2 };
        \\    p.x = 10;
        \\    return p.x + p.y;
        \\}
    ;
    const result = try runSource(src, "bump", &.{});
    try std.testing.expectEqual(@as(i128, 12), result.int);
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

test "e2e: array indexing in a loop" {
    const src =
        \\asum :: fn() -> i32 {
        \\    arr: [3]i32 = .{ 5, 7, 9 };
        \\    total := 0;
        \\    i := 0;
        \\    while i < 3 {
        \\        total = total + arr[i];
        \\        i = i + 1;
        \\    }
        \\    return total;
        \\}
    ;
    const result = try runSource(src, "asum", &.{});
    try std.testing.expectEqual(@as(i128, 21), result.int);
}

test "e2e: array length" {
    const src =
        \\alen :: fn() -> i32 {
        \\    arr: [5]i32 = .{ 1, 2, 3, 4, 5 };
        \\    return arr.len as i32;
        \\}
    ;
    const result = try runSource(src, "alen", &.{});
    try std.testing.expectEqual(@as(i128, 5), result.int);
}

test "e2e: slice of an array (index + len)" {
    const src =
        \\ssum :: fn() -> i32 {
        \\    arr: [4]i32 = .{ 1, 2, 3, 4 };
        \\    s: []i32 = arr[1..3];
        \\    return s[0] + s[1] + (s.len as i32);
        \\}
    ;
    // s = {2, 3}; 2 + 3 + len(2) = 7
    const result = try runSource(src, "ssum", &.{});
    try std.testing.expectEqual(@as(i128, 7), result.int);
}
