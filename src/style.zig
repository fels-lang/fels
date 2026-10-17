const std = @import("std");
const builtin = @import("builtin");

// Terminal color for diagnostics. A `Palette` is either on or off; every accessor
// returns an ANSI escape when on and an empty string when off, so the renderer can
// interleave colors unconditionally and a plain palette produces plain text (which
// is what tests and redirected output get).

pub const Palette = struct {
    on: bool = false,

    pub const plain: Palette = .{ .on = false };

    inline fn pick(self: Palette, comptime esc: []const u8) []const u8 {
        return if (self.on) esc else "";
    }

    pub fn reset(self: Palette) []const u8 {
        return self.pick("\x1b[0m");
    }
    pub fn bold(self: Palette) []const u8 {
        return self.pick("\x1b[1m");
    }
    pub fn dim(self: Palette) []const u8 {
        return self.pick("\x1b[2m");
    }
    pub fn red(self: Palette) []const u8 {
        return self.pick("\x1b[1;31m");
    }
    pub fn yellow(self: Palette) []const u8 {
        return self.pick("\x1b[1;33m");
    }
    pub fn green(self: Palette) []const u8 {
        return self.pick("\x1b[1;32m");
    }
    pub fn cyan(self: Palette) []const u8 {
        return self.pick("\x1b[1;36m");
    }
    pub fn blue(self: Palette) []const u8 {
        return self.pick("\x1b[1;34m");
    }
};

const win = struct {
    const std_error_handle: u32 = @bitCast(@as(i32, -12));
    const enable_vt: u32 = 0x4;
    extern "kernel32" fn GetStdHandle(n: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetConsoleMode(h: *anyopaque, mode: *u32) callconv(.winapi) i32;
    extern "kernel32" fn SetConsoleMode(h: *anyopaque, mode: u32) callconv(.winapi) i32;
    extern "kernel32" fn GetEnvironmentVariableA(name: [*:0]const u8, buf: [*]u8, size: u32) callconv(.winapi) u32;
};

/// What `detectPosix` found for stderr, on a system other than Windows. Plain until `main`
/// calls it, so tests get plain text.
var posix_stderr: Palette = .plain;

/// Decide whether to colorize stderr, enabling VT processing on the console if so.
/// Off when stderr is redirected (not a console) or when `NO_COLOR` is set; `FELS_COLOR`
/// turns it on. Elsewhere than on Windows, what `detectPosix` found.
pub fn forStderr() Palette {
    if (builtin.target.os.tag != .windows) return posix_stderr;
    if (envSet("NO_COLOR")) return .plain; // https://no-color.org
    if (envSet("FELS_COLOR")) return .{ .on = true }; // force on (e.g. piping to a pager)
    const h = win.GetStdHandle(win.std_error_handle) orelse return .plain;
    var mode: u32 = 0;
    if (win.GetConsoleMode(h, &mode) == 0) return .plain; // redirected → no console
    _ = win.SetConsoleMode(h, mode | win.enable_vt);
    return .{ .on = true };
}

/// On a system other than Windows, find out once whether stderr gets colors: when it is a
/// terminal and `TERM` is not `dumb`, with `NO_COLOR` and `FELS_COLOR` as on Windows.
pub fn detectPosix(io: std.Io, env: *const std.process.Environ.Map) void {
    if (builtin.target.os.tag == .windows) return;
    const set = struct {
        fn f(e: *const std.process.Environ.Map, name: []const u8) bool {
            const v: []const u8 = e.get(name) orelse return false;
            return v.len != 0;
        }
    }.f;
    const term: []const u8 = env.get("TERM") orelse "";
    posix_stderr = if (set(env, "NO_COLOR"))
        .plain
    else if (set(env, "FELS_COLOR"))
        .{ .on = true }
    else if (std.mem.eql(u8, term, "dumb"))
        .plain
    else if (std.Io.File.stderr().isTty(io) catch false)
        .{ .on = true }
    else
        .plain;
}

fn envSet(comptime name: [*:0]const u8) bool {
    var buf: [4]u8 = undefined;
    return win.GetEnvironmentVariableA(name, &buf, buf.len) != 0;
}
