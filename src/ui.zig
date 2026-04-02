//! The command line's own output: the marks before a result line, durations, the summary
//! lines, and the live progress tree that `fels build` and `fels test` draw while they work.
//!
//! On a terminal the marks are colored and a `std.Progress` tree shows the stages as they
//! run, as `zig build` does. When stderr is redirected (a pipe, a log, CI), or with `-q`,
//! there is no tree and no color: the same lines come out plain. Diagnostics have their own
//! renderer (diagnostic.zig) with the same palette.

const std = @import("std");
const style = @import("style.zig");
const clock = @import("clock.zig");
const driver = @import("driver.zig");

/// The colors of what the commands print. Plain unless `main` found a terminal, so tests
/// and redirected output get plain text.
pub var pal: style.Palette = .plain;

/// The live progress tree, while a command runs on a terminal; `.none` otherwise. Its
/// nodes do nothing when it is `.none`.
pub var root: std.Progress.Node = .none;
var started = false;

/// Start the live tree, named `name`, with `total` steps (0 when not known). Only on a
/// terminal: elsewhere the output stays line by line. Once per process: after `finish` the
/// rest of the command prints lines only.
///
/// The tree draws through the io of `std.debug.print` (main.zig gives it a thread for the
/// redraws), so a line printed while the tree is up takes the same lock and clears the tree
/// first.
pub fn start(name: []const u8, total: usize) void {
    if (!pal.on or started) return;
    started = true;
    root = std.Progress.start(std.Options.debug_io, .{ .root_name = name, .estimated_total_items = total });
}

/// Take the live tree away, before a summary, or before a program is run that writes to the
/// terminal itself.
pub fn finish() void {
    root.end();
    root = .none;
}

pub const Mark = enum { ok, fail, skip, run, warn };

/// The mark at the start of a result line: ✓ done, ✗ failed, · skipped or up to date,
/// ▸ running a program, ! a warning.
pub fn mark(kind: Mark) []const u8 {
    return switch (kind) {
        .ok => if (pal.on) "\x1b[1;32m\u{2713}\x1b[0m" else "\u{2713}",
        .fail => if (pal.on) "\x1b[1;31m\u{2717}\x1b[0m" else "\u{2717}",
        .skip => if (pal.on) "\x1b[2m\u{00b7}\x1b[0m" else "\u{00b7}",
        .run => if (pal.on) "\x1b[1;36m\u{25b8}\x1b[0m" else "\u{25b8}",
        .warn => if (pal.on) "\x1b[1;33m!\x1b[0m" else "!",
    };
}

/// What a failed compile or link is, in words, for a `✗` line (the reason is printed above it).
pub fn failure(err: anyerror) []const u8 {
    return switch (err) {
        error.CompileFailed, error.SemanticFailed, error.ParseFailed, error.LoweringFailed => "does not compile",
        error.LinkFailed => "did not link",
        error.EmitFailed => "could not write its object file",
        error.FileNotFound => "not found",
        else => @errorName(err),
    };
}

/// `48µs`, `312ms`, `2.41s`.
pub fn duration(buf: []u8, ns: u64) []const u8 {
    if (ns < std.time.ns_per_ms)
        return std.fmt.bufPrint(buf, "{d}\u{00b5}s", .{ns / std.time.ns_per_us}) catch "?";
    if (ns < std.time.ns_per_s)
        return std.fmt.bufPrint(buf, "{d}ms", .{ns / std.time.ns_per_ms}) catch "?";
    const hundredths = ns / (10 * std.time.ns_per_ms);
    return std.fmt.bufPrint(buf, "{d}.{d:0>2}s", .{ hundredths / 100, hundredths % 100 }) catch "?";
}

/// A duration in the dim color, for the end of a line.
pub fn dimDuration(buf: []u8, ns: u64) []const u8 {
    var inner: [24]u8 = undefined;
    const d = duration(&inner, ns);
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ pal.dim(), d, pal.reset() }) catch d;
}

/// The stages of one compile under a node of the tree: each stage is a child named after
/// it, and the node counts the stages done. Its `step` is a `driver.ProgressFn`.
pub const Stages = struct {
    node: std.Progress.Node,
    current: std.Progress.Node = .none,
    started: u64,

    /// The stages of a compile named `name`, under `parent`.
    pub fn begin(parent: std.Progress.Node, name: []const u8) Stages {
        return .{ .node = parent.start(name, stage_count), .started = clock.monoNs() };
    }

    pub fn step(ctx: ?*anyopaque, phase: driver.Phase) void {
        const self: *Stages = @ptrCast(@alignCast(ctx.?));
        self.stage(phase.label());
    }

    /// Begin the stage `name`, after the one before (ending a node counts it as done).
    pub fn stage(self: *Stages, name: []const u8) void {
        self.current.end();
        self.current = self.node.start(name, 0);
    }

    /// End the compile's node; the time since `begin`.
    pub fn end(self: *Stages) u64 {
        self.current.end();
        self.current = .none;
        self.node.end();
        return clock.sinceNs(self.started);
    }

    const stage_count = @typeInfo(driver.Phase).@"enum".fields.len;
};

/// `check 120ms · lower 30ms · codegen 400ms · link 200ms` for the end of a build line: the
/// stages that took a millisecond or more.
pub fn stageBreakdown(buf: []u8, t: driver.Timings) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const parts = [_]struct { name: []const u8, ns: u64 }{
        .{ .name = "check", .ns = t.frontend_ns },
        .{ .name = "lower", .ns = t.lower_ns + t.passes_ns },
        .{ .name = "codegen", .ns = t.codegen_ns + t.emit_ns },
        .{ .name = "link", .ns = t.link_ns },
    };
    var first = true;
    for (parts) |p| {
        if (p.ns < std.time.ns_per_ms) continue;
        var d: [24]u8 = undefined;
        w.print("{s}{s} {s}", .{ if (first) "" else " \u{00b7} ", p.name, duration(&d, p.ns) }) catch break;
        first = false;
    }
    return w.buffered();
}

/// Counts for a summary line, in their colors: `3 passed` green, `1 failed` red, and the
/// rest plain. A count of zero is left out, unless all are zero: then the first is shown.
pub const Count = struct {
    n: u32,
    what: []const u8,
    color: enum { good, bad, plain },
};

pub fn writeCounts(w: *std.Io.Writer, counts: []const Count) std.Io.Writer.Error!void {
    var first = true;
    const any = for (counts) |c| {
        if (c.n != 0) break true;
    } else false;
    for (counts, 0..) |c, i| {
        if (c.n == 0 and (any or i != 0)) continue;
        if (!first) try w.writeAll(", ");
        const color = switch (c.color) {
            .good => if (c.n > 0) pal.green() else "",
            .bad => if (c.n > 0) pal.red() else "",
            .plain => "",
        };
        try w.print("{s}{d} {s}{s}", .{ color, c.n, c.what, if (color.len > 0) pal.reset() else "" });
        first = false;
    }
}

/// A writer to stderr that takes the lock of `std.debug.print` for each write, so what it
/// writes clears the live tree first, as a print does.
pub const Stderr = struct {
    interface: std.Io.Writer,

    pub fn init(buffer: []u8) Stderr {
        return .{ .interface = .{ .buffer = buffer, .vtable = &.{ .drain = drain } } };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const locked = std.debug.lockStderr(&.{});
        defer std.debug.unlockStderr();
        const to = &locked.file_writer.interface;
        try to.writeAll(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try to.writeAll(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try to.writeAll(last);
        return n + last.len * splat;
    }
};

test "durations read as people write them" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("48\u{00b5}s", duration(&buf, 48_000));
    try std.testing.expectEqualStrings("312ms", duration(&buf, 312_000_000));
    try std.testing.expectEqualStrings("2.41s", duration(&buf, 2_419_000_000));
    try std.testing.expectEqualStrings("12.00s", duration(&buf, 12_000_000_000));
}
