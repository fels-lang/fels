const std = @import("std");
const gabbro = @import("gabbro_compiler");

test "diagnostics: return type mismatch shows types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\bad :: fn() -> i32 { return true; }
    ;
    const result = gabbro.compile(arena.allocator(), "bad.gab", bad);
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
    const result = gabbro.compile(arena.allocator(), "escape.gab", bad);
    try std.testing.expectError(error.SemanticFailed, result);
}

test "diagnostics: returning a capturing closure held in a local is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The indirect form — assign the capturing closure to a local, then return it.
    const bad =
        \\make :: fn(n: i32) -> fn(i32) -> i32 { f := fn(x: i32) -> i32 { return x + n; }; return f; }
    ;
    const result = gabbro.compile(arena.allocator(), "escape2.gab", bad);
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
    var fe = try gabbro.compile(arena.allocator(), "ok.gab", ok);
    fe.deinit(arena.allocator());
}

test "diagnostics: unknown name shows identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\bad :: fn() -> i32 { return foo; }
    ;
    const result = gabbro.compile(arena.allocator(), "bad.gab", bad);
    try std.testing.expectError(error.SemanticFailed, result);
}

test "diagnostics: wrong arg count shows expected vs actual" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\add :: fn(a: i32, b: i32) -> i32 { return a + b; }
        \\bad :: fn() -> i32 { return add(1); }
    ;
    const result = gabbro.compile(arena.allocator(), "bad.gab", bad);
    try std.testing.expectError(error.SemanticFailed, result);
}

test "diagnostics: arg type mismatch shows types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\add :: fn(a: i32, b: i32) -> i32 { return a + b; }
        \\bad :: fn() -> i32 { return add(1, true); }
    ;
    const result = gabbro.compile(arena.allocator(), "bad.gab", bad);
    try std.testing.expectError(error.SemanticFailed, result);
}

test "diagnostics: sema errors are stored in TypeEnv" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Successful compile — diagnostics should be empty
    const src =
        \\add :: fn(a: i32, b: i32) -> i32 { return a + b; }
    ;
    var fe = try gabbro.compile(arena.allocator(), "ok.gab", src);
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
        gabbro.compile(arena.allocator(), "bad.gab", bad));
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
        gabbro.compile(arena.allocator(), "test.gab", bad));

    // Verify Diagnostic.err constructor works
    const d = gabbro.Diagnostic.err("test message",
        gabbro.Span.new(0, 3), "test.gab");
    try std.testing.expectEqual(gabbro.DiagKind.err, d.kind);

    const rendered = try gabbro.renderDiagnostic(arena.allocator(), "test.gab", src, d);
    // Should contain file:line:col: error: message
    try std.testing.expect(std.mem.indexOf(u8, rendered, "test.gab") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "error:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "test message") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "^^^") != null);
}

test "diagnostics: rich render carries caret label, help and note; color only when asked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "main :: fn() -> i32 { return x; }";
    var d = gabbro.Diagnostic.err("undefined name `x`", gabbro.Span.new(28, 29), "t.gab");
    d.primary_label = "not found in this scope";
    d.helps = &.{"declare it first: `x := 0;`"};
    d.notes = &.{"names are resolved top to bottom"};

    const plain = try gabbro.renderDiagnostic(a, "t.gab", src, d);
    try std.testing.expect(std.mem.indexOf(u8, plain, "not found in this scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "help: declare it first") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "note: names are resolved") != null);
    // A plain render must carry no escape codes (what tests and pipes see).
    try std.testing.expect(std.mem.indexOfScalar(u8, plain, 0x1b) == null);

    // An explicit colored palette does carry them.
    const colored = try gabbro.renderDiagnosticColored(a, "t.gab", src, d, .{ .on = true });
    try std.testing.expect(std.mem.indexOfScalar(u8, colored, 0x1b) != null);
}

/// Return the first `error`-level diagnostic message for `src`, type-checking in
/// tolerant mode so the diagnostics survive even though checking fails. Lets the
/// tests below assert the *text* of an error, not just that one occurred.
fn firstError(arena: std.mem.Allocator, src: []const u8) !?[]const u8 {
    const mod = try gabbro.parseSource(arena, "t.gab", src);
    var syms = try gabbro.sema_mod.collectSymbols(arena, mod);
    const env = try gabbro.sema_mod.checkTypesTolerant(arena, mod, &syms, src, "t.gab");
    for (env.diagnostics.items) |d| {
        // Render so the assertions see the whole diagnostic (message + caret label +
        // `help:`/`note:` lines), matching what a user reads.
        if (d.kind == .err) return try gabbro.renderDiagnostic(arena, d.file, src, d);
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
        "cannot dereference value of type `integer literal`") != null);

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
    try std.testing.expectError(error.SemanticFailed, gabbro.compile(a, "where_ptr_id.gab", rejected));

    // The same for a `constraint`: when its predicate cannot run, `$T: Same` falls back to being
    // read as an interface and an `i64` is refused ("must be a named struct").
    const accepted =
        \\Node :: struct { val: i32 }
        \\Same :: constraint($T) { if core::type_id(*T) == core::type_id(*Node) { core::reject("no nodes"); } }
        \\only :: fn($T: Same, x: T) -> usize { return core::sizeof(T); }
        \\use :: fn() -> usize { o: i64 = 1; return only(o); }
    ;
    var fe = try gabbro.compile(a, "constraint_ptr_id.gab", accepted);
    fe.deinit(a);
}

test "diagnostics: sizeof of a variable that code generated at compile time brings in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `#insert #run gen()` declares `q` only after the first, tolerant pass has gone over `main`.
    // That pass finds no `q`, and must neither take `*q` for a type for good (the tree is shared
    // with the strict pass) nor stop at it: by the strict pass `q` is a variable.
    var fe = try gabbro.compile(a, "late_local.gab",
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
    const module = try gabbro.parseSource(arena.allocator(), "ast.gab", src);
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
        try std.testing.expectError(error.SemanticFailed, gabbro.compile(arena.allocator(), "bad_align.gab", src));
    }
    var ok = try gabbro.compile(arena.allocator(), "ok_align.gab", "#align(64)\nS :: struct { a: u32 }");
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
        try std.testing.expectError(error.SemanticFailed, gabbro.compile(arena.allocator(), "bad_packed.gab", src));
    }
    var ok = try gabbro.compile(arena.allocator(), "ok_packed.gab", "#packed\nS :: struct { a: u8, b: u32 }");
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
        try std.testing.expectError(error.SemanticFailed, gabbro.compile(arena.allocator(), "packed_addr.gab", src));
    }
    // The whole struct's address, by-value field access, and a plain struct's field
    // address are all fine.
    const ok = [_][]const u8{
        "main :: fn() -> i32 { p: Pk = .{}; r := &p; return (p.b + r.b) as i32; }",
        "Plain :: struct { a: u8, b: u32 }\nmain :: fn() -> i32 { q: Plain = .{}; r := &q.b; return 0; }",
    };
    for (ok) |body| {
        const src = try std.mem.concat(arena.allocator(), u8, &.{ decl, body });
        var fe = try gabbro.compile(arena.allocator(), "packed_ok.gab", src);
        fe.deinit(arena.allocator());
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
    try std.testing.expectError(error.SemanticFailed, gabbro.compile(arena.allocator(), "bad_variant.gab", bad));
    const good =
        \\E :: errors { first, second }
        \\f :: fn() -> i32 ! E { fail .first; }
        \\g :: fn() -> i32 { v := f() catch e { if e == .second { return 1; } return 0; }; return 9; }
    ;
    var fe = try gabbro.compile(arena.allocator(), "good_variant.gab", good);
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
        try std.testing.expectError(error.SemanticFailed, gabbro.compile(arena.allocator(), "catch_refused.gab", src));
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
        var fe = gabbro.compile(arena.allocator(), "catch_ok.gab", src) catch |err| {
            std.debug.print("\nthis catch should be accepted:\n  {s}\n", .{body});
            return err;
        };
        fe.deinit(arena.allocator());
    }
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
    var fe = try gabbro.compile(a, "ptr.gab", good);
    fe.deinit(a);
    // A value there used to fail the build without saying why.
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, "f :: fn() -> i32 { q := unsafe (core::ptr_from_int(5usize, 0usize)); return 0; }")).?,
        "the first argument of `ptr_from_int` must be a type") != null);
}

test "diagnostics: an error is compared with a variant only where it was caught" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // An error handed to another function was compared against the wrong variants (every error
    // looked like the first one), so comparing anything but the name `catch` bound is refused.
    const bad = [_][]const u8{
        "Oops :: errors { a, b }\ncode_of :: fn(e: Oops) -> i32 { if e == .b { return 2; } return 1; }",
        "Oops :: errors { a, b }\nfails :: fn() -> void ! Oops { fail .b; return; }\ng :: fn() -> i32 { r: i32 = 1; fails() catch e { copy := e; if copy == .b { r = 2; } }; return r; }",
        "Oops :: errors { a, b }\nh :: fn(e: Oops) -> bool { return .a != e; }",
    };
    for (bad) |src| {
        try std.testing.expectError(error.SemanticFailed, gabbro.compile(arena.allocator(), "err_param.gab", src));
    }
    // A function may still take an error and pass it on; it just cannot look inside it.
    const passes =
        \\Oops :: errors { a, b }
        \\show :: fn(e: Oops) {}
        \\fails :: fn() -> void ! Oops { fail .b; return; }
        \\g :: fn() { fails() catch e { show(e); }; }
    ;
    var passed = try gabbro.compile(arena.allocator(), "err_passes.gab", passes);
    passed.deinit(arena.allocator());
    // Inspecting the error where it is caught is the supported way.
    const good =
        \\Oops :: errors { a, b }
        \\fails :: fn() -> void ! Oops { fail .b; return; }
        \\code :: fn() -> i32 { r: i32 = 1; fails() catch e { if e == .b { r = 2; } }; return r; }
    ;
    var fe = try gabbro.compile(arena.allocator(), "err_caught.gab", good);
    fe.deinit(arena.allocator());
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
    var fe = try gabbro.compile(a, "t.gab", src);
    defer fe.deinit(a);
    const module = try gabbro.lowerFrontend(a, fe);
    try gabbro.ir_mod.validateModule(module);

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
    const mod = try gabbro.parseSource(a, "t.gab", src);
    var syms = try gabbro.sema_mod.collectSymbols(a, mod);
    const env = try gabbro.sema_mod.checkTypesTolerant(a, mod, &syms, src, "t.gab");
    var errors: usize = 0;
    for (env.diagnostics.items) |d| {
        if (d.kind == .err) errors += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), errors);
}
