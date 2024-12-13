const std = @import("std");
const backend = @import("backend.zig");
const ir = @import("ir.zig");

pub const default_source_path = "C:\\Users\\chris\\backend\\basalt";
pub const default_lib_dir = default_source_path ++ "\\bin";
pub const static_lib_name = "basalt";

pub const BasaltBackend = struct {
    source_path: []const u8 = default_source_path,
    lib_dir: []const u8 = default_lib_dir,

    pub fn init() BasaltBackend {
        return .{};
    }

    pub fn asBackend(self: *BasaltBackend) backend.Backend {
        return .{
            .ptr = self,
            .vtable = &.{
                .name = name,
                .supports = supports,
                .emit_text_ir = emitTextIr,
                .emit_object = emitObject,
            },
        };
    }

    fn name(_: *anyopaque) []const u8 {
        return "basalt";
    }

    fn supports(_: *anyopaque, artifact: backend.ArtifactKind) bool {
        return artifact == .object;
    }

    fn emitTextIr(_: *anyopaque, _: std.mem.Allocator, _: ir.IrModule) backend.BackendError![]u8 {
        return error.UnsupportedArtifact;
    }

    fn emitObject(ctx: *anyopaque, module: ir.IrModule, path: []const u8) backend.BackendError!void {
        const self: *BasaltBackend = @ptrCast(@alignCast(ctx));
        _ = self;
        _ = module;
        _ = path;

        return error.EmitFailed;
    }
};
