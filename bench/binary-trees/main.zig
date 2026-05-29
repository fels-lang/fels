// binary-trees: the Benchmarks Game's binary trees, built and walked many times over.
// Many small allocations and pointer chasing. Every tree is allocated in an arena that is
// reset after it is checked, in all three languages.
// The Zig version of main.fels: the same algorithm, data layout and output.

const std = @import("std");

// A chunked bump-pointer arena, the counterpart of the Fels std.heap Arena that main.fels uses
// and of the one in main.c, and the same design: chunks of `chunk_bytes` payload bytes, an
// allocation is the next 16-byte-aligned piece of the current chunk, and `reset` rewinds to the
// first chunk, keeping all of them (a later chunk is marked empty when an allocation moves into
// it). Zig's std.heap.ArenaAllocator is not used: it is safe to share between threads, and pays
// for that with atomic operations on every allocation, which the Fels and C arenas do not do.
const chunk_bytes = 65536;
const alignment = 16;

const Chunk = struct {
    next: ?*Chunk,
    cap: usize, // payload bytes
    used: usize, // payload bytes handed out

    const header = std.mem.alignForward(usize, @sizeOf(Chunk), alignment);

    fn data(c: *Chunk) [*]u8 {
        return @as([*]u8, @ptrCast(c)) + header;
    }
};

const Arena = struct {
    first: ?*Chunk = null, // the oldest chunk, where a reset starts over
    head: ?*Chunk = null, // the chunk allocations come from

    /// `size` uninitialized bytes. Panics when out of memory.
    fn alloc(a: *Arena, size: usize) [*]u8 {
        if (a.head) |c| {
            const at = std.mem.alignForward(usize, c.used, alignment);
            if (at + size <= c.cap) {
                c.used = at + size;
                return c.data() + at;
            }
            // The current chunk is full. After a reset, the next one is free for reuse.
            if (c.next) |next| {
                if (size <= next.cap) {
                    next.used = size;
                    a.head = next;
                    return next.data();
                }
            }
        }
        // A new chunk, linked in after the current one. A larger allocation gets its own.
        const cap = @max(size, chunk_bytes);
        const mem = std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(alignment), Chunk.header + cap) catch @panic("out of memory");
        const fresh: *Chunk = @ptrCast(@alignCast(mem.ptr));
        fresh.* = .{ .next = null, .cap = cap, .used = size };
        if (a.head) |c| {
            fresh.next = c.next;
            c.next = fresh;
        } else {
            a.first = fresh;
        }
        a.head = fresh;
        return fresh.data();
    }

    /// Empties the arena and keeps its chunks: what was allocated is gone, the memory is reused.
    fn reset(a: *Arena) void {
        if (a.first) |f| f.used = 0;
        a.head = a.first;
    }
};

const Node = struct { left: ?*Node, right: ?*Node };

fn bottomUp(depth: i32, a: *Arena) *Node {
    const node: *Node = @ptrCast(@alignCast(a.alloc(@sizeOf(Node))));
    if (depth > 0) {
        node.left = bottomUp(depth - 1, a);
        node.right = bottomUp(depth - 1, a);
    } else {
        node.left = null;
        node.right = null;
    }
    return node;
}

fn check(node: *Node) i32 {
    if (node.left) |l| {
        if (node.right) |r| return 1 + check(l) + check(r);
    }
    return 1;
}

/// The first argument as a number, or `fallback`.
fn argInt(init: std.process.Init, fallback: i64) !i64 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return fallback;
    return std.fmt.parseInt(i64, args[1], 10);
}

pub fn main(init: std.process.Init) !void {
    const min_depth: i32 = 4;
    var max_depth: i32 = @intCast(try argInt(init, 10));
    if (max_depth < min_depth + 2) max_depth = min_depth + 2;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const stretch = max_depth + 1;
    var scratch: Arena = .{};
    const stretch_check = check(bottomUp(stretch, &scratch));
    try out.print("stretch tree of depth {d}\t check: {d}\n", .{ stretch, stretch_check });
    scratch.reset();

    var long_arena: Arena = .{};
    const long_lived = bottomUp(max_depth, &long_arena);

    var d = min_depth;
    while (d <= max_depth) {
        const iterations: i32 = @as(i32, 1) << @intCast(max_depth - d + min_depth);
        var sum: i32 = 0;
        var i: i32 = 0;
        while (i < iterations) : (i += 1) {
            sum += check(bottomUp(d, &scratch));
            scratch.reset();
        }
        try out.print("{d}\t trees of depth {d}\t check: {d}\n", .{ iterations, d, sum });
        d += 2;
    }
    try out.print("long lived tree of depth {d}\t check: {d}\n", .{ max_depth, check(long_lived) });
    try out.flush();
}
