pub const Span = struct {
    start: usize,
    end: usize,

    pub fn new(start: usize, end: usize) Span {
        return .{
            .start = start,
            .end = end,
        };
    }

    pub fn join(self: Span, other: Span) Span {
        return .{
            .start = @min(self.start, other.start),
            .end = @max(self.end, other.end),
        };
    }

    pub const LineColResult = struct {
        line: usize,
        col: usize,
    };

    pub fn line_col(self: Span, source: []const u8) LineColResult {
        var line: usize = 1;
        var col: usize = 1;

        for (source, 0..) |ch, i| {
            if (i >= self.start) {
                break;
            }

            if (ch == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }

        return .{
            .line = line,
            .col = col,
        };
    }
};

/// Where each line of a source starts, so that an offset becomes a line and a column by a
/// binary search instead of a walk from the start of the file. The lowering asks for the
/// position of every instruction, and walking took time in proportion to the file each time:
/// a file of 100,000 lines spent 38 s there.
pub const LineStarts = struct {
    /// The offset of the first byte of each line; the first is 0.
    starts: []const u32,

    pub fn of(allocator: @import("std").mem.Allocator, source: []const u8) !LineStarts {
        var list: @import("std").ArrayList(u32) = .empty;
        errdefer list.deinit(allocator);
        try list.append(allocator, 0);
        for (source, 0..) |ch, i| {
            if (ch == '\n') try list.append(allocator, @intCast(i + 1));
        }
        return .{ .starts = try list.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: LineStarts, allocator: @import("std").mem.Allocator) void {
        allocator.free(self.starts);
    }

    /// The line and column of `offset` in the source, as `Span.line_col` gives them.
    pub fn lineCol(self: LineStarts, offset: usize, source_len: usize) Span.LineColResult {
        const at = @min(offset, source_len);
        // The last line that starts at or before `at`.
        var lo: usize = 0;
        var hi: usize = self.starts.len;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (self.starts[mid] <= at) lo = mid else hi = mid;
        }
        return .{ .line = lo + 1, .col = at - self.starts[lo] + 1 };
    }
};
