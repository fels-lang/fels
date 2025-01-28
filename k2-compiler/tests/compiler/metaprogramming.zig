const std = @import("std");
const k2 = @import("k2_compiler");

// Phase 2, slice 1: literal `#quote` + `#insert`. The operand of `#insert`
// must be a `#quote { ... }` block; its statements are spliced into the
// enclosing scope and re-checked there. No `$` splice / `macro` yet.

test "metaprogram: #insert literal #quote lowers to valid IR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\run :: fn() -> i32 {
        \\    x := 5;
        \\    #insert #quote {
        \\        y := x + 100;
        \\        x = y;
        \\    };
        \\    return x;
        \\}
    ;
    var fe = try k2.compile(a, "mp1.k2", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);

    // The spliced statements land in `run` — there must be exactly one function
    // and it must have lowered (non-empty) blocks.
    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "run")) break f;
    } else return error.FunctionNotFound;
    try std.testing.expect(fn_.blocks.len > 0);
}

test "metaprogram: spliced locals are visible to following statements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `total` is introduced inside the quote and used AFTER the #insert — this
    // only type-checks if the splice lands in the enclosing scope, not a child.
    const src =
        \\run :: fn() -> i32 {
        \\    #insert #quote {
        \\        total := 7;
        \\    };
        \\    return total + 1;
        \\}
    ;
    var fe = try k2.compile(a, "mp2.k2", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);
}

test "metaprogram: block macro expands and lowers to valid IR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\twice :: macro(body: Code) -> Code {
        \\    return #quote { $body; $body; };
        \\}
        \\run :: fn() -> i32 {
        \\    n := 0;
        \\    #insert twice(#quote { n = n + 1; });
        \\    return n;
        \\}
    ;
    var fe = try k2.compile(a, "mac1.k2", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);

    // The macro decl must NOT survive into the lowered module.
    for (m.functions) |f| {
        try std.testing.expect(!std.mem.eql(u8, f.name, "twice"));
    }
}

test "metaprogram: #for unrolls and lowers to valid IR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\run :: fn() -> i32 {
        \\    total := 0;
        \\    #for i in 0..=3 {
        \\        total = total + $(i);
        \\    }
        \\    return total;
        \\}
    ;
    var fe = try k2.compile(a, "for1.k2", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);
}

test "metaprogram: #for with non-constant bounds is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\run :: fn(n: i32) -> i32 {
        \\    total := 0;
        \\    #for i in 0..n {
        \\        total = total + $(i);
        \\    }
        \\    return total;
        \\}
    ;
    try std.testing.expectError(error.SemanticFailed, k2.compile(a, "for2.k2", src));
}

test "metaprogram: macro with wrong argument count is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\one :: macro(x: Code) -> Code { return #quote { use($x); }; }
        \\run :: fn() {
        \\    #insert one(#quote(1), #quote(2));
        \\}
    ;
    try std.testing.expectError(error.SemanticFailed, k2.compile(a, "mac2.k2", src));
}

test "metaprogram: stray $ splice outside a macro is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\run :: fn() -> i32 {
        \\    return $x;
        \\}
    ;
    try std.testing.expectError(error.SemanticFailed, k2.compile(a, "mac3.k2", src));
}

test "metaprogram: non-quote #insert operand is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\run :: fn() -> i32 {
        \\    #insert 42;
        \\    return 0;
        \\}
    ;
    // Sema must reject: the operand is not a #quote block.
    try std.testing.expectError(error.SemanticFailed, k2.compile(a, "mp3.k2", src));
}
