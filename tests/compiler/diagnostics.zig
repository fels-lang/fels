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

test "diagnostics: a type argument that is not a one-level pointer type has a message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `**G` in the argument list is read as an expression, not a type; that used to fail the
    // build without saying why.
    const bad =
        \\G :: struct { a: u32 }
        \\f :: fn() -> i32 { p: **G = unsafe (core::ptr_from_int(**G, 0usize)); return 0; }
    ;
    try std.testing.expectError(error.SemanticFailed, gabbro.compile(arena.allocator(), "ptrptr.gab", bad));
    const good =
        \\G :: struct { a: u32 }
        \\f :: fn() -> i32 { p: *G = unsafe (core::ptr_from_int(*G, 0usize)); return 0; }
    ;
    var fe = try gabbro.compile(arena.allocator(), "ptr.gab", good);
    fe.deinit(arena.allocator());
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
