const std = @import("std");
const k2 = @import("k2_compiler");
const ir = k2.ir_mod;

// VM comptime corpus. The VM is now the sole comptime engine (the AST
// tree-walker has been deleted), so this is a pure regression test: every
// top-level `X :: #run <expr>` below must fold to a constant on the VM
// (`failed` must stay 0).
//
// NOTE: `#run` binds tighter than binary operators, so `#run a + b` parses as
// `(#run a) + b`. Multi-token expressions must be parenthesised: `#run (a + b)`.

test "vm corpus: wide #run coverage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\BASE :: 100;
        \\SCALE :: 7;
        \\
        \\// ── arithmetic & operators ──
        \\addi :: fn(a: i32, b: i32) -> i32 { return a + b; }
        \\subi :: fn(a: i32, b: i32) -> i32 { return a - b; }
        \\muli :: fn(a: i32, b: i32) -> i32 { return a * b; }
        \\divi :: fn(a: i32, b: i32) -> i32 { return a / b; }
        \\modi :: fn(a: i32, b: i32) -> i32 { return a % b; }
        \\negi :: fn(n: i32) -> i32 { return -n; }
        \\bit_ops :: fn(a: i32, b: i32) -> i32 { return (a & b) | (a ^ b); }
        \\shifts :: fn(n: i32) -> i32 { return (n << 2) + (n >> 1); }
        \\cmp_lt :: fn(a: i32, b: i32) -> bool { return a < b; }
        \\cmp_ge :: fn(a: i32, b: i32) -> bool { return a >= b; }
        \\logic :: fn(p: bool, q: bool) -> bool { return (p && q) || (!p); }
        \\
        \\// ── recursion & loops ──
        \\fact :: fn(n: i32) -> i32 { if n <= 1 { return 1; } return n * fact(n - 1); }
        \\fib :: fn(n: i32) -> i32 { if n < 2 { return n; } return fib(n - 1) + fib(n - 2); }
        \\sumto :: fn(n: i32) -> i32 {
        \\    total := 0; i := 1;
        \\    while i <= n { total = total + i; i = i + 1; }
        \\    return total;
        \\}
        \\
        \\// ── structs ──
        \\Point :: struct { x: i32, y: i32 }
        \\Rect :: struct { w: i32, h: i32 }
        \\Nested :: struct { p: Point, z: i32 }
        \\psum :: fn() -> i32 { p: Point = .{ 3, 4 }; return p.x + p.y; }
        \\pmut :: fn() -> i32 { p: Point = .{ 1, 2 }; p.x = 10; return p.x + p.y; }
        \\nest :: fn() -> i32 { n: Nested = .{ .{ 5, 6 }, 7 }; return n.p.x + n.p.y + n.z; }
        \\
        \\// ── arrays & slices ──
        \\arr_idx :: fn() -> i32 { arr: [4]i32 = .{ 10, 20, 30, 40 }; return arr[1] + arr[3]; }
        \\arr_len :: fn() -> i32 { arr: [5]i32 = .{ 1, 2, 3, 4, 5 }; return arr.len as i32; }
        \\arr_sum :: fn() -> i32 {
        \\    arr: [3]i32 = .{ 5, 7, 9 };
        \\    total := 0; i := 0;
        \\    while i < 3 { total = total + arr[i]; i = i + 1; }
        \\    return total;
        \\}
        \\slice_sum :: fn() -> i32 {
        \\    arr: [4]i32 = .{ 1, 2, 3, 4 };
        \\    s: []i32 = arr[1..3];
        \\    return s[0] + s[1] + (s.len as i32);
        \\}
        \\
        \\// ── floats & casts ──
        \\favg :: fn(a: f64, b: f64) -> f64 { return (a + b) / 2.0; }
        \\fmax :: fn(a: f64, b: f64) -> f64 { if a > b { return a; } return b; }
        \\i2f :: fn(n: i32) -> f64 { return n as f64; }
        \\f2i :: fn(x: f64) -> i32 { return x as i32; }
        \\widen :: fn(n: i32) -> i64 { return n as i64; }
        \\
        \\// ── enums ──
        \\Color :: enum { red, green, blue }
        \\colrank :: fn(c: Color) -> i32 {
        \\    match c { .red => return 1; .green => return 2; .blue => return 3; else => return 0; }
        \\}
        \\
        \\// ── optionals ──
        \\opt_some :: fn() -> i32 { x: ?i32 = 5; return x ?? 9; }
        \\opt_none :: fn() -> i32 { x: ?i32 = null; return x ?? 9; }
        \\opt_unwrap :: fn() -> i32 { x: ?i32 = 7; return x!!; }
        \\
        \\// ── errors / fallible ──
        \\E2 :: errors { boom, splat }
        \\risky2 :: fn(v: i32) -> i32 ! E2 {
        \\    if v < 0 { fail .boom; }
        \\    if v == 0 { fail .splat; }
        \\    return v * 2;
        \\}
        \\safe2 :: fn(v: i32) -> i32 { d := risky2(v) catch e { return -1; }; return d; }
        \\
        \\// ── interfaces ──
        \\Shape :: interface { area :: fn(self: *Self) -> i32; }
        \\Square :: struct { side: i32 }
        \\Square as Shape { area :: fn(self: *Self) -> i32 { return self.side * self.side; } }
        \\BoxS :: struct { w: i32, h: i32 }
        \\BoxS as Shape { area :: fn(self: *Self) -> i32 { return self.w * self.h; } }
        \\sq_area :: fn() -> i32 { s: Square = .{ 5 }; sh: *Shape = &s; return sh.area(); }
        \\box_area :: fn() -> i32 { b: BoxS = .{ 3, 4 }; sh: *Shape = &b; return sh.area(); }
        \\
        \\// ── probe: aggregates ──
        \\aos :: fn() -> i32 { arr: [2]Point = .{ .{ 1, 2 }, .{ 3, 4 } }; return arr[0].x + arr[1].y; }
        \\mkp :: fn() -> Point { p: Point = .{ 8, 9 }; return p; }
        \\retstruct :: fn() -> i32 { q := mkp(); return q.x + q.y; }
        \\forsum :: fn() -> i32 { arr: [3]i32 = .{ 4, 5, 6 }; total := 0; for x in arr { total = total + x; } return total; }
        \\frange :: fn() -> i32 { total := 0; for i in 0..5 { total = total + i; } return total; }
        \\EP :: errors { code: i32 }
        \\fp :: fn(x: i32) -> i32 ! EP { if x < 0 { fail .code { 77 }; } return x; }
        \\gp :: fn() -> i32 { return fp(-1) catch e { if e == .code |c| { return c; } return -1; }; }
        \\
        \\// ── const #run cases ──
        \\C_add   :: #run addi(17, 25);
        \\C_sub   :: #run subi(50, 8);
        \\C_mul   :: #run muli(6, 7);
        \\C_div   :: #run divi(84, 2);
        \\C_mod   :: #run modi(17, 5);
        \\C_neg   :: #run negi(42);
        \\C_bit   :: #run bit_ops(12, 10);
        \\C_shift :: #run shifts(8);
        \\C_lt    :: #run cmp_lt(3, 5);
        \\C_ge    :: #run cmp_ge(9, 2);
        \\C_logic :: #run logic(true, false);
        \\C_fact  :: #run fact(5);
        \\C_fib   :: #run fib(10);
        \\C_sumto :: #run sumto(10);
        \\C_psum  :: #run psum();
        \\C_pmut  :: #run pmut();
        \\C_nest  :: #run nest();
        \\C_aidx  :: #run arr_idx();
        \\C_alen  :: #run arr_len();
        \\C_asum  :: #run arr_sum();
        \\C_ssum  :: #run slice_sum();
        \\C_favg  :: #run favg(3.0, 5.0);
        \\C_fmax  :: #run fmax(3.5, 2.25);
        \\C_i2f   :: #run i2f(7);
        \\C_f2i   :: #run f2i(9.8);
        \\C_widen :: #run widen(1000);
        \\C_col   :: #run colrank(Color.blue);
        \\C_opts  :: #run opt_some();
        \\C_optn  :: #run opt_none();
        \\C_optu  :: #run opt_unwrap();
        \\C_ok    :: #run safe2(5);
        \\C_errn  :: #run safe2(-3);
        \\C_errz  :: #run safe2(0);
        \\C_sq    :: #run sq_area();
        \\C_box   :: #run box_area();
        \\C_aos   :: #run aos();
        \\C_ret   :: #run retstruct();
        \\C_for   :: #run forsum();
        \\C_frange :: #run frange();
        \\C_epay  :: #run gp();
        \\C_glob  :: #run (BASE + SCALE);
        \\C_globf :: #run muli(BASE, 2);
        \\
        \\// ── sizeof ──
        \\S_i8    :: #run sizeof(i8);
        \\S_i16   :: #run sizeof(i16);
        \\S_i32   :: #run sizeof(i32);
        \\S_i64   :: #run sizeof(i64);
        \\S_u8    :: #run sizeof(u8);
        \\S_u64   :: #run sizeof(u64);
        \\S_f32   :: #run sizeof(f32);
        \\S_f64   :: #run sizeof(f64);
        \\S_bool  :: #run sizeof(bool);
        \\S_point :: #run sizeof(Point);
        \\S_rect  :: #run sizeof(Rect);
        \\S_nest  :: #run sizeof(Nested);
        \\S_arr   :: #run sizeof([4]i32);
        \\S_opti  :: #run sizeof(?i32);
        \\
        \\// ── type_info ──
        \\T_psize :: #run type_info(Point).size;
        \\T_pname :: #run type_info(Point).name;
        \\T_pkind :: #run type_info(Point).kind;
        \\T_cname :: #run type_info(Color).name;
        \\T_ckind :: #run type_info(Color).kind;
        \\T_bits  :: #run type_info(i32).bits;
        \\T_sign  :: #run type_info(i32).signed;
        \\T_uname :: #run type_info(u8).name;
        \\T_flen  :: #run type_info(Point).fields.len;
        \\T_f0    :: #run type_info(Point).fields[0].name;
        \\T_f1    :: #run type_info(Point).fields[1].name;
        \\T_pk    :: #run type_info(*i32).kind;
        \\T_sk    :: #run type_info([]u8).kind;
        \\T_elem  :: #run type_info([]u8).elem_info.name;
        \\
        \\// ── TARGET ──
        \\T_debug :: #run TARGET.debug;
    ;

    var fe = try k2.compile(a, "corpus.k2", src);
    defer fe.deinit(a);

    const stats = ir.evalCorpus(a, fe);

    std.debug.print(
        "\n[vm corpus] total={d} evaluated={d} failed={d}\n",
        .{ stats.total, stats.evaluated, stats.failed },
    );

    // The VM is the sole comptime engine: every #run in the corpus must fold.
    try std.testing.expectEqual(@as(usize, 0), stats.failed);
    try std.testing.expect(stats.total >= 50);
    try std.testing.expectEqual(stats.total, stats.evaluated);
}
