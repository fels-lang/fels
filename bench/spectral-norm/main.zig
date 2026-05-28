// spectral-norm: the Benchmarks Game's spectral norm of an infinite matrix, by the power method.
// Floating-point division and dot products in nested loops. Prints the norm to 9 decimals.
// The Zig version of main.fels: the same algorithm, data layout and output.

const std = @import("std");

fn evalA(i: usize, j: usize) f64 {
    return 1.0 / @as(f64, @floatFromInt((i + j) * (i + j + 1) / 2 + i + 1));
}

fn mulAv(v: []f64, out: []f64) void {
    for (0..out.len) |i| {
        var s: f64 = 0.0;
        for (0..v.len) |j| s += evalA(i, j) * v[j];
        out[i] = s;
    }
}

fn mulAtv(v: []f64, out: []f64) void {
    for (0..out.len) |i| {
        var s: f64 = 0.0;
        for (0..v.len) |j| s += evalA(j, i) * v[j];
        out[i] = s;
    }
}

fn mulAtAv(v: []f64, out: []f64, tmp: []f64) void {
    mulAv(v, tmp);
    mulAtv(tmp, out);
}

/// The first argument as a number, or `fallback`.
fn argInt(init: std.process.Init, fallback: i64) !i64 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return fallback;
    return std.fmt.parseInt(i64, args[1], 10);
}

pub fn main(init: std.process.Init) !void {
    const n: usize = @intCast(try argInt(init, 100));
    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const a = std.heap.page_allocator;
    const u = try a.alloc(f64, n);
    defer a.free(u);
    const v = try a.alloc(f64, n);
    defer a.free(v);
    const tmp = try a.alloc(f64, n);
    defer a.free(tmp);
    for (0..n) |i| u[i] = 1.0;
    for (0..10) |_| {
        mulAtAv(u, v, tmp);
        mulAtAv(v, u, tmp);
    }
    var vbv: f64 = 0.0;
    var vv: f64 = 0.0;
    for (0..n) |i| {
        vbv += u[i] * v[i];
        vv += v[i] * v[i];
    }
    try out.print("{d:.9}\n", .{@sqrt(vbv / vv)});
    try out.flush();
}
