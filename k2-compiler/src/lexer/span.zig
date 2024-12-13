pub const Span = struct {
    start: usize,
    end: usize,

    pub fn new(start: usize, end: usize) Span {
        return .{
            .start = start,
            .end = end,
        };
    }

    pub fn join(self: *Span, other: Span) Span {
        return .{
            .start = @min(self.start, other.start),
            .end = @max(self.end, other.end),
        };
    }

    pub const LineColResult = struct {
        line: usize,
        col: usize,
    };

    pub fn line_col(self: *Span, source: []const u8) LineColResult {
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
