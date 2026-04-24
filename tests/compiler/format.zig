//! Formats: a string literal passed to a `Format` parameter (`io::println("{x}")`) prints the
//! values in its braces, each by its type (`format_expand.zig`, std.io's value writer).

const std = @import("std");
const fels = @import("fels_compiler");
const builtin = @import("builtin");

/// Build `src` and run it; what it printed.
fn printed(a: std.mem.Allocator, src: []const u8, label: []const u8) ![]const u8 {
    if (comptime !fels.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    // A file, so its `#import std.io` is read from the standard library.
    const path = try std.fmt.allocPrint(a, ".zig-cache/fmt/{s}.fels", .{label});
    std.Io.Dir.cwd().createDirPath(io, ".zig-cache/fmt") catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src });
    const obj = try std.fmt.allocPrint(a, ".zig-cache/fmt/{s}.o", .{label});
    const exe = try std.fmt.allocPrint(a, ".zig-cache/fmt/{s}.exe", .{label});
    const lib_paths: []const []const u8 = if (fels.windows_sdk_lib_path.len > 0) &.{fels.windows_sdk_lib_path} else &.{};
    try fels.compileFileWithLlvm(a, io, .{
        .file_name = path,
        .source = src,
        .obj_path = obj,
        .exe_path = exe,
        .opt_level = 0,
        .llvm_bin = fels.llvm_path ++ "/bin",
        .lib_paths = lib_paths,
    });
    const r = try std.process.run(a, io, .{ .argv = &.{exe} });
    return r.stdout;
}

/// That `src` does not compile. A skip (no LLVM, not Windows) stays a skip.
fn refused(a: std.mem.Allocator, src: []const u8, label: []const u8) !void {
    _ = printed(a, src, label) catch |err| {
        // Without LLVM, `printed` can only skip, so its error set has no `CompileFailed`.
        if (@as(anyerror, err) == error.CompileFailed) return;
        return err;
    };
    return error.TestExpectedError;
}

test "format: the values in the braces print by their type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try printed(arena.allocator(),
        \\#import std.io;
        \\Point :: struct { x: i32, y: i32 }
        \\Shape :: struct { name: []const u8, at: Point, tags: []const i32, ok: bool, w: ?f64 }
        \\Mode :: enum { fast, slow }
        \\main :: fn() -> i32 {
        \\    name := "Ada";
        \\    n: i32 = -42;
        \\    p: Point = .{ 1, 2 };
        \\    tags: [3]i32 = .{ 7, 8, 9 };
        \\    s: Shape = .{ "box", p, tags[0..3], true, null };
        \\    m := Mode.slow;
        \\    some: ?i32 = 5;
        \\    io::println("{name} has {n + 2} items") catch e {};
        \\    io::println("{p} {m} {some} {tags} {true}") catch e {};
        \\    io::println("{s}") catch e {};
        \\    io::println("{3.14159265} {1.0} {2.0 / 3.0:.3} {0.000001234}") catch e {};
        \\    return 0;
        \\}
    , "fmt_types");
    try std.testing.expectEqualStrings(
        "Ada has -40 items\n" ++
            "Point{ x: 1, y: 2 } slow 5 [7, 8, 9] true\n" ++
            "Shape{ name: \"box\", at: Point{ x: 1, y: 2 }, tags: [7, 8, 9], ok: true, w: null }\n" ++
            "3.14159265 1 0.667 1.234e-6\n",
        out,
    );
}

test "format: specs pad, align and change the base" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try printed(arena.allocator(),
        \\#import std.io;
        \\main :: fn() -> i32 {
        \\    n: i32 = -42;
        \\    w := "Ada";
        \\    io::println("[{n:6}] [{n:06}] [{7:<4}] [{w:^7}] [{w:*>5}] [{255:x}] [{255:X}] [{5:b}] [{8:o}] [{w:?}]") catch e {};
        \\    return 0;
        \\}
    , "fmt_specs");
    try std.testing.expectEqualStrings("[   -42] [-00042] [7   ] [  Ada  ] [**Ada] [ff] [FF] [101] [10] [\"Ada\"]\n", out);
}

test "format: a type's own format method prints it, also inside another value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try printed(arena.allocator(),
        \\#import std.io;
        \\Money :: struct {
        \\    cents: i64,
        \\    pub format :: fn(self: Money, f: *Formatter) {
        \\        f.value(self.cents / 100, "");
        \\        f.text(",");
        \\        f.value(self.cents % 100, "02");
        \\    }
        \\}
        \\Line :: struct { what: []const u8, price: Money }
        \\Date :: struct {
        \\    day: u8,
        \\    pub format :: fn(self: *Self, pattern: []const u8) -> []const u8 { return pattern; }
        \\}
        \\main :: fn() -> i32 {
        \\    m: Money = .{ 1905 };
        \\    l: Line = .{ "tea", m };
        \\    d: Date = .{ 3 };
        \\    io::println("{m} {l} [{m:>6}] {d}") catch e {};
        \\    return 0;
        \\}
    , "fmt_custom");
    try std.testing.expectEqualStrings("19,05 Line{ what: \"tea\", price: 19,05 } [ 19,05] Date{ day: 3 }\n", out);
}

test "format: an error prints its name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try printed(arena.allocator(),
        \\#import std.io;
        \\E :: errors { not_found, too_big }
        \\find :: fn(n: i32) -> i32 ! E {
        \\    if n > 3 { fail .too_big; }
        \\    return n;
        \\}
        \\main :: fn() -> i32 {
        \\    r := find(5) catch e {
        \\        io::println("failed: {e}") catch x {};
        \\        yield 0;
        \\    };
        \\    return r;
        \\}
    , "fmt_error");
    try std.testing.expectEqualStrings("failed: too_big\n", out);
}

test "format: braces of the text, text passed on as it is, and a Format of the program's own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try printed(arena.allocator(),
        \\#import std.io;
        \\log :: fn(level: u8, f: Format) {
        \\    if level < 2 { return; }
        \\    io::println(f) catch e {};
        \\}
        \\main :: fn() -> i32 {
        \\    n := 3;
        \\    raw: []const u8 = "{not read}";
        \\    io::println("{{n}} is {n}") catch e {};
        \\    io::println(raw) catch e {};
        \\    log(1, "hidden {n}");
        \\    log(3, "shown {n}");
        \\    return 0;
        \\}
    , "fmt_text");
    try std.testing.expectEqualStrings("{n} is 3\n{not read}\nshown 3\n", out);
}

test "format: a writer takes a format, and printing works at compile time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try printed(arena.allocator(),
        \\#import std.io.{ Writer, stdout, println };
        \\shown :: fn() -> i32 {
        \\    x := 41;
        \\    b := println("at compile time {x + 1}") catch e { return -1; };
        \\    return b as i32;
        \\}
        \\M :: #run shown();
        \\main :: fn() -> i32 {
        \\    out := stdout();
        \\    w: *Writer = &out;
        \\    w.write_fmt_line("M = {M}") catch e {};
        \\    return 0;
        \\}
    , "fmt_writer");
    // `at compile time 42\n` is 19 bytes.
    try std.testing.expectEqualStrings("M = 19\n", out);
}

test "format: a mistake in a format is an error at its place in the string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = [_][]const u8{
        "io::println(\"x = {n\") catch e {};", // not closed
        "io::println(\"x = }\") catch e {};", // closes nothing
        "io::println(\"x = {}\") catch e {};", // names no value
        "io::println(\"x = {n:q}\") catch e {};", // no spec
        "io::println(\"x = {n +}\") catch e {};", // no expression
        "io::println(\"x = {nope}\") catch e {};", // unknown name
    };
    for (bad, 0..) |line, i| {
        const src = try std.fmt.allocPrint(a, "#import std.io;\nmain :: fn() -> i32 {{\n    n := 3;\n    {s}\n    return 0;\n}}\n", .{line});
        const label = try std.fmt.allocPrint(a, "fmt_bad_{d}", .{i});
        try refused(a, src, label);
    }
}

test "format: a format with values in a generic function is refused with the reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try refused(arena.allocator(),
        \\#import std.io;
        \\describe :: fn(v: $T) { io::println("value {v}") catch e {}; }
        \\main :: fn() -> i32 { describe(42); return 0; }
    , "fmt_generic");
}

test "a lambda that captures an optional tests its flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try printed(arena.allocator(),
        \\#import std.io;
        \\call_it :: fn(f: fn() -> bool) -> bool { return f(); }
        \\main :: fn() -> i32 {
        \\    o: ?i32 = null;
        \\    g := fn() -> bool { return o == null; };
        \\    io::println(if call_it(g) { "none" } else { "some" }) catch e {};
        \\    return 0;
        \\}
    , "capture_optional");
    try std.testing.expectEqualStrings("none\n", out);
}
