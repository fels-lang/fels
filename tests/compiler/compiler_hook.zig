const std = @import("std");
const k2 = @import("k2_compiler");

// Phase 3 — the `#compiler` message loop. A `#compiler` hook is a function the
// compiler runs at compile time; its returned `[]const u8` is parsed as
// top-level K2 declarations and added to the program. `compiler_decls()` lets a
// hook INSPECT the program (every top-level decl's name + kind) and generate
// code conditionally. These are the headline capabilities `#insert` (a
// statement-only splice) cannot provide.

fn hasFunction(m: anytype, name: []const u8) bool {
    for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

test "compiler-hook: generated top-level declaration is added to the module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `generate` runs at compile time and returns source for a new top-level
    // function `doubled`, which `main` then calls.
    const src =
        \\#compiler generate :: fn() -> []const u8 {
        \\    return "doubled :: fn(x: i32) -> i32 { return x * 2; }";
        \\}
        \\main :: fn() -> i32 { return doubled(21); }
    ;
    var fe = try k2.compile(a, "hook_gen.k2", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);

    // The generated `doubled` must exist as a real lowered function.
    try std.testing.expect(hasFunction(m, "doubled"));
    try std.testing.expect(hasFunction(m, "main"));
}

test "compiler-hook: compiler_decls() inspection drives conditional generation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The hook walks `compiler_decls()` and only emits the real `answer` (the
    // one a passing program needs) because a `struct` declaration is present.
    // Exercises: slice-of-struct iteration, `[]const u8` field reads, comptime
    // string compare (`.len` + byte indexing on host strings), and conditional
    // declaration generation.
    const src =
        \\Point :: struct { x: i32, y: i32 }
        \\streq :: fn(p: []const u8, q: []const u8) -> bool {
        \\    if p.len != q.len { return false; }
        \\    for i in 0..p.len {
        \\        if p[i] != q[i] { return false; }
        \\    }
        \\    return true;
        \\}
        \\#compiler gen :: fn() -> []const u8 {
        \\    for d in compiler_decls() {
        \\        if streq(d.kind, "struct") {
        \\            return "answer :: fn() -> i32 { return 42; }";
        \\        }
        \\    }
        \\    return "answer :: fn() -> i32 { return 0; }";
        \\}
        \\main :: fn() -> i32 { return answer(); }
    ;
    var fe = try k2.compile(a, "hook_inspect.k2", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);
    try std.testing.expect(hasFunction(m, "answer"));
}

test "compiler-hook: no hook means no compiler-prelude injection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A program with no `#compiler` hook must compile unchanged — `Decl` and the
    // hook pass are only introduced when a hook is present.
    const src =
        \\main :: fn() -> i32 { return 7; }
    ;
    var fe = try k2.compile(a, "no_hook.k2", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);
    try std.testing.expect(!hasFunction(m, "Decl"));
    try std.testing.expect(hasFunction(m, "main"));
}
