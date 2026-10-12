//! Debug info (`-g`): each function's name and place, and the line of every instruction, so a
//! debugger shows the source, steps through statements and prints stack traces. CodeView on
//! Windows (the linker writes a PDB), DWARF elsewhere, through LLVM's DIBuilder.

const std = @import("std");
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const build_options = @import("build_options");

pub const DebugCg = struct {
    allocator: std.mem.Allocator,
    di: llvm.LLVMDIBuilderRef,
    cu: llvm.LLVMMetadataRef = null,
    /// Relative source paths are made absolute against this folder, so a debugger finds the
    /// file from anywhere.
    cwd: []const u8,
    /// A DIFile per source path.
    files: std.StringHashMap(llvm.LLVMMetadataRef),
    optimized: bool,
    /// The subprogram of the function being defined; null while there is none.
    scope: llvm.LLVMMetadataRef = null,
    /// The line and column set last, so a run of instructions of one statement shares it.
    line: u32 = 0,
    column: u32 = 0,
    finished: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: llvm.LLVMContextRef,
        mod: llvm.LLVMModuleRef,
        root_file: []const u8,
        cwd: []const u8,
        optimized: bool,
        codeview: bool,
    ) DebugCg {
        var self: DebugCg = .{
            .allocator = allocator,
            .di = llvm.LLVMCreateDIBuilder(mod),
            .cwd = cwd,
            .files = std.StringHashMap(llvm.LLVMMetadataRef).init(allocator),
            .optimized = optimized,
        };
        const producer = "fels " ++ build_options.version;
        // There is no DWARF language code for Fels; C is what debuggers handle best.
        self.cu = llvm.LLVMDIBuilderCreateCompileUnit(
            self.di,
            llvm.LLVMDWARFSourceLanguageC99,
            self.file(root_file),
            producer.ptr,
            producer.len,
            @intFromBool(optimized),
            "",
            0,
            0,
            "",
            0,
            llvm.LLVMDWARFEmissionFull,
            0,
            0,
            0,
            "",
            0,
            "",
            0,
        );
        const i32_ty = llvm.LLVMInt32TypeInContext(ctx);
        addFlag(mod, i32_ty, "Debug Info Version", llvm.LLVMDebugMetadataVersion());
        if (codeview) addFlag(mod, i32_ty, "CodeView", 1) else addFlag(mod, i32_ty, "Dwarf Version", 4);
        return self;
    }

    /// The DIFile of `path`.
    fn file(self: *DebugCg, path: []const u8) llvm.LLVMMetadataRef {
        if (self.files.get(path)) |f| return f;
        // LLVM keeps its own copy of the name and the folder.
        const resolved = std.fs.path.resolve(self.allocator, &.{ self.cwd, path }) catch null;
        defer if (resolved) |r| self.allocator.free(r);
        const full = resolved orelse path;
        const name = std.fs.path.basename(full);
        const dir = std.fs.path.dirname(full) orelse "";
        const f = llvm.LLVMDIBuilderCreateFile(self.di, name.ptr, name.len, dir.ptr, dir.len);
        self.files.put(path, f) catch {};
        return f;
    }

    /// Start defining `func` as `llvm_fn`: give it a subprogram, and put what is built first (its
    /// stack slots) on the line of its declaration. A function the compiler made, or one of the
    /// embedded runtime (`<runtime>`), has no source and gets none.
    pub fn begin(self: *DebugCg, builder: llvm.LLVMBuilderRef, ctx: llvm.LLVMContextRef, func: ir.IrFunction, llvm_fn: llvm.LLVMValueRef) void {
        self.scope = null;
        self.line = 0;
        self.column = 0;
        llvm.LLVMSetCurrentDebugLocation2(builder, null);
        if (func.line == 0 or func.file.len == 0 or func.file[0] == '<') return;

        const f = self.file(func.file);
        const ty = llvm.LLVMDIBuilderCreateSubroutineType(self.di, f, null, 0, llvm.LLVMDIFlagZero);
        // `src_main_fels$run` is `run` in the source.
        const name = if (std.mem.lastIndexOfScalar(u8, func.name, '$')) |i| func.name[i + 1 ..] else func.name;
        var link_len: usize = 0;
        const link = llvm.LLVMGetValueName2(llvm_fn, &link_len);
        const local = llvm.LLVMGetLinkage(llvm_fn) == llvm.LLVMInternalLinkage;
        const sp = llvm.LLVMDIBuilderCreateFunction(
            self.di,
            f,
            name.ptr,
            name.len,
            link,
            link_len,
            f,
            func.line,
            ty,
            @intFromBool(local),
            1,
            func.line,
            llvm.LLVMDIFlagPrototyped,
            @intFromBool(self.optimized),
        );
        llvm.LLVMSetSubprogram(llvm_fn, sp);
        self.scope = sp;
        self.at(builder, ctx, func.line, 1);
    }

    /// Put what is built next at `line`:`column` of the function being defined. 0 keeps the
    /// place set last.
    pub fn at(self: *DebugCg, builder: llvm.LLVMBuilderRef, ctx: llvm.LLVMContextRef, line: u32, column: u32) void {
        const sp = self.scope orelse return;
        if (line == 0 or (line == self.line and column == self.column)) return;
        self.line = line;
        self.column = column;
        llvm.LLVMSetCurrentDebugLocation2(builder, llvm.LLVMDIBuilderCreateDebugLocation(ctx, line, column, sp, null));
    }

    /// The function is defined: what is built next belongs to no source line.
    pub fn end(self: *DebugCg, builder: llvm.LLVMBuilderRef) void {
        self.scope = null;
        llvm.LLVMSetCurrentDebugLocation2(builder, null);
    }

    /// Resolve the debug info into the module; it is complete after this.
    pub fn finish(self: *DebugCg) void {
        if (self.finished) return;
        self.finished = true;
        llvm.LLVMDIBuilderFinalize(self.di);
    }

    pub fn deinit(self: *DebugCg) void {
        self.finish();
        llvm.LLVMDisposeDIBuilder(self.di);
        self.files.deinit();
    }
};

fn addFlag(mod: llvm.LLVMModuleRef, i32_ty: llvm.LLVMTypeRef, key: []const u8, value: c_uint) void {
    const v = llvm.LLVMValueAsMetadata(llvm.LLVMConstInt(i32_ty, value, 0));
    llvm.LLVMAddModuleFlag(mod, llvm.LLVMModuleFlagBehaviorWarning, key.ptr, key.len, v);
}
