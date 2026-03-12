const std = @import("std");
const fels = @import("fels_compiler");

test "diagnostics: return type mismatch shows types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\bad :: fn() -> i32 { return true; }
    ;
    const result = fels.compile(arena.allocator(), "bad.fels", bad);
    try std.testing.expectError(error.SemanticFailed, result);
}

test "diagnostics: returning a capturing closure is rejected (would dangle)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The lambda captures `n` (a param), whose value lives on this stack frame —
    // returning the closure would dangle, so it must be a compile error.
    const bad =
        \\make :: fn(n: i32) -> fn(i32) -> i32 { return fn(x: i32) -> i32 { return x + n; }; }
    ;
    const result = fels.compile(arena.allocator(), "escape.fels", bad);
    try std.testing.expectError(error.SemanticFailed, result);
}

test "diagnostics: returning a capturing closure held in a local is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The indirect form — assign the capturing closure to a local, then return it.
    const bad =
        \\make :: fn(n: i32) -> fn(i32) -> i32 { f := fn(x: i32) -> i32 { return x + n; }; return f; }
    ;
    const result = fels.compile(arena.allocator(), "escape2.fels", bad);
    try std.testing.expectError(error.SemanticFailed, result);
}

test "diagnostics: returning a non-capturing function value is allowed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // No captures → just a fn pointer with an empty environment; safe to return.
    const ok =
        \\dbl :: fn(x: i32) -> i32 { return x * 2; }
        \\get :: fn() -> fn(i32) -> i32 { return dbl; }
    ;
    var fe = try fels.compile(arena.allocator(), "ok.fels", ok);
    fe.deinit(arena.allocator());
}

test "diagnostics: unknown name shows identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\bad :: fn() -> i32 { return foo; }
    ;
    const result = fels.compile(arena.allocator(), "bad.fels", bad);
    try std.testing.expectError(error.SemanticFailed, result);
}

test "diagnostics: wrong arg count shows expected vs actual" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\add :: fn(a: i32, b: i32) -> i32 { return a + b; }
        \\bad :: fn() -> i32 { return add(1); }
    ;
    const result = fels.compile(arena.allocator(), "bad.fels", bad);
    try std.testing.expectError(error.SemanticFailed, result);
}

test "diagnostics: arg type mismatch shows types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\add :: fn(a: i32, b: i32) -> i32 { return a + b; }
        \\bad :: fn() -> i32 { return add(1, true); }
    ;
    const result = fels.compile(arena.allocator(), "bad.fels", bad);
    try std.testing.expectError(error.SemanticFailed, result);
}

test "diagnostics: sema errors are stored in TypeEnv" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Successful compile — diagnostics should be empty
    const src =
        \\add :: fn(a: i32, b: i32) -> i32 { return a + b; }
    ;
    var fe = try fels.compile(arena.allocator(), "ok.fels", src);
    defer fe.deinit(arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), fe.types.diagnostics.items.len);
}

test "diagnostics: fail outside error function is caught" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\NetError :: errors { timeout, }
        \\bad :: fn() -> i32 { fail .timeout; return 0; }
    ;
    try std.testing.expectError(error.SemanticFailed,
        fels.compile(arena.allocator(), "bad.fels", bad));
}

test "diagnostics: renderDiagnostic produces correct format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "bad :: fn() -> i32 { return true; }";

    // Force a compile error, then render the diagnostic
    const bad =
        \\bad :: fn() -> i32 { return true; }
    ;
    // Just verify compile fails — rendering is tested via existence
    try std.testing.expectError(error.SemanticFailed,
        fels.compile(arena.allocator(), "test.fels", bad));

    // Verify Diagnostic.err constructor works
    const d = fels.Diagnostic.err("test message",
        fels.Span.new(0, 3), "test.fels");
    try std.testing.expectEqual(fels.DiagKind.err, d.kind);

    const rendered = try fels.renderDiagnostic(arena.allocator(), "test.fels", src, d);
    // Should contain file:line:col: error: message
    try std.testing.expect(std.mem.indexOf(u8, rendered, "test.fels") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "error:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "test message") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "^^^") != null);
}

test "diagnostics: rich render carries caret label, help and note; color only when asked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "main :: fn() -> i32 { return x; }";
    var d = fels.Diagnostic.err("undefined name `x`", fels.Span.new(28, 29), "t.fels");
    d.primary_label = "not found in this scope";
    d.helps = &.{"declare it first: `x := 0;`"};
    d.notes = &.{"names are resolved top to bottom"};

    const plain = try fels.renderDiagnostic(a, "t.fels", src, d);
    try std.testing.expect(std.mem.indexOf(u8, plain, "not found in this scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "help: declare it first") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "note: names are resolved") != null);
    // A plain render must carry no escape codes (what tests and pipes see).
    try std.testing.expect(std.mem.indexOfScalar(u8, plain, 0x1b) == null);

    // An explicit colored palette does carry them.
    const colored = try fels.renderDiagnosticColored(a, "t.fels", src, d, .{ .on = true });
    try std.testing.expect(std.mem.indexOfScalar(u8, colored, 0x1b) != null);
}

/// Return the first `error`-level diagnostic message for `src`, type-checking in
/// tolerant mode so the diagnostics survive even though checking fails. Lets the
/// tests below assert the *text* of an error, not just that one occurred.
fn firstError(arena: std.mem.Allocator, src: []const u8) !?[]const u8 {
    const mod = try fels.parseSource(arena, "t.fels", src);
    var syms = try fels.sema_mod.collectSymbols(arena, mod);
    const env = try fels.sema_mod.checkTypesTolerant(arena, mod, &syms, src, "t.fels");
    for (env.diagnostics.items) |d| {
        // Render so the assertions see the whole diagnostic (message + caret label +
        // `help:`/`note:` lines), matching what a user reads.
        if (d.kind == .err) return try fels.renderDiagnostic(arena, d.file, src, d);
    }
    return null;
}

test "diagnostics: unknown type is reported, never 'no further details'" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // u128/i128 → a tailored "unsupported integer width" message (used to fail
    // silently with the catch-all "semantic error (no further details)").
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, "main :: fn() -> i32 { x: u128 = 0u64; return 0; }")).?,
        "unsupported integer width `u128`") != null);
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, "main :: fn() -> i32 { x: i128 = 0i64; return 0; }")).?,
        "at most 64-bit") != null);

    // A non-standard width still gets a clear message (not the catch-all).
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, "main :: fn() -> i32 { x: u9 = 0u8; return 0; }")).?,
        "unsupported integer width `u9`") != null);

    // An unknown type close to a known one suggests it.
    const typo = (try firstError(a,
        "Point :: struct { x: i32 }\nmain :: fn() -> i32 { p: Poimt = .{0}; return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, typo, "unknown type `Poimt`") != null);
    try std.testing.expect(std.mem.indexOf(u8, typo, "did you mean `Point`?") != null);

    // A value used in type position names what it actually is.
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, "foo :: fn() {}\nmain :: fn() -> i32 { x: foo = 0; return 0; }")).?,
        "`foo` is not a type") != null);

    // An unknown error type after `!` is reported, not swallowed.
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, "f :: fn() -> i32 ! Ooops { return 0; }")).?,
        "unknown error type `Ooops`") != null);
}

/// `firstError` for `t.fels` when every import in it loads `lib.fels`, whose source is
/// `lib_src`. The import keeps the path written in `src`, so a help can quote it.
fn firstErrorWithLib(arena: std.mem.Allocator, lib_src: []const u8, src: []const u8) !?[]const u8 {
    const lib = try fels.parseSourceFrom(arena, "lib.fels", lib_src, 1);
    const main = try fels.parseSourceFrom(arena, "t.fels", src, lib.next_id);
    var items: std.ArrayList(fels.ast_mod.Item) = .empty;
    try items.appendSlice(arena, lib.module.items);
    for (main.module.items) |item| switch (item) {
        .import => |imp| {
            var resolved = imp;
            resolved.resolved_file = "lib.fels";
            try items.append(arena, .{ .import = resolved });
        },
        else => try items.append(arena, item),
    };
    const mod: fels.Module = .{ .file_name = "t.fels", .items = items.items };
    var syms = try fels.sema_mod.collectSymbols(arena, mod);
    const env = try fels.sema_mod.checkTypesTolerant(arena, mod, &syms, src, "t.fels");
    for (env.diagnostics.items) |d| {
        if (d.kind == .err and std.mem.eql(u8, d.file, "t.fels")) return try fels.renderDiagnostic(arena, d.file, src, d);
    }
    return null;
}

test "diagnostics: a type from a module imported whole says how to reach it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lib = "pub Build :: struct { id: i32 }\n";

    // `#import std.build;` reaches `Build` only as `build::Build`. The help used to be
    // "did you mean `Build`?", the very name that was not found.
    const bare = (try firstErrorWithLib(a, lib, "#import std.build;\nrun :: fn(b: Build) {}")).?;
    try std.testing.expect(std.mem.indexOf(u8, bare, "unknown type `Build`") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "help: write `build::Build`, or import it with `#import std.build.{ Build };`") != null);
    try std.testing.expect(std.mem.indexOf(u8, bare, "did you mean") == null);

    // Under an alias the namespace is the alias; the braced import keeps the path.
    const aliased = (try firstErrorWithLib(a, lib, "#import std.build as tools;\nrun :: fn(b: Build) {}")).?;
    try std.testing.expect(std.mem.indexOf(u8, aliased, "help: write `tools::Build`, or import it with `#import std.build.{ Build };`") != null);
}

test "diagnostics: a type suggestion is a name the file can write" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lib = "pub Build :: struct { id: i32 }\n";

    // `Build` is in the program but not reachable by that name, so it is no answer to a typo.
    const typo_whole = (try firstErrorWithLib(a, lib, "#import std.build;\nrun :: fn(b: Buld) {}")).?;
    try std.testing.expect(std.mem.indexOf(u8, typo_whole, "unknown type `Buld`") != null);
    try std.testing.expect(std.mem.indexOf(u8, typo_whole, "did you mean") == null);
    const not_imported = (try firstErrorWithLib(a, lib, "run :: fn(b: Build) {}")).?;
    try std.testing.expect(std.mem.indexOf(u8, not_imported, "unknown type `Build`") != null);
    try std.testing.expect(std.mem.indexOf(u8, not_imported, "did you mean") == null);

    // Imported by name it is one.
    const typo_braced = (try firstErrorWithLib(a, lib, "#import std.build.{ Build };\nrun :: fn(b: Buld) {}")).?;
    try std.testing.expect(std.mem.indexOf(u8, typo_braced, "did you mean `Build`?") != null);
}

test "diagnostics: a built-in type after `!` is not an error type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // It used to be "unknown error type `i32`; did you mean `i32`?".
    const builtin = (try firstError(a, "f :: fn() -> i32 ! i32 { return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, builtin, "`i32` is not an error type") != null);
    try std.testing.expect(std.mem.indexOf(u8, builtin, "did you mean") == null);
}

test "diagnostics: an unknown error type gets the help of an unknown type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const whole = (try firstErrorWithLib(a, "pub Oops :: errors { bad }\n", "#import std.build;\nf :: fn() -> i32 ! Oops { return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, whole, "unknown error type `Oops`") != null);
    try std.testing.expect(std.mem.indexOf(u8, whole, "help: write `build::Oops`, or import it with `#import std.build.{ Oops };`") != null);

    const typo = (try firstError(a, "Oops :: errors { bad }\nf :: fn() -> i32 ! Oopz { return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, typo, "unknown error type `Oopz`") != null);
    try std.testing.expect(std.mem.indexOf(u8, typo, "help: did you mean `Oops`?") != null);
}

test "diagnostics: a function or constant from a module imported whole says how to reach it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lib = "pub PI :: 3;\npub lerp :: fn(x: i32) -> i32 { return x; }\n";

    // Both used to get "did you mean" with their own name.
    const call = (try firstErrorWithLib(a, lib, "#import std.math;\nrun :: fn() -> i32 { return lerp(1); }")).?;
    try std.testing.expect(std.mem.indexOf(u8, call, "unknown function `lerp`") != null);
    try std.testing.expect(std.mem.indexOf(u8, call, "help: write `math::lerp`, or import it with `#import std.math.{ lerp };`") != null);
    try std.testing.expect(std.mem.indexOf(u8, call, "did you mean") == null);

    const name = (try firstErrorWithLib(a, lib, "#import std.math;\nrun :: fn() -> i32 { return PI; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, name, "unknown name `PI`") != null);
    try std.testing.expect(std.mem.indexOf(u8, name, "help: write `math::PI`, or import it with `#import std.math.{ PI };`") != null);
    try std.testing.expect(std.mem.indexOf(u8, name, "did you mean") == null);
}

test "diagnostics: a value suggestion is a name the file can write" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lib = "pub lerp :: fn(x: i32) -> i32 { return x; }\n";

    // `lerp` is in the program but not reachable by that name, so it is no answer to a typo.
    const typo_whole = (try firstErrorWithLib(a, lib, "#import std.math;\nrun :: fn() -> i32 { return lerq(1); }")).?;
    try std.testing.expect(std.mem.indexOf(u8, typo_whole, "unknown function `lerq`") != null);
    try std.testing.expect(std.mem.indexOf(u8, typo_whole, "did you mean") == null);
    const not_imported = (try firstErrorWithLib(a, lib, "run :: fn() -> i32 { return lerp(1); }")).?;
    try std.testing.expect(std.mem.indexOf(u8, not_imported, "unknown function `lerp`") != null);
    try std.testing.expect(std.mem.indexOf(u8, not_imported, "did you mean") == null);

    // Imported by name it is one.
    const typo_braced = (try firstErrorWithLib(a, lib, "#import std.math.{ lerp };\nrun :: fn() -> i32 { return lerq(1); }")).?;
    try std.testing.expect(std.mem.indexOf(u8, typo_braced, "did you mean `lerp`?") != null);
}

/// Fail, printing the program and the diagnostic, unless `prelude` + `body` type-checks
/// without an error.
fn expectNoError(arena: std.mem.Allocator, prelude: []const u8, body: []const u8) !void {
    const src = try std.fmt.allocPrint(arena, "{s}{s}\n", .{ prelude, body });
    if (try firstError(arena, src)) |msg| {
        std.debug.print("expected no error for:\n{s}\ngot:\n{s}\n", .{ src, msg });
        return error.UnexpectedDiagnostic;
    }
}

test "diagnostics: `*name` as a call argument is a dereference, not a pointer type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `f(*p)` and `g(1, *p)` used to fail with "unknown type `p`": the parser read `*name`
    // in an argument list as a pointer type, which only a few builtins and generics with
    // explicit type arguments want. `v := *p; f(v)` was the workaround.
    const prelude =
        \\Point :: struct { x: i32, y: i32 }
        \\f :: fn(x: i32) -> i32 { return x + 1; }
        \\g :: fn(a: i32, b: i32) -> i32 { return a + b; }
        \\h :: fn(q: *i32) -> i32 { return *q; }
        \\sum :: fn(p: Point) -> i32 { return p.x + p.y; }
        \\
    ;
    const bodies = [_][]const u8{
        "main :: fn() -> i32 { v: i32 = 4; p := &v; return f(*p); }",
        "main :: fn() -> i32 { v: i32 = 4; p := &v; return g(1, *p); }",
        "main :: fn() -> i32 { v: i32 = 4; p := &v; return g(*p, 1); }",
        "main :: fn() -> i32 { v: i32 = 4; w: i32 = 5; p := &v; q := &w; return g(*p, *q); }",
        // A named argument, a nested call and a trailing comma.
        "main :: fn() -> i32 { v: i32 = 4; p := &v; return f(x: *p); }",
        "main :: fn() -> i32 { v: i32 = 4; p := &v; return f(g(1, *p)); }",
        "main :: fn() -> i32 { v: i32 = 4; p := &v; return g(*p, *p,); }",
        // Through two levels: `**pp` is an `i32`, `*pp` is the `*i32` that `h` takes.
        "main :: fn() -> i32 { v: i32 = 4; p := &v; pp := &p; return f(**pp); }",
        "main :: fn() -> i32 { v: i32 = 4; p := &v; pp := &p; return h(*pp); }",
        // A struct copied out through a pointer.
        "main :: fn() -> i32 { pt: Point = .{ .x = 1, .y = 2 }; sp := &pt; return sum(*sp); }",
        // Inside a lambda, where `p` is captured.
        "main :: fn() -> i32 { v: i32 = 4; p := &v; k := fn() -> i32 { return f(*p); }; return k(); }",
        // `addr` and `byte` are builtin type names, and a variable named so shadows the type.
        "main :: fn() -> i32 { v: i32 = 4; addr := &v; return f(*addr); }",
        "main :: fn() -> i32 { v: i32 = 4; byte := &v; return g(1, *byte); }",
        "via :: fn(byte: *i32) -> i32 { return f(*byte); }\nmain :: fn() -> i32 { v: i32 = 4; return via(&v); }",
        // So does a variable named like a type of the program.
        "main :: fn() -> i32 { v: i32 = 4; Point := &v; return f(*Point); }",
    };
    for (bodies) |body| try expectNoError(a, prelude, body);
}

test "diagnostics: a pointer type is still a type argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The parser reads `*name` in an argument list as a dereference; sema turns it back
    // into a pointer type where `name` is one — so every argument below, which names a
    // type, keeps working, and so does `**name`, which never did.
    const prelude =
        \\Node :: struct { val: i32 }
        \\c_int :: i32;
        \\Pair :: struct($T: type) { first: T, second: T }
        \\pick :: fn($T: type, a: T, b: T) -> T { return b; }
        \\make :: fn($T: type, a: T) -> T { return a; }
        \\size_of_ptr_to :: fn($T: type) -> usize { return core::sizeof(*T); }
        \\
    ;
    const bodies = [_][]const u8{
        // Builtins: a struct, an alias, a lowercase builtin name and a keyword, at depth 1-3.
        "main :: fn() -> usize { return core::sizeof(*Node); }",
        "main :: fn() -> usize { return core::sizeof(**Node); }",
        "main :: fn() -> usize { return core::sizeof(***Node); }",
        "main :: fn() -> usize { return core::sizeof(*c_int); }",
        "main :: fn() -> usize { return core::sizeof(*f32); }",
        "main :: fn() -> usize { return core::sizeof(*addr); }",
        "main :: fn() -> usize { return core::sizeof(**u8); }",
        "main :: fn() -> usize { return core::sizeof(**const u8); }",
        // `*T` where `T` is a type parameter.
        "main :: fn() -> usize { return size_of_ptr_to(Node); }",
        // The pointer type that was written is the type that comes out.
        "main :: fn() -> *Node { return unsafe core::ptr_from_int(*Node, 0usize); }",
        "main :: fn() -> **Node { return unsafe core::ptr_from_int(**Node, 0usize); }",
        // Explicit type arguments of a generic function, and of a generic struct.
        "main :: fn() -> i32 { n: Node = .{ .val = 1 }; p := &n; q := pick(*Node, p, p); return q.val; }",
        "main :: fn() -> i32 { n: Node = .{ .val = 1 }; p := &n; pp := &p; q := pick(**Node, pp, pp); return (*q).val; }",
        "main :: fn() -> i32 { n: Node = .{ .val = 1 }; r: Pair(*Node) = .{ &n, &n }; return make(Pair(*Node), r).first.val; }",
    };
    for (bodies) |body| try expectNoError(a, prelude, body);

    // `**Node` is not `*Node`: the type written is the type returned, not just any pointer.
    const wrong = (try firstError(a, prelude ++
        "main :: fn() -> *Node { return unsafe core::ptr_from_int(**Node, 0usize); }")).?;
    try std.testing.expect(std.mem.indexOf(u8, wrong, "expected `*Node`, found `**Node`") != null);
}

test "diagnostics: `*name` is a type where one is wanted and a dereference elsewhere" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const prelude =
        \\Node :: struct { val: i32 }
        \\f :: fn(x: i32) -> i32 { return x + 1; }
        \\pick :: fn($T: type, a: T, b: T) -> T { return b; }
        \\
    ;
    // Where a value is wanted a variable is dereferenced, and is checked as such — this
    // used to say "unknown type `v`".
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, prelude ++ "main :: fn() -> i32 { v: i32 = 1; return f(*v); }")).?,
        "cannot dereference value of type `i32`") != null);
    // A name that is neither is an unknown name.
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, prelude ++ "main :: fn() -> i32 { return f(*zzz); }")).?,
        "unknown name `zzz`") != null);
    // A type where a value is wanted is refused, with a message that says what it is. (A
    // parameter of that pointer type used to take it for a null pointer.)
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, prelude ++ "main :: fn() -> i32 { return f(*Node); }")).?,
        "`Node` is a type, so `*Node` is a pointer type, not a value") != null);
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, prelude ++ "take :: fn(p: *Node) {}\nmain :: fn() { take(*Node); }")).?,
        "`Node` is a type, so `*Node` is a pointer type, not a value") != null);
    // ...while a variable that merely has the name of a type is an ordinary load.
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, prelude ++ "main :: fn() -> i32 { Node := 5; return f(*Node); }")).?,
        "cannot dereference value of type `i32`") != null);

    // Where only a type will do, `*name` is one and nothing else: a name that is no type says so,
    // as it always did, and a typo gets its suggestion.
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, prelude ++ "main :: fn() -> i32 { v: i32 = 1; p := &v; q := unsafe core::ptr_from_int(*p, 0usize); return 0; }")).?,
        "unknown type `p`") != null);
    const typo = (try firstError(a, prelude ++ "main :: fn() -> usize { return core::sizeof(*Nod); }")).?;
    try std.testing.expect(std.mem.indexOf(u8, typo, "unknown type `Nod`") != null);
    try std.testing.expect(std.mem.indexOf(u8, typo, "did you mean `Node`?") != null);
    const typo_generic = (try firstError(a,
        prelude ++ "main :: fn() -> i32 { n: Node = .{ .val = 1 }; np := &n; q := pick(*Nod, np, np); return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, typo_generic, "unknown type `Nod`") != null);
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, prelude ++ "main :: fn() -> usize { return core::sizeof(*u128); }")).?,
        "unsupported integer width `u128`") != null);
}

test "diagnostics: sizeof and type_name take an expression as well as a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `core::sizeof(**pp)` is the size of what `pp` points to; 0.1.1 took it, and `*p` and
    // `(*p)`, which is all that is left of the last once the parentheses are gone, must be
    // read the same way: a load where `p` is only a variable, a pointer type where it is a type.
    const prelude =
        \\Node :: struct { val: i32 }
        \\
    ;
    const bodies = [_][]const u8{
        "main :: fn() -> usize { v: i32 = 1; p := &v; return core::sizeof(*p); }",
        "main :: fn() -> usize { v: i32 = 1; p := &v; return core::sizeof((*p)); }",
        "main :: fn() -> usize { v: i32 = 1; p := &v; pp := &p; return core::sizeof(**pp); }",
        "main :: fn() -> i32 { v: i32 = 1; p := &v; pp := &p; return core::type_name(**pp).len as i32; }",
        "main :: fn() -> usize { n: Node = .{ .val = 1 }; np := &n; npp := &np; return core::sizeof(**npp); }",
        "main :: fn() -> usize { return core::sizeof(**Node); }",
    };
    for (bodies) |body| try expectNoError(a, prelude, body);
}

test "diagnostics: a variable does not hide a type that is asked for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The first argument of a builtin that takes a type, and an explicit type argument of a generic
    // function, are types whatever else the name is in scope: a parameter `Node` or a variable
    // `addr` (a builtin type) does not turn `*Node` into a load.
    const prelude =
        \\Node :: struct { val: i32 }
        \\pick :: fn($T: type, a: T, b: T) -> T { return b; }
        \\
    ;
    const bodies = [_][]const u8{
        "main :: fn(Node: i32) -> usize { return core::sizeof(*Node); }",
        "main :: fn(Node: i32) -> usize { return core::type_id(**Node); }",
        "main :: fn() -> i32 { v: i32 = 1; addr := &v; q := unsafe core::ptr_from_int(*addr, 0usize); return 0; }",
        "main :: fn() -> i32 { v: i32 = 1; byte := &v; return core::sizeof(*byte) as i32; }",
        "main :: fn(Node: i32) -> i32 { n: Node = .{ .val = 1 }; np := &n; q := pick(*Node, np, np); return q.val; }",
    };
    for (bodies) |body| try expectNoError(a, prelude, body);
}

test "diagnostics: where and constraint predicates see the id of a pointer type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A `where` block runs on the comptime VM during resolution, from the tree the checker has
    // been through. Its `type_id(*Node)` must reach the VM as a type: lowered as a load, the
    // predicate could not run, and the VM's failure counts as an accept, so this was lost
    // without a word.
    const rejected =
        \\Node :: struct { val: i32 }
        \\never :: fn(x: $T) -> usize
        \\where { if core::type_id(*Node) == core::type_id(*Node) { core::reject("always rejected"); } }
        \\{ return core::sizeof(T); }
        \\use :: fn() -> usize { return never(5); }
    ;
    try std.testing.expectError(error.SemanticFailed, fels.compile(a, "where_ptr_id.fels", rejected));

    // The same for a `constraint`: when its predicate cannot run, `$T: Same` falls back to being
    // read as an interface and an `i64` is refused ("must be a named struct").
    const accepted =
        \\Node :: struct { val: i32 }
        \\Same :: constraint($T) { if core::type_id(*T) == core::type_id(*Node) { core::reject("no nodes"); } }
        \\only :: fn($T: Same, x: T) -> usize { return core::sizeof(T); }
        \\use :: fn() -> usize { o: i64 = 1; return only(o); }
    ;
    var fe = try fels.compile(a, "constraint_ptr_id.fels", accepted);
    fe.deinit(a);
}

test "diagnostics: sizeof of a variable that code generated at compile time brings in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `#insert #run gen()` declares `q` only after the first, tolerant pass has gone over `main`.
    // That pass finds no `q`, and must neither take `*q` for a type for good (the tree is shared
    // with the strict pass) nor stop at it: by the strict pass `q` is a variable.
    var fe = try fels.compile(a, "late_local.fels",
        \\gen :: fn() -> AstBlock { return #quote { v: i32 = 41; q := &v; }; }
        \\main :: fn() -> usize {
        \\    #insert #run gen();
        \\    return core::sizeof(*q);
        \\}
    );
    fe.deinit(a);
}

test "diagnostics: an asm output may be a pointer type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `core::asm` reads the type of its output from the call `"={rax}"(*Node)`, which is not
    // an argument list that the checker's call rule visits.
    try expectNoError(arena.allocator(),
        \\Node :: struct { val: i32 }
        \\
    ,
        "get :: fn() -> *Node { return unsafe core::asm(volatile, \"xor %rax, %rax\", inputs: {}, outputs: { \"={rax}\"(*Node) }, clobbers: {}); }");
}

test "parser: `*name` in an argument list is a dereference; only a type keyword makes it a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Each statement is `f(<argument>);`; read the argument back out of the tree.
    const src =
        \\main :: fn() {
        \\    f(*p);
        \\    f(**p);
        \\    f(*Node);
        \\    f(*u8);
        \\    f(**u8);
        \\    f(*const Node);
        \\    f(*p + 1);
        \\}
    ;
    const module = try fels.parseSource(arena.allocator(), "ast.fels", src);
    const statements = module.items[0].function.body.?.statements;
    const Kind = enum { deref, deref_deref, type_ref };
    const expected = [_]Kind{ .deref, .deref_deref, .deref, .type_ref, .type_ref, .type_ref };
    for (expected, 0..) |kind, i| {
        const arg = statements[i].expr.kind.call.args[0].positional;
        switch (kind) {
            .deref => {
                try std.testing.expect(arg.kind == .unary and arg.kind.unary.op == .deref);
                try std.testing.expect(arg.kind.unary.expr.kind == .ident);
            },
            .deref_deref => {
                try std.testing.expect(arg.kind == .unary and arg.kind.unary.op == .deref);
                const inner = arg.kind.unary.expr.kind;
                try std.testing.expect(inner == .unary and inner.unary.op == .deref);
                try std.testing.expect(inner.unary.expr.kind == .ident);
            },
            .type_ref => try std.testing.expect(arg.kind == .type_ref and arg.kind.type_ref == .pointer),
        }
    }
    // `**u8` is a pointer to a pointer, and `*p + 1` stays `(*p) + 1`.
    const pp = statements[4].expr.kind.call.args[0].positional.kind.type_ref.pointer;
    try std.testing.expect(pp.inner.* == .pointer);
    const sum = statements[6].expr.kind.call.args[0].positional;
    try std.testing.expect(sum.kind == .binary and sum.kind.binary.left.kind == .unary);
}

test "diagnostics: invalid integer/float literal width suffix is reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `0u128`: an over-wide suffix on a literal used to be silently dropped
    // (collapsing to i32); now it errors like the type-side `u128`.
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, "main :: fn() -> i32 { x := 0u128; return 0; }")).?,
        "unsupported integer width `u128`") != null);

    // A non-standard width on a literal is flagged, not swallowed.
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, "main :: fn() -> i32 { x := 0u9; return 0; }")).?,
        "unsupported integer width `u9`") != null);

    // The float side is symmetric — only `f32`/`f64` are valid widths.
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, "main :: fn() -> i32 { x := 3.0f16; return 0; }")).?,
        "unsupported float width `f16`") != null);

    // A hex literal that legitimately ends in letters is NOT a bad suffix.
    try std.testing.expect((try firstError(a,
        "main :: fn() -> i32 { return 0xABC; }")) == null);
}

test "diagnostics: #align must be a power-of-two integer literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Anything else names a layout that does not exist, so it is an error rather
    // than a silently ignored attribute.
    const bad = [_][]const u8{
        "#align(3)\nS :: struct { a: u32 }",
        "#align(0)\nS :: struct { a: u32 }",
        "#align(x)\nS :: struct { a: u32 }",
        "#align\nS :: struct { a: u32 }",
        "#align(8192)\nS :: struct { a: u32 }",
    };
    for (bad) |src| {
        try std.testing.expectError(error.SemanticFailed, fels.compile(arena.allocator(), "bad_align.fels", src));
    }
    var ok = try fels.compile(arena.allocator(), "ok_align.fels", "#align(64)\nS :: struct { a: u32 }");
    ok.deinit(arena.allocator());
}

test "diagnostics: #packed takes no argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `#packed(2)` used to compile as plain `#packed`: a struct that C packs to 2 bytes came out
    // a different size, with no message. There is no pack-to-N, so it is an error.
    const bad = [_][]const u8{
        "#packed(2)\nS :: struct { a: u8, b: u32 }",
        "#packed(1)\nS :: struct { a: u8, b: u32 }",
        // a generic struct is checked when it is instantiated
        "#packed(4)\nBox :: struct($T: type) { a: u8, b: T }\nmain :: fn() -> i32 { x: Box(u32) = .{ 1, 2 }; return 0; }",
    };
    for (bad) |src| {
        try std.testing.expectError(error.SemanticFailed, fels.compile(arena.allocator(), "bad_packed.fels", src));
    }
    var ok = try fels.compile(arena.allocator(), "ok_packed.fels", "#packed\nS :: struct { a: u8, b: u32 }");
    ok.deinit(arena.allocator());
}

test "diagnostics: the address of a #packed struct's field is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A packed field can sit at any byte offset and a `*T` has no way to say so.
    // (docs/02_types.md has always said this; the compiler used to accept it.)
    const decl = "#packed\nPk :: struct { a: u8, b: u32, arr: [4]u8, inner: Inner }\n#packed\nInner :: struct { x: u16 }\n";
    const bad = [_][]const u8{
        "main :: fn() -> i32 { p: Pk = .{}; r := &p.b; return 0; }",
        "main :: fn() -> i32 { p: Pk = .{}; r := &p.arr[1]; return 0; }",
        "main :: fn() -> i32 { p: Pk = .{}; r := &p.inner.x; return 0; }",
        "f :: fn(p: *Pk) -> i32 { r := &p.b; return 0; }",
    };
    for (bad) |body| {
        const src = try std.mem.concat(arena.allocator(), u8, &.{ decl, body });
        try std.testing.expectError(error.SemanticFailed, fels.compile(arena.allocator(), "packed_addr.fels", src));
    }
    // The whole struct's address, by-value field access, and a plain struct's field
    // address are all fine.
    const ok = [_][]const u8{
        "main :: fn() -> i32 { p: Pk = .{}; r := &p; return (p.b + r.b) as i32; }",
        "Plain :: struct { a: u8, b: u32 }\nmain :: fn() -> i32 { q: Plain = .{}; r := &q.b; return 0; }",
    };
    for (ok) |body| {
        const src = try std.mem.concat(arena.allocator(), u8, &.{ decl, body });
        var fe = try fels.compile(arena.allocator(), "packed_ok.fels", src);
        fe.deinit(arena.allocator());
    }
}

test "diagnostics: the address of an unsuffixed literal points at its default type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `&5` points at a temporary, which has one width: the literal's default, as for
    // `x := 5`. It used to be a `*integer literal`, which no `*i32` parameter accepted.
    const decl = "get :: fn(p: *i32) -> i32 { return *p; }\n";
    const ok = [_][]const u8{
        "main :: fn() -> i32 { return get(&41); }",
        "main :: fn() -> i32 { p: *i32 = &5; q: *const i32 = &5; return *p + *q; }",
        "main :: fn() -> i32 { p: *f64 = &2.5; q: *i64 = &5i64; r: *u8 = &5u8; return 0; }",
        "main :: fn() -> i32 { p := &(-5); return get(p); }",
    };
    for (ok) |body| {
        const src = try std.mem.concat(arena.allocator(), u8, &.{ decl, body });
        var fe = try fels.compile(arena.allocator(), "addr_lit_ok.fels", src);
        fe.deinit(arena.allocator());
    }
    // A different width is spelled with a suffix (`&5i64`), not taken from the context.
    const bad = [_][]const u8{
        "main :: fn() -> i32 { p: *i64 = &5; return 0; }",
        "main :: fn() -> i32 { p: *f32 = &2.5; return 0; }",
        "main :: fn() -> i32 { p: *u8 = &5; return 0; }",
    };
    for (bad) |body| {
        const src = try std.mem.concat(arena.allocator(), u8, &.{ decl, body });
        try std.testing.expectError(error.SemanticFailed, fels.compile(arena.allocator(), "addr_lit_bad.fels", src));
    }
}

test "diagnostics: comparing an error with a variant its set does not have is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `e == .secnd` used to compile and compare against garbage; the misspelling is now
    // an error, found against the error set the caught value belongs to.
    const bad =
        \\E :: errors { first, second }
        \\f :: fn() -> i32 ! E { fail .first; }
        \\g :: fn() -> i32 { v := f() catch e { if e == .secnd { return 1; } return 0; }; return 9; }
    ;
    try std.testing.expectError(error.SemanticFailed, fels.compile(arena.allocator(), "bad_variant.fels", bad));
    const good =
        \\E :: errors { first, second }
        \\f :: fn() -> i32 ! E { fail .first; }
        \\g :: fn() -> i32 { v := f() catch e { if e == .second { return 1; } return 0; }; return 9; }
    ;
    var fe = try fels.compile(arena.allocator(), "good_variant.fels", good);
    fe.deinit(arena.allocator());
}

test "diagnostics: a catch handler may only run to its end when the value is not used" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const decls =
        \\E :: errors { first }
        \\num :: fn() -> i32 ! E { fail .first; }
        \\nothing :: fn() -> void ! E { fail .first; return; }
        \\
    ;
    // The call produces an i32 and the catch is used for it: a handler that can fall off its
    // end leaves the expression with no value, so it is refused.
    const refused = [_][]const u8{
        "g :: fn() -> i32 { v := num() catch e { }; return v; }",
        "g :: fn() -> i32 { v := num() catch e { if e == .first { return 1; } }; return v; }",
        "g :: fn() -> i32 { return num() catch e { }; }",
        "g :: fn(n: i32) -> i32 { v := num() catch e { n = 3; }; return v; }",
    };
    for (refused) |body| {
        const src = try std.mem.concat(arena.allocator(), u8, &.{ decls, body });
        try std.testing.expectError(error.SemanticFailed, fels.compile(arena.allocator(), "catch_refused.fels", src));
    }
    // Fine: the handler always leaves the expression, the call has no value, or the whole
    // `catch` is a statement and its value is thrown away.
    const accepted = [_][]const u8{
        "g :: fn() -> i32 { v := num() catch e { return 1; }; return v; }",
        "g :: fn() -> i32 ! E { v := num() catch e { fail .first; }; return v; }",
        "g :: fn() -> i32 { n := 0; while true { v := num() catch e { break; }; n += v; } return n; }",
        "g :: fn() -> i32 { v := num() catch e { if e == .first { return 1; } else { return 2; } }; return v; }",
        "g :: fn() -> i32 { n := 0; nothing() catch e { n = 1; }; return n; }",
        "g :: fn() -> i32 { n := 0; num() catch e { n = 1; }; return n; }",
        "g :: fn() -> i32 { num() catch e {}; return 0; }",
    };
    for (accepted) |body| {
        const src = try std.mem.concat(arena.allocator(), u8, &.{ decls, body });
        var fe = fels.compile(arena.allocator(), "catch_ok.fels", src) catch |err| {
            std.debug.print("\nthis catch should be accepted:\n  {s}\n", .{body});
            return err;
        };
        fe.deinit(arena.allocator());
    }
}

test "diagnostics: `yield` gives a used catch its value, and nothing else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls =
        \\E :: errors { first, second }
        \\Color :: enum { red, green }
        \\num :: fn() -> i32 ! E { fail .first; }
        \\small :: fn() -> u8 ! E { fail .first; }
        \\color :: fn() -> Color ! E { fail .first; }
        \\nothing :: fn() -> void ! E { fail .first; return; }
        \\
    ;
    const cases = [_]struct { body: []const u8, needle: []const u8 }{
        .{ .body = "g :: fn() -> i32 { yield 1; }", .needle = "`yield` outside a `catch` handler" },
        .{ .body = "g :: fn() -> i32 { nothing() catch e { yield 1; }; return 0; }", .needle = "produces no value" },
        .{ .body = "g :: fn() -> i32 { num() catch e { yield 1; }; return 0; }", .needle = "would be thrown away" },
        .{ .body = "g :: fn() -> i32 { v := num() catch e { defer { yield 2; } yield 1; }; return v; }", .needle = "`yield` in a `defer` body" },
        .{ .body = "g :: fn() -> i32 { v := num() catch e { yield \"x\"; }; return v; }", .needle = "`yield` type mismatch: the call produces `i32`" },
        .{ .body = "g :: fn() -> u8 { v := small() catch e { yield 300; }; return v; }", .needle = "integer literal `300` does not fit in `u8`" },
        // A handler that yields on one path only can still run to its end.
        .{ .body = "g :: fn() -> i32 { v := num() catch e { if e == .first { yield 1; } }; return v; }", .needle = "end the handler with `yield`" },
    };
    for (cases) |case| {
        const src = try std.mem.concat(a, u8, &.{ decls, case.body, "\n" });
        try expectFirstError(a, src, &.{case.needle});
    }
    const accepted = [_][]const u8{
        "g :: fn() -> i32 { v := num() catch e { yield 1; }; return v; }",
        "g :: fn() -> i32 { v := num() catch e { if e == .first { yield 1; } else { yield 2; } }; return v; }",
        "g :: fn() -> i32 { return num() catch e { yield 3; }; }",
        "g :: fn() -> u8 { v := small() catch e { yield 255; }; return v; }",
        // The literal local takes the call's type, `u8`, from the `yield`.
        "g :: fn() -> u8 { n := 7; v := small() catch e { yield n; }; return v; }",
        "g :: fn() -> Color { c := color() catch e { yield .green; }; return c; }",
        // A `yield` in a loop in the handler leaves the loop and the handler.
        "g :: fn() -> i32 { v := num() catch e { for i in 0..9 { if i == 4 { yield i; } } yield 0; }; return v; }",
        // Each `yield` belongs to the innermost handler.
        "g :: fn() -> i32 { v := num() catch e { yield (num() catch e2 { yield 2; }) + 1; }; return v; }",
        // A `catch` in a `defer` body yields to its own handler.
        "g :: fn() -> i32 { n := 0; v := num() catch e { defer { n = num() catch e2 { yield 5; }; } yield 1; }; return v + n; }",
    };
    for (accepted) |body| try expectNoError(a, decls, body);
}

test "diagnostics: a builtin whose first argument is not a type says so" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `*G` and `**G` are both pointer types in an argument list, so both are type arguments.
    const good =
        \\G :: struct { a: u32 }
        \\f :: fn() -> i32 {
        \\    p: *G = unsafe (core::ptr_from_int(*G, 0usize));
        \\    pp: **G = unsafe (core::ptr_from_int(**G, 0usize));
        \\    return 0;
        \\}
    ;
    var fe = try fels.compile(a, "ptr.fels", good);
    fe.deinit(a);
    // A value there used to fail the build without saying why.
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, "f :: fn() -> i32 { q := unsafe (core::ptr_from_int(5usize, 0usize)); return 0; }")).?,
        "the first argument of `ptr_from_int` must be a type") != null);
}

test "diagnostics: an error is compared with a variant wherever it is" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Only the name a `catch` bound could be compared: outside it an error was no value of its
    // own (a pointer), so a parameter, a copy or a call result read as the wrong variant.
    const good = [_][]const u8{
        "Oops :: errors { a, b }\ncode_of :: fn(e: Oops) -> i32 { if e == .b { return 2; } return 1; }",
        "Oops :: errors { a, b }\nfails :: fn() -> void ! Oops { fail .b; return; }\ng :: fn() -> i32 { r: i32 = 1; fails() catch e { copy := e; if copy == .b { r = 2; } }; return r; }",
        "Oops :: errors { a, b }\nh :: fn(e: Oops) -> bool { return .a != e; }",
        "Oops :: errors { a, b }\nBox :: struct { err: Oops }\nh :: fn(x: Box) -> bool { return x.err == .a; }",
        "Oops :: errors { a, b }\npick :: fn() -> Oops { return .b; }\nh :: fn() -> bool { return pick() == .b; }",
    };
    for (good) |src| {
        if (try firstError(a, src)) |msg| {
            std.debug.print("\nexpected no error for:\n{s}\ngot:\n{s}\n", .{ src, msg });
            return error.UnexpectedDiagnostic;
        }
    }
    // The variant must still be one of the set's.
    try expectFirstError(a, "Oops :: errors { a, b }\ncode_of :: fn(e: Oops) -> bool { return e == .c; }", &.{"`Oops` has no error variant `.c`"});
}

test "diagnostics: fail e takes an error the function's set holds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls =
        \\E :: errors { a }
        \\F :: errors { b, c: i64 }
        \\
    ;
    try expectFirstError(a, decls ++ "g :: fn(e: F) -> i32 ! E { fail e; }\n", &.{"this error is a `F`, and the function fails with `E`"});
    try expectFirstError(a, decls ++ "g :: fn() -> i32 ! E { fail 5; }\n", &.{"`fail` takes an error, `.name`, `.name(payload)` or an error value"});
    try expectFirstError(a, decls ++ "g :: fn(e: E) -> i32 { fail e; }\n", &.{"`fail` used in a function without a `!` error return type"});
    try expectFirstError(a, decls ++ "g :: fn() -> F { return F.d; }\n", &.{"`F` has no error variant `.d`"});
    try expectNoError(a, decls, "g :: fn(e: F) -> i32 ! F { fail e; }\nh :: fn(e: F) -> i32 ! { fail e; }\nk :: fn() -> F { return F.c(3i64); }");
}

test "diagnostics: a payload in braces warns, and the build goes on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `fail .v(p)` is built as an enum variant is; `fail .v { p }` is the form before it.
    var fe = try fels.compile(a, "brace_payload.fels",
        \\PE :: errors { plain, big: i64 }
        \\f :: fn(k: i32) -> i32 ! PE { if k == 1 { fail .big(77i64); } fail .big { 5i64 }; }
    );
    defer fe.deinit(a);
    var warnings: usize = 0;
    for (fe.diagnostics()) |d| {
        try std.testing.expect(d.kind != .err);
        if (std.mem.indexOf(u8, d.message, "write the payload in parentheses, `fail .big(…)`") != null) warnings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), warnings);
}

test "diagnostics: a type parameter left out must be inferable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls =
        \\make :: fn($T: type) -> T { r: T = 5; return r; }
        \\both :: fn($T: type, $U: Numeric, a: T, b: U) -> i64 { return (a as i64) + (b as i64); }
        \\
    ;
    try expectFirstError(a, decls ++ "main :: fn() -> i32 { x: i32 = make(); return x; }", &.{"`make` cannot infer its type parameter `T` from these arguments: pass the type arguments first"});
    // Neither the values alone, nor with the `$T: type` ones, nor with all type arguments.
    try expectFirstError(a, decls ++ "main :: fn() -> i32 { return both(i32, u8, 9, 1, 2u8) as i32; }", &.{"`both` expects 3 argument(s), but 5 were provided"});
    try expectNoError(a, decls, "main :: fn() -> i32 { return both(1, 2u8) as i32 + both(i32, 1, 2u8) as i32 + both(i32, u8, 1, 2u8) as i32; }");
}

test "diagnostics: a match pattern must fit the subject's type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFirstError(a, "f :: fn(c: u8) -> i32 { match c { -1 => { return 1; }, else => { return 0; } } }\nmain :: fn() -> i32 { return 0; }", &.{"integer literal `-1` does not fit in `u8`"});
    try expectNoError(a, "", "f :: fn(c: u8) -> i32 { match c { 'a', 'b' => { return 1; }, else => { return 0; } } }\nmain :: fn() -> i32 { return 0; }");
}

test "diagnostics: a top-level #if asks about the build only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Decided as the file is read, before any constant has a value: "`TARGET.os` has no
    // value `.windos`", "a top-level `#if` asks about the build: …", "expected } to close a
    // branch of a top-level #if".
    const bad = [_][]const u8{
        "#if TARGET.os == .windos { X :: 1; }\nmain :: fn() -> i32 { return 0; }",
        "N :: 3;\n#if N == 3 { X :: 1; }\nmain :: fn() -> i32 { return 0; }",
        "#if TARGET.os == .windows { X :: 1;\nmain :: fn() -> i32 { return 0; }",
    };
    for (bad) |src| try std.testing.expectError(error.ParseFailed, fels.compile(a, "toplevel_if_bad.fels", src));
    // A declaration of the branch not taken is not there.
    try std.testing.expectError(error.SemanticFailed, fels.compile(a, "toplevel_if_dropped.fels", "#if false { X :: 1; }\nmain :: fn() -> i32 { return X; }"));
}

test "diagnostics: TARGET's fields are enums, so a misspelt platform is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `TARGET` comes with the pipeline's preludes, so these go through `compile`: "enum
    // `TargetOs` has no variant `.windos`", "... `TargetArch` has no variant `.arm`", and
    // "`TARGET` is a constant".
    const bad = [_][]const u8{
        "main :: fn() -> i32 { if TARGET.os == .windos { return 1; } return 0; }",
        "main :: fn() -> i32 { if TARGET.arch == .arm { return 1; } return 0; }",
        "main :: fn() -> i32 { TARGET.debug = false; return 0; }",
    };
    for (bad) |src| try std.testing.expectError(error.SemanticFailed, fels.compile(a, "target_bad.fels", src));
    var fe = try fels.compile(a, "target_ok.fels", "main :: fn() -> i32 { if TARGET.os == .windows && !TARGET.debug { return 1; } return 0; }");
    fe.deinit(a);
}

test "diagnostics: a constant is not written to" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `M = 3;` for `M :: 7;` compiled and did nothing; writing a field of a constant aggregate
    // wrote read-only memory.
    const decls =
        \\Point :: struct { x: i32, y: i32 }
        \\M :: 7;
        \\ORIGIN : Point : .{ 3, 4 };
        \\TABLE : [3]u8 : .{ 1, 2, 3 };
        \\poke :: fn(p: *Point) { p.x = 1; }
        \\
    ;
    const cases = [_]struct { body: []const u8, needle: []const u8 }{
        .{ .body = "main :: fn() -> i32 { M = 3; return M; }", .needle = "`M` is a constant" },
        .{ .body = "main :: fn() -> i32 { M += 1; return M; }", .needle = "`M` is a constant" },
        .{ .body = "main :: fn() -> i32 { ORIGIN.x = 5; return 0; }", .needle = "`ORIGIN` is a constant" },
        .{ .body = "main :: fn() -> i32 { ORIGIN = .{ 1, 2 }; return 0; }", .needle = "`ORIGIN` is a constant" },
        .{ .body = "main :: fn() -> i32 { TABLE[1] = 9u8; return 0; }", .needle = "`TABLE` is a constant" },
        // `&` of a constant points at read-only data.
        .{ .body = "main :: fn() -> i32 { p := &ORIGIN; p.x = 1; return 0; }", .needle = "cannot assign to field through `*const` pointer" },
        .{ .body = "main :: fn() -> i32 { poke(&ORIGIN); return 0; }", .needle = "expected `*Point`, found `*const Point`" },
    };
    for (cases) |case| {
        const src = try std.mem.concat(a, u8, &.{ decls, case.body, "\n" });
        try expectFirstError(a, src, &.{case.needle});
    }
    // A local of the name is no constant, and a write through a pointer a constant holds is
    // allowed.
    try expectNoError(a, decls, "main :: fn() -> i32 { M := 1; M = 3; return M; }");
    try expectNoError(a, "Point :: struct { x: i32, y: i32 }\ng: Point = .{ 1, 2 };\nP :: &g;\n", "main :: fn() -> i32 { P.x = 5; return g.x; }");
}

test "diagnostics: an error's payload is bound where its variant carries one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls =
        \\PE :: errors { plain, big: i64 }
        \\E :: errors { first, second }
        \\num :: fn() -> i32 ! PE { fail .big(5i64); }
        \\loose :: fn() -> i32 ! { return num()?; }
        \\
    ;
    const cases = [_]struct { body: []const u8, needle: []const u8 }{
        // An inferred set keeps an error's number, not its payload.
        .{ .body = "g :: fn() -> i64 { v := loose() catch e { if e == .big |n| { return n; } yield 0; }; return 0i64; }", .needle = "an error of an inferred set (`!`) carries no payload" },
        .{ .body = "g :: fn() -> i64 { v := loose() catch e { match e { .big |n| => { return n; }, else => { return 0i64; } } }; return 0i64; }", .needle = "an error of an inferred set (`!`) carries no payload" },
        .{ .body = "g :: fn() -> i64 { v := num() catch e { if e == .plain |n| { return 1i64; } yield 0; }; return 0i64; }", .needle = "the error `.plain` carries no payload to bind" },
        .{ .body = "g :: fn(e: PE) -> i64 { match e { .plain |n| => { return 1i64; }, else => { return 0i64; } } }", .needle = "the error `.plain` carries no payload to bind" },
        .{ .body = "g :: fn(e: E) -> i32 { if e == .first |p| { return 1; } return 0; }", .needle = "the error `.first` carries no payload to bind" },
        .{ .body = "g :: fn(x: i32) -> i32 { if x > 3 |c| { return 1; } return 0; }", .needle = "`|c|` binds the value of an optional, or the payload of an error" },
        // Which is equal, the variant or the payload too? Each is compared with a variant.
        .{ .body = "g :: fn(a: PE, b: PE) -> bool { return a == b; }", .needle = "two errors of `PE` cannot be compared" },
        .{ .body = "g :: fn() -> PE { return .nope; }", .needle = "`PE` has no error variant `.nope`" },
    };
    for (cases) |case| {
        const src = try std.mem.concat(a, u8, &.{ decls, case.body, "\n" });
        try expectFirstError(a, src, &.{case.needle});
    }
    const accepted = [_][]const u8{
        "g :: fn() -> i64 { v := num() catch e { if e == .big |n| { return n; } yield 0; }; return 0i64; }",
        "g :: fn(e: PE) -> i64 { return match e { .big |n| => n, .plain => 0i64 }; }",
        "g :: fn(a: E, b: E) -> bool { return a == b; }",
        "g :: fn() -> PE { return .plain; }",
    };
    for (accepted) |body| try expectNoError(a, decls, body);
}

test "diagnostics: an inline error set carries no payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFirstError(a, "f :: fn(n: i32) -> i32 ! { .small, .big: i64 } { if n > 9 { fail .big(5i64); } return n; }\nmain :: fn() -> i32 { return 0; }", &.{
        "the error `.big` of an inline set cannot carry a payload",
    });
    try expectNoError(a, "", "f :: fn(n: i32) -> i32 ! { .small, .big } { if n > 9 { fail .big; } return n; }\nmain :: fn() -> i32 { return 0; }");
}

test "diagnostics: `match` on an error covers its set's variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A named set, an inferred one (`-> T !`) and an inline one, through the catch name.
    const decls =
        \\E1 :: errors { p, x }
        \\raise :: fn() -> i32 ! E1 { fail .x; }
        \\inferred :: fn() -> i32 ! { v := raise()?; return v; }
        \\inline_set :: fn() -> i32 ! { .p, .x } { fail .x; }
        \\
    ;
    for ([_][]const u8{ "raise", "inferred", "inline_set" }) |callee| {
        const src = try std.fmt.allocPrint(a,
            \\{s}main :: fn() -> i32 {{
            \\    r := {s}() catch err {{
            \\        match err {{ .x => {{ return 5; }}, _ => {{ return 6; }} }}
            \\    }};
            \\    return r;
            \\}}
        , .{ decls, callee });
        if (try firstError(a, src)) |msg| {
            std.debug.print("\n`match` on an error from `{s}` was refused:\n{s}\n", .{ callee, msg });
            return error.UnexpectedDiagnostic;
        }
    }
    const set =
        \\E :: errors { first, second }
        \\num :: fn() -> i32 ! E { fail .first; }
        \\loose :: fn() -> i32 ! { return num()?; }
        \\
    ;
    const cases = [_]struct { body: []const u8, needle: []const u8 }{
        .{ .body = "g :: fn(e: E) -> i32 { match e { .first => { return 1; } } return 0; }", .needle = "error `.second` is not handled" },
        .{ .body = "g :: fn(e: E) -> i32 { return match e { .first => 1 }; }", .needle = "error `.second` is not handled" },
        .{ .body = "g :: fn(e: E) -> i32 { match e { .first => { return 1; }, .nope => { return 2; }, else => { return 3; } } }", .needle = "unknown error variant `.nope`" },
        .{ .body = "g :: fn(e: E) -> i32 { match e { .first => { return 1; }, .first => { return 2; }, else => { return 3; } } }", .needle = "duplicate match arm for error `.first`" },
        // An inferred set has no list of variants: any name, but always an `else`.
        .{ .body = "g :: fn() -> i32 { v := loose() catch e { match e { .first => { yield 1; } } }; return v; }", .needle = "needs an `else` arm" },
    };
    for (cases) |case| {
        const src = try std.mem.concat(a, u8, &.{ set, case.body, "\n" });
        try expectFirstError(a, src, &.{case.needle});
    }
    const accepted = [_][]const u8{
        "g :: fn(e: E) -> i32 { match e { .first => { return 1; }, .second => { return 2; } } }",
        "g :: fn(e: E) -> i32 { return match e { .first, .second => 1 }; }",
        "g :: fn() -> i32 { v := loose() catch e { yield match e { .anything => 1, else => 2 }; }; return v; }",
    };
    for (accepted) |body| try expectNoError(a, set, body);
}

test "diagnostics: `X :: Name;` is a type alias when Name is a type, a constant otherwise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `i32` is a keyword to the parser but `f32` is an identifier, so `my_float :: f32;`
    // used to read as a value constant, and using it as a type failed with
    // "`my_float` is not a type (it is a constant)".
    try std.testing.expect((try firstError(a,
        "my_float :: f32;\nmain :: fn() -> i32 { x: my_float = 1.5; return 0; }")) == null);

    // Likewise for a declared type: the parser cannot tell `Node` from a constant's name.
    try std.testing.expect((try firstError(a,
        \\Node :: struct { v: i32 }
        \\node_t :: Node;
        \\main :: fn() -> i32 { x: node_t = .{ .v = 3 }; return x.v; }
    )) == null);

    // Every identifier-spelled built-in type, not only the floats.
    try std.testing.expect((try firstError(a,
        \\double_t :: f64;
        \\byte_t :: byte;
        \\addr_t :: addr;
        \\text_t :: Text;
        \\rune_t :: Rune;
        \\bits_t :: u3;
        \\main :: fn() -> i32 { d: double_t = 1.0; return 0; }
    )) == null);

    // An enum, an alias of an alias, and aliases declared before what they name.
    try std.testing.expect((try firstError(a,
        \\Early :: Late;
        \\Late :: Real;
        \\Real :: f32;
        \\Paint :: Color;
        \\Color :: enum { red, green }
        \\main :: fn() -> i32 { x: Early = 2.5; p: Paint = .green; return 0; }
    )) == null);

    // A constant naming a constant is still a constant — it is not a type...
    const not_a_type = (try firstError(a,
        "W :: 8;\nV :: W;\nmain :: fn() -> i32 { x: V = 1; return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, not_a_type, "`V` is not a type") != null);
    // ...and a name that is no type and no constant stays an unknown name.
    const unknown = (try firstError(a,
        "X :: Nope;\nmain :: fn() -> i32 { return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, unknown, "unknown name `Nope`") != null);
}

test "diagnostics: an alias spelled like a constant is not lowered as a global" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `my_float :: f64;` with nothing using it: lowering it as a constant failed with
    // "constant initializer could not be folded at compile time".
    const src =
        \\my_float :: f64;
        \\Node :: struct { v: i32 }
        \\node_t :: Node;
        \\N :: 8;
        \\M :: N;
        \\main :: fn() -> i32 { return M; }
    ;
    var fe = try fels.compile(a, "t.fels", src);
    defer fe.deinit(a);
    const module = try fels.lowerFrontend(a, fe);
    try fels.ir_mod.validateModule(module);

    // The aliases have no storage; the constants beside them keep theirs.
    var constants: usize = 0;
    for (module.globals) |g| {
        try std.testing.expect(!std.mem.eql(u8, g.name, "my_float"));
        try std.testing.expect(!std.mem.eql(u8, g.name, "node_t"));
        if (std.mem.eql(u8, g.name, "N") or std.mem.eql(u8, g.name, "M")) constants += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), constants);
}

test "diagnostics: exponent notation gets its own message, with the number written out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `1e5` used to say "unknown type `e5`": the lexer reads it as `1` with the suffix `e5`.
    const int_msg = (try firstError(a, "main :: fn() -> i32 { x := 1e5; return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, int_msg, "exponent notation `1e5` is not supported") != null);
    try std.testing.expect(std.mem.indexOf(u8, int_msg, "`100000.0`") != null);
    try std.testing.expect(std.mem.indexOf(u8, int_msg, "unknown type") == null);
    const float_msg = (try firstError(a, "main :: fn() -> i32 { x := 1.5e3; return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, float_msg, "exponent notation `1.5e3` is not supported") != null);
    try std.testing.expect(std.mem.indexOf(u8, float_msg, "`1500.0`") != null);
    // In a hex literal `e` is a digit.
    try std.testing.expect((try firstError(a, "main :: fn() -> i32 { x := 0x1e5; return x - 485; }")) == null);
}

test "diagnostics: a problem in a top level constant is reported once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The initializer of a top level constant is checked twice; it used to give two
    // identical errors.
    const src =
        \\BIG :: 5u128;
        \\main :: fn() -> i32 { return 0; }
    ;
    const mod = try fels.parseSource(a, "t.fels", src);
    var syms = try fels.sema_mod.collectSymbols(a, mod);
    const env = try fels.sema_mod.checkTypesTolerant(a, mod, &syms, src, "t.fels");
    var errors: usize = 0;
    for (env.diagnostics.items) |d| {
        if (d.kind == .err) errors += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), errors);
}

test "diagnostics: the address of a local inferred from a literal points at the default type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `x := 42; p: *i32 = &x;` used to say "expected `*i32`, found `*integer literal`". The
    // local is stored as an `i32` (`f64` for a float literal), so that is what `&x` points at.
    const accepted = [_][]const u8{
        "main :: fn() -> i32 { x := 42; p: *i32 = &x; return *p; }",
        "take :: fn(p: *i32) -> i32 { return *p; }\nmain :: fn() -> i32 { x := 42; return take(&x); }",
        "main :: fn() -> i32 { x := 42; y: i32 = 1; q: *i32 = &y; if &x == q { return 1; } return 0; }",
        "main :: fn() -> i32 { x := 42; p := &x; q: *i32 = p; return *q; }",
        "main :: fn() -> i32 { x := 42; n := unsafe ((&x) as usize); b := unsafe ((&x) as *u8); return 0; }",
        "main :: fn() -> i32 { x := 1.5; p: *f64 = &x; return 0; }",
        "main :: fn() -> i32 { x := 0u8; p: *u8 = &x; return 0; }",
        "main :: fn() -> i32 { s := 0; for i in 0..10 { p: *i32 = &i; s += *p; } return s; }",
        // Another width takes a cast: the local is an `i32`.
        "main :: fn() -> i32 { x := 5; y: i64 = x as i64; z: u8 = x as u8; return 0; }",
    };
    for (accepted) |src| {
        if (try firstError(a, src)) |msg| {
            std.debug.print("\nthis should be accepted:\n  {s}\ngot:\n{s}\n", .{ src, msg });
            return error.TestUnexpectedResult;
        }
    }
    // A pointer of another type than the local's is refused, and the message names the real type.
    const wrong_width = (try firstError(a, "main :: fn() -> i32 { x := 42; y: i32 = x; p: *i64 = &x; return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, wrong_width, "found `*i32`") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrong_width, "literal") == null);
    const wrong_float = (try firstError(a, "main :: fn() -> i32 { x := 1.5; z: f64 = x; p: *f32 = &x; return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, wrong_float, "found `*f64`") != null);
    // What the pointer reads back is an `i32`, not a literal that could widen.
    const through_ptr = (try firstError(a, "main :: fn() -> i32 { x := 0; p := &x; y: i64 = *p; return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, through_ptr, "found `i32`") != null);
    // Once a use has given the local its type, reading it as another integer type is refused.
    // It used to be accepted and read with the wrong width (`x := -5; y: i64 = x;` gave `y != -5`).
    const widened = (try firstError(a, "main :: fn() -> i32 { x := 5; z: i32 = x; y: i64 = x; return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, widened, "found `i32`") != null);
    // A float literal's local that a use made an `f64` takes a cast to be narrowed. `y: f32 = x;`
    // used to be accepted for an `f64` local and stored its bits into the `f32`.
    const narrowed = (try firstError(a, "main :: fn() -> i32 { x := 1.5; z: f64 = x; y: f32 = x; return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, narrowed, "found `f64`") != null);
    try std.testing.expect((try firstError(a, "main :: fn() -> i32 { x := 1.5; y: f32 = x as f32; z: f64 = x; return 0; }")) == null);
}

test "diagnostics: a range's index has the type of its bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A literal bound takes the other bound's type; the index used to have the start's type,
    // a literal that adapted to anything (and that IR counted in as an `i32`).
    try std.testing.expect((try firstError(a,
        "main :: fn() -> i32 { xs: []const u8 = \"ab\"; for i in 0..xs.len { y: usize = i; p: *usize = &i; } return 0; }")) == null);
    try std.testing.expect((try firstError(a,
        "main :: fn() -> i32 { n: i64 = 3; for i in 0..n { y: i64 = i; } for j in n..10 { z: i64 = j; } return 0; }")) == null);
    // Between two literals the index has the type its uses ask for, as `x := 5` has.
    try std.testing.expect((try firstError(a, "main :: fn() -> i32 { for i in 0..10 { y: usize = i; } return 0; }")) == null);
    const both = (try firstError(a, "main :: fn() -> i32 { for i in 0..10 { y: usize = i; z: i64 = i; } return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, both, "expected `i64`, found `usize`") != null);
    // A literal bound that does not fit the other bound's type is refused.
    const negative = (try firstError(a, "main :: fn() -> i32 { n: usize = 3; for i in -1..n { } return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, negative, "does not fit") != null);
}

test "diagnostics: a `void ! E` function may run to its end without `return;`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Falling off the end of a fallible `void` function is success, as `return;` is. It used to
    // be "may not return a value on all code paths", as if there were a value to return.
    const accepted = [_][]const u8{
        "E :: errors { bad }\nf :: fn() -> void ! E {}",
        "E :: errors { bad }\nf :: fn(n: i32) -> void ! E { if n > 0 { fail .bad; } }",
        "E :: errors { bad }\nf :: fn(n: i32) -> void ! E { if n > 0 { fail .bad; } }\ng :: fn(n: i32) -> void ! E { f(n)?; }",
        "f :: fn(n: i32) -> void ! { if n > 0 { fail .bad; } }",
        "E :: errors { bad }\nW :: interface { go :: fn(self: *Self) -> void ! E; }\nB :: struct { n: i32 }\nB as W { go :: fn(self: *Self) -> void ! E { self.n += 1; } }",
    };
    for (accepted) |src| {
        if (try firstError(a, src)) |msg| {
            std.debug.print("\nthis should be accepted:\n  {s}\ngot:\n{s}\n", .{ src, msg });
            return error.TestUnexpectedResult;
        }
    }
    // A fallible function with a value to return still has to return it on every path.
    const refused = [_][]const u8{
        "E :: errors { bad }\nf :: fn() -> i32 ! E {}",
        "E :: errors { bad }\nf :: fn(n: i32) -> i32 ! E { if n > 0 { return 1; } }",
        "E :: errors { bad }\nf :: fn(n: i32) -> i32 ! E { if n > 0 { fail .bad; } }",
    };
    for (refused) |src| {
        const msg = (try firstError(a, src)) orelse {
            std.debug.print("\nthis should be refused:\n  {s}\n", .{src});
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(std.mem.indexOf(u8, msg, "may not return a value on all code paths") != null);
    }
}

test "diagnostics: a top level constant may use what is declared below it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The constants used to be typed in source order, in the walk that records the function
    // signatures and struct layouts: a call to a function declared below was an internal
    // compiler error, and a constant declared below had no type yet.
    try expectNoError(a, "",
        \\X :: seven();
        \\R :: #run seven();
        \\seven :: fn() -> i32 { return 7; }
        \\main :: fn() -> i32 { return X + R; }
    );
    try expectNoError(a, "",
        \\A :: B + 1;
        \\B :: C * 2;
        \\C :: 3;
        \\main :: fn() -> i32 { return A; }
    );
    try expectNoError(a, "",
        \\ORIGIN :: #run make();
        \\make :: fn() -> Point { p: Point = .{ .x = 3, .y = 4 }; return p; }
        \\Point :: struct { x: i32, y: i32 }
        \\main :: fn() -> i32 { return ORIGIN.x + ORIGIN.y; }
    );
}

test "diagnostics: a top level constant whose value depends on itself" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // These used to fail with whatever the half-typed constant tripped over, such as "operator
    // `+` requires numeric operands, found `B`".
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, "A :: A + 1;\nmain :: fn() -> i32 { return A; }")).?,
        "the value of constant `A` depends on itself") != null);
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, "A :: B + 1;\nB :: A + 1;\nmain :: fn() -> i32 { return A; }")).?,
        "the value of constant `A` depends on itself") != null);
}

test "diagnostics: a `$T` inside a param type is bound from the argument and substituted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `*$T` (also `[]$T`, `?$T`) did not introduce `T`: the call failed with "expected
    // `*T`, found `*i32`", and a `T` in the body or the return type was unknown.
    const prelude =
        \\bump :: fn(p: *$T) -> void { *p += 1; }
        \\size_of_target :: fn(p: *$T) -> usize { return core::sizeof(T); }
        \\get :: fn(p: *$T) -> T { return *p; }
        \\first :: fn(s: []$T) -> T { return s[0]; }
        \\or_else :: fn(o: ?$T, d: T) -> T { if (o) |v| { return v; } return d; }
        \\swap :: fn(a: *$T, b: *T) -> void { t := *a; *a = *b; *b = t; }
        \\
    ;
    const bodies = [_][]const u8{
        "main :: fn() -> i32 { y: i32 = 40; bump(&y); return y; }",
        "main :: fn() -> i32 { y: i64 = 40; return size_of_target(&y) as i32; }",
        "main :: fn() -> i32 { y: i32 = 40; return get(&y); }",
        "main :: fn() -> i32 { a: [2]i32 = .{ 5, 6 }; return first(a[0..]); }",
        // `null` says nothing about `T`; the next argument binds it.
        "main :: fn() -> i32 { x: ?i32 = 5; return or_else(x, 0) + or_else(null, 1); }",
        "main :: fn() -> i32 { x: i32 = 1; y: i32 = 2; swap(&x, &y); return x; }",
    };
    for (bodies) |body| try expectNoError(a, prelude, body);

    // A mismatch names the parameter type with `T` filled in.
    const cases = [_]struct { body: []const u8, msg: []const u8 }{
        .{ .body = "main :: fn() -> i32 { y: i32 = 40; bump(y); return y; }", .msg = "argument 1 of `bump`: expected `*i32`, found `i32`" },
        .{ .body = "main :: fn() -> i32 { x: i32 = 1; y: i64 = 2; swap(&x, &y); return x; }", .msg = "argument 2 of `swap`: expected `*i32`, found `*i64`" },
        .{ .body = "main :: fn() -> i32 { return first(5); }", .msg = "argument 1 of `first`: expected `[]i32`, found `integer literal`" },
    };
    for (cases) |c| {
        const src = try std.fmt.allocPrint(a, "{s}{s}\n", .{ prelude, c.body });
        const msg = (try firstError(a, src)) orelse {
            std.debug.print("expected an error for:\n{s}\n", .{src});
            return error.MissingDiagnostic;
        };
        if (std.mem.indexOf(u8, msg, c.msg) == null) {
            std.debug.print("expected `{s}` in:\n{s}\n", .{ c.msg, msg });
            return error.WrongDiagnostic;
        }
    }
}

/// Fail, printing the program and what it gave, unless the first error of `src` contains
/// every one of `needles`.
fn expectFirstError(arena: std.mem.Allocator, src: []const u8, needles: []const []const u8) !void {
    const msg = (try firstError(arena, src)) orelse {
        std.debug.print("expected an error for:\n{s}\ngot none\n", .{src});
        return error.MissingDiagnostic;
    };
    for (needles) |needle| if (std.mem.indexOf(u8, msg, needle) == null) {
        std.debug.print("expected `{s}` in the error for:\n{s}\ngot:\n{s}\n", .{ needle, src, msg });
        return error.WrongDiagnostic;
    };
}

test "diagnostics: an integer literal that does not fit its target type is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // These were accepted and the value truncated: `y` held 705032704, `b` 44.
    try expectFirstError(a, "main :: fn() -> i32 { y: i32 = 5000000000; return 0; }", &.{
        "integer literal `5000000000` does not fit in `i32`", "`i32` holds -2147483648 to 2147483647",
    });
    try expectFirstError(a, "main :: fn() -> i32 { y: i32 = 0; y = 5000000000; return y; }", &.{
        "integer literal `5000000000` does not fit in `i32`",
    });
    try expectFirstError(a, "main :: fn() -> i32 { b: u8 = 300; return 0; }", &.{
        "integer literal `300` does not fit in `u8`", "`u8` holds 0 to 255",
    });

    // One past either end of each type, in each notation. `-128` is unary minus on `128`.
    const outside = [_][2][]const u8{
        .{ "i8", "-129" },                 .{ "i8", "128" },
        .{ "u8", "-1" },                   .{ "u8", "0x100" },
        .{ "byte", "0b1_0000_0000" },      .{ "i16", "-32_769" },
        .{ "u16", "65_536" },              .{ "i32", "-2147483649" },
        .{ "i32", "0x8000_0000" },         .{ "u32", "4294967296" },
        .{ "i64", "9223372036854775808" }, .{ "i64", "-9223372036854775809" },
        .{ "isize", "-0x8000_0000_0000_0001" }, .{ "u64", "0x1_0000_0000_0000_0000" },
        .{ "usize", "-1" },
    };
    for (outside) |case| {
        const src = try std.fmt.allocPrint(a, "main :: fn() -> i32 {{ x: {s} = {s}; return 0; }}", .{ case[0], case[1] });
        const msg = try std.fmt.allocPrint(a, "integer literal `{s}` does not fit in `{s}`", .{ case[1], case[0] });
        try expectFirstError(a, src, &.{msg});
    }
    // Exactly at either end is fine.
    try expectNoError(a, "",
        \\main :: fn() -> i32 {
        \\    a: i8 = -128; b: i8 = 127; c: u8 = 0xFF; d: byte = 0b1111_1111;
        \\    e: i16 = -32_768; f: u16 = 65_535; g: i32 = -2147483648; h: u32 = 0xFFFF_FFFF;
        \\    i: i64 = -9223372036854775808; j: i64 = 0x7FFF_FFFF_FFFF_FFFF;
        \\    k: u64 = 18446744073709551615; l: usize = 0xFFFF_FFFF_FFFF_FFFF; m: u8 = 0; n: u64 = -0;
        \\    return 0;
        \\}
    );
    // A literal wider than any integer type.
    try expectFirstError(a, "main :: fn() -> i32 { x: u64 = 99999999999999999999999999999999999999999999; return 0; }", &.{
        "does not fit in `u64`", "at most 64 bits",
    });
}

test "diagnostics: an integer literal is checked wherever it takes its type from the context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const prelude =
        \\P :: struct { x: u8, y: i16  pub set :: fn(self: *Self, v: u8) { self.x = v; } }
        \\Shape :: enum { circle: u8, none }
        \\E :: errors { big: u8 }
        \\Sink :: interface { put :: fn(self: *Self, b: u8); }
        \\P as Sink { put :: fn(self: *Self, b: u8) { self.x = b; } }
        \\take :: fn(v: i16) -> i16 { return v; }
        \\get :: fn() -> u8 { return 1; }
        \\maybe :: fn() -> ?u8 { return null; }
        \\id :: fn($T: type, v: T) -> T { return v; }
        \\
    ;
    const cases = [_][2][]const u8{
        .{ "main :: fn() -> i32 { take(-32769); return 0; }", "`-32769` does not fit in `i16`" },
        .{ "f :: fn() -> u8 { return 256; }", "`256` does not fit in `u8`" },
        .{ "main :: fn() -> i32 { p: P = .{ .x = 1, .y = 40000 }; return 0; }", "`40000` does not fit in `i16`" },
        .{ "main :: fn() -> i32 { p: P = .{ 300, 1 }; return 0; }", "`300` does not fit in `u8`" },
        .{ "Q :: struct { x: u8 = 256 }", "`256` does not fit in `u8`" },
        .{ "main :: fn() -> i32 { xs: [3]u8 = .{ 1, 2, 300 }; return 0; }", "`300` does not fit in `u8`" },
        .{ "G: u8 = 256;", "`256` does not fit in `u8`" },
        .{ "main :: fn() -> i32 { b: u8 = 0; b += 256; return 0; }", "`256` does not fit in `u8`" },
        // As an operand it takes the other operand's type: this compared `b` with 0.
        .{ "main :: fn() -> i32 { b := get(); if b < 256 { return 1; } return 0; }", "`256` does not fit in `u8`" },
        .{ "main :: fn() -> i32 { n: usize = 0; if n == -1 { return 1; } return 0; }", "`-1` does not fit in `usize`" },
        .{ "main :: fn() -> i32 { match get() { 300 => { return 1; } else => { return 0; } } }", "`300` does not fit in `u8`" },
        .{ "main :: fn() -> i32 { match get() { 0..=300 => { return 1; } else => { return 0; } } }", "`300` does not fit in `u8`" },
        .{ "main :: fn() -> i32 { c := true; b: u8 = if c { 1 } else { 256 }; return 0; }", "`256` does not fit in `u8`" },
        .{ "main :: fn() -> i32 { b: u8 = match get() { 1 => 2, else => 999 }; return 0; }", "`999` does not fit in `u8`" },
        .{ "main :: fn() -> i32 { b := maybe() ?? 256; return 0; }", "`256` does not fit in `u8`" },
        .{ "main :: fn() -> i32 { o: ?u8 = 256; return 0; }", "`256` does not fit in `u8`" },
        .{ "main :: fn() -> i32 { p: P = .{ .x = 0, .y = 0 }; p.set(300); return 0; }", "`300` does not fit in `u8`" },
        .{ "main :: fn() -> i32 { p: P = .{ .x = 0, .y = 0 }; s: *Sink = &p; s.put(300); return 0; }", "`300` does not fit in `u8`" },
        .{ "main :: fn() -> i32 { s := Shape.circle(300); return 0; }", "`300` does not fit in `u8`" },
        .{ "f :: fn() -> i32 ! E { fail .big(300); }", "`300` does not fit in `u8`" },
        .{ "main :: fn() -> i32 { g := take; g(40000); return 0; }", "`40000` does not fit in `i16`" },
        .{ "main :: fn() -> i32 { x := id(u8, 300); return 0; }", "`300` does not fit in `u8`" },
    };
    for (cases) |case| {
        const src = try std.fmt.allocPrint(a, "{s}{s}\n", .{ prelude, case[0] });
        try expectFirstError(a, src, &.{case[1]});
    }

    // A shift amount is not a value of the shifted type, and `as` truncates on purpose.
    try expectNoError(a, prelude, "main :: fn() -> i32 { b: u8 = 1; b <<= 3; c := b >> 7; return 0; }");
    try expectNoError(a, prelude, "main :: fn() -> i32 { b := 300 as u8; h := 0x8000_4005 as i32; return 0; }");
}

test "diagnostics: a suffix gives an integer literal its type, and the value has to fit it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectFirstError(a, "main :: fn() -> i32 { x := 256u8; return 0; }", &.{"integer literal `256u8` does not fit in `u8`"});
    try expectFirstError(a, "main :: fn() -> i32 { x := -129i8; return 0; }", &.{"integer literal `-129i8` does not fit in `i8`"});
    try expectFirstError(a, "main :: fn() -> i32 { x := -1u32; return 0; }", &.{"integer literal `-1u32` does not fit in `u32`"});
    try expectFirstError(a, "main :: fn() -> i32 { x := 0x1_0000_0000_0000_0000u64; return 0; }", &.{"does not fit in `u64`"});
    try expectNoError(a, "", "main :: fn() -> i32 { a := -128i8; b := 255u8; c := 0xFFFF_FFFF_FFFF_FFFFu64; d := -9223372036854775808i64; return 0; }");
}

test "diagnostics: an integer literal with no type to take is an i32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `x` used to stay an untyped literal and be accepted for any integer type, while IR
    // stored it as an `i32`: four bytes into the `u8`, which overwrote the next local. It has
    // the type of its first use that asks for one, so a second use asking for another is an error.
    try expectFirstError(a, "main :: fn() -> i32 { x := 5; b: u8 = x; c: i64 = x; return 0; }", &.{"type mismatch: expected `i64`, found `u8`"});
    try expectFirstError(a, "main :: fn() -> i32 { x := 0; y: i32 = x; n: usize = 5; x = n; return 0; }", &.{"expected `i32`, found `usize`"});
    try expectFirstError(a, "main :: fn() -> i32 { x := 5000000000; return 0; }", &.{
        "integer literal `5000000000` does not fit in `i32`", "as in `5000000000i64`",
    });
    try expectFirstError(a, "main :: fn() -> i32 { x := -3000000000; return 0; }", &.{"as in `-3000000000i64`"});
    try expectFirstError(a, "main :: fn() -> i32 { x := 0xFFFF_FFFF; return 0; }", &.{"as in `0xFFFF_FFFFu32`"});
    try expectFirstError(a, "main :: fn() -> i32 { c := true; x := if c { 1 } else { 3000000000 }; return 0; }", &.{"`3000000000` does not fit in `i32`"});
    try expectNoError(a, "", "main :: fn() -> i32 { x := -2147483648; y := 2147483647; z: i64 = x as i64; w := 5000000000i64; return y; }");
}

test "diagnostics: a local from a literal has the type its first use asks for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const accepted = [_][]const u8{
        // `+=` a typed value, `return`, a typed operand, an assignment, an argument
        "main :: fn() -> i32 { xs: [3]i64 = .{ 1, 2, 3 }; total := 0; for x in xs { total += x; } return 0; }",
        "count :: fn(s: []const u8) -> usize { n := 0; for c in s { if c == 88 { n += 1; } } return n; }\nmain :: fn() -> i32 { return 0; }",
        "main :: fn() -> i32 { xs: [3]u32 = .{ 4, 9, 2 }; best := 0; for x in xs { if x > best { best = x; } } return 0; }",
        "main :: fn() -> i32 { xs: []const u8 = \"ab\"; n := 0; n = xs.len; return 0; }",
        "get :: fn(i: usize) -> i64 { return 1; }\nmain :: fn() -> i32 { i := 0; s: i64 = 0; while i < 3 { s += get(i); i += 1; } return 0; }",
        // a field, and a pointer it is read through
        "P :: struct { v: usize }\nmain :: fn() -> i32 { n := 3; p: P = .{ n }; return 0; }",
        "main :: fn() -> i32 { x := 42; p: *i64 = &x; return 0; }",
        // `b := a;` ties the two: both are `u64`
        "main :: fn() -> i32 { a := 0; b := a; c: u64 = b; d: u64 = a; return 0; }",
        // an inner local of the same name has a type of its own
        "main :: fn() -> i32 { n := 0; if true { n := 5; y: u8 = n; } z: i64 = n; return 0; }",
        // with no use asking for a type it is an `i32`, which still indexes
        "main :: fn() -> i32 { xs: []const u8 = \"ab\"; i := 0; c := xs[i]; return i; }",
        // a local from a float literal takes `f32` the same ways
        "half :: fn(x: f32) -> f32 { return x / 2.0; }\nmain :: fn() -> i32 { h := 3.0; y := half(h); return 0; }",
        "main :: fn() -> i32 { ws: [2]f32 = .{ 1.5, 2.5 }; w := 0.0; for v in ws { if v > w { w = v; } } return 0; }",
        "P :: struct { w: f32 }\nmain :: fn() -> i32 { n := -0.25; p: P = .{ n }; q := 2.5; r: *f32 = &q; return 0; }",
    };
    for (accepted) |src| {
        if (try firstError(a, src)) |msg| {
            std.debug.print("\nthis should be accepted:\n  {s}\ngot:\n{s}\n", .{ src, msg });
            return error.TestUnexpectedResult;
        }
    }
    // The literal has to fit the type its use gives it.
    try expectFirstError(a, "main :: fn() -> i32 { x := 300; b: u8 = x; return 0; }", &.{"`300` does not fit in `u8`"});
    // A second use asking for another type is refused.
    try expectFirstError(a, "main :: fn() -> i32 { n := 0; a: u8 = n; b: u16 = n; return 0; }", &.{"expected `u16`, found `u8`"});
    try expectFirstError(a, "main :: fn() -> i32 { w := 0.5; a: f32 = w; b: f64 = w; return 0; }", &.{"expected `f64`, found `f32`"});
    // A float type does not go to a local from an integer literal, nor the other way round.
    try expectFirstError(a, "main :: fn() -> i32 { n := 0; x: f32 = n; return 0; }", &.{"expected `f32`, found `i32`"});
}

test "diagnostics: a local from a literal leaves alone what compiled before" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const accepted = [_][]const u8{
        // An operand next to a typed one gives no type: the operators take mixed widths, and
        // `i < xs.len` made `i` a `usize` that `return i` then refused.
        "main :: fn() -> i32 { xs: []const u8 = \"ab\"; i := 0; while i < xs.len { i += 1; } return i; }",
        "main :: fn() -> i32 { n := 1; m: u8 = 5; m = m + n; return n; }",
        // through `p := &n`, and a range to such a local
        "main :: fn() -> i32 { n := 0; k := 0; p := &n; *p = 3; big: i64 = 5000000000; k += big; return 0; }",
        "main :: fn() -> i32 { n := 3; total := 0; for i in 0..n { total += i; } m: u64 = n; return 0; }",
        // a constant without a type starts a local like its literal
        "K :: 7;\nmain :: fn() -> i32 { m := K; b: u8 = m; return 42; }",
    };
    for (accepted) |src| {
        if (try firstError(a, src)) |msg| {
            std.debug.print("\nthis should be accepted:\n  {s}\ngot:\n{s}\n", .{ src, msg });
            return error.TestUnexpectedResult;
        }
    }
    // A shift amount is no value of the shifted one's type.
    try expectFirstError(a, "main :: fn() -> i32 { n := 1; s: u8 = 10; n <<= s; return n; }", &.{"expected `i32`, found `u8`"});
    // An error the first pass met outside the body (a generic struct it instantiated first) stays.
    try expectFirstError(a, "Box :: struct($T: type) { v: T, w: Nope }\nmain :: fn() -> i32 { n := 0; p: ?*Box(i32) = null; return n; }", &.{"unknown type `Nope`"});
}

test "diagnostics: a constant without a type is checked like its literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectFirstError(a, "N :: 300;\nmain :: fn() -> i32 { b: u8 = N; return 0; }", &.{"`N` is 300, which does not fit in `u8`"});
    try expectFirstError(a, "N :: 5;\nmain :: fn() -> i32 { b: u8 = -N; return 0; }", &.{"`-N` is -5, which does not fit in `u8`"});
    // Its uses take any integer type, but it is stored as an `i32`.
    try expectFirstError(a, "BIG :: 5000000000;\nmain :: fn() -> i32 { return 0; }", &.{
        "integer literal `5000000000` does not fit in `i32`", "as in `5000000000i64`",
    });
    try expectNoError(a, "N :: 255;\nM :: -128;\nBIG :: 5000000000i64;\n",
        "main :: fn() -> i32 { b: u8 = N; c: i8 = M; d: i64 = -N; e: i64 = BIG; return 0; }");
    // A local of the same name is not the constant.
    try expectNoError(a, "N :: 300;\n", "main :: fn() -> i32 { N := 5; b: i32 = N; return b; }");
}

test "diagnostics: a bare variant compared with an enum has to be one of its variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const color = "Color :: enum { red, green, blue }\nShape :: enum { dot, circle: i32 }\n";
    try expectFirstError(a, color ++ "main :: fn() -> i32 { p := Color.red; if p == .purple { return 1; } return 0; }", &.{"enum `Color` has no variant `.purple`"});
    try expectFirstError(a, color ++ "main :: fn() -> i32 { p := Color.red; if .purple != p { return 1; } return 0; }", &.{"enum `Color` has no variant `.purple`"});
    try expectFirstError(a, color ++ "main :: fn() -> i32 { s := Shape.dot; if s == .square { return 1; } return 0; }", &.{"enum `Shape` has no variant `.square`"});
    try expectNoError(a, color, "main :: fn() -> i32 { p := Color.red; s := Shape.dot; if p == .green || .blue != p || s == .circle { return 1; } return 0; }");
}

const frame_prelude =
    \\P :: struct { x: i32, y: i32 }
    \\S :: struct { p: *i32 }
    \\Q :: struct { arr: [4]i32, s: []i32 }
    \\G: i32 = 1;
    \\GA: [4]i32 = .{ 1, 2, 3, 4 };
    \\seven :: fn() -> i32 { return 7; }
    \\
;

test "diagnostics: returning the address of a local, a parameter or a temporary is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const local = "the address of local `x` cannot be returned";

    try expectFirstError(a, frame_prelude ++ "f :: fn() -> *i32 { x := 5; return &x; }", &.{ local, "points at `x`, which lives in this function's frame", "help:" });
    try expectFirstError(a, frame_prelude ++ "f :: fn() -> ?*i32 { x := 5; return &x; }", &.{local});
    try expectFirstError(a, frame_prelude ++ "f :: fn(n: i32) -> *i32 { return &n; }", &.{"the address of parameter `n` cannot be returned"});
    // A pointer parameter is a copy in the frame too: its own address dangles.
    try expectFirstError(a, frame_prelude ++ "f :: fn(p: *i32) -> **i32 { return &p; }", &.{"the address of parameter `p` cannot be returned"});
    try expectFirstError(a, frame_prelude ++ "f :: fn(p: P) -> *i32 { return &p.x; }", &.{"the address of parameter `p` cannot be returned"});
    // Temporaries.
    const temp = "the address of a temporary cannot be returned";
    try expectFirstError(a, frame_prelude ++ "f :: fn() -> *i32 { return &5; }", &.{temp});
    try expectFirstError(a, frame_prelude ++ "f :: fn() -> *i32 { return &seven(); }", &.{temp});
    try expectFirstError(a, frame_prelude ++ "f :: fn() -> *i32 { x := 5; return &(x + 1); }", &.{temp});
    // A field or an element stored in a local.
    try expectFirstError(a, frame_prelude ++ "f :: fn() -> *i32 { p: P = .{ 1, 2 }; return &p.y; }", &.{"the address of local `p` cannot be returned"});
    try expectFirstError(a, frame_prelude ++ "f :: fn() -> *i32 { b: [4]i32 = .{ 1, 2, 3, 4 }; return &b[2]; }", &.{"the address of local `b` cannot be returned"});
    try expectFirstError(a, frame_prelude ++ "f :: fn() -> *u8 { b: [4]u8 = .{ 1u8, 2u8, 3u8, 4u8 }; return b.ptr; }", &.{"the address of local `b` cannot be returned"});
    // Through a local that holds the address, as far as declarations and plain assignments tell.
    try expectFirstError(a, frame_prelude ++ "f :: fn() -> *i32 { x := 5; q := &x; return q; }", &.{local});
    try expectFirstError(a, frame_prelude ++ "f :: fn() -> *i32 { x := 5; q := &x; r := q; return r; }", &.{local});
    try expectFirstError(a, frame_prelude ++ "f :: fn() -> *i32 { x := 5; q: *i32 = &G; q = &x; return q; }", &.{local});
    try expectFirstError(a, frame_prelude ++ "f :: fn() -> *i32 { x := 5; q := &x; if true { return q; } return &G; }", &.{local});
    try expectFirstError(a, frame_prelude ++ "f :: fn(c: bool) -> *i32 { x := 5; return if c { &x } else { &G }; }", &.{local});
    try expectFirstError(a, frame_prelude ++ "f :: fn() -> *i32 { b: [4]i32 = .{ 1, 2, 3, 4 }; for &e in b { return e; } return &G; }", &.{"the address of local `b` cannot be returned"});
    // Inside an aggregate that is returned.
    try expectFirstError(a, frame_prelude ++ "f :: fn() -> S { x := 5; return .{ .p = &x }; }", &.{local});
    try expectFirstError(a, frame_prelude ++ "f :: fn() -> S { x := 5; s: S = .{ .p = &G }; s.p = &x; return s; }", &.{local});
}

test "diagnostics: returning an address that outlives the function is allowed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try expectNoError(a, frame_prelude, "f :: fn() -> *i32 { return &G; }");
    try expectNoError(a, frame_prelude, "f :: fn() -> *i32 { p := &GA[1]; return p; }");
    try expectNoError(a, frame_prelude, "f :: fn() -> []i32 { return GA[0..2]; }");
    try expectNoError(a, frame_prelude, "f :: fn(p: *i32) -> *i32 { return p; }");
    try expectNoError(a, frame_prelude, "f :: fn(p: *P) -> *i32 { return &p.x; }");
    try expectNoError(a, frame_prelude, "f :: fn(p: *P) -> *i32 { return &(*p).y; }");
    try expectNoError(a, frame_prelude, "f :: fn(p: *P) -> *i32 { q := &p.y; return q; }");
    try expectNoError(a, frame_prelude, "f :: fn(q: *Q) -> []i32 { return q.arr[0..]; }");
    try expectNoError(a, frame_prelude, "f :: fn(q: Q) -> []i32 { return q.s; }");
    try expectNoError(a, frame_prelude, "f :: fn(q: Q) -> *i32 { return &q.s[0]; }");
    try expectNoError(a, frame_prelude, "f :: fn(s: []i32) -> *i32 { return &s[1]; }");
    try expectNoError(a, frame_prelude, "f :: fn(s: []i32) -> []i32 { return s[1..]; }");
    try expectNoError(a, frame_prelude, "f :: fn(s: []i32) -> *i32 { for &e in s { return e; } return &G; }");
    try expectNoError(a, frame_prelude, "f :: fn(out: **i32) -> **i32 { x := 5; return out; }");
    // The value, not the address.
    try expectNoError(a, frame_prelude, "f :: fn() -> i32 { x := 5; q := &x; return *q; }");
    // A local that held a frame address and then was given another.
    try expectNoError(a, frame_prelude, "f :: fn() -> *i32 { x := 5; q := &x; q = &G; return q; }");
    // A store through a pointer parameter does not make the parameter a frame address.
    try expectNoError(a, frame_prelude, "f :: fn(s: *S) -> *S { s.p = &G; return s; }");
    // A lambda's capture lives in its environment, which the caller keeps.
    try expectNoError(a, frame_prelude, "main :: fn() -> i32 { n := 5; g := fn() -> *i32 { return &n; }; return *g(); }");
    // The bytes a function that `#run` calls built in a local array (docs/09_comptime.md).
    try expectNoError(a, frame_prelude, "f :: fn() -> []const u8 { buf: [2]u8 = .{ 97u8, 98u8 }; return buf[:]; }");
}

test "diagnostics: an array type is named in a message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // It was printed as `T`.
    const msg = (try firstError(a, "main :: fn() -> i32 { x: [2]i32 = 5u8; return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, msg, "expected `[2]i32`, found `u8`") != null);
}

test "diagnostics: an array literal with more elements than its array is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The extra elements were dropped without a word.
    const local = (try firstError(a, "main :: fn() -> i32 { x: [3]i32 = .{ 1, 2, 3, 4 }; return x[0]; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, local, "too many elements for `[3]i32`: the literal has 4, the array holds 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, local, "`[3]i32` ends before this element") != null);
    const named = (try firstError(a, "N :: 2 + 1;\nS :: struct { a: [N]u8 }\nmain :: fn() -> i32 { s: S = .{ .{ 1, 2, 3, 4 } }; return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, named, "too many elements for `[3]u8`") != null);
    const arg = (try firstError(a, "f :: fn(x: [2]i32) -> i32 { return x[0]; }\nmain :: fn() -> i32 { return f(.{ 1, 2, 3 }); }")).?;
    try std.testing.expect(std.mem.indexOf(u8, arg, "too many elements for `[2]i32`") != null);
    // Fewer elements are fine: the rest is zero.
    try expectNoError(a, "", "main :: fn() -> i32 { x: [3]i32 = .{ 1 }; y: [3]i32 = .{}; return x[2] + y[0]; }");
}

test "diagnostics: a struct literal value of another type than its field is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pair = "Inner :: struct { x: i32, y: i32 }\nPair :: struct { a: i32, s: Inner, b: bool }\n";
    // `fels check` said "ok" and LLVM crashed in `fels build`: nothing compared a value with its field.
    try expectFirstError(a, pair ++ "main :: fn() -> i32 { p: Pair = .{ 1, true }; return p.a; }", &.{
        "field `s` of `Pair`: expected `Inner`, found `bool`", "expected `Inner`",
    });
    try expectFirstError(a, pair ++ "main :: fn() -> i32 { p: Pair = .{ .a = 1, .s = true, .b = false }; return p.a; }", &.{"field `s` of `Pair`: expected `Inner`, found `bool`"});
    try expectFirstError(a, pair ++ "main :: fn() -> i32 { p: Pair = .{ 1, .{ 2, true } }; return p.a; }", &.{"field `y` of `Inner`: expected `i32`, found `bool`"});
    try expectFirstError(a, pair ++ "f :: fn(p: Pair) -> i32 { return p.a; }\nmain :: fn() -> i32 { return f(.{ true }); }", &.{"field `a` of `Pair`: expected `i32`, found `bool`"});
    try expectFirstError(a, pair ++ "mk :: fn() -> Pair { return .{ 1, .{}, 2.5 }; }", &.{"field `b` of `Pair`: expected `bool`, found `float literal`"});
    try expectFirstError(a, pair ++ "main :: fn() -> i32 { p: Pair = .{}; p = .{ 1, .{}, 4 }; return p.a; }", &.{"field `b` of `Pair`: expected `bool`, found `integer literal`"});
    // The value past the last field was dropped without a word.
    try expectFirstError(a, pair ++ "main :: fn() -> i32 { p: Pair = .{ 1, .{}, true, 4 }; return p.a; }", &.{
        "too many values for `Pair`: the literal has 4, the struct has 3 fields", "`Pair` ends before this value",
    });
    // A literal that stops short is fine: the fields after it take their defaults, then zero.
    try expectNoError(a, pair, "main :: fn() -> i32 { p: Pair = .{ 1 }; q: Pair = .{ 1, .{ 2 } }; r: Pair = .{}; return p.a + q.s.x + r.a; }");
    try expectNoError(a, pair ++ "Color :: enum { red, green }\nRobot :: struct { id: i32, c: Color }\n",
        "main :: fn() -> i32 { s: Inner = .{ 1, 2 }; p: Pair = .{ 1, s, true }; r: Robot = .{ 1, .green }; q: Robot = .{ .c = .red, .id = 2 }; return p.a + r.id + q.id; }");
}

test "diagnostics: an array length computed at compile time is checked against the literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const four = "four :: fn() -> usize { return 4usize; }\n";
    // The comptime VM computes `N` before the strict pass, which checks the literal against 4.
    var ok = try fels.compile(a, "len_ok.fels", four ++ "N :: #run four();\nmain :: fn() -> i32 { x: [N]i32 = .{ 1, 2, 3, 4 }; return x[3]; }");
    ok.deinit(a);
    try std.testing.expectError(error.SemanticFailed, fels.compile(a, "len_local.fels", four ++
        "N :: #run four();\nmain :: fn() -> i32 { x: [N]i32 = .{ 1, 2, 3, 4, 5 }; return x[0]; }"));
    try std.testing.expectError(error.SemanticFailed, fels.compile(a, "len_global.fels", four ++
        "N :: four();\nG: [N]i32 = .{ 1, 2, 3, 4, 5 };\nmain :: fn() -> i32 { return G[0]; }"));
    try std.testing.expectError(error.SemanticFailed, fels.compile(a, "len_field.fels", four ++
        "N :: #run four();\nS :: struct { a: [N]u8 }\nmain :: fn() -> i32 { s: S = .{ .{ 1, 2, 3, 4, 5 } }; return 0; }"));
    // A length that is not a non-negative integer is an error, not an empty array.
    try std.testing.expectError(error.SemanticFailed, fels.compile(a, "len_negative.fels",
        "neg :: fn() -> i32 { return -1; }\nN :: #run neg();\nmain :: fn() -> i32 { x: [N]i32 = .{}; return 0; }"));
    try std.testing.expectError(error.SemanticFailed, fels.compile(a, "len_bool.fels",
        "yes :: fn() -> bool { return true; }\nN :: #run yes();\nmain :: fn() -> i32 { x: [N]i32 = .{}; return 0; }"));
    // The language server's tolerant pass runs no evaluator: there `N` is unknown, which is
    // not an error.
    try expectNoError(a, four, "N :: #run four();\nmain :: fn() -> i32 { x: [N]i32 = .{ 1, 2, 3, 4 }; return x[3]; }");
}

test "diagnostics: a keyword in an import path says to rename the file or folder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Once just "expected ; after import", which does not say what is wrong with the path.
    var p = try fels.parser_mod.Parser.init(a, "kw.fels", "#import app.import.prices;\n", 1);
    try std.testing.expectError(error.ParseFailed, p.parseModule());
    try std.testing.expectEqual(@as(usize, 1), p.diagnostics.items.len);
    try std.testing.expectEqualStrings(
        "`import` is a keyword, so a file or folder of that name cannot be imported; rename it",
        p.diagnostics.items[0].message,
    );
}
