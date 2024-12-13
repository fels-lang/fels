const std = @import("std");
const ir = @import("ir.zig");

pub const ArtifactKind = enum {
    text_ir,
    object,

    pub fn label(self: ArtifactKind) []const u8 {
        return switch (self) {
            .text_ir => "text IR",
            .object => "object files",
        };
    }
};

pub const BackendError = error{
    UnsupportedArtifact,
    EmitFailed,
    OutOfMemory,
};

pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (*anyopaque) []const u8,
        supports: *const fn (*anyopaque, ArtifactKind) bool,
        emit_text_ir: *const fn (*anyopaque, std.mem.Allocator, ir.IrModule) BackendError![]u8,
        emit_object: *const fn (*anyopaque, ir.IrModule, []const u8) BackendError!void,
    };

    pub fn name(self: Backend) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn supports(self: Backend, artifact: ArtifactKind) bool {
        return self.vtable.supports(self.ptr, artifact);
    }

    pub fn emitTextIr(self: Backend, allocator: std.mem.Allocator, module: ir.IrModule) BackendError![]u8 {
        return self.vtable.emit_text_ir(self.ptr, allocator, module);
    }

    pub fn emitObject(self: Backend, module: ir.IrModule, path: []const u8) BackendError!void {
        return self.vtable.emit_object(self.ptr, module, path);
    }
};

pub const NullBackend = struct {
    pub fn backend(self: *NullBackend) Backend {
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
        return "null";
    }

    fn supports(_: *anyopaque, _: ArtifactKind) bool {
        return false;
    }

    fn emitTextIr(_: *anyopaque, _: std.mem.Allocator, _: ir.IrModule) BackendError![]u8 {
        return error.UnsupportedArtifact;
    }

    fn emitObject(_: *anyopaque, _: ir.IrModule, _: []const u8) BackendError!void {
        return error.UnsupportedArtifact;
    }
};
