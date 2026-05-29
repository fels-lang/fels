// mandelbrot: the Benchmarks Game's Mandelbrot set, an n x n bitmap of 50 iterations each.
// A tight floating-point loop, and bits packed into bytes. Instead of the bitmap it prints a
// checksum of its bytes.
// The Zig version of main.fels: the same algorithm, data layout and output.

const std = @import("std");

/// The first argument as a number, or `fallback`.
fn argInt(init: std.process.Init, fallback: i64) !i64 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return fallback;
    return std.fmt.parseInt(i64, args[1], 10);
}

pub fn main(init: std.process.Init) !void {
    const n: usize = @intCast(try argInt(init, 200));
    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const w: f64 = @floatFromInt(n);
    var checksum: u32 = 0;
    for (0..n) |y| {
        const ci = 2.0 * @as(f64, @floatFromInt(y)) / w - 1.0;
        var byte: u32 = 0;
        var bits: u32 = 0;
        for (0..n) |x| {
            const cr = 2.0 * @as(f64, @floatFromInt(x)) / w - 1.5;
            var zr: f64 = 0.0;
            var zi: f64 = 0.0;
            var tr: f64 = 0.0;
            var ti: f64 = 0.0;
            var i: i32 = 0;
            while (i < 50 and tr + ti <= 4.0) {
                zi = 2.0 * zr * zi + ci;
                zr = tr - ti + cr;
                tr = zr * zr;
                ti = zi * zi;
                i += 1;
            }
            byte = byte << 1;
            if (tr + ti <= 4.0) byte = byte | 1;
            bits += 1;
            if (bits == 8) {
                checksum = checksum *% 31 +% byte;
                byte = 0;
                bits = 0;
            } else if (x == n - 1) {
                byte = (byte << @intCast(8 - @as(u32, @intCast(n % 8)))) & 255;
                checksum = checksum *% 31 +% byte;
                byte = 0;
                bits = 0;
            }
        }
    }
    try out.print("{d} {d}\n", .{ n, checksum });
    try out.flush();
}
