const std = @import("std");
const builtin = @import("builtin");

// Monotonic wall-clock without an `Io` handle — Zig 0.16's `std.Io.Clock` needs
// one, but the comptime evaluator (`ir.zig`) doesn't have it. Used only for
// best-effort phase/comptime timing in the driver and CLI.

const win = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) i32;
    extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) i32;
} else struct {};

/// Monotonic nanoseconds (best-effort; returns 0 where unavailable).
pub fn monoNs() u64 {
    if (builtin.os.tag != .windows) return 0;
    var counter: i64 = 0;
    var freq: i64 = 0;
    if (win.QueryPerformanceCounter(&counter) == 0) return 0;
    if (win.QueryPerformanceFrequency(&freq) == 0 or freq == 0) return 0;
    return @intCast(@divTrunc(@as(i128, counter) * 1_000_000_000, @as(i128, freq)));
}

/// Nanoseconds elapsed since an earlier `monoNs()` sample.
pub fn sinceNs(start: u64) u64 {
    const end = monoNs();
    return if (end > start) end - start else 0;
}
