pub const Span = struct {
    start: usize,
    end: usize,

    pub fn new(start: usize, end: usize) Span {
        return .{
            .start = start,
            .end = end,
        };
    }
};
