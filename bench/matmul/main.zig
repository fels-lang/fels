// matmul: an n x n matrix product of doubles, the naive i-k-j loop order.
// Floating-point multiply-add over rows, the loop compilers vectorize. The entries are small
// integers, so the sum it prints is exact in every language.
// The Zig version of main.fels: the same algorithm, data layout and output.

const std = @import("std");

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
    const x = try a.alloc(f64, n * n);
    defer a.free(x);
    const y = try a.alloc(f64, n * n);
    defer a.free(y);
    const z = try a.alloc(f64, n * n);
    defer a.free(z);
    for (0..n) |i| {
        for (0..n) |j| {
            x[i * n + j] = @floatFromInt((i + j) % 3);
            y[i * n + j] = @floatFromInt((i * j) % 5);
            z[i * n + j] = 0.0;
        }
    }
    for (0..n) |i| {
        for (0..n) |k| {
            const xik = x[i * n + k];
            for (0..n) |j| z[i * n + j] += xik * y[k * n + j];
        }
    }
    var sum: f64 = 0.0;
    for (0..(n * n)) |i| sum += z[i];
    try out.print("{d}\n", .{@as(i64, @intFromFloat(sum))});
    try out.flush();
}
