/// Windows link step.
///
/// Zig 0.16 requires std.Io for all process spawning, which isn't available
/// in library context.  For now this module builds the lld-link command and
/// either writes a `link.bat` helper or can be extended later to spawn
/// the process directly from a tool that has access to std.Io.
///
/// To link manually after emitObject("output.o"):
///   lld-link output.o /OUT:output.exe /SUBSYSTEM:CONSOLE /ENTRY:mainCRTStartup /NODEFAULTLIB kernel32.lib
const std = @import("std");

pub const LinkError = error{ OutOfMemory, WriteFailed };

pub const WindowsLinkOptions = struct {
    /// Directory containing lld-link.exe (e.g. <llvm>/bin).
    llvm_bin:  []const u8,
    /// Object files to link.
    obj_files: []const []const u8,
    /// Output executable path.
    output:    []const u8,
    /// Extra /LIBPATH: directories for kernel32.lib etc.
    lib_paths: []const []const u8 = &.{},
};

/// Build the lld-link command line as a slice of argument strings (caller frees).
pub fn buildArgs(allocator: std.mem.Allocator, opts: WindowsLinkOptions) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);

    try args.append(allocator, try std.fmt.allocPrint(allocator, "{s}/lld-link.exe", .{opts.llvm_bin}));
    for (opts.obj_files) |obj| try args.append(allocator, obj);
    try args.append(allocator, try std.fmt.allocPrint(allocator, "/OUT:{s}", .{opts.output}));
    try args.append(allocator, "/SUBSYSTEM:CONSOLE");
    try args.append(allocator, "/ENTRY:mainCRTStartup");
    try args.append(allocator, "/NODEFAULTLIB");
    try args.append(allocator, "kernel32.lib");
    for (opts.lib_paths) |lp|
        try args.append(allocator, try std.fmt.allocPrint(allocator, "/LIBPATH:{s}", .{lp}));

    return args.toOwnedSlice(allocator);
}

/// Print the link command to stderr for manual execution.
pub fn printCommand(allocator: std.mem.Allocator, opts: WindowsLinkOptions) void {
    const args = buildArgs(allocator, opts) catch return;
    defer {
        for (args) |a| allocator.free(@constCast(a));
        allocator.free(args);
    }
    std.debug.print("Link command:\n  ", .{});
    for (args) |a| std.debug.print("{s} ", .{a});
    std.debug.print("\n", .{});
}

/// Print the link command and return.
/// In Zig 0.16, process spawning requires std.Io which is not available in
/// library context.  Run the printed command to link manually, or invoke
/// lld-link directly from a tool that has access to std.Io.
pub fn windows(allocator: std.mem.Allocator, opts: WindowsLinkOptions) LinkError!void {
    printCommand(allocator, opts);
}
