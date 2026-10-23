//! What the program is built for, as `TARGET`, `core::os`/`core::arch` and a top-level `#if`
//! see it. The driver sets `current` for each compile; anything else (a build script,
//! `fels check`, the language server) sees the host, in a debug build.
const std = @import("std");

pub const BuildTarget = struct {
    os: std.Target.Os.Tag = @import("builtin").os.tag,
    /// x86-64, or aarch64 for a UEFI or freestanding program.
    arch: std.Target.Cpu.Arch = .x86_64,
    /// Built without optimisation (`-O0`, the `debug` mode).
    debug: bool = true,

    pub fn osName(self: BuildTarget) []const u8 {
        return switch (self.os) {
            .windows => "windows",
            .linux => "linux",
            .macos => "macos",
            else => "unknown",
        };
    }

    pub fn archName(self: BuildTarget) []const u8 {
        return switch (self.arch) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            else => "unknown",
        };
    }
};

/// The variants of `TargetOs` and `TargetArch`, the types of `TARGET.os` and `TARGET.arch`.
pub const os_names = [_][]const u8{ "windows", "linux", "macos", "unknown" };
pub const arch_names = [_][]const u8{ "x86_64", "aarch64", "unknown" };

pub threadlocal var current: BuildTarget = .{};
