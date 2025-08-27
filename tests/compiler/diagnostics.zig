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
        var fe = try gabbro.compile(arena.allocator(), "addr_lit_ok.gab", src);
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
        try std.testing.expectError(error.SemanticFailed, gabbro.compile(arena.allocator(), "addr_lit_bad.gab", src));
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

test "diagnostics: `match` on a caught error is refused, whatever its set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `err == .x` is the way to inspect an error. `match` does not accept one; that must stay a
    // compile error for an inferred set (`-> T !`) too, where comparing used to go wrong silently.
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
        const msg = (try firstError(a, src)) orelse {
            std.debug.print("\n`match` on an error from `{s}` was accepted\n", .{callee});
            return error.TestExpectedError;
        };
        try std.testing.expect(std.mem.indexOf(u8, msg, "match subject must be an enum or integer type") != null);
    }
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
    // A pointer of another type is still refused, and the message names the real type.
    const wrong_width = (try firstError(a, "main :: fn() -> i32 { x := 42; p: *i64 = &x; return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, wrong_width, "found `*i32`") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrong_width, "literal") == null);
    const wrong_float = (try firstError(a, "main :: fn() -> i32 { x := 1.5; p: *f32 = &x; return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, wrong_float, "found `*f64`") != null);
    // What the pointer reads back is an `i32`, not a literal that could widen.
    const through_ptr = (try firstError(a, "main :: fn() -> i32 { x := 0; p := &x; y: i64 = *p; return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, through_ptr, "found `i32`") != null);
    // The local itself is an `i32` too: reading it as another integer type is refused. It used
    // to be accepted and read with the wrong width (`x := -5; y: i64 = x;` gave `y != -5`).
    const widened = (try firstError(a, "main :: fn() -> i32 { x := 5; y: i64 = x; return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, widened, "found `i32`") != null);
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
        .{ "f :: fn() -> i32 ! E { fail .big { 300 }; }", "`300` does not fit in `u8`" },
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
    // stored it as an `i32`: four bytes into the `u8`, which overwrote the next local.
    try expectFirstError(a, "main :: fn() -> i32 { x := 5; b: u8 = x; return 0; }", &.{"type mismatch: expected `u8`, found `i32`"});
    try expectFirstError(a, "main :: fn() -> i32 { x := 0; n: usize = 5; x = n; return 0; }", &.{"expected `i32`, found `usize`"});
    try expectFirstError(a, "main :: fn() -> i32 { x := 5000000000; return 0; }", &.{
        "integer literal `5000000000` does not fit in `i32`", "as in `5000000000i64`",
    });
    try expectFirstError(a, "main :: fn() -> i32 { x := -3000000000; return 0; }", &.{"as in `-3000000000i64`"});
    try expectFirstError(a, "main :: fn() -> i32 { x := 0xFFFF_FFFF; return 0; }", &.{"as in `0xFFFF_FFFFu32`"});
    try expectFirstError(a, "main :: fn() -> i32 { c := true; x := if c { 1 } else { 3000000000 }; return 0; }", &.{"`3000000000` does not fit in `i32`"});
    try expectNoError(a, "", "main :: fn() -> i32 { x := -2147483648; y := 2147483647; z: i64 = x as i64; w := 5000000000i64; return y; }");
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
