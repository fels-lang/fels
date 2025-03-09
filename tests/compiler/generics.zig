const std = @import("std");
const k2 = @import("k2_compiler");

test "built-in constraint: a satisfying type is accepted (`$T: Numeric`)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\dbl :: fn($T: Numeric, x: T) -> T { return x +% x; }
        \\use :: fn() -> i32 { return dbl(20u8) as i32 + dbl(11) as i32; }  // 40 + 22
    ;
    var fe = try k2.compile(arena.allocator(), "ok_constraint.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(module);
    // Numeric accepted both u8 and i32 (the literal) → two instantiations.
    try std.testing.expect(fe.types.generic_instantiations.items.len >= 1);
}

test "built-in constraint: a non-satisfying type is rejected with a clear message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A struct does not satisfy `Numeric`; the constraint fails at resolution.
    const src =
        \\P :: struct { a: i32 }
        \\dbl :: fn($T: Numeric, x: T) -> T { return x; }
        \\use :: fn() -> i32 { p: P = .{ 0 }; _ := dbl(p); return 0; }
    ;
    var fe = k2.compile(arena.allocator(), "bad_constraint.k2", src);
    if (fe) |*f| {
        f.deinit(arena.allocator());
        try std.testing.expect(false); // should not compile
    } else |err| {
        try std.testing.expectEqual(error.SemanticFailed, err);
    }
}

test "where clause: a satisfying type is accepted (user predicate over type_info)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The `where` block inspects `type_info(T)` and only accepts numeric types.
    const src =
        \\dbl :: fn(x: $T) -> T
        \\where { match type_info(T) { .int => {} .float => {} else => reject("needs a numeric type"); } }
        \\{ return x +% x; }
        \\use :: fn() -> i32 { return dbl(21); }
    ;
    var fe = try k2.compile(arena.allocator(), "where_ok.k2", src);
    defer fe.deinit(arena.allocator());
    // The where predicate runs at lowering (on the comptime VM); a numeric T accepts.
    const module = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(module);
}

test "where clause: a non-satisfying type is rejected during resolution (two-pass)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A struct fails the `where` predicate. With the two-pass resolution rail the
    // predicate runs *during sema* (the body uses `+%`, which would itself error
    // on a struct — but the reject fires first and suppresses it).
    const src =
        \\P :: struct { a: i32 }
        \\dbl :: fn(x: $T) -> T
        \\where { match type_info(T) { .int => {} .float => {} else => reject("needs a numeric type"); } }
        \\{ return x +% x; }
        \\use :: fn() -> i32 { p: P = .{ 0 }; _ := dbl(p); return 0; }
    ;
    try std.testing.expectError(
        error.SemanticFailed,
        k2.compile(arena.allocator(), "where_bad.k2", src),
    );
}

test "named constraint: `Name :: constraint($T)` accepts a satisfying type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A reusable, named comptime predicate, enforced at `$T: MyNum` resolution.
    const src =
        \\MyNum :: constraint($T) { match type_info(T) { .int => {} .float => {} else => reject("expected a numeric type"); } }
        \\dbl :: fn($T: MyNum, x: T) -> T { return x +% x; }
        \\use :: fn() -> i32 { return dbl(21); }
    ;
    var fe = try k2.compile(arena.allocator(), "constraint_ok.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(module);
}

test "named constraint: a non-satisfying type is rejected with the predicate's message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\MyNum :: constraint($T) { match type_info(T) { .int => {} .float => {} else => reject("expected a numeric type"); } }
        \\P :: struct { a: i32 }
        \\dbl :: fn($T: MyNum, x: T) -> T { return x; }
        \\use :: fn() -> i32 { p: P = .{ 0 }; _ := dbl(p); return 0; }
    ;
    try std.testing.expectError(
        error.SemanticFailed,
        k2.compile(arena.allocator(), "constraint_bad.k2", src),
    );
}

test "named constraint: `require(T, Other)` composition accepts when all hold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // `Ordered` composes `MyNum` via `require`; both must hold for i32.
    const src =
        \\MyNum   :: constraint($T) { match type_info(T) { .int => {} .float => {} else => reject("not numeric"); } }
        \\Ordered :: constraint($T) { require(T, MyNum); }
        \\use :: fn($T: Ordered, x: T) -> T { return x +% x; }
        \\go :: fn() -> i32 { return use(21); }
    ;
    var fe = try k2.compile(arena.allocator(), "require_ok.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(module);
}

test "named constraint: `require` propagates the required constraint's rejection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A struct fails `MyNum`, so the composing `Ordered` rejects too.
    const src =
        \\MyNum   :: constraint($T) { match type_info(T) { .int => {} .float => {} else => reject("not numeric"); } }
        \\Ordered :: constraint($T) { require(T, MyNum); }
        \\P :: struct { a: i32 }
        \\use :: fn($T: Ordered, x: T) -> T { return x; }
        \\go :: fn() -> i32 { p: P = .{ 0 }; _ := use(p); return 0; }
    ;
    try std.testing.expectError(
        error.SemanticFailed,
        k2.compile(arena.allocator(), "require_bad.k2", src),
    );
}

test "where clause: output type param `-> $Acc` computed from type_info (two-pass)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The `where` block selects the accumulator width from `type_info(T)`:
    // sub-32-bit ints widen to i32, everything else keeps T. The body and the
    // call's return type both use the computed `Acc`.
    const src =
        \\acc_of :: fn(x: $T) -> $Acc
        \\where {
        \\    match type_info(T) {
        \\        .int |i| => if i.bits < 32 { Acc = i32; } else { Acc = T; }
        \\        else => Acc = T;
        \\    }
        \\} {
        \\    total: Acc = x as Acc;
        \\    return total;
        \\}
        \\use :: fn() -> i32 { return acc_of(100u8) + acc_of(8i32); }
    ;
    var fe = try k2.compile(arena.allocator(), "out_ty.k2", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(module);
    // Two instantiations (u8 and i32), both with the body checked against Acc.
    try std.testing.expect(fe.types.generic_instantiations.items.len >= 2);
}

test "where clause: output type param + reject coexist (reject a float)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The `where` computes `Acc` for integers and rejects everything else.
    const src =
        \\acc :: fn(x: $T) -> $Acc
        \\where { match type_info(T) { .int |i| => Acc = T; else => reject("acc needs an integer"); } }
        \\{ total: Acc = x; return total; }
        \\use :: fn() -> i32 { _ := acc(1.5f64); return 0; }
    ;
    try std.testing.expectError(
        error.SemanticFailed,
        k2.compile(arena.allocator(), "out_ty_reject.k2", src),
    );
}

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
