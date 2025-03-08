const std = @import("std");
const k2 = @import("k2_compiler");

test "generic function: inferred $T, monomorphized to i32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\min :: fn(a: $T, b: T) -> T {
        \\    if a < b { return a; }
        \\    return b;
        \\}
        \\
        \\use_min :: fn() -> i32 {
        \\    x := min(3, 7);
        \\    y := min(10, 2);
        \\    return x - y;
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "generics.k2", src);
    defer fe.deinit(arena.allocator());

    // Both calls use i32 — only one instantiation
    try std.testing.expectEqual(@as(usize, 1), fe.types.generic_instantiations.items.len);
    try std.testing.expectEqualStrings("min__T_i32", fe.types.generic_instantiations.items[0].mangled_name);

    const module = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(module);

    var found = false;
    for (module.functions) |f| {
        if (std.mem.eql(u8, f.name, "min__T_i32")) found = true;
    }
    try std.testing.expect(found);
}

test "generic function: two separate instantiations produce two IR functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\identity :: fn(x: $T) -> T { return x; }
        \\
        \\use_identity :: fn() -> bool {
        \\    a := identity(42);
        \\    b := identity(true);
        \\    return b;
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "generics2.k2", src);
    defer fe.deinit(arena.allocator());

    try std.testing.expectEqual(@as(usize, 2), fe.types.generic_instantiations.items.len);

    const module = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(module);

    var found_i32 = false;
    var found_bool = false;
    for (module.functions) |f| {
        if (std.mem.eql(u8, f.name, "identity__T_i32"))  found_i32  = true;
        if (std.mem.eql(u8, f.name, "identity__T_bool")) found_bool = true;
    }
    try std.testing.expect(found_i32);
    try std.testing.expect(found_bool);
}

test "generic function: same-type uses deduplicate to one instantiation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\id :: fn(x: $T) -> T { return x; }
        \\use :: fn() -> i32 {
        \\    a := id(1);
        \\    b := id(2);
        \\    return a + b;
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "dedup.k2", src);
    defer fe.deinit(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), fe.types.generic_instantiations.items.len);
}

test "generic function: two T params — second must match first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\eq_check :: fn(a: $T, b: T) -> bool { return a == b; }
        \\use :: fn() -> bool { return eq_check(1, 2); }
    ;
    var fe = try k2.compile(arena.allocator(), "eq.k2", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}

test "generic function: type mismatch between T params fails sema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\same :: fn(a: $T, b: T) -> bool { return a == b; }
        \\bad  :: fn() -> bool { return same(1, true); }
    ;
    try std.testing.expectError(
        error.SemanticFailed,
        k2.compile(arena.allocator(), "bad_generic.k2", bad),
    );
}

test "generic function: explicit $T: type param" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\zeroed :: fn($T: type) -> T {
        \\    x: T = .{};
        \\    return x;
        \\}
        \\
        \\use :: fn() -> i32 {
        \\    return zeroed(i32);
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "zeroed.k2", src);
    defer fe.deinit(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), fe.types.generic_instantiations.items.len);
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}
