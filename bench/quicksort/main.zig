// quicksort: n pseudo-random u32 (xorshift32) sorted by one quicksort written out the same way
// in every language: Hoare partition around the middle element, insertion sort below 16
// elements, the smaller side recursed into. Comparisons, swaps and unpredictable branches.
// Prints whether the result is sorted, its ends and a checksum.
// The Zig version of main.fels: the same algorithm, data layout and output.

const std = @import("std");

fn insertionSort(a: []u32, lo: i64, hi: i64) void {
    var i = lo + 1;
    while (i <= hi) {
        const v = a[@intCast(i)];
        var j = i - 1;
        while (j >= lo and a[@intCast(j)] > v) {
            a[@intCast(j + 1)] = a[@intCast(j)];
            j -= 1;
        }
        a[@intCast(j + 1)] = v;
        i += 1;
    }
}

fn quicksort(a: []u32, lo_in: i64, hi_in: i64) void {
    var lo = lo_in;
    var hi = hi_in;
    while (hi - lo > 16) {
        const p = a[@intCast(lo + @divTrunc(hi - lo, 2))];
        var i = lo - 1;
        var j = hi + 1;
        while (true) {
            i += 1;
            while (a[@intCast(i)] < p) i += 1;
            j -= 1;
            while (a[@intCast(j)] > p) j -= 1;
            if (i >= j) break;
            const t = a[@intCast(i)];
            a[@intCast(i)] = a[@intCast(j)];
            a[@intCast(j)] = t;
        }
        // Recurse into the smaller side, go on with the larger.
        if (j - lo < hi - j) {
            quicksort(a, lo, j);
            lo = j + 1;
        } else {
            quicksort(a, j + 1, hi);
            hi = j;
        }
    }
    insertionSort(a, lo, hi);
}

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

    const allocator = std.heap.page_allocator;
    const a = try allocator.alloc(u32, n);
    defer allocator.free(a);
    var x: u32 = 2463534242;
    for (0..n) |i| {
        x = x ^ (x << 13);
        x = x ^ (x >> 17);
        x = x ^ (x << 5);
        a[i] = x;
    }
    quicksort(a, 0, @as(i64, @intCast(n)) - 1);
    var sorted = true;
    var checksum: u64 = 0;
    for (0..n) |i| {
        if (i > 0 and a[i - 1] > a[i]) sorted = false;
        checksum = checksum +% @as(u64, a[i]) *% (@as(u64, @intCast(i)) + 1);
    }
    try out.print("{} {d} {d} {d}\n", .{ sorted, a[0], a[n - 1], checksum });
    try out.flush();
}
