// hashmap: an open-addressing hash table of u64 keys, written out the same way in every
// language: linear probing, a power-of-two table at least twice the keys, a multiplicative
// hash. n keys from splitmix64 are inserted, then looked up again with n keys of another
// seed. Random memory access and a branch per probe. Prints the hits and the sum of their
// values.
// The Zig version of main.fels: the same algorithm, data layout and output.

const std = @import("std");

const Table = struct { keys: []u64, vals: []u64, shift: u64 };

fn splitmix(state: *u64) u64 {
    state.* = state.* +% 0x9E3779B97F4A7C15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return (z ^ (z >> 31)) | 1; // 0 marks an empty slot
}

fn slot(t: *Table, key: u64) usize {
    return @intCast((key *% 0x9E3779B97F4A7C15) >> @intCast(t.shift));
}

fn insert(t: *Table, key: u64, val: u64) void {
    const mask = t.keys.len - 1;
    var i = slot(t, key);
    while (t.keys[i] != 0 and t.keys[i] != key) i = (i + 1) & mask;
    t.keys[i] = key;
    t.vals[i] = val;
}

fn find(t: *Table, key: u64) ?u64 {
    const mask = t.keys.len - 1;
    var i = slot(t, key);
    while (t.keys[i] != 0) {
        if (t.keys[i] == key) return t.vals[i];
        i = (i + 1) & mask;
    }
    return null;
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

    var bits: u64 = 1;
    while ((@as(usize, 1) << @intCast(bits)) < 2 * n) bits += 1;
    const cap = @as(usize, 1) << @intCast(bits);
    const a = std.heap.page_allocator;
    var t: Table = .{ .keys = try a.alloc(u64, cap), .vals = try a.alloc(u64, cap), .shift = 64 - bits };
    defer a.free(t.keys);
    defer a.free(t.vals);
    for (0..cap) |i| {
        t.keys[i] = 0;
        t.vals[i] = 0;
    }
    var seed: u64 = 1;
    for (0..n) |i| insert(&t, splitmix(&seed), @intCast(i));
    var found: u64 = 0;
    var sum: u64 = 0;
    seed = 1;
    for (0..n) |_| {
        if (find(&t, splitmix(&seed))) |v| {
            found += 1;
            sum = sum +% v;
        }
    }
    seed = 2;
    for (0..n) |_| {
        if (find(&t, splitmix(&seed))) |v| {
            found += 1;
            sum = sum +% v;
        }
    }
    try out.print("{d} {d}\n", .{ found, sum });
    try out.flush();
}
