const std = @import("std");
const backend = @import("backend.zig");
const ir = @import("ir.zig");

pub const static_lib_name = "basalt";

pub const BasaltBackend = struct {
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
