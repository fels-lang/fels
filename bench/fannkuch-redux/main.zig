// fannkuch-redux: the Benchmarks Game's pancake flips over every permutation of 1..n.
// Small integer arrays, copies and reversals, and a permutation generator. Prints the checksum
// and the most flips.
// The Zig version of main.fels: the same algorithm, data layout and output.

const std = @import("std");

/// The first argument as a number, or `fallback`.
fn argInt(init: std.process.Init, fallback: i64) !i64 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return fallback;
    return std.fmt.parseInt(i64, args[1], 10);
}

pub fn main(init: std.process.Init) !void {
    const n: usize = @intCast(try argInt(init, 7));
    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const a = std.heap.page_allocator;
    const perm = try a.alloc(i32, n);
    defer a.free(perm);
    const perm1 = try a.alloc(i32, n);
    defer a.free(perm1);
    const count = try a.alloc(i32, n);
    defer a.free(count);
    for (0..n) |i| perm1[i] = @intCast(i);

    var max_flips: i32 = 0;
    var checksum: i32 = 0;
    var perm_count: i32 = 0;
    var r = n;
    while (true) {
        while (r != 1) {
            count[r - 1] = @intCast(r);
            r -= 1;
        }
        for (0..n) |i| perm[i] = perm1[i];
        var flips: i32 = 0;
        var k: usize = @intCast(perm[0]);
        while (k != 0) {
            var lo: usize = 0;
            var hi = k;
            while (lo < hi) {
                const t = perm[lo];
                perm[lo] = perm[hi];
                perm[hi] = t;
                lo += 1;
                hi -= 1;
            }
            flips += 1;
            k = @intCast(perm[0]);
        }
        if (flips > max_flips) max_flips = flips;
        if (@rem(perm_count, 2) == 0) {
            checksum += flips;
        } else {
            checksum -= flips;
        }

        // The next permutation.
        while (true) {
            if (r == n) {
                try out.print("{d}\nPfannkuchen({d}) = {d}\n", .{ checksum, n, max_flips });
                try out.flush();
                return;
            }
            const perm0 = perm1[0];
            for (0..r) |i| perm1[i] = perm1[i + 1];
            perm1[r] = perm0;
            count[r] -= 1;
            if (count[r] > 0) break;
            r += 1;
        }
        perm_count += 1;
    }
}
