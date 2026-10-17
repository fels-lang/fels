const std = @import("std");
const fels = @import("fels_compiler");
const ir = @import("fels_compiler").ir_mod;

test "comptime: #if with TARGET.os compiles both branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\write :: fn(msg: []const u8) -> i32 {
        \\    #if TARGET.os == .windows {
        \\        return 1;
        \\    } else {
        \\        return 2;
        \\    }
        \\}
    ;
    var fe = try fels.compile(arena.allocator(), "ct.fels", src);
    defer fe.deinit(arena.allocator());
    const m = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(m);
}

test "comptime: #if takes else #if, a chain of tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // There was no `else if`: the next test had to go inside the `else` block.
    const src =
        \\pick :: fn(n: i32) -> i32 {
        \\    #if TARGET.os == .linux { return 1; } else #if TARGET.os == .windows { return 2; } else { return 3; }
        \\}
        \\third :: fn() -> i32 {
        \\    #if false { return 1; } else #if false { return 2; } else { return 3; }
        \\}
        \\P :: #run pick(0);
        \\Q :: #run third();
    ;
    var fe = try fels.compile(arena.allocator(), "ct_chain.fels", src);
    defer fe.deinit(arena.allocator());
    const m = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(m);
    const want_p: i128 = if (@import("builtin").os.tag == .linux) 1 else if (@import("builtin").os.tag == .windows) 2 else 3;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "P")) try std.testing.expectEqual(ir.Imm{ .int = want_p }, g.init.imm);
        if (std.mem.eql(u8, g.name, "Q")) try std.testing.expectEqual(ir.Imm{ .int = 3 }, g.init.imm);
    }
}

test "comptime: #run expression as value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\double :: fn(x: i32) -> i32 { return x * 2; }
        \\ANSWER :: #run double(21);
    ;
    var fe = try fels.compile(arena.allocator(), "ct2.fels", src);
    defer fe.deinit(arena.allocator());
    const m = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(m);
}

test "comptime: #run block at statement level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\setup :: fn() -> i32 { return 42; }
        \\
        \\main :: fn() -> i32 {
        \\    result := 0;
        \\    #run {
        \\        result = setup();
        \\    }
        \\    return result;
        \\}
    ;
    var fe = try fels.compile(arena.allocator(), "ct3.fels", src);
    defer fe.deinit(arena.allocator());
    const m = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(m);
}

test "#run: constant computed at compile time, not runtime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\// Recursive fibonacci computed ENTIRELY at compile time.
        \\fib :: fn(n: i32) -> i32 {
        \\    if n <= 1 { return n; }
        \\    return fib(n - 1) + fib(n - 2);
        \\}
        \\
        \\FIB_10 :: #run fib(10);    // = 55  — no runtime call
        \\FIB_7  :: #run fib(7);     // = 13  — no runtime call
        \\ANSWER :: #run fib(6) * 7; // = 8*7 = 56? no: fib(6)=8, 8*7=56
        \\
        \\use_them :: fn() -> i32 {
        \\    return FIB_10 + FIB_7;   // 55 + 13 = 68
        \\}
    ;
    var fe = try fels.compile(arena.allocator(), "fib_ct.fels", src);
    defer fe.deinit(arena.allocator());
    const m = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(m);

    // The globals should be initialised with COMPILE-TIME constants, not function calls.
    var found_fib10 = false;
    var found_fib7 = false;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "FIB_10")) {
            found_fib10 = true;
            // Must be a compile-time integer constant (not unknown/null)
            try std.testing.expectEqual(ir.Imm{ .int = 55 }, g.init.imm);
        }
        if (std.mem.eql(u8, g.name, "FIB_7")) {
            found_fib7 = true;
            try std.testing.expectEqual(ir.Imm{ .int = 13 }, g.init.imm);
        }
    }
    try std.testing.expect(found_fib10);
    try std.testing.expect(found_fib7);
}

test "#run: string .len and enum-payload construction fold on the VM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // `s.len` on a `.text` string and `EnumType.variant(payload)` construction
    // both used to be unsupported in the comptime VM (string fell through the
    // `.len` switch; payload variants couldn't be built at all).
    const src =
        \\Tok :: enum { num: i32, word: []const u8, end }
        \\slen :: fn() -> i32 { s := "hello"; return s.len as i32; }
        \\enum_payload :: fn() -> i32 {
        \\    t := Tok.num(20);
        \\    match t { .num |v| => return v + 1; else => return -1; }
        \\}
        \\str_payload :: fn() -> i32 {
        \\    t := Tok.word("abcd");
        \\    match t { .word |w| => return w.len as i32; else => return -1; }
        \\}
        \\LEN :: #run slen();          // 5
        \\EP  :: #run enum_payload();  // 21
        \\SP  :: #run str_payload();   // 4
    ;
    var fe = try fels.compile(arena.allocator(), "vmstr.fels", src);
    defer fe.deinit(arena.allocator());
    const m = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(m);

    var got: usize = 0;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "LEN")) {
            got += 1;
            try std.testing.expectEqual(ir.Imm{ .int = 5 }, g.init.imm);
        }
        if (std.mem.eql(u8, g.name, "EP")) {
            got += 1;
            try std.testing.expectEqual(ir.Imm{ .int = 21 }, g.init.imm);
        }
        if (std.mem.eql(u8, g.name, "SP")) {
            got += 1;
            try std.testing.expectEqual(ir.Imm{ .int = 4 }, g.init.imm);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), got);
}

test "#run: a string's escapes are resolved, as at run time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The VM read the escapes as written: "a\nb\"c" was 7 bytes at compile time and 5 at run
    // time, and a `#run` string result kept its backslashes.
    const src =
        \\slen :: fn() -> i32 { s := "a\nb\"c"; return s.len as i32; }
        \\hex :: fn() -> i32 { s := "\x41\\"; return (s[0] as i32) * 100 + s.len as i32; }
        \\LEN :: #run slen();           // 5
        \\HEX :: #run hex();            // 'A' * 100 + 2
        \\TEXT :: #run "tab\there";     // the 8 bytes, with a real tab
    ;
    var fe = try fels.compile(arena.allocator(), "vmesc.fels", src);
    defer fe.deinit(arena.allocator());
    const m = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(m);

    var got: usize = 0;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "LEN")) {
            got += 1;
            try std.testing.expectEqual(ir.Imm{ .int = 5 }, g.init.imm);
        }
        if (std.mem.eql(u8, g.name, "HEX")) {
            got += 1;
            try std.testing.expectEqual(ir.Imm{ .int = 'A' * 100 + 2 }, g.init.imm);
        }
        if (std.mem.eql(u8, g.name, "TEXT")) {
            got += 1;
            try std.testing.expectEqualStrings("tab\there", g.init.imm.text);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), got);
}

test "#run: print and println write at compile time and return the byte count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The runtime's write_stdout reached the host through pointers into VM memory and stopped
    // the VM; now the VM writes the bytes itself.
    const src =
        \\#import std.io.{ print, println };
        \\count :: fn() -> i32 {
        \\    a := print("abc") catch err { return -1; };
        \\    b := println("de") catch err { return -1; };
        \\    return (a + b) as i32;
        \\}
        \\N :: #run count();            // 3 + "de\n"
    ;
    const io = std.testing.io;
    std.Io.Dir.cwd().createDirPath(io, ".zig-cache/vmprint") catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ".zig-cache/vmprint/vmprint.fels", .data = src });
    var fe = try fels.compileFileWithRuntime(arena.allocator(), io, ".zig-cache/vmprint/vmprint.fels");
    defer fe.deinit(arena.allocator());
    const m = try fels.lowerFrontend(arena.allocator(), fe);
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "N")) return std.testing.expectEqual(ir.Imm{ .int = 6 }, g.init.imm);
    }
    return error.TestUnexpectedResult;
}

test "#run: taking the address of a scalar local folds on the VM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // `&x` of a scalar local used to be unsupported in the comptime VM, so the
    // function trapped and the const silently folded to a wrong value. Now the
    // local is spilled to an addressable cell and the result is correct.
    const src =
        \\bump :: fn() -> i32 {
        \\    x := 5;
        \\    p := &x;
        \\    *p = *p + 1;
        \\    return x;
        \\}
        \\incr :: fn(p: *i32) { *p = *p + 10; }
        \\via_param :: fn(start: i32) -> i32 {
        \\    n := start;
        \\    incr(&n);
        \\    return n;
        \\}
        \\R1 :: #run bump();          // 6
        \\R2 :: #run via_param(1);    // 11
    ;
    var fe = try fels.compile(arena.allocator(), "addr_ct.fels", src);
    defer fe.deinit(arena.allocator());
    const m = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(m);

    var r1: bool = false;
    var r2: bool = false;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "R1")) {
            r1 = true;
            try std.testing.expectEqual(ir.Imm{ .int = 6 }, g.init.imm);
        }
        if (std.mem.eql(u8, g.name, "R2")) {
            r2 = true;
            try std.testing.expectEqual(ir.Imm{ .int = 11 }, g.init.imm);
        }
    }
    try std.testing.expect(r1 and r2);
}

test "#run: a struct, array or enum result becomes the data of a global" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // What a `#run` returns is read back out of the VM and becomes constant data, however it was
    // declared: with no type (`PAIR ::`, the type is the call's), with one, or as a field.
    const src =
        \\P :: struct { x: i32, y: i32 }
        \\Mode :: enum { fast, slow, off }
        \\Wrap :: struct { p: P, tail: [3]u32 }
        \\make_p :: fn() -> P { return .{ 1, 2 }; }
        \\make_a :: fn() -> [4]u32 { return .{ 10, 20, 0, 0 }; }
        \\make_m :: fn() -> Mode { return .off; }
        \\PAIR :: #run make_p();
        \\ARR: [4]u32 = #run make_a();
        \\MODE: Mode = #run make_m();
        \\W: Wrap = .{ #run make_p(), .{ 7, 8, 9 } };
    ;
    var fe = try fels.compile(arena.allocator(), "run_aggregate.fels", src);
    defer fe.deinit(arena.allocator());
    const m = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(m);

    var seen: u32 = 0;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "PAIR")) {
            seen += 1;
            const fields = g.init.struct_init.fields;
            try std.testing.expectEqual(@as(usize, 2), fields.len);
            try std.testing.expectEqual(ir.Imm{ .int = 1 }, fields[0].value.imm);
            try std.testing.expectEqual(ir.Imm{ .int = 2 }, fields[1].value.imm);
            try std.testing.expect(!g.mutable);
        }
        if (std.mem.eql(u8, g.name, "ARR")) {
            seen += 1;
            // An array is zero past its last element, so the trailing zeros are not kept.
            try std.testing.expectEqual(@as(usize, 2), g.init.array_init.len);
            try std.testing.expectEqual(ir.Imm{ .int = 20 }, g.init.array_init[1].imm);
        }
        if (std.mem.eql(u8, g.name, "MODE")) {
            seen += 1;
            try std.testing.expectEqual(@as(u32, 2), g.init.variant_tag);
        }
        if (std.mem.eql(u8, g.name, "W")) {
            seen += 1;
            const fields = g.init.struct_init.fields;
            try std.testing.expectEqual(ir.Imm{ .int = 2 }, fields[0].value.struct_init.fields[1].value.imm);
            try std.testing.expectEqual(ir.Imm{ .int = 9 }, fields[1].value.array_init[2].imm);
        }
    }
    try std.testing.expectEqual(@as(u32, 4), seen);
}

test "#run: a result that cannot be data fails with a diagnostic, not silent garbage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Each of these runs fine on the VM; what it returns just has no place in the image.
    const head =
        \\Holder :: struct { p: *i32 }
        \\Shape :: enum { circle: i32, none }
        \\Cbs :: struct { f: fn(i32) -> i32 }
        \\
    ;
    const refused = [_][]const u8{
        // a pointer into compile-time memory: the program will not have that memory (passed
        // through a call, since the checker rejects a plain `return .{ &x }` itself)
        "addr :: fn(p: *i32) -> *i32 { return p; }\nmk :: fn() -> Holder { x := 5; return .{ addr(&x) }; }\nH: Holder = #run mk();",
        // an element the type cannot hold: a checked u8 addition that overflowed
        "mk :: fn() -> [2]u8 { x: u8 = 200u8; y: u8 = 100u8; a: [2]u8 = .{}; a[0] = x + y; return a; }\nA: [2]u8 = #run mk();",
        // a slice of anything but bytes
        "mk :: fn() -> []const u32 { a: [2]u32 = .{ 1, 2 }; return a[:]; }\nS: []const u32 = #run mk();",
        // a lambda has no plain code address, returned from a call or put in a function-pointer field
        "pick :: fn() -> fn(i32) -> i32 { return fn(x: i32) -> i32 { return x + 3; }; }\nF: fn(i32) -> i32 = #run pick();",
        "mk :: fn() -> Cbs { k := 3; return .{ fn(x: i32) -> i32 { return x + k; } }; }\nC: Cbs = #run mk();",
    };
    for (refused) |decl| {
        const src = try std.mem.concat(arena.allocator(), u8, &.{ head, decl, "\n" });
        var fe = fels.compile(arena.allocator(), "run_refused.fels", src) catch |err| {
            std.debug.print("\nthe front end should accept (the VM is what refuses it):\n  {s}\n", .{decl});
            return err;
        };
        defer fe.deinit(arena.allocator());
        if (fels.lowerFrontend(arena.allocator(), fe)) |_| {
            std.debug.print("\nthis should have been refused when lowered:\n  {s}\n", .{decl});
            return error.TestUnexpectedResult;
        } else |err| try std.testing.expectEqual(error.LoweringFailed, err);
    }
}

test "#run: a global another #run computes is not readable by it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The VM that evaluates a `#run` is built before any `#run` has a value, so a global that a
    // `#run` computes is not there to read. It stops the evaluation (and says so) rather than
    // reading a stand-in that looks like a value.
    const src =
        \\P :: struct { x: i32, y: i32 }
        \\make_p :: fn() -> P { return .{ 1, 2 }; }
        \\FIRST: P = #run make_p();
        \\second_x :: fn() -> i32 { return FIRST.x + 1; }
        \\SECOND: i32 = #run second_x();
    ;
    var fe = try fels.compile(arena.allocator(), "run_chain.fels", src);
    defer fe.deinit(arena.allocator());
    try std.testing.expectError(error.LoweringFailed, fels.lowerFrontend(arena.allocator(), fe));
}

test "#run: a constant may call a function declared below it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Sema used to type the constants in the same walk that records the function signatures, so
    // a constant above its callee was an internal compiler error ("function symbol has no
    // signature record"). The second program has a `where` clause, so it is checked twice: by
    // the tolerant pre-pass and then by the strict pass.
    const decls =
        \\E :: errors { bad }
        \\setup :: fn() -> void ! E { return; }
        \\COMPTIME :: #run comptime_ok();
        \\PLAIN :: seven();
        \\comptime_ok :: fn() -> i32 {
        \\    setup() catch err { return 1; };
        \\    return 7;
        \\}
        \\seven :: fn() -> i32 { return 7; }
        \\main :: fn() -> i32 { return COMPTIME + PLAIN; }
        \\
    ;
    const where_fn =
        \\dbl :: fn(x: $T) -> T
        \\where { match core::type_info(T) { .int => {} else => core::reject("needs an integer"); } }
        \\{ return x +% x; }
        \\
    ;
    for ([_][]const u8{ decls, decls ++ where_fn }) |src| {
        var fe = try fels.compile(arena.allocator(), "run_above.fels", src);
        defer fe.deinit(arena.allocator());
        const m = try fels.lowerFrontend(arena.allocator(), fe);
        try fels.ir_mod.validateModule(m);
        var found: usize = 0;
        for (m.globals) |g| {
            if (std.mem.eql(u8, g.name, "COMPTIME") or std.mem.eql(u8, g.name, "PLAIN")) {
                found += 1;
                try std.testing.expectEqual(ir.Imm{ .int = 7 }, g.init.imm);
            }
        }
        try std.testing.expectEqual(@as(usize, 2), found);
    }
}

// The VM computes in 128 bits. A value that a narrower type would have dropped bits from must be
// narrowed the way the machine does it: after a wrapping operation, a left shift, `~`, and a cast.
// Without that, `x ^ (x << 13)` on a u32 keeps its high bits and the `>> 17` that follows shifts
// them back down into the number: an in-range, wrong, silent result.
const wrapping =
    \\wrap_add :: fn() -> u32 { a: u32 = 0xFFFFFFFFu32; return a +% 1u32; }
    \\wrap_sub :: fn() -> u32 { a: u32 = 0u32; return a -% 1u32; }
    \\wrap_mul :: fn() -> u32 { a: u32 = 2166136261u32; return a *% 16777619u32; }
    \\shl32 :: fn() -> u32 { a: u32 = 0x80000001u32; return a << 1u32; }
    \\shl16 :: fn() -> u16 { a: u16 = 0x8001u16; return a << 1u16; }
    \\i8wrap :: fn() -> i8 { a: i8 = 127i8; return a +% 1i8; }
    \\not32 :: fn() -> u32 { a: u32 = 0u32; return ~a; }
    \\not8 :: fn() -> u8 { a: u8 = 0x0Fu8; return ~a; }
    \\cast_u8 :: fn() -> u8 { a: u32 = 300u32; return a as u8; }
    \\cast_i32 :: fn() -> i32 { a: u32 = 0xFFFFFFFFu32; return a as i32; }
    \\cast_u32 :: fn() -> u32 { a: i32 = -1; return a as u32; }
    \\cast_u64 :: fn() -> u64 { a: i32 = -1; return a as u64; }
    \\xorshift :: fn() -> u32 {
    \\    x: u32 = 2463534242u32;
    \\    x = x ^ (x << 13u32);
    \\    x = x ^ (x >> 17u32);
    \\    x = x ^ (x << 5u32);
    \\    return x;
    \\}
    \\fnv :: fn() -> u32 {
    \\    h: u32 = 2166136261u32;
    \\    h = (h ^ 97u32) *% 16777619u32;
    \\    h = (h ^ 98u32) *% 16777619u32;
    \\    return h;
    \\}
    \\
;

test "comptime: wrapping arithmetic, shifts, ~ and casts drop what the type cannot hold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The expected values are the ones the machine gives (and Python, for the two hashes).
    const holds = [_][]const u8{
        "wrap_add() == 0u32",
        "wrap_sub() == 0xFFFFFFFFu32",
        "wrap_mul() == 84696351u32",
        "shl32() == 2u32",
        "shl16() == 2u16",
        "i8wrap() == -128i8",
        "not32() == 0xFFFFFFFFu32",
        "not8() == 0xF0u8",
        "cast_u8() == 44u8",
        "cast_i32() == -1",
        "cast_u32() == 0xFFFFFFFFu32",
        "cast_u64() == 0xFFFFFFFFFFFFFFFFu64",
        "xorshift() == 723471715u32",
        "fnv() == 1294271946u32",
    };
    for (holds) |cond| {
        const src = try std.fmt.allocPrint(arena.allocator(), "{s}#assert({s}, \"narrowing\");\nmain :: fn() -> i32 {{ return 0; }}\n", .{ wrapping, cond });
        var fe = try fels.compile(arena.allocator(), "wrapping.fels", src);
        defer fe.deinit(arena.allocator());
        _ = fels.lowerFrontend(arena.allocator(), fe) catch |err| {
            std.debug.print("\nthis should hold at compile time, as it does on the machine:\n  {s}\n", .{cond});
            return err;
        };
    }
}

test "#run: a comptime @panic halts the build with its message (#2)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A comptime `@panic("…")` used to bare-trap (message thrown away). It now
    // records the message via `halt_msg` and the `#run` fails with it instead of
    // the generic "could not be evaluated". The text goes straight to stderr, so
    // this asserts the halt (LoweringFailed); the message itself is verified by
    // eye — `error: explicit comptime panic`.
    const src =
        \\boom :: fn() -> i32 { @panic("explicit comptime panic"); return 0; }
        \\BAD :: #run boom();
    ;
    var fe = try fels.compile(arena.allocator(), "panic_ct.fels", src);
    defer fe.deinit(arena.allocator());
    try std.testing.expectError(error.LoweringFailed, fels.lowerFrontend(arena.allocator(), fe));
}

test "#if: only live branch emitted to IR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\platform_id :: fn() -> i32 {
        \\    #if TARGET.os == .windows {
        \\        return 1;
        \\    } else {
        \\        return 2;
        \\    }
        \\}
    ;
    var fe = try fels.compile(arena.allocator(), "platform.fels", src);
    defer fe.deinit(arena.allocator());
    const m = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(m);

    // Find platform_id and verify it compiled (the #if selected a branch)
    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "platform_id")) break f;
    } else return error.FunctionNotFound;
    try std.testing.expect(fn_.blocks.len > 0);
}

fn expectGlobalInt(m: anytype, name: []const u8, want: i128) !void {
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, name)) {
            const got: i128 = switch (g.init.imm) {
                .int => |v| v,
                .uint => |v| @intCast(v),
                .bool => |b| @intFromBool(b),
                else => return error.NotAnInt,
            };
            try std.testing.expectEqual(want, got);
            return;
        }
    }
    return error.GlobalNotFound;
}

test "comptime: matchable TypeInfo — scalar kinds + fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\bits_of   :: fn($T: type) -> i32 { match core::type_info(T) { .int |i| => return i.bits as i32; .float |f| => return f.bits as i32; else => return 0; } }
        \\is_signed :: fn($T: type) -> i32 { match core::type_info(T) { .int |i| => { if i.signed { return 1; } return 0; } else => return -1; } }
        \\is_bool   :: fn($T: type) -> i32 { match core::type_info(T) { .boolean => return 1; else => return 0; } }
        \\I32_BITS   :: #run bits_of(i32);
        \\U8_BITS    :: #run bits_of(u8);
        \\F64_BITS   :: #run bits_of(f64);
        \\I32_SIGNED :: #run is_signed(i32);
        \\U8_SIGNED  :: #run is_signed(u8);
        \\BOOL_IS    :: #run is_bool(bool);
    ;
    var fe = try fels.compile(arena.allocator(), "ti1.fels", src);
    defer fe.deinit(arena.allocator());
    const m = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(m);

    try expectGlobalInt(m, "I32_BITS", 32);
    try expectGlobalInt(m, "U8_BITS", 8);
    try expectGlobalInt(m, "F64_BITS", 64);
    try expectGlobalInt(m, "I32_SIGNED", 1);
    try expectGlobalInt(m, "U8_SIGNED", 0);
    try expectGlobalInt(m, "BOOL_IS", 1);
}

test "comptime: matchable TypeInfo — struct fields (iterate names + types)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Point :: struct { x: i32, yy: i32, zzz: i32 }
        \\nfields  :: fn($T: type) -> i32 { match core::type_info(T) { .struct_ |s| => return s.fields.len as i32; else => return -1; } }
        \\namelen  :: fn($T: type) -> i32 { match core::type_info(T) { .struct_ |s| => return s.name.len as i32; else => return -1; } }
        \\namesum  :: fn($T: type) -> i32 { t := 0; match core::type_info(T) { .struct_ |s| => { for f in s.fields { t = t + (f.name.len as i32); } return t; } else => return -1; } }
        \\int_flds :: fn($T: type) -> i32 { n := 0; match core::type_info(T) { .struct_ |s| => { for f in s.fields { match *f.ty { .int => n = n + 1; else => {} } } return n; } else => return -1; } }
        \\FIELD_COUNT :: #run nfields(Point);
        \\STRUCT_NAMELEN :: #run namelen(Point);
        \\NAME_SUM :: #run namesum(Point);
        \\INT_FIELDS :: #run int_flds(Point);
    ;
    var fe = try fels.compile(arena.allocator(), "ti2.fels", src);
    defer fe.deinit(arena.allocator());
    const m = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(m);

    try expectGlobalInt(m, "FIELD_COUNT", 3);
    try expectGlobalInt(m, "STRUCT_NAMELEN", 5); // "Point"
    try expectGlobalInt(m, "NAME_SUM", 6); // x(1)+yy(2)+zzz(3)
    try expectGlobalInt(m, "INT_FIELDS", 3);
}

test "comptime: matchable TypeInfo — pointer/slice/optional + element navigation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\is_ptr   :: fn($T: type) -> i32 { match core::type_info(T) { .pointer => return 1; else => return 0; } }
        \\is_slice :: fn($T: type) -> i32 { match core::type_info(T) { .slice => return 1; else => return 0; } }
        \\is_opt   :: fn($T: type) -> i32 { match core::type_info(T) { .optional => return 1; else => return 0; } }
        \\elem_bits :: fn($T: type) -> i32 { match core::type_info(T) { .slice |e| => { match *e { .int |i| => return i.bits as i32; else => return -1; } } else => return -2; } }
        \\IS_PTR   :: #run is_ptr(*i32);
        \\IS_SLICE :: #run is_slice([]u8);
        \\IS_OPT   :: #run is_opt(?i32);
        \\ELEM_BITS :: #run elem_bits([]u8);
    ;
    var fe = try fels.compile(arena.allocator(), "ti3.fels", src);
    defer fe.deinit(arena.allocator());
    const m = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(m);

    try expectGlobalInt(m, "IS_PTR", 1);
    try expectGlobalInt(m, "IS_SLICE", 1);
    try expectGlobalInt(m, "IS_OPT", 1);
    try expectGlobalInt(m, "ELEM_BITS", 8);
}

test "comptime: type_name returns mangled type name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\NAME :: #run core::type_name(i32);
    ;
    var fe = try fels.compile(arena.allocator(), "tn1.fels", src);
    defer fe.deinit(arena.allocator());
    const m = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(m);

    var found = false;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "NAME")) {
            found = true;
            try std.testing.expectEqualStrings("i32", g.init.imm.text);
        }
    }
    try std.testing.expect(found);
}

