const std = @import("std");
const fels = @import("fels_compiler");

// Multi-file tests use compileMulti with pre-loaded sources, so they exercise
// module resolution without filesystem access.

test "modules: compileMulti with two source files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const math_src =
        \\pub add      :: fn(a: i32, b: i32) -> i32 { return a + b; }
        \\pub multiply :: fn(a: i32, b: i32) -> i32 { return a * b; }
    ;
    const main_src =
        \\#import math;
        \\run :: fn() -> i32 {
        \\    x := math::add(3, 4);
        \\    y := math::multiply(x, 2);
        \\    return y;
        \\}
    ;

    var fe = try fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "math.fels", .source = math_src },
        .{ .file_name = "main.fels", .source = main_src },
    });
    defer fe.deinit(arena.allocator());

    try std.testing.expectEqual(@as(usize, 4), fe.module.items.len);

    const m = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(m);
    try std.testing.expectEqual(@as(usize, 3), m.functions.len);
}

test "modules: public symbols from imported file are visible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const utils =
        \\MAX :: 100;
        \\pub clamp :: fn(x: i32) -> bool { return x < MAX; }
    ;
    const app =
        \\#import utils;
        \\check :: fn(v: i32) -> bool { return utils::clamp(v); }
    ;

    var fe = try fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "utils.fels", .source = utils },
        .{ .file_name = "app.fels", .source = app },
    });
    defer fe.deinit(arena.allocator());

    const m = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(m);
}

test "modules: namespace import forms — as alias and .* glob" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lib =
        \\pub twice :: fn(x: i32) -> i32 { return x * 2; }
    ;
    // `as` binds a custom namespace; `.*` glob brings names in unqualified.
    const aliased =
        \\#import lib as l;
        \\run :: fn() -> i32 { return l::twice(21); }
    ;
    const globbed =
        \\#import lib.*;
        \\go :: fn() -> i32 { return twice(21); }
    ;

    var fe1 = try fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "lib.fels", .source = lib },
        .{ .file_name = "aliased.fels", .source = aliased },
    });
    defer fe1.deinit(arena.allocator());
    try fels.ir_mod.validateModule(try fels.lowerFrontend(arena.allocator(), fe1));

    var fe2 = try fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "lib.fels", .source = lib },
        .{ .file_name = "globbed.fels", .source = globbed },
    });
    defer fe2.deinit(arena.allocator());
    try fels.ir_mod.validateModule(try fels.lowerFrontend(arena.allocator(), fe2));
}

test "modules: two modules may define the same name (collision mangling)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Both `a` and `b` declare `greet`; `main` uses both via their namespaces.
    // Per-module mangling gives each a distinct linkage name so this links.
    const a = "pub greet :: fn() -> i32 { return 1; }";
    const b = "pub greet :: fn() -> i32 { return 2; }";
    const main =
        \\#import a;
        \\#import b;
        \\main :: fn() -> i32 { return a::greet() + b::greet() * 10; }
    ;
    var fe = try fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "a.fels", .source = a },
        .{ .file_name = "b.fels", .source = b },
        .{ .file_name = "main.fels", .source = main },
    });
    defer fe.deinit(arena.allocator());

    const m = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(m);

    // Two distinct `greet` functions must exist (mangled apart), plus `main`.
    var greets: usize = 0;
    for (m.functions) |f| {
        if (std.mem.endsWith(u8, f.name, "greet")) greets += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), greets);
}

test "modules: two modules may bind one C symbol under the same name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Each module declares its own `GetTickCount` binding of the same kernel32
    // symbol, with a different return width. Neither may be reported as a
    // duplicate, and each keeps its own declaration (own IR name and signature).
    const a =
        \\#extern("kernel32", "GetTickCount")
        \\pub GetTickCount :: fn() -> u32;
        \\pub ticks :: fn() -> u32 { return GetTickCount(); }
    ;
    const b =
        \\#extern("kernel32", "GetTickCount")
        \\pub GetTickCount :: fn() -> u64;
        \\pub ticks_wide :: fn() -> u64 { return GetTickCount(); }
    ;
    const main =
        \\#import a;
        \\#import b;
        \\main :: fn() -> i32 {
        \\    if a::ticks() == 0u32 && b::ticks_wide() == 0u64 { return 1; }
        \\    return 0;
        \\}
    ;
    var fe = try fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "a.fels", .source = a },
        .{ .file_name = "b.fels", .source = b },
        .{ .file_name = "main.fels", .source = main },
    });
    defer fe.deinit(arena.allocator());

    const m = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(m);

    // Two extern declarations of one C symbol: distinct IR names, same `extern_name`.
    var first: ?[]const u8 = null;
    var bound: usize = 0;
    for (m.functions) |f| {
        const sym = f.extern_name orelse continue;
        if (!std.mem.eql(u8, sym, "GetTickCount")) continue;
        bound += 1;
        if (first) |name| try std.testing.expect(!std.mem.eql(u8, name, f.name));
        first = f.name;
    }
    try std.testing.expectEqual(@as(usize, 2), bound);
}

test "modules: a user #extern and constant may reuse names the runtime declares" {
    if (comptime @import("builtin").os.tag != .windows) return error.SkipZigTest; // the Windows runtime's names
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The embedded runtime declares `CloseHandle` (-> bool), `GetStdHandle` and the
    // constant `STD_OUTPUT_HANDLE`. A program binding the same Win32 names itself
    // used to fail with "duplicate top-level declaration" for something it never
    // wrote; its own declarations must now shadow the runtime's inside its own file.
    const src =
        \\#extern("kernel32", "CloseHandle")
        \\CloseHandle :: fn(h: usize) -> i32;
        \\#extern("kernel32", "GetStdHandle")
        \\GetStdHandle :: fn(n: i32) -> usize;
        \\STD_OUTPUT_HANDLE :: -11i32;
        \\main :: fn() -> i32 {
        \\    h := GetStdHandle(STD_OUTPUT_HANDLE);
        \\    return CloseHandle(h);
        \\}
    ;
    var fe = try fels.compileWithRuntime(arena.allocator(), "user.fels", src);
    defer fe.deinit(arena.allocator());

    const m = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(m);

    // The runtime's `CloseHandle` and the user's are two declarations of one symbol.
    var bound: usize = 0;
    for (m.functions) |f| {
        const sym = f.extern_name orelse continue;
        if (std.mem.eql(u8, sym, "CloseHandle")) bound += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), bound);
}

test "modules: cross-module UFCS finds a method in the type's module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // `get` is NOT imported into `app` — only the type `Box` is. `b.get()` must
    // still resolve, because a method follows its type's module (UFCS).
    const lib =
        \\pub Box :: struct { v: i32 }
        \\pub get :: fn(self: *Box) -> i32 { return self.v; }
    ;
    const app =
        \\#import lib.{ Box };
        \\run :: fn(b: Box) -> i32 { return b.get(); }
    ;
    var fe = try fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "lib.fels", .source = lib },
        .{ .file_name = "app.fels", .source = app },
    });
    defer fe.deinit(arena.allocator());
    try fels.ir_mod.validateModule(try fels.lowerFrontend(arena.allocator(), fe));
}

test "modules: #run of a namespace call folds at comptime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lib = "pub twice :: fn(x: i32) -> i32 { return x * 2; }";
    const app =
        \\#import lib;
        \\main :: fn() -> i32 { return #run lib::twice(21); }
    ;
    var fe = try fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "lib.fels", .source = lib },
        .{ .file_name = "app.fels", .source = app },
    });
    defer fe.deinit(arena.allocator());

    const m = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(m);

    // `#run lib::twice(21)` must fold to a constant — `main` should contain no
    // runtime call instruction.
    const main_fn = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "main")) break f;
    } else return error.FunctionNotFound;
    for (main_fn.blocks) |b| for (b.instrs) |ins| {
        try std.testing.expect(ins.kind != .call);
    };
}

test "modules: bare import is namespace-only (no unqualified access)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lib =
        \\pub helper :: fn() -> i32 { return 1; }
    ;
    // `#import lib;` binds the `lib` namespace but must NOT expose `helper`
    // unqualified — calling it bare is an error.
    const app =
        \\#import lib;
        \\run :: fn() -> i32 { return helper(); }
    ;
    const result = fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "lib.fels", .source = lib },
        .{ .file_name = "app.fels", .source = app },
    });
    try std.testing.expectError(error.SemanticFailed, result);
}

test "modules: compile parses imports without resolving them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\#import std.io;
        \\hello :: fn() -> i32 { return 42; }
    ;
    var fe = try fels.compile(arena.allocator(), "hello.fels", src);
    defer fe.deinit(arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), fe.module.items.len);
}

test "modules: selective import exposes only selected public names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const math_src =
        \\pub add :: fn(a: i32, b: i32) -> i32 { return a + b; }
        \\pub multiply :: fn(a: i32, b: i32) -> i32 { return a * b; }
    ;
    const app_src =
        \\#import math.{add};
        \\run :: fn() -> i32 { return add(1, 2); }
    ;

    var fe = try fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "math.fels", .source = math_src },
        .{ .file_name = "app.fels", .source = app_src },
    });
    defer fe.deinit(arena.allocator());
}

test "modules: unselected and private names are not visible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const dependency =
        \\private_value :: fn() -> i32 { return 1; }
        \\pub public_value :: fn() -> i32 { return private_value(); }
        \\pub other_value :: fn() -> i32 { return 2; }
    ;
    const private_use =
        \\#import dependency;
        \\run :: fn() -> i32 { return private_value(); }
    ;
    const unselected_use =
        \\#import dependency.{public_value};
        \\run :: fn() -> i32 { return other_value(); }
    ;

    try std.testing.expectError(error.SemanticFailed, fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "dependency.fels", .source = dependency },
        .{ .file_name = "private_use.fels", .source = private_use },
    }));
    try std.testing.expectError(error.SemanticFailed, fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "dependency.fels", .source = dependency },
        .{ .file_name = "unselected_use.fels", .source = unselected_use },
    }));
}

test "modules: selective imports reject missing and private declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const dependency =
        \\hidden :: fn() -> i32 { return 1; }
        \\pub #inline shown :: fn() -> i32 { return hidden(); }
    ;

    try std.testing.expectError(error.SemanticFailed, fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "dependency.fels", .source = dependency },
        .{ .file_name = "private.fels", .source = "#import dependency.{hidden};" },
    }));
    try std.testing.expectError(error.SemanticFailed, fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "dependency.fels", .source = dependency },
        .{ .file_name = "missing.fels", .source = "#import dependency.{missing};" },
    }));
}

test "modules: missing modules are errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.IoError, fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "app.fels", .source = "#import missing;" },
    }));
}

test "modules: std root resolves independently of importing directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "std/io.fels", .source = "pub write_stdout :: fn() {}" },
        .{ .file_name = "app/main.fels", .source = "#import std.io.{write_stdout}; run :: fn() { write_stdout(); }" },
    });
    defer fe.deinit(arena.allocator());
}

test "modules: public constants and types respect visibility" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const dependency =
        \\pub LIMIT :: 4;
        \\pub Value :: struct { item: i32, }
        \\Hidden :: struct { item: i32, }
    ;
    const app =
        \\#import dependency.{LIMIT, Value};
        \\limit :: fn() -> i32 { return LIMIT; }
        \\read :: fn(value: *Value) -> i32 { return value.item; }
    ;

    var fe = try fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "dependency.fels", .source = dependency },
        .{ .file_name = "app.fels", .source = app },
    });
    defer fe.deinit(arena.allocator());
}

test "modules: a constraint names what its own module declares" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The body of a constraint was type-checked in the file of the call it was used for, so a
    // helper of its own module was an unknown function there.
    const keys_src =
        \\whole :: fn(ti: TypeInfo) -> bool { match ti { .int => { return true; }, else => { return false; } } }
        \\Whole :: constraint($K) { if !whole(core::type_info(K)) { core::reject("not an integer"); } }
        \\pub take :: fn($K: Whole, k: K) -> i32 { return 1; }
    ;
    var fe = try fels.compileMulti(a, &.{
        .{ .file_name = "keys.fels", .source = keys_src },
        .{ .file_name = "main.fels", .source = "#import keys;\nrun :: fn() -> i32 { return keys::take(5); }" },
    });
    defer fe.deinit(a);
    try std.testing.expectError(error.SemanticFailed, fels.compileMulti(a, &.{
        .{ .file_name = "keys.fels", .source = keys_src },
        .{ .file_name = "main.fels", .source = "#import keys;\nrun :: fn() -> i32 { return keys::take(1.5); }" },
    }));
}

test "modules: std.map refuses a key AutoHashMap cannot compare by its bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const dir = ".zig-cache/bytekey";
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const cases = [_]struct { key: []const u8, ok: bool }{
        .{ .key = "i32", .ok = true },
        .{ .key = "Tight", .ok = true },
        .{ .key = "f64", .ok = false },
        .{ .key = "[]const u8", .ok = false },
        .{ .key = "Gap", .ok = false },
        .{ .key = "?i32", .ok = false },
        .{ .key = "Overlay", .ok = false },
    };
    for (cases, 0..) |case, i| {
        const src = try std.fmt.allocPrint(a,
            \\#import std.map as map;
            \\#import std.heap as heap;
            \\Gap :: struct {{ a: u8, b: u32 }}
            \\Tight :: struct {{ a: u32, b: u32 }}
            \\Overlay :: union {{ a: u8, b: u32 }}
            \\main :: fn() -> i32 {{ h := heap::make(); m := map::auto({s}, i32, &h); return 0; }}
            \\
        , .{case.key});
        const path = try std.fmt.allocPrint(a, "{s}/key{d}.fels", .{ dir, i });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src });
        if (case.ok) {
            var fe = try fels.compileFileWithRuntime(a, io, path);
            fe.deinit(a);
        } else {
            try std.testing.expectError(error.SemanticFailed, fels.compileFileWithRuntime(a, io, path));
        }
    }
}

test "modules: compileFile resolves local imports from disk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try fels.compileFile(
        arena.allocator(),
        std.testing.io,
        "tests/fixtures/modules/main.fels",
    );
    defer fe.deinit(arena.allocator());

    const module = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(module);
}

test "modules: compileMulti normalizes logical module paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = ".\\app\\dependency.fels", .source = "pub answer :: fn() -> i32 { return 42; }" },
        .{ .file_name = "./app/main.fels", .source = "#import dependency.{answer}; run :: fn() -> i32 { return answer(); }" },
    });
    defer fe.deinit(arena.allocator());
}

test "modules: configured std root loads std.mem" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try fels.compileFile(
        arena.allocator(),
        std.testing.io,
        "tests/fixtures/stdlib/mem_app.fels",
    );
    defer fe.deinit(arena.allocator());

    const module = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(module);
}

test "modules: configured std root loads std.io" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try fels.compileFileWithRuntime(
        arena.allocator(),
        std.testing.io,
        "tests/fixtures/stdlib/io_app.fels",
    );
    defer fe.deinit(arena.allocator());

    const module = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(module);
}

test "modules: game stdlib (std.math + std.rand + std.color) resolves and lowers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try fels.compileFileWithRuntime(
        arena.allocator(),
        std.testing.io,
        "tests/fixtures/stdlib/game_app.fels",
    );
    defer fe.deinit(arena.allocator());

    const module = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(module);
}

test "modules: general stdlib (std.path + std.time + std.crypto) resolves and lowers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    inline for (.{
        "tests/fixtures/stdlib/path_app.fels",
        "tests/fixtures/stdlib/time_app.fels",
        "tests/fixtures/stdlib/crypto_app.fels",
    }) |fixture| {
        var fe = try fels.compileFileWithRuntime(arena.allocator(), std.testing.io, fixture);
        defer fe.deinit(arena.allocator());
        const module = try fels.lowerFrontend(arena.allocator(), fe);
        try fels.ir_mod.validateModule(module);
    }
}

test "modules: configured std root loads std.heap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try fels.compileFileWithRuntime(
        arena.allocator(),
        std.testing.io,
        "tests/fixtures/stdlib/heap_app.fels",
    );
    defer fe.deinit(arena.allocator());

    const module = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(module);
}

test "modules: a zone in an imported module reaches std.heap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The embedded std.heap is imported into each file with a zone, not only the root.
    const util =
        \\pub first :: fn(n: usize) -> u8 {
        \\    zone z: Arena {
        \\        buf := z.new_slice(u8, n);
        \\        buf[0] = 7u8;
        \\        return buf[0];
        \\    }
        \\    return 0u8;
        \\}
    ;
    const main_src =
        \\#import util;
        \\run :: fn() -> u8 { return util::first(4); }
    ;

    // The first file is the root.
    var fe = try fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "main.fels", .source = main_src },
        .{ .file_name = "util.fels", .source = util },
    });
    defer fe.deinit(arena.allocator());

    const module = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(module);
}

test "modules: imported self functions are extension methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const helpers =
        \\pub doubled :: fn(self: i32) -> i32 { return self * 2; }
        \\pub add :: fn(self: i32, value: i32) -> i32 { return self + value; }
    ;
    const app =
        \\#import helpers.{doubled, add};
        \\run :: fn() -> i32 { return 20.doubled().add(2); }
    ;

    var fe = try fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "helpers.fels", .source = helpers },
        .{ .file_name = "app.fels", .source = app },
    });
    defer fe.deinit(arena.allocator());

    const module = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(module);
}

test "parser: namespace-qualified generic type in a typed local (ns::Name(args))" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Regression: `parseType` handled `Name(args)` and `ns::Name`, but not the
    // combination — after the `::`-qualified name it expected `=` and reported
    // "expected = after typed local". The qualifier must now flow into the AST.
    const src =
        \\run :: fn() -> i32 {
        \\    c: atomics::Atomic(u32) = .{ 0u32 };
        \\    return 0;
        \\}
    ;
    const module = try fels.parseSource(arena.allocator(), "q.fels", src);
    const ty = module.items[0].function.body.?.statements[0].local_typed.ty;
    try std.testing.expect(ty == .generic_inst);
    try std.testing.expectEqualStrings("Atomic", ty.generic_inst.name);
    try std.testing.expect(ty.generic_inst.namespace != null);
    try std.testing.expectEqualStrings("atomics", ty.generic_inst.namespace.?);
    try std.testing.expectEqual(@as(usize, 1), ty.generic_inst.args.len);
}

test "modules: namespace-qualified generic type resolves + lowers (ns::Name(args))" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The generic template is reached *only* through the namespace alias (a plain
    // `#import`, no selective `.{Pair}`), so `lib::Pair(i32)` exercises namespace
    // resolution of the template AND the non-generic-context instantiation.
    const lib =
        \\pub Pair :: struct($T: type) { a: T, b: T }
    ;
    const app =
        \\#import lib;
        \\sum :: fn() -> i32 {
        \\    p: lib::Pair(i32) = .{ 3, 4 };
        \\    return p.a + p.b;
        \\}
    ;
    var fe = try fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "lib.fels", .source = lib },
        .{ .file_name = "app.fels", .source = app },
    });
    defer fe.deinit(arena.allocator());

    const module = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(module);
}

test "modules: a type alias is imported like any other public name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Aliases of identifier-spelled types (`f32`, a struct, an enum, another alias) read
    // as constants to the parser; sema must still hand them to importers as types. `Pair`
    // names a PRIVATE struct: the importer sees the alias, and the aliased type is
    // resolved where the alias is declared, not in the importing file.
    const lib =
        \\Hidden :: struct { a: i32, b: i32 }
        \\pub Scalar :: f32;
        \\pub Real :: Scalar;
        \\pub Pair :: Hidden;
        \\pub Shade :: Color;
        \\pub Color :: enum { red, green, blue }
        \\pub make :: fn(a: i32, b: i32) -> Pair { return .{ a, b }; }
    ;
    const selective =
        \\#import lib.{ Real, Pair, Shade, make };
        \\pick :: fn(s: Shade) -> i32 { match s { .red => { return 1; } .green => { return 2; } .blue => { return 3; } } }
        \\run :: fn() -> i32 {
        \\    p: Pair = make(3, 4);
        \\    r: Real = 2.5;
        \\    return p.a + p.b + (r as i32) + pick(.blue);
        \\}
    ;
    const namespaced =
        \\#import lib;
        \\run :: fn() -> i32 {
        \\    p: lib::Pair = lib::make(3, 4);
        \\    r: lib::Real = 2.5;
        \\    return p.a + p.b + (r as i32);
        \\}
    ;
    const globbed =
        \\#import lib.*;
        \\run :: fn() -> i32 { p: Pair = make(3, 4); r: Scalar = 2.5; return p.a + p.b + (r as i32); }
    ;
    inline for (.{ selective, namespaced, globbed }) |app| {
        var fe = try fels.compileMulti(arena.allocator(), &.{
            .{ .file_name = "lib.fels", .source = lib },
            .{ .file_name = "app.fels", .source = app },
        });
        defer fe.deinit(arena.allocator());
        const module = try fels.lowerFrontend(arena.allocator(), fe);
        try fels.ir_mod.validateModule(module);
        // The aliases emit no storage.
        for (module.globals) |g| {
            try std.testing.expect(!std.mem.eql(u8, g.name, "Scalar"));
            try std.testing.expect(!std.mem.eql(u8, g.name, "Pair"));
        }
    }
}

test "modules: a local alias of an imported type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `Pos :: Vec2;` names a type that lives in another module — by a selective import
    // and by a namespace — which only name resolution across modules can tell from a
    // constant.
    const lib =
        \\pub Vec2 :: struct { x: f32, y: f32 }
        \\pub Real :: f32;
    ;
    const selective =
        \\#import lib.{ Vec2, Real };
        \\Pos :: Vec2;
        \\Num :: Real;
        \\run :: fn() -> i32 { p: Pos = .{ 1.5, 2.5 }; n: Num = 4.0; return (p.x + p.y + n) as i32; }
    ;
    const namespaced =
        \\#import lib;
        \\Pos :: lib::Vec2;
        \\Num :: lib::Real;
        \\run :: fn() -> i32 { p: Pos = .{ 1.5, 2.5 }; n: Num = 4.0; return (p.x + p.y + n) as i32; }
    ;
    inline for (.{ selective, namespaced }) |app| {
        var fe = try fels.compileMulti(arena.allocator(), &.{
            .{ .file_name = "lib.fels", .source = lib },
            .{ .file_name = "app.fels", .source = app },
        });
        defer fe.deinit(arena.allocator());
        try fels.ir_mod.validateModule(try fels.lowerFrontend(arena.allocator(), fe));
    }
}

test "modules: an imported constant naming a constant stays a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lib =
        \\pub LIMIT :: 4;
        \\pub MAX :: LIMIT;
    ;
    const app =
        \\#import lib.{ MAX };
        \\run :: fn() -> i32 { return MAX; }
    ;
    var fe = try fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "lib.fels", .source = lib },
        .{ .file_name = "app.fels", .source = app },
    });
    defer fe.deinit(arena.allocator());
    const module = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(module);

    // Both are constants, so both have storage — `MAX` is not read as an alias of `LIMIT`.
    var found: usize = 0;
    for (module.globals) |g| {
        if (std.mem.eql(u8, g.name, "LIMIT") or std.mem.eql(u8, g.name, "MAX")) found += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), found);
}

test "modules: two modules may each declare an alias of a name, as two types may" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // An alias kept its bare name for the IR to find it by, so two of one name were a
    // duplicate declaration; it is now lowered as what it stands for.
    var fe = try fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "a.fels", .source = "pub real :: f32;" },
        .{ .file_name = "b.fels", .source = "pub real :: f64;" },
        .{ .file_name = "main.fels", .source = "#import a;\n#import b;\nrun :: fn() -> i32 { x: a::real = 1.5; y: b::real = 2.5; return (x as f64 + y) as i32; }" },
    });
    defer fe.deinit(arena.allocator());
    const module = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(module);
}

test "modules: a pub alias re-exports a type of another module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `std.net` had to say "import a submodule for its types": an alias of the same name was a
    // duplicate declaration, `! ErrorAlias` was "not an error type", and `alias::Type::fn`,
    // `alias::Enum.variant` did not resolve.
    const inner =
        \\pub Stream :: struct { fd: i32
        \\    pub open :: fn(fd: i32) -> Stream { return .{ fd }; }
        \\    pub id :: fn(self: *Self) -> i32 { return self.fd; }
        \\}
        \\pub Kind :: enum { tcp, udp }
        \\pub NetError :: errors { refused, reset: i32 }
        \\pub dial :: fn(fd: i32) -> Stream ! NetError { if fd < 0 { fail .reset(fd); } return .{ fd }; }
    ;
    const facade =
        \\#import inner;
        \\pub Stream :: inner::Stream;
        \\pub Kind :: inner::Kind;
        \\pub NetError :: inner::NetError;
        \\pub connect :: fn(fd: i32) -> Stream ! NetError { return inner::dial(fd); }
    ;
    const main =
        \\#import facade;
        \\fails :: fn() -> i32 ! facade::NetError { fail .refused; }
        \\run :: fn() -> i32 {
        \\    s: facade::Stream = facade::connect(3) catch e { return 1; };
        \\    t := facade::Stream::open(4);
        \\    k: facade::Kind = facade::Kind.udp;
        \\    v := fails() catch e { yield if e == .refused { 6 } else { 0 }; };
        \\    if k != .udp { return 2; }
        \\    return s.id() + t.id() + v;
        \\}
        \\R :: #run run();
    ;
    var fe = try fels.compileMulti(a, &.{
        .{ .file_name = "inner.fels", .source = inner },
        .{ .file_name = "facade.fels", .source = facade },
        .{ .file_name = "main.fels", .source = main },
    });
    defer fe.deinit(a);
    const module = try fels.lowerFrontend(a, fe);
    try fels.ir_mod.validateModule(module);
    for (module.globals) |g| if (std.mem.eql(u8, g.name, "R")) {
        try std.testing.expectEqual(fels.ir_mod.Imm{ .int = 13 }, g.init.imm);
        return;
    };
    return error.TestUnexpectedResult;
}

test "modules: std.c resolves and lowers (selective and namespaced imports)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `std.c` aliases `f32`/`f64` (identifier-spelled types), which used to make the whole
    // module fail to lower ("constant initializer could not be folded at compile time").
    inline for (.{
        "tests/fixtures/stdlib/c_types_app.fels",
        "tests/fixtures/stdlib/c_namespace_app.fels",
    }) |fixture| {
        var fe = try fels.compileFileWithRuntime(arena.allocator(), std.testing.io, fixture);
        defer fe.deinit(arena.allocator());
        const module = try fels.lowerFrontend(arena.allocator(), fe);
        try fels.ir_mod.validateModule(module);
    }
}

test "modules: unimported self functions are not extension methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.SemanticFailed, fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "helpers.fels", .source = "pub doubled :: fn(self: i32) -> i32 { return self * 2; }" },
        .{ .file_name = "app.fels", .source = "run :: fn() -> i32 { return 20.doubled(); }" },
    }));
}

test "modules: generic extension methods retain explicit type arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const helpers =
        \\pub first_or :: fn($T: type, self: []const T, fallback: T) -> T {
        \\    if self.len == 0usize { return fallback; }
        \\    return self[0];
        \\}
    ;
    const app =
        \\#import helpers.{first_or};
        \\run :: fn() -> i32 {
        \\    values: [1]i32 = .{ 42 };
        \\    return values[:].first_or(i32, 0);
        \\}
    ;

    var fe = try fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "helpers.fels", .source = helpers },
        .{ .file_name = "app.fels", .source = app },
    });
    defer fe.deinit(arena.allocator());

    const module = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(module);
}

test "modules: `*name` in an argument is a pointer type for an imported type, a dereference for a variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The parser cannot know that `Chunk` and `word` are types: they exist only in `lib`, and
    // `word` is spelled in lowercase like the aliases of std.c. The checker resolves them
    // through the import, and still reads `*p` on a local as a load.
    const lib =
        \\pub Chunk :: struct { next: usize, size: usize }
        \\pub word :: usize;
        \\pub twice :: fn(x: i32) -> i32 { return x * 2; }
    ;
    const app =
        \\#import lib.{ Chunk, word, twice };
        \\run :: fn() -> usize {
        \\    v: i32 = 21;
        \\    p := &v;
        \\    if twice(*p) != 42 { return 0usize; }
        \\    return core::sizeof(*Chunk) + core::sizeof(**Chunk) + core::sizeof(*word);
        \\}
    ;

    var fe = try fels.compileMulti(arena.allocator(), &.{
        .{ .file_name = "lib.fels", .source = lib },
        .{ .file_name = "app.fels", .source = app },
    });
    defer fe.deinit(arena.allocator());

    const module = try fels.lowerFrontend(arena.allocator(), fe);
    try fels.ir_mod.validateModule(module);
}

test "modules: an import that only finds a .gab file says to rename it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const util = "pub add :: fn(x: i32, y: i32) -> i32 { return x + y; }\n";
    const main = "#import util;\nrun :: fn() -> i32 { return util::add(1, 2); }\n";

    // From memory, as these tests load files.
    try std.testing.expectError(error.IoError, fels.compileMulti(a, &.{
        .{ .file_name = "util.gab", .source = util },
        .{ .file_name = "main.fels", .source = main },
    }));

    // From disk, as the compiler does.
    const io = std.testing.io;
    const dir = ".zig-cache/old_ext";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/util.gab", .data = util });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/main.fels", .data = main });
    try std.testing.expectError(error.IoError, fels.compileFile(a, io, dir ++ "/main.fels"));
}
