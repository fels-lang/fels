const std = @import("std");
const ast = @import("ast.zig");
const basalt  = @import("basalt.zig");
pub const k2_runtime = @import("runtime.zig");
const backend = @import("backend.zig");
const diagnostic = @import("diagnostic.zig");
const driver = @import("driver.zig");
const ir = @import("ir.zig");
const parser = @import("parser.zig");
const pipeline = @import("pipeline.zig");
const sema = @import("sema.zig");
const span = @import("lexer/span.zig");
const tokens = @import("lexer/tokens.zig");

pub const ast_mod = ast;
pub const basalt_mod = basalt;
pub const backend_mod = backend;
pub const diagnostic_mod = diagnostic;
pub const driver_mod = driver;
pub const ir_mod = ir;
pub const parser_mod = parser;
pub const pipeline_mod = pipeline;
pub const sema_mod = sema;

pub const Span = span.Span;
pub const TokenKind = tokens.TokenKind;
pub const Token = tokens.Token;
pub const keywordKind = tokens.keywordKind;

pub const Module = ast.Module;
pub const Diagnostic = diagnostic.Diagnostic;
pub const DiagKind = diagnostic.DiagKind;
pub const renderDiagnostic = diagnostic.renderDiagnostic;
pub const renderAll = diagnostic.renderAll;
pub const parseSource = parser.parseSource;
pub const parseSourceFrom = parser.parseSourceFrom;
pub const compile             = pipeline.compile;
pub const compileWithRuntime  = pipeline.compileWithRuntime;
pub const compileMulti        = pipeline.compileMulti;
pub const compileFile         = pipeline.compileFile;
pub const compileFileWithRuntime = pipeline.compileFileWithRuntime;
pub const FrontEnd = pipeline.FrontEnd;
pub const NodeId = ast.NodeId;
pub const SymbolKind = sema.SymbolKind;
pub const SymbolTable = sema.SymbolTable;
pub const Ty = sema.Ty;
pub const TypeEnv = sema.TypeEnv;
pub const IrModule = ir.IrModule;
pub const lowerFrontend = ir.lowerFrontend;
pub const Backend = backend.Backend;
pub const BasaltBackend = basalt.BasaltBackend;

const build_options = @import("build_options");
/// Whether LLVM codegen is available (requires `-Dllvm-path=...` at build time).
pub const llvm_enabled = build_options.enable_llvm;
pub const llvm_path = build_options.llvm_path;
pub const windows_sdk_lib_path = build_options.windows_sdk_lib_path;
/// LLVM backend — only available when compiled with `-Dllvm-path=<path>`.
pub const LlvmBackend = if (build_options.enable_llvm)
    @import("backend/llvm.zig").LlvmBackend
else
    LlvmBackendStub;

pub const comptime_mod    = @import("comptime.zig");
pub const compileWithLlvm = driver_mod.compileWithLlvm;
pub const compileFileWithLlvm = driver_mod.compileFileWithLlvm;
pub const LlvmCompileOptions = driver_mod.LlvmCompileOptions;

const LlvmBackendStub = struct {
    pub const Error = error{LlvmNotEnabled};
    pub fn init(_: std.mem.Allocator, _: [*:0]const u8) LlvmBackendStub {
        return .{};
    }
    pub fn deinit(_: *LlvmBackendStub) void {}
    pub fn setOptLevel(_: *LlvmBackendStub, _: u2) void {}
    pub fn lower(_: *LlvmBackendStub, _: ir.IrModule) Error!void {
        return error.LlvmNotEnabled;
    }
    pub fn emitIr(_: *LlvmBackendStub, _: std.mem.Allocator) Error![]u8 {
        return error.LlvmNotEnabled;
    }
};

test {
    refAllDeclsRecursive(@This());
}

fn refAllDeclsRecursive(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return,
    }

    inline for (comptime std.meta.declarations(T)) |decl| {
        _ = &@field(T, decl.name);

        const value = @field(T, decl.name);
        if (@TypeOf(value) == type) {
            switch (@typeInfo(value)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(value),
                else => {},
            }
        }
    }
}
