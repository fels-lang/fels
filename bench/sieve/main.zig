// sieve: the primes up to n, by the sieve of Eratosthenes over one byte per number.
// Memory traffic with strided writes, and a branch per number. Prints how many there are.
// The Zig version of main.fels: the same algorithm, data layout and output.

const std = @import("std");

/// The first argument as a number, or `fallback`.
fn argInt(init: std.process.Init, fallback: i64) !i64 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return fallback;
    return std.fmt.parseInt(i64, args[1], 10);
}

pub fn main(init: std.process.Init) !void {
    const n: usize = @intCast(try argInt(init, 1000));
    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const a = std.heap.page_allocator;
    const composite = try a.alloc(u8, n + 1);
    defer a.free(composite);
    for (0..(n + 1)) |i| composite[i] = 0;
    var count: usize = 0;
    for (2..(n + 1)) |i| {
        if (composite[i] == 0) {
            count += 1;
            var j = i * i;
            while (j <= n) {
                composite[j] = 1;
                j += i;
            }
        }
    }
    try out.print("{d}\n", .{count});
    try out.flush();
}
