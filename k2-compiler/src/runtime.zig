/// K2 runtime module embedded inside the compiler binary.
///
/// Real programs automatically receive the host runtime, which provides:
///   - write_stdout(data), write_stderr(data)
///   - exit(code), abort()
///   - @panic(msg), assert(cond), assert_msg(cond, msg)
const builtin = @import("builtin");

pub const windows_src = @embedFile("runtime/windows.k2");
pub const linux_src = @embedFile("runtime/linux.k2");

/// Return the runtime source for a supported platform.
pub fn runtimeSourceFor(os: @TypeOf(builtin.os.tag)) ?[]const u8 {
    return switch (os) {
        .windows => windows_src,
        .linux => linux_src,
        else => null,
    };
}

/// Return the runtime source for the compiler host.
pub fn runtimeSource() []const u8 {
    return runtimeSourceFor(builtin.os.tag) orelse "";
}
