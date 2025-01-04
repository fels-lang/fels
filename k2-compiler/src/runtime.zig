/// K2 runtime module — embedded inside the compiler binary.
///
/// The runtime source is loaded with @embedFile at compile time,
/// so k2.exe ships as a single file with no external dependencies.
///
/// When compiling a K2 program the appropriate runtime is automatically
/// prepended to the source list, giving every program access to:
///   - @panic(msg)
///   - assert(cond)
///   - assert_msg(cond, msg)
///   - write_stdout(data)
///   - write_stderr(data)
///   - sys_exit(code)        [Linux only]
const builtin = @import("builtin");

pub const windows_src = @embedFile("runtime/windows.k2");
pub const linux_src   = @embedFile("runtime/linux.k2");

/// Return the runtime source string for the current compilation target.
pub fn runtimeSource() []const u8 {
    return switch (builtin.os.tag) {
        .windows => windows_src,
        .linux   => linux_src,
        .macos   => linux_src,   // macOS syscall ABI differs but structure is same
        else     => "",          // unknown platform — no runtime
    };
}
