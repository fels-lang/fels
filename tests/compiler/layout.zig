const std = @import("std");
const fels = @import("fels_compiler");

// `core::align_of`, `core::offset_of` and `#assert`. The expected numbers below were
// checked against clang's layout for x86_64-pc-windows-msvc (`_Alignof`,
// `__builtin_offsetof`, `sizeof` on the equivalent C structs), not worked out by hand.

/// Compile and lower `src` (type-check, then fold constants and evaluate `#assert`s).
fn lower(allocator: std.mem.Allocator, src: []const u8) !void {
    var fe = try fels.compile(allocator, "layout.fels", src);
    defer fe.deinit(allocator);
    _ = try fels.lowerFrontend(allocator, fe);
}

const structs =
    \\Plain :: struct { a: u8, b: u32, c: u64, d: u16 }
    \\#packed
    \\Pk :: struct { a: u8, b: u32, c: u64, d: u16 }
    \\#align(16)
    \\Al :: struct { a: u32 }
    \\Nested :: struct { x: u8, p: Plain, y: u8 }
    \\Mixed :: struct { tag: u8, items: [3]u32, tail: u16, f: f64, flag: bool, ptr: *u8 }
    \\WithAl :: struct { a: u8, al: Al, z: u8 }
    \\
;

test "layout: align_of and offset_of agree with C" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const checks =
        \\#assert(core::align_of(Plain) == 8);
        \\#assert(core::align_of(Pk) == 1);
        \\#assert(core::align_of(Al) == 16);
        \\#assert(core::align_of(u16) == 2);
        \\#assert(core::align_of(f64) == 8);
        \\#assert(core::offset_of(Plain, "a") == 0);
        \\#assert(core::offset_of(Plain, "b") == 4);
        \\#assert(core::offset_of(Plain, "c") == 8);
        \\#assert(core::offset_of(Plain, "d") == 16);
        \\#assert(core::offset_of(Pk, "b") == 1);
        \\#assert(core::offset_of(Pk, "c") == 5);
        \\#assert(core::offset_of(Pk, "d") == 13);
        \\#assert(core::offset_of(Nested, "p") == 8);
        \\#assert(core::offset_of(Nested, "y") == 32);
        \\#assert(core::offset_of(Mixed, "items") == 4);
        \\#assert(core::offset_of(Mixed, "tail") == 16);
        \\#assert(core::offset_of(Mixed, "f") == 24);
        \\#assert(core::offset_of(Mixed, "flag") == 32);
        \\#assert(core::offset_of(Mixed, "ptr") == 40);
        \\#assert(core::offset_of(WithAl, "al") == 16);
        \\#assert(core::offset_of(WithAl, "z") == 32);
        \\#assert(core::sizeof(WithAl) == 48);
        \\#assert(core::sizeof(Mixed) == 48);
    ;
    const src = try std.mem.concat(arena.allocator(), u8, &.{ structs, checks });
    try lower(arena.allocator(), src);
}

test "layout: a constant defined by a layout query is a real value, even inside #run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Constants defined from `core::sizeof` used to be baked as zero in the module the
    // comptime VM reads, so any `#run` or `#assert` that named one saw 0.
    const src = try std.mem.concat(arena.allocator(), u8, &.{ structs,
        \\SIZE :: core::sizeof(Plain);
        \\OFF  :: core::offset_of(Plain, "d");
        \\ALN  :: core::align_of(Plain);
        \\TOTAL :: #run SIZE + OFF + ALN;
        \\#assert(SIZE == 24);
        \\#assert(OFF == 16);
        \\#assert(ALN == 8);
        \\#assert(TOTAL == 48, "constants defined by layout queries fold through #run");
    });
    try lower(arena.allocator(), src);
}

test "layout: distinct types and aliases are measured as what they are stored as" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try lower(arena.allocator(),
        \\Handle :: distinct u64;
        \\Small :: i16;
        \\S :: struct { x: u8, h: Handle, s: Small }
        \\#assert(core::align_of(Handle) == 8);
        \\#assert(core::align_of(Small) == 2);
        \\#assert(core::offset_of(S, "s") == 16);
        \\#assert(core::sizeof(S) == 24);
    );
}

test "layout: a byte takes one byte, alone, in an array and in a struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try lower(arena.allocator(),
        \\B :: struct { a: byte, b: byte, n: u16 }
        \\#assert(core::sizeof(byte) == 1);
        \\#assert(core::align_of(byte) == 1);
        \\#assert(core::sizeof([4]byte) == 4);
        \\#assert(core::offset_of(B, "b") == 1);
        \\#assert(core::sizeof(B) == 4);
    );
}

test "layout: #assert fails the build when its condition is false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // With and without a message; both must stop the build.
    const failing = [_][]const u8{
        "#assert(core::sizeof(Plain) == 5, \"Plain must be 5 bytes\");",
        "#assert(core::offset_of(Plain, \"b\") == 1);",
        "#assert(core::align_of(Plain) == 4);",
        "N :: 3;\n#assert(N * 2 == 7);",
    };
    for (failing) |assertion| {
        const src = try std.mem.concat(arena.allocator(), u8, &.{ structs, assertion, "\n" });
        try std.testing.expectError(error.LoweringFailed, lower(arena.allocator(), src));
    }
}

test "layout: #assert needs a bool and a compile-time value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A non-bool condition is a type error, caught while type-checking.
    {
        const src = try std.mem.concat(arena.allocator(), u8, &.{ structs, "#assert(core::sizeof(Plain));\n" });
        try std.testing.expectError(error.SemanticFailed, fels.compile(arena.allocator(), "layout.fels", src));
    }
    // A condition that needs the host (here a call into kernel32) cannot be folded: a
    // pure compile-time evaluation has no host access.
    {
        const src = try std.mem.concat(arena.allocator(), u8, &.{ structs,
            \\#extern("kernel32", "GetTickCount")
            \\GetTickCount :: fn() -> u32;
            \\#assert(GetTickCount() > 0);
        });
        try std.testing.expectError(error.LoweringFailed, lower(arena.allocator(), src));
    }
}

test "layout: invalid layout queries are diagnosed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const invalid = [_][]const u8{
        "X :: core::offset_of(Plain, \"nope\");", // no such field
        "X :: core::offset_of(u32, \"a\");", // not a struct
        "n :: \"b\";\nX :: core::offset_of(Plain, n);", // field is not a literal
        "X :: core::offset_of(Plain);", // wrong arity
        "X :: core::align_of(u8, u8);", // wrong arity
        "X :: offset_of(Plain, \"a\");", // bare builtin
        "O :: opaque;\nX :: core::align_of(O);", // unsized
        "E :: enum { a, b }\nX :: core::align_of(E);", // enum layout is not guaranteed
    };
    for (invalid) |decl| {
        const src = try std.mem.concat(arena.allocator(), u8, &.{ structs, decl, "\n" });
        try std.testing.expectError(error.SemanticFailed, fels.compile(arena.allocator(), "layout.fels", src));
    }
}
