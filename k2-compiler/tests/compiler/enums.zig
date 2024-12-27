const std = @import("std");
const k2  = @import("k2_compiler");

test "enum: simple declaration and value access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Direction :: enum { north, south, east, west }
        \\
        \\go :: fn(d: Direction) -> i32 {
        \\    match d {
        \\        .north => return 1;
        \\        .south => return 2;
        \\        .east  => return 3;
        \\        .west  => return 4;
        \\        else   => return 0;
        \\    }
        \\}
        \\
        \\use :: fn() -> i32 {
        \\    return go(Direction.north);
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "enum.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    // The enum should appear in module.variants
    try std.testing.expectEqual(@as(usize, 1), m.variants.len);
    try std.testing.expectEqualStrings("Direction", m.variants[0].name);
    try std.testing.expectEqual(@as(usize, 4), m.variants[0].variants.len);

    // There should be a variant_lit instruction somewhere in `use`
    const use_fn = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "use")) break f;
    } else return error.FunctionNotFound;

    var found_variant_lit = false;
    for (use_fn.blocks) |block| {
        for (block.instrs) |instr| switch (instr.kind) {
            .variant_lit => |vl| {
                found_variant_lit = true;
                try std.testing.expectEqualStrings("Direction", vl.type_name);
                try std.testing.expectEqualStrings("north",     vl.variant);
            },
            else => {},
        };
    }
    try std.testing.expect(found_variant_lit);
}

test "enum: match generates variant_is instructions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Color :: enum { red, green, blue }
        \\
        \\name :: fn(c: Color) -> i32 {
        \\    match c {
        \\        .red   => return 0;
        \\        .green => return 1;
        \\        .blue  => return 2;
        \\        else   => return 3;
        \\    }
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "color.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "name")) break f;
    } else return error.FunctionNotFound;

    var variant_is_count: usize = 0;
    for (fn_.blocks) |block| {
        for (block.instrs) |instr| switch (instr.kind) {
            .variant_is => |vi| {
                variant_is_count += 1;
                try std.testing.expectEqualStrings("Color", vi.type_name);
            },
            else => {},
        };
    }
    // 3 non-else arms → 3 variant_is checks
    try std.testing.expectEqual(@as(usize, 3), variant_is_count);
}

test "enum: payload variant with binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Msg :: enum { quit, value: i32 }
        \\
        \\process :: fn(m: Msg) -> i32 {
        \\    match m {
        \\        .value |v| => return v;
        \\        else       => return 0;
        \\    }
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "msg.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    // Enum with payload should be in variants
    try std.testing.expectEqual(@as(usize, 1), m.variants.len);
    try std.testing.expectEqualStrings("Msg", m.variants[0].name);
    try std.testing.expect(m.variants[0].variants[1].payload != null); // value has i32 payload
}

test "function pointers: declare, pass, and call through local" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\double :: fn(x: i32) -> i32 { return x * 2; }
        \\
        \\apply :: fn(f: fn(i32) -> i32, x: i32) -> i32 {
        \\    return f(x);
        \\}
        \\
        \\use_apply :: fn() -> i32 {
        \\    return apply(double, 21);
        \\}
        \\
        \\call_local :: fn(f: fn(i32) -> i32, n: i32) -> i32 {
        \\    return f(n);
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "fnptr.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}

test "self-referencing type: linked list node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Node :: struct {
        \\    value: i32,
        \\    next:  ?*Node,
        \\}
        \\
        \\node_value :: fn(n: *Node) -> i32 {
        \\    return n.value;
        \\}
        \\
        \\has_next :: fn(n: *Node) -> bool {
        \\    if next := n.next {
        \\        return true;
        \\    }
        \\    return false;
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "linked.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    // Node struct should appear in IR
    var found_node = false;
    for (m.structs) |s| {
        if (std.mem.eql(u8, s.name, "Node")) {
            found_node = true;
            try std.testing.expectEqual(@as(usize, 2), s.fields.len); // value + next
        }
    }
    try std.testing.expect(found_node);
}

test "enum: unknown variant in match fails sema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\Dir :: enum { north, south }
        \\bad :: fn(d: Dir) -> i32 {
        \\    match d { .east => return 1; else => return 0; }
        \\}
    ;
    try std.testing.expectError(error.SemanticFailed,
        k2.compile(arena.allocator(), "bad.k2", bad));
}

test "enum: match subject must be enum type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\bad :: fn(x: i32) -> i32 {
        \\    match x { .foo => return 1; else => return 0; }
        \\}
    ;
    try std.testing.expectError(error.SemanticFailed,
        k2.compile(arena.allocator(), "bad.k2", bad));
}
