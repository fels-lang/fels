// crc32: the IEEE CRC-32 (the table-driven, byte-at-a-time loop zlib's reference uses) of a
// 16 MiB buffer of xorshift32 bytes, `n` times over. Byte loads, table lookups and shifts in
// a dependency chain. Prints the CRC.
// The Zig version of main.fels: the same algorithm, data layout and output.

const std = @import("std");

const SIZE = 16777216;

/// The first argument as a number, or `fallback`.
fn argInt(init: std.process.Init, fallback: i64) !i64 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return fallback;
    return std.fmt.parseInt(i64, args[1], 10);
}

pub fn main(init: std.process.Init) !void {
    const passes = try argInt(init, 1);
    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const a = std.heap.page_allocator;
    const table = try a.alloc(u32, 256);
    defer a.free(table);
    for (0..256) |i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| {
            if (c & 1 != 0) {
                c = 0xEDB88320 ^ (c >> 1);
            } else {
                c = c >> 1;
            }
        }
        table[i] = c;
    }
    const buf = try a.alloc(u8, SIZE);
    defer a.free(buf);
    var x: u32 = 2463534242;
    for (0..buf.len) |i| {
        x = x ^ (x << 13);
        x = x ^ (x >> 17);
        x = x ^ (x << 5);
        buf[i] = @intCast(x & 255);
    }
    var crc: u32 = 0xFFFFFFFF;
    var p: i64 = 0;
    while (p < passes) : (p += 1) {
        for (buf) |b| crc = table[@as(usize, (crc ^ @as(u32, b)) & 255)] ^ (crc >> 8);
    }
    try out.print("{d}\n", .{crc ^ 0xFFFFFFFF});
    try out.flush();
}
