const std = @import("std");
const fels = @import("fels_compiler");

// Static storage: `NAME: T = <initialiser>;` at the top level. The initialiser is data in the
// image — a constant, a `.{ ... }` of constants, the address of a function, or the address of
// another global — and nothing runs at startup to put it there. These tests look at what
// reaches LLVM and at what is refused; `exe_integration.zig` runs the fixture
// `tests/fixtures/lang/static_data_app.fels` and loads a DLL exporting such globals.

/// Type-check `src`, lower it, and return the LLVM IR text.
fn irText(allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    var fe = try fels.compile(allocator, "static_data.fels", src);
    defer fe.deinit(allocator);
    const module = try fels.lowerFrontend(allocator, fe);
    var backend = fels.LlvmBackend.init(allocator, "static_data");
    defer backend.deinit();
    try backend.lower(module);
    return backend.getIrText(allocator);
}

fn expectIrHas(ir: []const u8, expected: []const u8) !void {
    if (std.mem.indexOf(u8, ir, expected) == null) {
        std.debug.print("\nexpected the LLVM IR to contain:\n  {s}\n", .{expected});
        return error.TestExpectedEqual;
    }
}

fn expectIrLacks(ir: []const u8, unexpected: []const u8) !void {
    if (std.mem.indexOf(u8, ir, unexpected) != null) {
        std.debug.print("\nexpected the LLVM IR not to contain:\n  {s}\n", .{unexpected});
        return error.TestUnexpectedResult;
    }
}

const decls =
    \\Point :: struct { x: i32, y: i32 }
    \\Cfg :: struct { name: []const u8, retries: i32 = 3, verbose: bool = false, limit: u64 }
    \\Vtbl :: struct { add: extern fn(i32, i32) -> i32, id: u32 }
    \\Mode :: enum { fast, slow, off }
    \\Shape :: enum { circle: i32, none }
    \\Settings :: struct { mode: Mode = .slow, n: i32 = 4 }
    \\add :: fn(a: i32, b: i32) -> i32 { return a + b; }
    \\dbl :: fn(x: i32) -> i32 { return x * 2; }
    \\
;

test "static data: initialisers reach LLVM as constants, and nothing runs at startup" {
    if (comptime !fels.llvm_enabled) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = try std.mem.concat(arena.allocator(), u8, &.{ decls,
        \\ORIGIN: Point = .{ 3, 4 };
        \\CFG: Cfg = .{ .name = "build", .limit = 9u64 };
        \\PRIMES: [3]u32 = .{ 2u32, 3u32 };
        \\VT: Vtbl = .{ add, 7u32 };
        \\TBL: [2]extern fn(i32) -> i32 = .{ dbl, dbl };
        \\PTR: *Point = &ORIGIN;
        \\NOPE: ?*Point = null;
        \\MODE: Mode = .slow;
        \\SHAPE: Shape = .none;
        \\main :: fn() -> i32 { return ORIGIN.x + VT.add(1, 2); }
    });
    const ir = try irText(arena.allocator(), src);
    try expectIrHas(ir, "@ORIGIN = global %Point { i32 3, i32 4 }");
    // A field omitted from a named literal takes its default; the string's bytes are a constant.
    try expectIrHas(ir, "@CFG = global %Cfg { { ptr, i64 } { ptr @.str.0, i64 5 }, i32 3, i1 false, i64 9 }");
    // A literal that stops short is zero beyond its end.
    try expectIrHas(ir, "@PRIMES = global [3 x i32] [i32 2, i32 3, i32 0]");
    // A function's address is the function itself, in a field or an array; no closure, no thunk.
    try expectIrHas(ir, "@VT = global %Vtbl { ptr @add, i32 7 }");
    try expectIrHas(ir, "@TBL = global [2 x ptr] [ptr @dbl, ptr @dbl]");
    // The address of another global, and null.
    try expectIrHas(ir, "@PTR = global ptr @ORIGIN");
    try expectIrHas(ir, "@NOPE = global ptr null");
    // A payload-less enum is its discriminant; one with payloads keeps its payload bytes zero.
    try expectIrHas(ir, "@MODE = global i32 1");
    try expectIrHas(ir, "@SHAPE = global %Shape.enum { i32 1, [4 x i8] zeroinitializer }");
    // Nothing stores to them to set them up: no initialiser function, no store in `main`.
    try expectIrLacks(ir, "store i32 3");
    try expectIrLacks(ir, "store ptr @add");
    try expectIrLacks(ir, "@llvm.global_ctors");
}

test "static data: an omitted field is read the way a local literal reads it" {
    if (comptime !fels.llvm_enabled) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = try std.mem.concat(arena.allocator(), u8, &.{ decls,
        \\Dflt :: struct { n: i32 = 4, m: i32 = 5, z: i32 }
        \\Gap :: struct { a: i32, b: i32 = 7, c: i32 = 8 }
        \\Wrap :: struct { c: Dflt, k: i32 = 3 }
        \\D_EMPTY: Dflt = .{};
        \\D_ONE: Dflt = .{ 1 };
        \\D_NAMED: Dflt = .{ .z = 9 };
        \\G_EMPTY: Gap = .{};
        \\G_ONE: Gap = .{ 1 };
        \\G_NAMED: Gap = .{ .a = 3 };
        \\W_EMPTY: Wrap = .{};
        \\W_INNER: Wrap = .{ .{}, 6 };
        \\S_EMPTY: Settings = .{};
        \\S_NAMED: Settings = .{ .mode = .off };
        \\ARR_EMPTY: [2]Dflt = .{};
        \\ARR_SHORT: [2]Dflt = .{ .{ .z = 1 } };
    });
    const ir = try irText(arena.allocator(), src);
    // Positional or empty: defaults up to the first field that has none, zero after that.
    try expectIrHas(ir, "@D_EMPTY = global %Dflt { i32 4, i32 5, i32 0 }");
    try expectIrHas(ir, "@D_ONE = global %Dflt { i32 1, i32 5, i32 0 }");
    try expectIrHas(ir, "@D_NAMED = global %Dflt { i32 4, i32 5, i32 9 }");
    // A defaulted field behind one with no default is not reached by a short positional literal.
    try expectIrHas(ir, "@G_EMPTY = global %Gap zeroinitializer");
    try expectIrHas(ir, "@G_ONE = global %Gap { i32 1, i32 7, i32 8 }");
    try expectIrHas(ir, "@G_NAMED = global %Gap { i32 3, i32 7, i32 8 }");
    try expectIrHas(ir, "@W_EMPTY = global %Wrap zeroinitializer");
    // ...but a literal that is itself a field's value is read on its own terms.
    try expectIrHas(ir, "@W_INNER = global %Wrap { %Dflt { i32 4, i32 5, i32 0 }, i32 6 }");
    // Enum-typed defaults.
    try expectIrHas(ir, "@S_EMPTY = global %Settings { i32 1, i32 4 }");
    try expectIrHas(ir, "@S_NAMED = global %Settings { i32 2, i32 4 }");
    // An array literal is zero past its end, element defaults do not apply.
    try expectIrHas(ir, "@ARR_EMPTY = global [2 x %Dflt] zeroinitializer");
    try expectIrHas(ir, "@ARR_SHORT = global [2 x %Dflt] [%Dflt { i32 4, i32 5, i32 1 }, %Dflt zeroinitializer]");
}

test "static data: #export makes a global a data export" {
    if (comptime !fels.llvm_enabled) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = try std.mem.concat(arena.allocator(), u8, &.{ decls,
        \\#export("gab_origin")
        \\ORIGIN: Point = .{ 1, 2 };
        \\#export
        \\bare_counter: i32 = 7;
        \\#export("gab_vt")
        \\VT: Vtbl = .{ add, 7u32 };
        \\#export("gab_limit")
        \\LIMIT :: 42;
        \\plain: i32 = 1;
    });
    const ir = try irText(arena.allocator(), src);
    // A named export is renamed; a bare `#export` keeps the global's own name.
    try expectIrHas(ir, "@gab_origin = dllexport global %Point { i32 1, i32 2 }");
    try expectIrHas(ir, "@bare_counter = dllexport global i32 7");
    try expectIrHas(ir, "@gab_vt = dllexport global %Vtbl { ptr @add, i32 7 }");
    try expectIrHas(ir, "@gab_limit = dllexport constant i32 42");
    // An unexported global stays an ordinary one.
    try expectIrHas(ir, "@plain = global i32 1");
}

test "static data: a function pointer is called through a global, a field or a table element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fe = try fels.compile(arena.allocator(), "static_data.fels", decls ++
        \\ONE: extern fn(i32) -> i32 = dbl;
        \\VT: Vtbl = .{ add, 7u32 };
        \\T: [2]extern fn(i32) -> i32 = .{ dbl, dbl };
        \\pick :: fn(n: bool) -> fn(i32) -> i32 { return dbl; }
        \\run :: fn() -> i32 { return ONE(10) + VT.add(1, 2) + T[1](3) + pick(true)(4); }
    );
    fe.deinit(arena.allocator());
}

test "static data: a call has to match the function pointer's signature, and the callee has to be one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bad = [_][]const u8{
        "N: i32 = 3;\nrun :: fn() -> i32 { return N(1); }",
        "ONE: extern fn(i32) -> i32 = dbl;\nrun :: fn() -> i32 { return ONE(1, 2); }", // wrong arity
        "ONE: extern fn(i32) -> i32 = dbl;\nrun :: fn() -> i32 { return ONE(); }",
        "ONE: extern fn(i32) -> i32 = dbl;\nrun :: fn() -> i32 { return ONE(true); }", // wrong type
        // the same checks when the callee is a field or an element of a table
        "VT: Vtbl = .{ add, 7u32 };\nrun :: fn() -> i32 { return VT.add(1); }",
        "VT: Vtbl = .{ add, 7u32 };\nrun :: fn() -> i32 { return VT.add(1, true); }",
        "T: [2]extern fn(i32) -> i32 = .{ dbl, dbl };\nrun :: fn() -> i32 { return T[0](1, 2); }",
        "T: [2]extern fn(i32) -> i32 = .{ dbl, dbl };\nrun :: fn() -> i32 { return T[1](true); }",
        // a table of plain numbers is not callable
        "T: [2]i32 = .{ 1, 2 };\nrun :: fn() -> i32 { return T[0](1); }",
    };
    for (bad) |decl| {
        const src = try std.mem.concat(arena.allocator(), u8, &.{ decls, decl, "\n" });
        try std.testing.expectError(error.SemanticFailed, fels.compile(arena.allocator(), "static_data.fels", src));
    }
}

fn expectRefused(allocator: std.mem.Allocator, decl: []const u8) !void {
    const src = try std.mem.concat(allocator, u8, &.{
        decls,
        "local_counter: i32 = 1;\ngen :: fn($T: type, a: T) -> T { return a; }\n",
        decl,
        "\n",
    });
    // The front end already refuses it - the same check `fels check` runs - so nothing is lowered.
    if (fels.compile(allocator, "static_data.fels", src)) |fe_ok| {
        var fe = fe_ok;
        defer fe.deinit(allocator);
        std.debug.print("\nthis initialiser was accepted by the front end but should be refused:\n  {s}\n", .{decl});
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(error.SemanticFailed, err);
    }
}

test "static data: an initialiser that is not a constant is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const refused = [_][]const u8{
        // not a literal where one is needed
        "G: Point = add(1, 2);",
        "G: [2]i32 = 5;",
        "G: Cfg = \"x\";",
        // wrong value for the field or element
        "G: Point = .{ true, 1 };",
        "G: Point = .{ 1.5, 2 };",
        "G: Point = .{ \"x\", 2 };",
        "G: [2]Point = .{ .{ 1, 2 }, .{ 3, \"z\" } };",
        "G: [1]u32 = .{ -1 };",
        "G: [2]u8 = .{ 1, 300 };",
        "G: i8 = 128;",
        "G: bool = 1;",
        // field mistakes
        "G: Point = .{ 1, 2, 3 };",
        "G: Point = .{ .x = 1, .z = 3 };",
        "G: Point = .{ .x = 1, .x = 2, .y = 3 };",
        "G: Point = .{ .x = 1 };",
        "G: Cfg = .{ .name = \"a\" };",
        "G: [2]i32 = .{ 1, 2, 3 };",
        // optionals hold null in static storage, nothing else
        "G: ?i32 = 5;",
        // pointers: null, or the address of a global
        "G: *i32 = 5;",
        "G: *i32 = &(local_counter + 1);",
        "G: *Point = &ORIGIN_NOT_DECLARED;",
        // function pointers: a named, non-generic function
        "G: extern fn(i32) -> i32 = local_counter;",
        "G: extern fn(i32) -> i32 = gen;",
        "G: extern fn(i32) -> i32 = fn(x: i32) -> i32 { return x; };",
        "G: extern fn(i32) -> i32 = 0;",
        // enums: a payload-less variant, spelt out
        "G: Shape = .circle;",
        "G: Shape = Shape.circle(5);",
        "G: Mode = .nope;",
        "G: Mode = 1;",
        "G: Mode = Mode.nope;",
        "mk :: fn() -> Mode { return .off; }\nG: Mode = mk();",
        // a slice is a string literal or empty
        "G: []const u8 = 5;",
    };
    for (refused) |decl| try expectRefused(arena.allocator(), decl);
}

test "static data: a value only the comptime VM can compute is not refused by the front end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The check that `fels check` runs has no evaluator, so it cannot judge these: a `#run`, a
    // call in a constant. They pass the front end and are checked when the module is lowered.
    const accepted = [_][]const u8{
        "twice :: fn(x: i32) -> i32 { return x * 2; }\nG: i32 = #run twice(4);",
        "twice :: fn(x: i32) -> i32 { return x * 2; }\nP: Point = .{ #run twice(1), #run twice(2) };",
        "twice :: fn(x: i32) -> i32 { return x * 2; }\nA: [2]u8 = .{ #run twice(1), 3 };",
        "N :: 3;\nG: [4]i32 = .{ N, N * 2 };",
        "G: u64 = core::sizeof(Point) as u64;",
    };
    for (accepted) |decl| {
        const src = try std.mem.concat(arena.allocator(), u8, &.{ decls, decl, "\n" });
        var fe = fels.compile(arena.allocator(), "static_data.fels", src) catch |err| {
            std.debug.print("\nthe front end should accept:\n  {s}\n", .{decl});
            return err;
        };
        fe.deinit(arena.allocator());
    }
    // ...and a mistake in an initialiser that does need the VM still surfaces at lowering.
    const src = try std.mem.concat(arena.allocator(), u8, &.{ decls, "twice :: fn(x: i32) -> i32 { return x * 2; }\nG: u8 = #run twice(200);\n" });
    var fe = try fels.compile(arena.allocator(), "static_data.fels", src);
    defer fe.deinit(arena.allocator());
    try std.testing.expectError(error.LoweringFailed, fels.lowerFrontend(arena.allocator(), fe));
}

// Compile-time code reading static data. The comptime VM runs the IR the native backend lowers,
// and a global that is a struct, an array, an enum value or a function pointer is built the first
// time a run reads it. `tests/fixtures/lang/static_vm_app.fels` checks the values against the machine;
// these check what is accepted and what is refused.

/// Lower `src` (declarations + a `#assert`) and report whether lowering succeeded. A failing
/// `#assert`, an unreadable global and a refused write all come back as `LoweringFailed`.
fn lowers(allocator: std.mem.Allocator, src: []const u8) !bool {
    var fe = try fels.compile(allocator, "static_read.fels", src);
    defer fe.deinit(allocator);
    if (fels.lowerFrontend(allocator, fe)) |_| {
        return true;
    } else |err| {
        try std.testing.expectEqual(error.LoweringFailed, err);
        return false;
    }
}

const readable =
    \\Point :: struct { x: i32, y: i32 }
    \\Rec :: struct { id: u32, name: []const u8, pos: Point, tags: [3]u8, on: bool, scale: f64 }
    \\Mode :: enum { fast, slow, off }
    \\Vtbl :: struct { add: extern fn(i32, i32) -> i32, id: u32 }
    \\add :: fn(a: i32, b: i32) -> i32 { return a + b; }
    \\dbl :: fn(x: i32) -> i32 { return x * 2; }
    \\SQUARES: [4]u32 = .{ 0, 1, 4, 9 };
    \\ORIGIN: Point = .{ 3, 4 };
    \\RECS: [2]Rec = .{ .{ 1, "one", .{ 1, 2 }, .{ 7, 8, 9 }, true, 1.5 }, .{ 2, "two", .{ 3, 4 }, .{ 1, 2, 3 }, false, 2.5 } };
    \\MODES: [3]Mode = .{ .off, .fast, .slow };
    \\VT: Vtbl = .{ add, 7 };
    \\OPS: [2]fn(i32) -> i32 = .{ dbl, dbl };
    \\ZEROS: [8]u8 = .{};
    \\SHORT: [4]i32 = .{ 5, 6 };
    \\COUNT: i32 = 41;
    \\
;

test "static data: compile-time code reads a struct, an array, an enum and a function pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const holds = [_][]const u8{
        "#assert(SQUARES[3] == 9, \"element\");",
        "#assert(SQUARES.len == 4, \"length\");",
        "#assert(ORIGIN.x == 3 && ORIGIN.y == 4, \"fields\");",
        "#assert(RECS[1].pos.y == 4 && RECS[0].tags[2] == 9 && RECS[1].name.len == 3, \"nested fields\");",
        "#assert(RECS[0].on && !RECS[1].on && RECS[0].scale + RECS[1].scale == 4.0, \"bool and float fields\");",
        "#assert(MODES[0] == Mode.off && MODES[2] == Mode.slow && MODES[1] != Mode.slow, \"enum elements compare\");",
        "#assert(VT.add(20, 22) == 42 && VT.id == 7, \"a function pointer field\");",
        "#assert(OPS[1](4) == 8, \"a table of function pointers\");",
        "#assert(ZEROS[7] == 0 && ZEROS.len == 8, \"a zero-filled array\");",
        "#assert(SHORT[1] == 6 && SHORT[2] == 0 && SHORT[3] == 0, \"zero past the end of a short literal\");",
        "#assert(COUNT == 41, \"a scalar global reads its initial value\");",
        // through a function, a pointer, a copy
        "sum :: fn() -> u32 { s := 0u32; i := 0usize; while i < SQUARES.len { s += SQUARES[i]; i += 1; } return s; }\n#assert(sum() == 14, \"loop\");",
        "at :: fn() -> u32 { p := &SQUARES[2]; return *p; }\n#assert(at() == 4, \"address of an element\");",
        "copy :: fn() -> u32 { t := SQUARES; return t[3]; }\n#assert(copy() == 9, \"copy into a local\");",
        "origin :: fn() -> i32 { p := &ORIGIN; return p.x + p.y; }\n#assert(origin() == 7, \"address of a struct\");",
        "which :: fn(i: usize) -> i32 { match MODES[i] { .fast => { return 1; }, .slow => { return 2; }, .off => { return 3; }, } }\n#assert(which(0) == 3 && which(1) == 1 && which(2) == 2, \"match\");",
    };
    for (holds) |decl| {
        const src = try std.mem.concat(arena.allocator(), u8, &.{ readable, decl, "\nmain :: fn() -> i32 { return 0; }\n" });
        if (!try lowers(arena.allocator(), src)) {
            std.debug.print("\nthis should hold at compile time:\n  {s}\n", .{decl});
            return error.TestUnexpectedResult;
        }
    }
}

test "static data: an #assert over a table is really evaluated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The same shapes as above with a wrong value: the build has to fail, or the test above proves nothing.
    const wrong = [_][]const u8{
        "#assert(SQUARES[3] == 10, \"element\");",
        "#assert(ORIGIN.y == 5, \"field\");",
        "#assert(RECS[1].pos.y == 3, \"nested\");",
        "#assert(MODES[0] == Mode.slow, \"enum\");",
        "#assert(VT.add(20, 22) == 43, \"call through a field\");",
        "#assert(OPS[1](4) == 9, \"call through a table\");",
        "#assert(SHORT[2] == 1, \"zero fill\");",
    };
    for (wrong) |decl| {
        const src = try std.mem.concat(arena.allocator(), u8, &.{ readable, decl, "\nmain :: fn() -> i32 { return 0; }\n" });
        if (try lowers(arena.allocator(), src)) {
            std.debug.print("\nthis is false and should have failed the build:\n  {s}\n", .{decl});
            return error.TestUnexpectedResult;
        }
    }
}

test "static data: compile-time code cannot change a global" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A run sees the initial value that goes into the image; a write would never reach it. Writing
    // through an element, a field, a pointer, or a copy that aliases the table is refused, not
    // silently applied to a table the next read would then see altered.
    const refused = [_][]const u8{
        "poke :: fn() -> u32 { SQUARES[0] = 5; return SQUARES[0]; }\n#assert(poke() == 5, \"x\");",
        "poke :: fn() -> i32 { ORIGIN.x = 9; return ORIGIN.x; }\n#assert(poke() == 9, \"x\");",
        "poke :: fn() -> u32 { p := &SQUARES[1]; *p = 7; return SQUARES[1]; }\n#assert(poke() == 7, \"x\");",
        "poke :: fn() -> u32 { t := SQUARES; t[0] = 99; return SQUARES[0]; }\n#assert(poke() == 0, \"a copy of a table must not alias it\");",
        "poke :: fn() -> bool { RECS[0].on = false; return RECS[0].on; }\n#assert(!poke(), \"x\");",
        // a scalar global cannot be assigned either
        "poke :: fn() -> i32 { COUNT = 5; return COUNT; }\n#assert(poke() == 5, \"x\");",
    };
    for (refused) |decl| {
        const src = try std.mem.concat(arena.allocator(), u8, &.{ readable, decl, "\nmain :: fn() -> i32 { return 0; }\n" });
        if (try lowers(arena.allocator(), src)) {
            std.debug.print("\ncompile-time code should not be able to do this:\n  {s}\n", .{decl});
            return error.TestUnexpectedResult;
        }
    }
}

test "static data: a global that holds the address of another is not readable at compile time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Following `next` would need the other global built first, and `A` and `B` point at each
    // other. The run stops and says which global it could not read (a limitation, pinned here so
    // that lifting it is a deliberate change). The program itself is fine.
    const nodes =
        \\Node :: struct { v: i32, next: *Node }
        \\A: Node = .{ 1, &B };
        \\B: Node = .{ 2, &A };
        \\hop :: fn() -> i32 { return A.next.v; }
        \\
    ;
    const src_ct = try std.mem.concat(arena.allocator(), u8, &.{ nodes, "#assert(hop() == 2, \"x\");\nmain :: fn() -> i32 { return hop(); }\n" });
    try std.testing.expect(!try lowers(arena.allocator(), src_ct));
    const src_rt = try std.mem.concat(arena.allocator(), u8, &.{ nodes, "main :: fn() -> i32 { return hop(); }\n" });
    try std.testing.expect(try lowers(arena.allocator(), src_rt));
}

test "static data: a run that builds a table gives the image the table, once" {
    if (comptime !fels.llvm_enabled) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = try std.mem.concat(arena.allocator(), u8, &.{ decls,
        \\Table :: struct { name: []const u8, fns: [2]fn(i32) -> i32, mode: Mode, pos: Point }
        \\make_squares :: fn() -> [6]u32 {
        \\    t: [6]u32 = .{};
        \\    i := 0usize;
        \\    while i < 6 { t[i] = (i * i) as u32; i += 1; }
        \\    return t;
        \\}
        \\make_table :: fn() -> Table { return .{ "built", .{ dbl, dbl }, .off, .{ 5, 6 } }; }
        \\make_wide :: fn() -> [3]u32 {
        \\    x: u32 = 2463534242u32;
        \\    t: [3]u32 = .{};
        \\    i := 0usize;
        \\    while i < 3 {
        \\        x = x ^ (x << 13u32);
        \\        x = x ^ (x >> 17u32);
        \\        x = x ^ (x << 5u32);
        \\        t[i] = x;
        \\        i += 1;
        \\    }
        \\    return t;
        \\}
        \\SQUARES: [6]u32 = #run make_squares();
        \\TABLE: Table = #run make_table();
        \\XOR: [3]u32 = #run make_wide();
        \\SQ2 :: #run make_squares();
        \\main :: fn() -> i32 { return SQUARES[5] as i32 + TABLE.pos.y; }
    });
    const ir = try irText(arena.allocator(), src);
    // The results are constants in the image: no initialiser function runs, nothing stores them.
    try expectIrHas(ir, "@SQUARES = global [6 x i32] [i32 0, i32 1, i32 4, i32 9, i32 16, i32 25]");
    // A plain `fn` is the closure `{ thunk, null }`, in an array of them exactly as a literal writes it.
    try expectIrHas(ir, "@TABLE = global %Table { { ptr, i64 } { ptr @.str.0, i64 5 }, [2 x { ptr, ptr }] [{ ptr, ptr } { ptr @__thunk_dbl, ptr null }, { ptr, ptr } { ptr @__thunk_dbl, ptr null }], i32 2, %Point { i32 5, i32 6 } }");
    // The xorshift numbers are what the machine computes (a 32-bit shift drops the high bits); LLVM
    // prints an i32 signed, so the second one is 2497366906 - 2^32.
    try expectIrHas(ir, "@XOR = global [3 x i32] [i32 723471715, i32 -1797600390, i32 2064144800]");
    // An untyped `::` takes the type of the call and is a constant.
    try expectIrHas(ir, "@SQ2 = constant [6 x i32] [i32 0, i32 1, i32 4, i32 9, i32 16, i32 25]");
    try expectIrLacks(ir, "@llvm.global_ctors");
}

const qpc = struct {
    extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) i32;
    extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) i32;
};

test "static data: a run that fills a big array does not leave a slow function behind" {
    if (comptime !fels.llvm_enabled) return error.SkipZigTest;
    if (comptime @import("builtin").os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `fill` is only for the `#run`. The VM stores each element in O(1), and once the table is
    // data the function does not reach the code generator at all. (It once cost seconds there:
    // a 10000-element array returned as a value is split into one piece per element. Such a
    // return now goes through a hidden pointer, see `llvm_correctness.zig`.)
    const src =
        \\fill :: fn() -> [10000]u32 {
        \\    t: [10000]u32 = .{};
        \\    i: usize = 0usize;
        \\    while i < 10000usize { t[i] = (i * 3) as u32; i += 1usize; }
        \\    return t;
        \\}
        \\T: [10000]u32 = #run fill();
        \\main :: fn() -> i32 { return (T[100] as i32) - 300; }
    ;
    var t0: i64 = 0;
    var t1: i64 = 0;
    var freq: i64 = 1;
    _ = qpc.QueryPerformanceFrequency(&freq);
    _ = qpc.QueryPerformanceCounter(&t0);

    var fe = try fels.compile(arena.allocator(), "big_fill.fels", src);
    defer fe.deinit(arena.allocator());
    const module = try fels.lowerFrontend(arena.allocator(), fe);
    var backend = fels.LlvmBackend.init(arena.allocator(), "big_fill");
    defer backend.deinit();
    try backend.lower(module);
    try backend.emitObject(".zig-cache/big_fill_test.o", 2);
    const ir = try backend.getIrText(arena.allocator());

    _ = qpc.QueryPerformanceCounter(&t1);
    const ms = @divTrunc((t1 - t0) * 1000, freq);
    try expectIrHas(ir, "@T = global [10000 x i32] [i32 0, i32 3, i32 6");
    try expectIrLacks(ir, "@fill");
    if (ms > 5000) {
        std.debug.print("\nbuilding took {d} ms, expected well under 5000\n", .{ms});
        return error.TestUnexpectedResult;
    }
}
