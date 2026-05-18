/// LLVM codegen backend. Usage: init a LlvmBackend, lower(ir_module), then
/// emitObject(...) or linkWindows(...). The Windows entry point (mainCRTStartup) is
/// generated automatically when the module has an entry fn (main or #entry) — it
/// calls Fels main, then ExitProcess.
const std = @import("std");
const ir = @import("../ir.zig");
const ctx_mod = @import("llvm/context.zig");
const structs = @import("llvm/structs.zig");
const globals = @import("llvm/globals.zig");
const fns = @import("llvm/functions.zig");
const emit = @import("llvm/emit.zig");
const link = @import("llvm/link.zig");
const vars_mod = @import("llvm/variants.zig");
const vtables = @import("llvm/vtables.zig");
const values = @import("llvm/values.zig");
const llvm_c = @import("llvm/c_api.zig").llvm;

pub const LlvmBackend = struct {
    cg: ctx_mod.ModuleCg,

    pub fn init(allocator: std.mem.Allocator, module_name: [*:0]const u8) LlvmBackend {
        return .{ .cg = ctx_mod.ModuleCg.init(allocator, module_name) };
    }

    pub fn deinit(self: *LlvmBackend) void {
        self.cg.deinit();
    }

    /// Configure the optimization level before lowering.
    pub fn setOptLevel(self: *LlvmBackend, opt_level: u2) void {
        self.cg.opt_level = opt_level;
    }

    /// Whether lowering inserts the runtime safety checks (see `ModuleCg.safety`).
    pub fn setSafety(self: *LlvmBackend, on: bool) void {
        self.cg.safety = on;
    }

    /// Set the target OS (cross-compilation). Must be called before `lower`.
    pub fn setTarget(self: *LlvmBackend, target_os: std.Target.Os.Tag) void {
        self.cg.target_os = target_os;
    }

    /// Lower a complete IrModule to LLVM IR in memory.
    pub fn lower(self: *LlvmBackend, module: ir.IrModule) !void {
        // Target-specific module-level stubs (Windows `__chkstk`; nothing on Linux).
        self.cg.applyTargetStubs();

        // Order-independent type registration via shells, satisfying two opposing
        // constraints at once:
        //  1. A struct's by-value enum field (`color: Color`, even a payloaded enum)
        //     needs the enum's TYPE before the struct is bodied — else it falls back
        //     to a pointer (wrong-typed/sized field, breaks `match s.field`).
        //  2. A payloaded enum's `[N x i8]` payload must be sized against fully
        //     bodied struct variants (e.g. `TypeInfo.struct_: TiStruct` = 32 B).
        // So: declare all enum types (payloaded = named opaque shell), body structs
        // (their enum fields reference the shell, resolved lazily), then fill the
        // enum shells' bodies now that payload sizes are known.
        try vars_mod.declareAll(&self.cg, module.variants);
        try structs.lowerAll(&self.cg, module.structs);
        try vars_mod.bodyAll(&self.cg, module.variants);
        // Functions are declared before globals so a static initializer can hold a function's
        // address; function bodies are defined last, once every global exists.
        try fns.declareAll(&self.cg, module.functions);
        try globals.lowerAll(&self.cg, module.globals);
        try vtables.lowerAll(&self.cg, module.vtables);
        try fns.defineAll(&self.cg, module.functions);

        if (self.cg.target_os == .windows) {
            // Windows float-support marker, needed for a standalone exe under
            // /NODEFAULTLIB. Skipped for a `--no-entry` library object: the host
            // binary's CRT already provides `_fltused` (avoids a duplicate symbol).
            if (!self.cg.no_entry) {
                const i32_ty = llvm_c.LLVMInt32TypeInContext(self.cg.ctx);
                const fltused = llvm_c.LLVMAddGlobal(self.cg.mod, i32_ty, "_fltused");
                llvm_c.LLVMSetInitializer(fltused, llvm_c.LLVMConstInt(i32_ty, 1, 0));
                llvm_c.LLVMSetLinkage(fltused, llvm_c.LLVMExternalLinkage);
            }

            // The felsld import map (a `.skimp` section). Lets the self-hosted
            // linker resolve each import's DLL without parsing any `.lib`.
            try emitImportMap(&self.cg, module);
            // The export map (`.skexp`) — `#export`ed symbol names, so felsld can
            // build a DLL's export table (.edata) without /EXPORT: directives.
            try emitExportMap(&self.cg, module);
        }

        // Auto-generate the platform entry point. Windows: a `mainCRTStartup` that
        // calls `main` + `ExitProcess`. Linux: the runtime's `#naked _start` calls
        // `__fels_main`, which calls `main` and returns the status to exit with.
        if (self.cg.target_os == .windows and !self.cg.no_entry) {
            for (module.functions) |f| {
                if (f.entry) {
                    try emitWindowsEntryPoint(&self.cg, f);
                    break;
                }
            }
        }
        if (self.cg.target_os == .linux and !self.cg.no_entry) {
            for (module.functions) |f| {
                if (f.entry and !std.mem.eql(u8, f.name, "_start")) {
                    try emitLinuxMain(&self.cg, f);
                    break;
                }
            }
        }

        // If any instruction lowering detected an internal shape/invariant
        // mismatch (recorded via `cg.recordLoweringError`), fail the build
        // cleanly here rather than handing a malformed module to LLVM's
        // verifier/codegen — those paths assert/crash on bad input instead
        // of returning errors.
        if (self.cg.lowering_failed) return error.LoweringFailed;

        if (self.cg.library_object) {
            internalizeForLibrary(&self.cg);
            try emitDefaultLibs(&self.cg, module);
        }

        try emit.verify(&self.cg);
    }

    /// Emit a native object file.
    /// `opt_level`: 0=none 1=less 2=default 3=aggressive.
    pub fn emitObject(self: *LlvmBackend, path: [*:0]const u8, opt_level: u2) !void {
        self.setOptLevel(opt_level);
        const tm = try emit.TargetMachine.initNative(opt_level);
        defer tm.deinit();
        tm.applyToModule(&self.cg);
        emit.dropDeadFunctions(&self.cg);
        try emit.verify(&self.cg);
        self.cg.applyMemoryStubs();
        try emit.optimize(&self.cg, tm, opt_level);
        try emit.emitObject(&self.cg, tm, path);
    }

    /// Emit the object into an in-memory byte buffer (caller frees).
    pub fn emitObjectToMemory(self: *LlvmBackend, allocator: std.mem.Allocator, opt_level: u2) ![]u8 {
        self.setOptLevel(opt_level);
        const tm = try emit.TargetMachine.initTarget(self.cg.target_os, opt_level);
        defer tm.deinit();
        tm.applyToModule(&self.cg);
        emit.dropDeadFunctions(&self.cg);
        try emit.verify(&self.cg);
        self.cg.applyMemoryStubs();
        try emit.optimize(&self.cg, tm, opt_level);
        return emit.emitObjectToMemory(&self.cg, tm, allocator);
    }

    /// Link object files into a Windows executable via lld-link.
    pub fn linkWindows(self: *LlvmBackend, allocator: std.mem.Allocator, io: std.Io, opts: link.WindowsLinkOptions) !void {
        _ = self;
        return link.windows(allocator, io, opts);
    }

    /// Link an in-memory ELF object into a static Linux executable via ld.lld.
    pub fn linkLinuxMem(self: *LlvmBackend, allocator: std.mem.Allocator, io: std.Io, obj_path: []const u8, obj_bytes: []const u8, opts: link.LinuxLinkOptions) !void {
        _ = self;
        return link.linkLinux(allocator, io, obj_path, obj_bytes, opts);
    }

    /// Link straight from in-memory object bytes (no .obj on disk) — felsld fast
    /// path; spills to disk only for the LLD fallback.
    pub fn linkWindowsMem(self: *LlvmBackend, allocator: std.mem.Allocator, io: std.Io, obj_bytes: []const u8, opts: link.WindowsLinkOptions) !void {
        _ = self;
        return link.windowsMem(allocator, io, obj_bytes, opts);
    }

    /// Dump the LLVM IR to stderr (debugging).
    pub fn dumpIr(self: *LlvmBackend) void {
        emit.dumpIr(&self.cg);
    }

    /// Return the LLVM IR as text (debugging/testing).
    pub fn getIrText(self: *LlvmBackend, allocator: std.mem.Allocator) ![]u8 {
        return emit.getIrText(&self.cg, allocator);
    }
};

/// Convenience wrapper — link step exposed at module level.
pub const linkWindows = link.windows;

// Windows entry point generator
//
// When the Fels module has an `entry` function, automatically emit:
//
//   void mainCRTStartup() {
//       ExitProcess((u32)main());
//   }
//
// This replaces felsrt — no separate object file to compile or distribute.

/// Emit the felsld import map as a `.skimp` COFF section: a flat list of
/// `symbol\0dll\0` records, one per `#extern("dll","symbol")` import. The
/// self-hosted linker reads this to know each undefined symbol's DLL directly —
/// no `.lib` archive parsing (LLD's biggest cost). LLD ignores the section.
fn emitImportMap(cg: *ctx_mod.ModuleCg, module: ir.IrModule) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(cg.allocator);
    for (module.functions) |f| {
        const sym = f.extern_name orelse continue;
        const lib = f.extern_lib orelse continue;
        if (sym.len == 0 or lib.len == 0) continue;
        try buf.appendSlice(cg.allocator, sym);
        try buf.append(cg.allocator, 0);
        try buf.appendSlice(cg.allocator, lib);
        try buf.append(cg.allocator, 0);
    }
    if (buf.items.len == 0) return; // no DLL imports — nothing for felsld to map

    const i8_ty = llvm_c.LLVMInt8TypeInContext(cg.ctx);
    const arr_ty = llvm_c.LLVMArrayType(i8_ty, @intCast(buf.items.len));
    const init = llvm_c.LLVMConstStringInContext(cg.ctx, buf.items.ptr, @intCast(buf.items.len), 1);
    const g = llvm_c.LLVMAddGlobal(cg.mod, arr_ty, "__fels_import_map");
    llvm_c.LLVMSetInitializer(g, init);
    llvm_c.LLVMSetLinkage(g, llvm_c.LLVMExternalLinkage);
    llvm_c.LLVMSetGlobalConstant(g, 1);
    llvm_c.LLVMSetSection(g, ".skimp");
}

/// Emit the felsld export map as a `.skexp` section: a flat list of `name\0`
/// records, one per `#export`ed function or global. felsld reads it to build a DLL's export
/// directory (.edata) — no `/EXPORT:` linker directives, no .drectve parsing.
fn emitExportMap(cg: *ctx_mod.ModuleCg, module: ir.IrModule) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(cg.allocator);
    for (module.functions) |f| {
        const sym = f.export_sym orelse continue;
        try appendExportName(cg, &buf, sym, f.name);
    }
    for (module.globals) |g| {
        const sym = g.export_sym orelse continue;
        try appendExportName(cg, &buf, sym, g.name);
    }
    if (buf.items.len == 0) return; // nothing exported

    const i8_ty = llvm_c.LLVMInt8TypeInContext(cg.ctx);
    const arr_ty = llvm_c.LLVMArrayType(i8_ty, @intCast(buf.items.len));
    const init = llvm_c.LLVMConstStringInContext(cg.ctx, buf.items.ptr, @intCast(buf.items.len), 1);
    const g = llvm_c.LLVMAddGlobal(cg.mod, arr_ty, "__fels_export_map");
    llvm_c.LLVMSetInitializer(g, init);
    llvm_c.LLVMSetLinkage(g, llvm_c.LLVMExternalLinkage);
    llvm_c.LLVMSetGlobalConstant(g, 1);
    llvm_c.LLVMSetSection(g, ".skexp");
}

/// One export-map record: the name the symbol is exported under — the explicit
/// `#export("name")`, or (bare `#export`) the symbol's own link name.
fn appendExportName(cg: *ctx_mod.ModuleCg, buf: *std.ArrayList(u8), explicit: []const u8, own: []const u8) !void {
    const name = if (explicit.len > 0) explicit else own;
    try buf.appendSlice(cg.allocator, name);
    try buf.append(cg.allocator, 0);
}

/// For a static library's object: every definition except the `#export`ed ones becomes
/// internal, and the exported ones lose `dllexport` (a program that links the library should
/// not export them from its own image).
fn internalizeForLibrary(cg: *ctx_mod.ModuleCg) void {
    var f = llvm_c.LLVMGetFirstFunction(cg.mod);
    while (f) |fv| : (f = llvm_c.LLVMGetNextFunction(fv)) {
        if (llvm_c.LLVMIsDeclaration(fv) == 0) internalizeOne(fv);
    }
    var g = llvm_c.LLVMGetFirstGlobal(cg.mod);
    while (g) |gv| : (g = llvm_c.LLVMGetNextGlobal(gv)) {
        if (llvm_c.LLVMIsDeclaration(gv) == 0) internalizeOne(gv);
    }
}

/// For a static library's object: a `/DEFAULTLIB:<lib>.lib` linker directive for each library
/// its `#extern` functions come from, so the program that links the static library also links
/// what the library needs (the way an MSVC static library carries its dependencies).
fn emitDefaultLibs(cg: *ctx_mod.ModuleCg, module: ir.IrModule) !void {
    var seen: std.StringHashMap(void) = .init(cg.allocator);
    defer seen.deinit();
    for (module.functions) |f| {
        const lib = f.extern_lib orelse continue;
        if (lib.len == 0 or (try seen.getOrPut(lib)).found_existing) continue;
        const opt = try std.fmt.allocPrint(cg.allocator, "/DEFAULTLIB:{s}.lib", .{link.importLibraryFor(lib)});
        defer cg.allocator.free(opt);
        var str = llvm_c.LLVMMDStringInContext2(cg.ctx, opt.ptr, opt.len);
        const node = llvm_c.LLVMMDNodeInContext2(cg.ctx, &str, 1);
        llvm_c.LLVMAddNamedMetadataOperand(cg.mod, "llvm.linker.options", llvm_c.LLVMMetadataAsValue(cg.ctx, node));
    }
}

fn internalizeOne(v: llvm_c.LLVMValueRef) void {
    if (llvm_c.LLVMGetDLLStorageClass(v) == llvm_c.LLVMDLLExportStorageClass) {
        llvm_c.LLVMSetDLLStorageClass(v, llvm_c.LLVMDefaultStorageClass);
    } else {
        llvm_c.LLVMSetLinkage(v, llvm_c.LLVMInternalLinkage);
    }
}

fn emitWindowsEntryPoint(cg: *ctx_mod.ModuleCg, main: ir.IrFunction) !void {
    // Declare ExitProcess(u32) if not already present.
    const ep_sym = "ExitProcess";
    if (!cg.fn_decls.contains(ep_sym)) {
        const u32_ty = llvm_c.LLVMInt32TypeInContext(cg.ctx);
        const void_ty = llvm_c.LLVMVoidTypeInContext(cg.ctx);
        const ep_ty = llvm_c.LLVMFunctionType(void_ty, @constCast(&[_]llvm_c.LLVMTypeRef{u32_ty}), 1, 0);
        const ep = llvm_c.LLVMAddFunction(cg.mod, ep_sym, ep_ty);
        llvm_c.LLVMSetLinkage(ep, llvm_c.LLVMExternalLinkage);
        try cg.fn_decls.put(ep_sym, ep);
    }

    // Emit mainCRTStartup.
    const void_ty = llvm_c.LLVMVoidTypeInContext(cg.ctx);
    const crt_ty = llvm_c.LLVMFunctionType(void_ty, null, 0, 0);
    const crt_fn = llvm_c.LLVMAddFunction(cg.mod, "mainCRTStartup", crt_ty);
    const bb = llvm_c.LLVMAppendBasicBlockInContext(cg.ctx, crt_fn, "entry");
    llvm_c.LLVMPositionBuilderAtEnd(cg.builder, bb);

    // Call Fels main.
    const main_fn = cg.fn_decls.get(main.name) orelse return;
    const main_ret = callMain(cg, main_fn);

    const exit_code = exitStatus(cg, main, main_ret);

    // Call ExitProcess.
    const ep_fn = cg.fn_decls.get(ep_sym).?;
    const ep_fn_ty = llvm_c.LLVMGlobalGetValueType(ep_fn);
    var ep_args = [_]llvm_c.LLVMValueRef{exit_code};
    _ = llvm_c.LLVMBuildCall2(cg.builder, ep_fn_ty, ep_fn, &ep_args, 1, "");
    _ = llvm_c.LLVMBuildUnreachable(cg.builder);
}

/// `__fels_main() -> i32` for Linux: the runtime's `_start` calls it (or glibc's
/// `__libc_start_main` does) and exits with what it returns, the status `main` ends with.
fn emitLinuxMain(cg: *ctx_mod.ModuleCg, main: ir.IrFunction) !void {
    const i32_ty = llvm_c.LLVMInt32TypeInContext(cg.ctx);
    const wrapper_ty = llvm_c.LLVMFunctionType(i32_ty, null, 0, 0);
    const wrapper = llvm_c.LLVMAddFunction(cg.mod, "__fels_main", wrapper_ty);
    const bb = llvm_c.LLVMAppendBasicBlockInContext(cg.ctx, wrapper, "entry");
    llvm_c.LLVMPositionBuilderAtEnd(cg.builder, bb);
    const main_fn = cg.fn_decls.get(main.name) orelse return;
    const main_ret = callMain(cg, main_fn);
    _ = llvm_c.LLVMBuildRet(cg.builder, exitStatus(cg, main, main_ret));
}

/// A call of `main`. A `void` one has no result to name: LLVM refuses the module when it has
/// one (`%ret = call void @main()`), which was a `main :: fn() { … }` on Windows.
fn callMain(cg: *ctx_mod.ModuleCg, main_fn: llvm_c.LLVMValueRef) llvm_c.LLVMValueRef {
    const fn_ty = llvm_c.LLVMGlobalGetValueType(main_fn);
    const void_result = llvm_c.LLVMGetTypeKind(llvm_c.LLVMGetReturnType(fn_ty)) == llvm_c.LLVMVoidTypeKind;
    return llvm_c.LLVMBuildCall2(cg.builder, fn_ty, main_fn, null, 0, if (void_result) "" else "ret");
}

/// The status a program exits with when `main` returned `main_ret`: its `i32`, 0 for a
/// `void` main, and for a main that can fail, the error's code when it failed.
fn exitStatus(cg: *ctx_mod.ModuleCg, main: ir.IrFunction, main_ret: llvm_c.LLVMValueRef) llvm_c.LLVMValueRef {
    // Coerce i32 → u32 (bitcast — same bits, different signedness).
    const u32_ty = llvm_c.LLVMInt32TypeInContext(cg.ctx);
    return if (main.error_ty != null) blk: {
        const err = llvm_c.LLVMBuildExtractValue(cg.builder, main_ret, 1, "main_err");
        const ok = if (main.return_ty == .void)
            llvm_c.LLVMConstInt(u32_ty, 0, 0)
        else
            values.coerce(cg.builder, cg.ctx, llvm_c.LLVMBuildExtractValue(cg.builder, main_ret, 0, "main_ok"), u32_ty);
        const err_code = values.coerce(cg.builder, cg.ctx, err, u32_ty);
        const is_err = llvm_c.LLVMBuildICmp(
            cg.builder,
            llvm_c.LLVMIntNE,
            err_code,
            llvm_c.LLVMConstInt(u32_ty, 0, 0),
            "main_failed",
        );
        break :blk llvm_c.LLVMBuildSelect(cg.builder, is_err, err_code, ok, "exit_code");
    } else if (main.return_ty == .void)
        llvm_c.LLVMConstInt(u32_ty, 0, 0)
    else
        values.coerce(cg.builder, cg.ctx, main_ret, u32_ty);
}
