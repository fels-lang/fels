//! Navigation across a project for `gabbro lsp`: find references, rename, document
//! highlight and workspace symbols.
//!
//! The project is the folder with `build.fels` above the document (else the workspace
//! folder, else the document's own folder), and every `.fels` file under it, except the
//! standard library and the build output folders (`zig-out`, `.zig-cache`, `.git`,
//! `.claude`, `dist`, `out`). At most `max_files` files are taken; the server says so
//! with a `window/showMessage` when a project has more.
//!
//! Each project file gets a reference index (`FileIndex`): every name in the file that
//! declares or uses something, together with the thing it means (its `Target`). A target
//! is known by the file that declares it and the byte offset of its name there, so every
//! analysis that loads the declaring file agrees on it, and a search across files is a
//! comparison of targets. An index is built by walking the AST of a tolerant analysis
//! (`pipeline.analyzeFile`) that loaded the file:
//!
//! * where sema resolved a name, its answer is used: `expr_symbols`, `extension_calls`,
//!   `impl_method_calls`, `enum_lits`, the `expr_types` of the base of a field access and
//!   the `literal_types` of a `.{ }` literal;
//! * locals, parameters and type parameters, which sema keeps only as names on a scope
//!   stack, are tracked here with the scope rules of the checker, so two `x` in two blocks
//!   stay apart;
//! * names in code the tolerant check does not reach (generic functions, field defaults,
//!   a function after its first error) are looked up the same way sema looks them up
//!   (`resolveVisible`, `resolveScoped`, the declared types of locals, parameters, fields
//!   and return values).
//!
//! Indexes are cached per file. One stays valid while the text of its file and of every
//! file that file imports is the same (compared by a hash of the text), so an edit or a
//! save makes only the affected entries stale. One analysis indexes every stale file it
//! loaded, and the files that import others are analyzed first, so a project whose
//! `main.fels` imports everything costs one analysis. A local, a parameter or a declaration
//! without `pub` can only be named in its own file, so only that file is searched for it.
//! For anything else `references` indexes the files that contain the name as a word, and
//! `rename` also those that contain the new name or import a module with `.*`.

const std = @import("std");
const lsp = @import("lsp.zig");
const sema = @import("sema.zig");
const ast = @import("ast.zig");
const pipeline = @import("pipeline.zig");
const parser = @import("parser.zig");
const lexer = @import("lexer/tokens.zig");
const clock = @import("clock.zig");
const build_options = @import("build_options");
const Span = @import("lexer/span.zig").Span;

const json = std.json;
const Allocator = std.mem.Allocator;
const SymbolId = sema.SymbolId;

/// The most `.fels` files a project contributes.
pub const max_files: usize = 400;
/// The most directory entries one project scan looks at.
const max_entries: usize = 50_000;
/// The most results of `workspace/symbol`.
const max_symbols: usize = 1000;

// Index data

pub const Role = enum(u8) {
    /// The declaration itself.
    decl,
    read,
    /// Assigned: `x = …`, `p.x = …`, or a field set in a `.{ .x = … }` literal.
    write,
    /// The method of an interface, implemented by a type (`Good as Show { val :: … }`).
    impl,
};

pub const Kind = enum(u8) {
    function,
    method,
    type,
    constant,
    global,
    field,
    variant,
    interface_method,
    local,
    param,
    type_param,
    other,

    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .function => "function",
            .method => "method",
            .type => "type",
            .constant => "constant",
            .global => "global variable",
            .field => "field",
            .variant => "variant",
            .interface_method => "interface method",
            .local => "local",
            .param => "parameter",
            .type_param => "type parameter",
            .other => "name",
        };
    }

    pub fn isLocal(k: Kind) bool {
        return k == .local or k == .param or k == .type_param;
    }

    pub fn isMember(k: Kind) bool {
        return switch (k) {
            .field, .variant, .interface_method, .method => true,
            else => false,
        };
    }
};

/// Why a target is not renamed.
pub const Fixed = enum(u8) { no, std_lib, runtime, external, exported, entry };

pub const no_owner: u32 = std.math.maxInt(u32);

/// What a name means: the declaration it refers to.
pub const Target = struct {
    /// Path key (`lsp.pathKey`) of the declaring file; `<runtime>` for the runtime.
    file: []const u8,
    /// Byte offset of the declared name in that file.
    offset: u32,
    /// The name as written (`push`, not the hoisted `Vec.push`).
    name: []const u8,
    kind: Kind,
    fixed: Fixed = .no,
    /// Can be named outside its file: a `pub` declaration, a member of a type (a field is
    /// reached through any value of its type), anything of the runtime. A local or a
    /// private declaration is only referred to in its own file.
    public: bool = false,
    /// Members (fields, variants, methods): offset of the name of their type.
    owner: u32 = no_owner,
    /// Locals: the bytes where the name is in scope, from the declaration to the end
    /// of the enclosing block.
    scope_start: u32 = 0,
    scope_end: u32 = 0,

    pub fn same(a: Target, b: Target) bool {
        return a.offset == b.offset and std.mem.eql(u8, a.file, b.file);
    }
};

/// One name in a file.
pub const Occ = struct {
    start: u32,
    end: u32,
    /// Index into `FileIndex.targets`.
    target: u32,
    role: Role,
    /// Written as `alias::name` or `Type::name`: looked up in a module or type, not in
    /// the scope of the site.
    qualified: bool = false,
};

/// A file whose text an index depends on (one that the indexed file imports).
pub const Dep = struct { key: []const u8, path: []const u8, hash: u64 };

pub const FileIndex = struct {
    arena: std.heap.ArenaAllocator,
    key: []const u8,
    path: []const u8,
    /// Hash of the text the index was built from.
    hash: u64,
    deps: []const Dep = &.{},
    targets: []const Target = &.{},
    /// Sorted by `start`.
    occs: []const Occ = &.{},
    /// Top level names visible in the file: its own declarations, the names its imports
    /// bring in, its namespace aliases.
    visible: []const []const u8 = &.{},
    /// Keys of the modules this file imports with `.*`.
    glob_from: []const []const u8 = &.{},

    pub fn destroy(self: *FileIndex, gpa: Allocator) void {
        var arena = self.arena;
        gpa.destroy(self);
        arena.deinit();
    }

    /// The name whose bytes cover `off`; a cursor right after a name also counts.
    pub fn occAt(self: *const FileIndex, off: usize) ?Occ {
        var after: ?Occ = null;
        for (self.occs) |o| {
            if (off >= o.start and off < o.end) return o;
            if (off == o.end and after == null) after = o;
        }
        return after;
    }

    pub fn isVisible(self: *const FileIndex, name: []const u8) bool {
        for (self.visible) |v| if (std.mem.eql(u8, v, name)) return true;
        return false;
    }

    pub fn globs(self: *const FileIndex, key: []const u8) bool {
        for (self.glob_from) |g| if (std.mem.eql(u8, g, key)) return true;
        return false;
    }
};

// Text helpers

fn isIdent(c: u8) bool {
    return lsp.isIdentChar(c);
}

/// Whether `name` is written at byte `pos` of `src` as a whole word.
fn wordAt(src: []const u8, pos: usize, name: []const u8) bool {
    if (name.len == 0 or pos + name.len > src.len) return false;
    if (!std.mem.eql(u8, src[pos .. pos + name.len], name)) return false;
    if (pos > 0 and isIdent(src[pos - 1])) return false;
    if (pos + name.len < src.len and isIdent(src[pos + name.len])) return false;
    return true;
}

/// Whether `text` has `name` as a whole word anywhere (comments too: a cheap filter).
pub fn containsWord(text: []const u8, name: []const u8) bool {
    if (name.len == 0) return false;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, name)) |i| {
        if (wordAt(text, i, name)) return true;
        from = i + 1;
    }
    return false;
}

/// The first token spelled `name` that lies in `src[from..to]`. Read with the compiler's
/// lexer, so comments and string literals are skipped.
fn findWord(src: []const u8, from: usize, to: usize, name: []const u8) ?usize {
    if (from >= to or from >= src.len) return null;
    var lx = lexer.Lexer.init(src);
    lx.index = from;
    while (true) {
        const tok = lx.next();
        if (tok.kind == .eof or tok.start >= to or tok.start + tok.len > to) return null;
        if (std.mem.eql(u8, tok.text(src), name)) return tok.start;
    }
}

/// The byte offset of `name` inside a declaration's span.
fn nameStart(src: []const u8, span: Span, name: []const u8) usize {
    return lsp.nameSpan(src, span, name).start;
}

/// `Vec.push` -> `push`.
fn shortName(name: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[i + 1 ..];
}

fn isLambda(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "__lambda_");
}

pub fn textHash(text: []const u8) u64 {
    return std.hash.Wyhash.hash(0, text);
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

fn hasAttr(attrs: []const ast.Attribute, name: []const u8) bool {
    for (attrs) |a| if (std.mem.eql(u8, a.name, name)) return true;
    return false;
}

fn isExtern(attrs: []const ast.Attribute) bool {
    return hasAttr(attrs, "extern") or hasAttr(attrs, "foreign");
}

/// Whether a function's name means something outside the program's text: an `#extern`
/// binds a C symbol, a plain `#export` exports its own name, `main` and the `build` of
/// `build.fels` are looked up by name.
fn fixedFunction(f: ast.FunctionDecl, file: []const u8) Fixed {
    if (isExtern(f.attrs)) return .external;
    for (f.attrs) |a| {
        if (std.mem.eql(u8, a.name, "export") and a.args.len == 0) return .exported;
    }
    if (std.mem.eql(u8, f.name, "main")) return .entry;
    if (std.mem.eql(u8, f.name, "build") and std.mem.eql(u8, pipeline.withoutExt(std.fs.path.basename(file)), "build")) return .entry;
    return .no;
}

/// Call names the checker handles itself before it looks at the declarations.
fn isBuiltinCall(name: []const u8) bool {
    if (sema.isBuiltinValue(name)) return true;
    if (std.mem.startsWith(u8, name, "__build_") or (name.len > 0 and name[0] == '@')) return true;
    const more = [_][]const u8{ "require", "typeid_of", "__str_cat", "compiler_error", "compiler_remove", "type_name", "reject", "any", "type_info", "compiler_decls" };
    return contains(&more, name);
}

fn firstParamIsSelf(f: ast.FunctionDecl) bool {
    for (f.params) |p| {
        if (p.is_type_param) continue;
        return std.mem.eql(u8, p.name, "self");
    }
    return false;
}

/// The byte offset of a parameter's name. A plain parameter's span is that of its type,
/// so the name is the identifier before the `:`.
fn paramNamePos(src: []const u8, p: ast.Param) ?usize {
    if (wordAt(src, p.span.start, p.name)) return p.span.start;
    var i: usize = @min(p.span.start, src.len);
    while (i > 0 and (src[i - 1] == ' ' or src[i - 1] == '\t' or src[i - 1] == '\r' or src[i - 1] == '\n')) i -= 1;
    if (i == 0 or src[i - 1] != ':') return null;
    i -= 1;
    while (i > 0 and (src[i - 1] == ' ' or src[i - 1] == '\t')) i -= 1;
    const end = i;
    while (i > 0 and isIdent(src[i - 1])) i -= 1;
    if (end - i != p.name.len or !wordAt(src, i, p.name)) return null;
    return i;
}

// Building the index of a file

const TKey = struct { file: []const u8, offset: u32 };

const TKeyCtx = struct {
    pub fn hash(_: TKeyCtx, k: TKey) u64 {
        var h = std.hash.Wyhash.init(k.offset);
        h.update(k.file);
        return h.final();
    }
    pub fn eql(_: TKeyCtx, a: TKey, b: TKey) bool {
        return a.offset == b.offset and std.mem.eql(u8, a.file, b.file);
    }
};

/// The index of one file while it is built; its arena becomes the index's.
const Builder = struct {
    arena: std.heap.ArenaAllocator,
    /// The file as the analysis names it.
    file: []const u8,
    key: []const u8,
    source: []const u8,
    targets: std.ArrayList(Target) = .empty,
    ids: std.HashMapUnmanaged(TKey, u32, TKeyCtx, 80) = .empty,
    occs: std.ArrayList(Occ) = .empty,
    globs: std.ArrayList([]const u8) = .empty,
    sym_ids: std.AutoHashMapUnmanaged(SymbolId, u32) = .empty,
    failed: bool = false,

    fn alloc(b: *Builder) Allocator {
        return b.arena.allocator();
    }

    fn addTarget(b: *Builder, t: Target) ?u32 {
        const a = b.alloc();
        const gop = b.ids.getOrPut(a, .{ .file = t.file, .offset = t.offset }) catch {
            b.failed = true;
            return null;
        };
        if (gop.found_existing) return gop.value_ptr.*;
        var copy = t;
        copy.file = a.dupe(u8, t.file) catch "";
        copy.name = a.dupe(u8, t.name) catch "";
        gop.key_ptr.* = .{ .file = copy.file, .offset = t.offset };
        const id: u32 = @intCast(b.targets.items.len);
        gop.value_ptr.* = id;
        b.targets.append(a, copy) catch {
            b.failed = true;
            return null;
        };
        return id;
    }

    /// Record `name` at `pos` as a reference to `target`, if the source really spells the
    /// name there: generated code (`#derive`, `Self` substitution) carries the spans of
    /// other tokens and is skipped by this check.
    fn addOcc(b: *Builder, pos: usize, name: []const u8, target: u32, role: Role, qualified: bool) void {
        if (!wordAt(b.source, pos, name)) return;
        b.occs.append(b.alloc(), .{
            .start = @intCast(pos),
            .end = @intCast(pos + name.len),
            .target = target,
            .role = role,
            .qualified = qualified,
        }) catch {
            b.failed = true;
        };
    }
};

const FileInfo = struct {
    /// The file as the analysis names it.
    name: []const u8,
    key: []const u8,
    source: []const u8,
    is_std: bool,
};

/// What the walk of one analysis shares.
const Ctx = struct {
    gpa: Allocator,
    scratch: Allocator,
    an: *const pipeline.Analysis,
    syms: sema.SymbolTable,
    env: *const sema.TypeEnv,
    files: std.StringHashMapUnmanaged(FileInfo) = .empty,
    /// The top level declaration of each top level symbol.
    decls: std.AutoHashMapUnmanaged(SymbolId, ast.Item) = .empty,
    impls: std.ArrayList(ast.InterfaceImpl) = .empty,
    builders: std.StringHashMapUnmanaged(*Builder) = .empty,
    lambdas_done: std.AutoHashMapUnmanaged(SymbolId, void) = .empty,

    /// A generic instance stands for its template, an alias for the type it names.
    fn concrete(cx: *Ctx, id0: SymbolId) SymbolId {
        var id = id0;
        var guard: u8 = 0;
        while (guard < 8) : (guard += 1) {
            if (cx.env.generic_struct_instance_args.get(id)) |app| {
                id = app.template;
                continue;
            }
            if (cx.env.alias_refs.get(id)) |tr| {
                const sym = cx.syms.symbol(id);
                if (cx.typeRefSym(sym.file_name, tr, &.{})) |next| if (next != id) {
                    id = next;
                    continue;
                };
            }
            break;
        }
        return id;
    }

    /// The type symbol a type reference names, looked up from `file` (through pointers
    /// and optionals); null for type parameters, `Self` and built-in types.
    fn typeRefSym(cx: *Ctx, file: []const u8, tr: ast.TypeRef, tparams: []const []const u8) ?SymbolId {
        const id: ?SymbolId = switch (tr) {
            .named => |n| blk: {
                if (n.namespace) |ns| break :blk cx.syms.resolveScoped(file, ns, n.name);
                if (contains(tparams, n.name) or std.mem.eql(u8, n.name, "Self")) break :blk null;
                break :blk cx.syms.resolveVisible(file, n.name);
            },
            .generic_inst => |g| blk: {
                if (g.namespace) |ns| break :blk cx.syms.resolveScoped(file, ns, g.name);
                break :blk cx.syms.resolveVisible(file, g.name);
            },
            .pointer, .many_pointer => |p| return cx.typeRefSym(file, p.inner.*, tparams),
            .optional => |o| return cx.typeRefSym(file, o.inner.*, tparams),
            .atomic => |x| return cx.typeRefSym(file, x.inner.*, tparams),
            .borrow => |x| return cx.typeRefSym(file, x.inner.*, tparams),
            else => null,
        };
        const sid = id orelse return null;
        return if (cx.syms.symbol(sid).kind == .type) sid else null;
    }

    /// The type behind a sema type, through one pointer and an optional.
    fn symOfTy(cx: *Ctx, ty: sema.Ty) ?SymbolId {
        return switch (ty) {
            .named => |id| cx.concrete(id),
            .pointer, .const_ptr, .optional, .borrow => |inner| switch (inner.*) {
                .named => |id| cx.concrete(id),
                .pointer, .const_ptr => |in2| if (in2.* == .named) cx.concrete(in2.named) else null,
                else => null,
            },
            else => null,
        };
    }

    fn typeDecl(cx: *Ctx, id: SymbolId) ?ast.TypeDecl {
        const item = cx.decls.get(cx.concrete(id)) orelse return null;
        return switch (item) {
            .type_decl => |d| d,
            else => null,
        };
    }

    fn fnDecl(cx: *Ctx, id: SymbolId) ?ast.FunctionDecl {
        const item = cx.decls.get(id) orelse return null;
        return switch (item) {
            .function => |f| f,
            else => null,
        };
    }

    fn symTarget(cx: *Ctx, b: *Builder, sid0: SymbolId) ?u32 {
        var sid = sid0;
        if (cx.env.generic_struct_instance_args.get(sid)) |app| sid = app.template;
        if (b.sym_ids.get(sid)) |t| return t;
        const sym = cx.syms.symbol(sid);
        const short = shortName(sym.name);
        const dotted = short.len != sym.name.len;
        var t: Target = .{
            .file = "<runtime>",
            .offset = @intCast(sym.span.start),
            .name = short,
            .kind = switch (sym.kind) {
                .function => if (dotted) Kind.method else Kind.function,
                .type => .type,
                .const_symbol => .constant,
                .global_var => .global,
                else => .other,
            },
            .fixed = .runtime,
            .public = true,
        };
        if (!std.mem.eql(u8, sym.file_name, "<runtime>")) {
            const fi = cx.files.get(sym.file_name) orelse return null;
            t.public = sym.is_public;
            t.file = fi.key;
            const at = nameStart(fi.source, sym.span, short);
            // A generated declaration (`#derive`) has the span of another name; it has no
            // place of its own to be known by.
            if (!wordAt(fi.source, at, short)) return null;
            t.offset = @intCast(at);
            t.fixed = if (fi.is_std) .std_lib else .no;
            if (cx.decls.get(sid)) |item| switch (item) {
                .function => |f| if (t.fixed == .no) {
                    t.fixed = fixedFunction(f, fi.name);
                },
                else => {},
            };
            if (dotted) {
                const type_name = sym.name[0 .. sym.name.len - short.len - 1];
                if (cx.syms.visible_names.get(sym.file_name)) |vis| if (vis.get(type_name)) |tid| {
                    t.owner = @intCast(nameStart(fi.source, cx.syms.symbol(tid).span, type_name));
                };
            }
        }
        const id = b.addTarget(t) orelse return null;
        b.sym_ids.put(b.alloc(), sid, id) catch {};
        return id;
    }

    /// A member of type `d` (a field, a variant, an interface method).
    fn memberAt(cx: *Ctx, b: *Builder, d: ast.TypeDecl, span: Span, name: []const u8, kind: Kind) ?u32 {
        var t: Target = .{ .file = "<runtime>", .offset = @intCast(span.start), .name = name, .kind = kind, .fixed = .runtime, .public = true };
        if (cx.files.get(d.file_name)) |fi| {
            const at = nameStart(fi.source, span, name);
            if (!wordAt(fi.source, at, name)) return null;
            t.file = fi.key;
            t.offset = @intCast(at);
            t.owner = @intCast(nameStart(fi.source, d.span, d.name));
            t.fixed = if (fi.is_std) .std_lib else .no;
        }
        return b.addTarget(t);
    }

    fn fieldTarget(cx: *Ctx, b: *Builder, type_id: SymbolId, name: []const u8) ?u32 {
        const d = cx.typeDecl(type_id) orelse return null;
        switch (d.kind) {
            .struct_type => |s| for (s.fields) |f| {
                if (std.mem.eql(u8, f.name, name)) return cx.memberAt(b, d, f.span, f.name, .field);
            },
            else => {},
        }
        return null;
    }

    fn variantTarget(cx: *Ctx, b: *Builder, type_id: SymbolId, name: []const u8) ?u32 {
        const d = cx.typeDecl(type_id) orelse return null;
        switch (d.kind) {
            .enum_type => |e| for (e.variants) |v| {
                if (std.mem.eql(u8, v.name, name)) return cx.memberAt(b, d, v.span, v.name, .variant);
            },
            .errors => |e| for (e.variants) |v| {
                if (std.mem.eql(u8, v.name, name)) return cx.memberAt(b, d, v.span, v.name, .variant);
            },
            else => {},
        }
        return null;
    }

    fn ifaceMethodTarget(cx: *Ctx, b: *Builder, type_id: SymbolId, name: []const u8) ?u32 {
        const d = cx.typeDecl(type_id) orelse return null;
        switch (d.kind) {
            .interface_type => |i| for (i.methods) |m| {
                if (std.mem.eql(u8, m.name, name)) return cx.memberAt(b, d, m.span, m.name, .interface_method);
            },
            else => {},
        }
        return null;
    }

    /// The method `name` declared in the body of struct `type_id` (hoisted by the parser
    /// to a top level `Type.name`).
    fn hoistedMethod(cx: *Ctx, type_id0: SymbolId, name: []const u8) ?SymbolId {
        const type_id = cx.concrete(type_id0);
        const sym = cx.syms.symbol(type_id);
        var buf: [256]u8 = undefined;
        const dotted = std.fmt.bufPrint(&buf, "{s}.{s}", .{ sym.name, name }) catch return null;
        const vis = cx.syms.visible_names.get(sym.file_name) orelse return null;
        const id = vis.get(dotted) orelse return null;
        return if (cx.syms.symbol(id).kind == .function) id else null;
    }

    fn memberTarget(cx: *Ctx, b: *Builder, type_id: SymbolId, name: []const u8) ?u32 {
        if (cx.fieldTarget(b, type_id, name)) |t| return t;
        if (cx.variantTarget(b, type_id, name)) |t| return t;
        if (cx.ifaceMethodTarget(b, type_id, name)) |t| return t;
        if (cx.hoistedMethod(type_id, name)) |m| return cx.symTarget(b, m);
        return null;
    }

    fn implMethodTarget(cx: *Ctx, b: *Builder, imc: sema.ImplMethodCall) ?u32 {
        for (cx.impls.items) |impl| {
            if (!std.mem.eql(u8, impl.type_name, imc.type_name) or !std.mem.eql(u8, impl.interface_name, imc.interface_name)) continue;
            const iface = cx.syms.resolveVisible(impl.file_name, impl.interface_name) orelse continue;
            return cx.ifaceMethodTarget(b, iface, imc.method_name);
        }
        return null;
    }

    /// The type of `x.name` when `x` has type `type_id`.
    fn memberType(cx: *Ctx, type_id: SymbolId, name: []const u8) ?SymbolId {
        const d = cx.typeDecl(type_id) orelse return null;
        switch (d.kind) {
            .struct_type => |s| for (s.fields) |f| {
                if (std.mem.eql(u8, f.name, name)) return cx.typeRefSym(d.file_name, f.ty, s.type_params);
            },
            .enum_type => |e| for (e.variants) |v| {
                if (std.mem.eql(u8, v.name, name)) return cx.concrete(type_id);
            },
            else => {},
        }
        return null;
    }

    /// The type of field number `i` of struct `type_id` (a positional literal).
    fn fieldTypeAt(cx: *Ctx, type_id: SymbolId, i: usize) ?SymbolId {
        const d = cx.typeDecl(type_id) orelse return null;
        return switch (d.kind) {
            .struct_type => |s| if (i < s.fields.len) cx.typeRefSym(d.file_name, s.fields[i].ty, s.type_params) else null,
            else => null,
        };
    }

    fn variantPayload(cx: *Ctx, type_id: SymbolId, name: []const u8) ?SymbolId {
        const d = cx.typeDecl(type_id) orelse return null;
        switch (d.kind) {
            .enum_type => |e| for (e.variants) |v| {
                if (std.mem.eql(u8, v.name, name)) return if (v.payload) |p| cx.typeRefSym(d.file_name, p, &.{}) else null;
            },
            else => {},
        }
        return null;
    }

    fn returnType(cx: *Ctx, f: ast.FunctionDecl) ?SymbolId {
        return cx.typeRefSym(f.file_name, f.return_ty, f.type_params);
    }

    fn errorType(cx: *Ctx, f: ast.FunctionDecl) ?SymbolId {
        const spec = f.error_ty orelse return null;
        return switch (spec) {
            .named => |n| cx.typeRefSym(f.file_name, .{ .named = n }, f.type_params),
            else => null,
        };
    }

    /// The type of the parameter that positional argument `index` is passed to (an
    /// explicit `$T: type` argument takes its place among the arguments too).
    fn paramType(cx: *Ctx, f: ast.FunctionDecl, index: usize) ?SymbolId {
        if (index >= f.params.len) return null;
        const p = f.params[index];
        if (p.is_type_param) return null;
        return cx.typeRefSym(f.file_name, p.ty, f.type_params);
    }

    fn paramTypeNamed(cx: *Ctx, f: ast.FunctionDecl, name: []const u8) ?SymbolId {
        for (f.params) |p| {
            if (!p.is_type_param and std.mem.eql(u8, p.name, name)) return cx.typeRefSym(f.file_name, p.ty, f.type_params);
        }
        return null;
    }

    /// The type of a top level symbol used as a value: a type stands for itself (the
    /// base of `Color.red`), a constant or global has its declared or inferred type.
    fn symValueType(cx: *Ctx, sid: SymbolId) ?SymbolId {
        const sym = cx.syms.symbol(sid);
        switch (sym.kind) {
            .type => return cx.concrete(sid),
            .const_symbol, .global_var => {
                if (cx.env.symbol_types.get(sid)) |ty| if (cx.symOfTy(ty)) |s| return s;
                if (cx.decls.get(sid)) |item| switch (item) {
                    .const_decl => |d| if (d.ty) |tr| return cx.typeRefSym(d.file_name, tr, &.{}),
                    else => {},
                };
                return null;
            },
            else => return null,
        }
    }

    /// The public declaration `name` of the module `file` (a selective import).
    fn symbolInFile(cx: *Ctx, file: []const u8, name: []const u8) ?SymbolId {
        if (cx.syms.visible_names.get(file)) |vis| if (vis.get(name)) |id| {
            if (std.mem.eql(u8, cx.syms.symbol(id).file_name, file)) return id;
        };
        for (cx.syms.symbols.items) |s| {
            if (std.mem.eql(u8, s.file_name, file) and std.mem.eql(u8, s.name, name)) return s.id;
        }
        return null;
    }
};

/// How the type of a local is found when it is needed (sema does not record the type of
/// a name that is a local).
const LocalType = union(enum) {
    none,
    /// Declared: `x: T`, a parameter.
    ref: ast.TypeRef,
    /// The type of this expression (`x := e`, a `match` binding of the whole subject).
    expr: ast.Expr,
    /// An element of this slice or array (`for x in e`).
    elem: ast.Expr,
    /// The payload of this optional (`if x := e`, `while e |x|`).
    unwrap: ast.Expr,
    /// The error of this fallible call (`e catch err { … }`).
    err: ast.Expr,
    sym: SymbolId,
};

const Local = struct {
    name: []const u8,
    /// Null when the declaration's name was not found in the source.
    target: ?u32,
    ty: LocalType = .none,
    type_param: bool = false,
};

const Mark = struct { len: usize, end: u32 };

/// Declares the `$T` written in a function's parameter types (`a: $T`, `p: *$T`,
/// `xs: []$T`) where the first one of each name is; a later `$T` of the same name
/// is a use of it.
const ParamTypeParams = struct {
    w: *Walker,
    /// Where the function's own locals start in `w.locals`.
    from: usize,

    pub fn visit(d: *ParamTypeParams, tp: ast.NamedType) error{OutOfMemory}!void {
        // The `Box($T)` that stands for `Self` in a generic struct's method is made
        // by the parser and spans the struct's name: its `T` is declared at the
        // struct's header, after the parameters.
        if (!wordAt(d.w.src, tp.span.start, tp.name)) return;
        for (d.w.locals.items[d.from..]) |l| {
            if (l.type_param and std.mem.eql(u8, l.name, tp.name)) return;
        }
        d.w.declare(tp.name, tp.span.start, .type_param, .none);
    }
};

/// The walk of one top level item, with the locals in scope.
const Walker = struct {
    cx: *Ctx,
    b: *Builder,
    file: []const u8,
    src: []const u8,
    locals: std.ArrayList(Local) = .empty,
    marks: std.ArrayList(Mark) = .empty,
    func: ?ast.FunctionDecl = null,
    depth: u32 = 0,

    fn init(cx: *Ctx, b: *Builder) Walker {
        return .{ .cx = cx, .b = b, .file = b.file, .src = b.source };
    }

    fn deinit(w: *Walker) void {
        w.locals.deinit(w.cx.scratch);
        w.marks.deinit(w.cx.scratch);
    }

    // Scopes

    fn pushScope(w: *Walker, end: usize) void {
        w.marks.append(w.cx.scratch, .{ .len = w.locals.items.len, .end = @intCast(@min(end, w.src.len)) }) catch {};
    }

    fn popScope(w: *Walker) void {
        const m = w.marks.pop() orelse return;
        w.locals.shrinkRetainingCapacity(m.len);
    }

    fn scopeEnd(w: *Walker) u32 {
        if (w.marks.items.len == 0) return @intCast(w.src.len);
        return w.marks.items[w.marks.items.len - 1].end;
    }

    fn declare(w: *Walker, name: []const u8, pos: ?usize, kind: Kind, ty: LocalType) void {
        var target: ?u32 = null;
        if (pos) |p| if (wordAt(w.src, p, name)) {
            target = w.b.addTarget(.{
                .file = w.b.key,
                .offset = @intCast(p),
                .name = name,
                .kind = kind,
                .scope_start = @intCast(p),
                .scope_end = w.scopeEnd(),
            });
            if (target) |t| w.b.addOcc(p, name, t, .decl, false);
        };
        w.locals.append(w.cx.scratch, .{ .name = name, .target = target, .ty = ty, .type_param = kind == .type_param }) catch {};
    }

    fn lookupValue(w: *Walker, name: []const u8) ?Local {
        var i = w.locals.items.len;
        while (i > 0) {
            i -= 1;
            const l = w.locals.items[i];
            if (!l.type_param and std.mem.eql(u8, l.name, name)) return l;
        }
        return null;
    }

    fn lookupTypeParam(w: *Walker, name: []const u8) ?Local {
        var i = w.locals.items.len;
        while (i > 0) {
            i -= 1;
            const l = w.locals.items[i];
            if (l.type_param and std.mem.eql(u8, l.name, name)) return l;
        }
        return null;
    }

    fn addSym(w: *Walker, pos: usize, name: []const u8, sid: SymbolId, role: Role, qualified: bool) void {
        if (w.cx.symTarget(w.b, sid)) |t| w.b.addOcc(pos, name, t, role, qualified);
    }

    fn typeRefSym(w: *Walker, tr: ast.TypeRef) ?SymbolId {
        switch (tr) {
            .named => |n| if (n.namespace == null and w.lookupTypeParam(n.name) != null) return w.constraintOf(n.name),
            .type_param => |n| return w.constraintOf(n.name),
            .pointer, .many_pointer => |p| return w.typeRefSym(p.inner.*),
            .optional => |o| return w.typeRefSym(o.inner.*),
            .borrow => |x| return w.typeRefSym(x.inner.*),
            else => {},
        }
        return w.cx.typeRefSym(w.file, tr, &.{});
    }

    /// The interface a type parameter is bound by (`$T: Show`, `where T: Show`), whose
    /// methods a value of that type has.
    fn constraintOf(w: *Walker, name: []const u8) ?SymbolId {
        const f = w.func orelse return null;
        for (f.type_constraints) |c| {
            if (!std.mem.eql(u8, c.param, name)) continue;
            const id = w.cx.syms.resolveVisible(w.file, c.interface) orelse continue;
            if (w.cx.syms.symbol(id).kind == .type) return id;
        }
        return null;
    }

    fn isAlias(w: *Walker, name: []const u8) bool {
        const ns = w.cx.syms.namespaces.get(w.file) orelse return false;
        return ns.contains(name);
    }

    // Types of expressions

    fn localType(w: *Walker, l: Local) ?SymbolId {
        return switch (l.ty) {
            .none => null,
            .ref => |tr| w.typeRefSym(tr),
            .expr, .unwrap => |e| w.typeOf(e),
            .elem => |e| w.elemType(e),
            .err => |e| w.errType(e),
            .sym => |s| s,
        };
    }

    /// The type (struct, enum, interface) of an expression, for its members.
    fn typeOf(w: *Walker, e: ast.Expr) ?SymbolId {
        if (w.depth > 16) return null;
        w.depth += 1;
        defer w.depth -= 1;
        if (w.cx.env.expr_types.get(e.id)) |ty| if (w.cx.symOfTy(ty)) |s| return s;
        switch (e.kind) {
            .struct_literal, .compound_literal => return if (w.cx.env.literal_types.get(e.id)) |s| w.cx.concrete(s) else null,
            .ident => |name| {
                if (name.len == 0 or name[0] == '.') return null;
                if (w.cx.env.expr_symbols.get(e.id)) |sid| return w.cx.symValueType(sid);
                if (w.lookupValue(name)) |l| return w.localType(l);
                const sid = w.cx.syms.resolveVisible(w.file, name) orelse return null;
                return w.cx.symValueType(sid);
            },
            .field => |f| {
                const base = w.typeOf(f.base.*) orelse return null;
                return w.cx.memberType(base, f.name);
            },
            .call => |c| return w.callType(c),
            .unary => |u| return w.typeOf(u.expr.*),
            .try_expr => |t| return w.typeOf(t.value.*),
            .force_unwrap, .unsafe_expr, .run_expr => |inner| return w.typeOf(inner.*),
            .nil_coalesce => |n| return w.typeOf(n.value.*),
            .catch_expr => |c| return w.typeOf(c.value.*),
            .as_cast => |c| return w.typeRefSym(c.to),
            .index => |ix| return w.elemType(ix.base.*),
            .scope_access => |sa| {
                const sid = w.cx.env.expr_symbols.get(e.id) orelse w.scopeSym(sa) orelse return null;
                return w.cx.symValueType(sid);
            },
            .if_expr => |ie| return w.typeOf(ie.then_value),
            .match_expr => |me| return if (me.arms.len > 0) w.typeOf(me.arms[0].value) else null,
            else => return null,
        }
    }

    /// The function a call goes to, when it is a top level one.
    fn calleeDecl(w: *Walker, c: ast.CallExpr) ?ast.FunctionDecl {
        const callee = c.callee.*;
        switch (callee.kind) {
            .ident => |name| {
                if (isBuiltinCall(name)) return null;
                const sid = w.cx.syms.resolveVisible(w.file, name) orelse return null;
                return w.cx.fnDecl(sid);
            },
            .scope_access => |sa| {
                const sid = w.cx.env.expr_symbols.get(callee.id) orelse w.scopeSym(sa) orelse return null;
                return w.cx.fnDecl(sid);
            },
            .field => |f| {
                if (w.cx.env.extension_calls.get(callee.id)) |sid| return w.cx.fnDecl(sid);
                const base = w.typeOf(f.base.*) orelse return null;
                if (w.cx.hoistedMethod(base, f.name)) |sid| return w.cx.fnDecl(sid);
                const sid = w.cx.syms.resolveVisible(w.file, f.name) orelse return null;
                return w.cx.fnDecl(sid);
            },
            else => return null,
        }
    }

    fn callType(w: *Walker, c: ast.CallExpr) ?SymbolId {
        const callee = c.callee.*;
        if (callee.kind == .field and w.cx.env.enum_lits.contains(callee.id)) return w.typeOf(callee.kind.field.base.*);
        const f = w.calleeDecl(c) orelse return null;
        return w.cx.returnType(f);
    }

    const RefIn = struct { ref: ast.TypeRef, file: []const u8, tparams: []const []const u8 };

    /// The declared type of a local or a field, as written.
    fn declaredRef(w: *Walker, e: ast.Expr) ?RefIn {
        switch (e.kind) {
            .ident => |name| {
                const l = w.lookupValue(name) orelse return null;
                return switch (l.ty) {
                    .ref => |tr| .{ .ref = tr, .file = w.file, .tparams = if (w.func) |f| f.type_params else &.{} },
                    else => null,
                };
            },
            .field => |f| {
                const base = w.typeOf(f.base.*) orelse return null;
                const d = w.cx.typeDecl(base) orelse return null;
                switch (d.kind) {
                    .struct_type => |s| for (s.fields) |fd| {
                        if (std.mem.eql(u8, fd.name, f.name)) return .{ .ref = fd.ty, .file = d.file_name, .tparams = s.type_params };
                    },
                    else => {},
                }
                return null;
            },
            else => return null,
        }
    }

    fn elemOfRef(w: *Walker, tr: ast.TypeRef, file: []const u8, tparams: []const []const u8) ?SymbolId {
        return switch (tr) {
            .slice => |s| w.cx.typeRefSym(file, s.inner.*, tparams),
            .array => |a| w.cx.typeRefSym(file, a.inner.*, tparams),
            .many_pointer => |p| w.cx.typeRefSym(file, p.inner.*, tparams),
            .pointer => |p| w.elemOfRef(p.inner.*, file, tparams),
            else => null,
        };
    }

    /// The type of an element of `e` (a slice, an array, a pointer to one).
    fn elemType(w: *Walker, e: ast.Expr) ?SymbolId {
        if (w.cx.env.expr_types.get(e.id)) |ty| {
            const inner: ?sema.Ty = switch (ty) {
                .slice => |p| p.*,
                .array => |a| a.elem.*,
                .pointer, .const_ptr => |p| switch (p.*) {
                    .array => |a| a.elem.*,
                    .slice => |q| q.*,
                    else => p.*,
                },
                else => null,
            };
            if (inner) |t| return w.cx.symOfTy(t);
        }
        const d = w.declaredRef(e) orelse return null;
        return w.elemOfRef(d.ref, d.file, d.tparams);
    }

    fn errType(w: *Walker, e: ast.Expr) ?SymbolId {
        if (w.cx.env.expr_types.get(e.id)) |ty| switch (ty) {
            .fallible => |f| return w.cx.symOfTy(f.err.*),
            else => {},
        };
        if (e.kind == .call) if (w.calleeDecl(e.kind.call)) |f| return w.cx.errorType(f);
        return null;
    }

    // Items

    fn walkItem(w: *Walker, item: ast.Item) void {
        switch (item) {
            .import => |imp| w.walkImport(imp),
            .const_decl => |d| w.walkConst(d),
            .type_decl => |d| w.walkTypeDecl(d),
            .function => |f| if (!isLambda(f.name)) w.walkFunction(f, .auto, .decl),
            .interface_impl => |impl| w.walkImpl(impl),
            .static_assert => |sa| w.walkExpr(sa.condition, .read, null),
            .system_library => {},
        }
    }

    fn walkImport(w: *Walker, imp: ast.ImportDecl) void {
        const target = imp.resolved_file orelse return;
        if (imp.glob) {
            if (w.cx.files.get(target)) |fi| w.b.globs.append(w.b.alloc(), w.b.alloc().dupe(u8, fi.key) catch return) catch {};
        }
        const names = imp.names orelse return;
        var cursor = std.mem.indexOfScalarPos(u8, w.src, imp.span.start, '{') orelse return;
        for (names) |n| {
            const pos = findWord(w.src, cursor, imp.span.end, n) orelse continue;
            cursor = pos + n.len;
            const sid = w.cx.symbolInFile(target, n) orelse continue;
            w.addSym(pos, n, sid, .read, false);
        }
    }

    fn walkConst(w: *Walker, d: ast.ConstDecl) void {
        if (w.cx.syms.resolveVisible(w.file, d.name)) |sid| if (w.cx.symTarget(w.b, sid)) |t| {
            w.b.addOcc(d.span.start, d.name, t, .decl, false);
        };
        var expected: ?SymbolId = null;
        if (d.ty) |ty| {
            w.walkTypeRef(ty);
            expected = w.typeRefSym(ty);
        }
        w.walkExpr(d.value, .read, expected);
    }

    fn walkTypeDecl(w: *Walker, d: ast.TypeDecl) void {
        const sid = w.cx.syms.resolveVisible(w.file, d.name);
        if (sid) |s| if (w.cx.symTarget(w.b, s)) |t| w.b.addOcc(d.span.start, d.name, t, .decl, false);
        switch (d.kind) {
            .alias, .distinct => |tr| w.walkTypeRef(tr),
            .opaque_type => {},
            .struct_type => |s| {
                w.pushScope(d.span.end);
                defer w.popScope();
                const brace = std.mem.indexOfScalarPos(u8, w.src, d.span.start, '{') orelse d.span.end;
                for (s.type_params) |tp| w.declare(tp, findWord(w.src, d.span.start + d.name.len, brace, tp), .type_param, .none);
                for (s.type_constraints) |c| w.constraintRef(c);
                for (s.fields) |f| {
                    if (sid) |id| if (w.cx.fieldTarget(w.b, id, f.name)) |t| w.b.addOcc(f.span.start, f.name, t, .decl, false);
                    w.walkTypeRef(f.ty);
                    if (f.default) |def| w.walkExpr(def, .read, w.typeRefSym(f.ty));
                }
            },
            .enum_type => |e| for (e.variants) |v| {
                if (sid) |id| if (w.cx.variantTarget(w.b, id, v.name)) |t| w.b.addOcc(nameStart(w.src, v.span, v.name), v.name, t, .decl, false);
                if (v.payload) |p| w.walkTypeRef(p);
            },
            .errors => |e| for (e.variants) |v| {
                if (sid) |id| if (w.cx.variantTarget(w.b, id, v.name)) |t| w.b.addOcc(nameStart(w.src, v.span, v.name), v.name, t, .decl, false);
                if (v.payload) |p| w.walkTypeRef(p);
            },
            .interface_type => |i| for (i.methods) |m| {
                const t: ?u32 = if (sid) |id| w.cx.ifaceMethodTarget(w.b, id, m.name) else null;
                w.walkFunction(m, if (t) |x| .{ .target = x } else .none, .decl);
            },
        }
    }

    fn walkImpl(w: *Walker, impl: ast.InterfaceImpl) void {
        if (w.cx.syms.resolveVisible(w.file, impl.type_name)) |sid| w.addSym(impl.span.start, impl.type_name, sid, .read, false);
        const iface = w.cx.syms.resolveVisible(w.file, impl.interface_name);
        if (iface) |iid| {
            if (findWord(w.src, impl.span.start + impl.type_name.len, impl.span.end, impl.interface_name)) |p| w.addSym(p, impl.interface_name, iid, .read, false);
        }
        for (impl.methods) |m| {
            const t: ?u32 = if (iface) |iid| w.cx.ifaceMethodTarget(w.b, iid, m.name) else null;
            w.walkFunction(m, if (t) |x| .{ .target = x } else .none, .impl);
        }
    }

    /// `$T: Name`: the interface or constraint `Name`.
    fn constraintRef(w: *Walker, c: ast.TypeConstraint) void {
        if (c.span.end < c.interface.len) return;
        const sid = w.cx.syms.resolveVisible(w.file, c.interface) orelse return;
        w.addSym(c.span.end - c.interface.len, c.interface, sid, .read, false);
    }

    const NameTarget = union(enum) { auto, none, target: u32 };

    fn walkFunction(w: *Walker, f: ast.FunctionDecl, nt: NameTarget, name_role: Role) void {
        const lambda = isLambda(f.name);
        const short = shortName(f.name);
        // A function `#derive` generated has no source of its own: its span is that of
        // the struct name.
        if (!lambda and !wordAt(w.src, f.span.start, short)) return;
        if (!lambda) {
            const t: ?u32 = switch (nt) {
                .auto => if (w.cx.syms.resolveVisible(w.file, f.name)) |sid| w.cx.symTarget(w.b, sid) else null,
                .none => null,
                .target => |x| x,
            };
            if (t) |x| w.b.addOcc(f.span.start, short, x, name_role, false);
        }
        const outer_func = w.func;
        w.func = f;
        defer w.func = outer_func;
        w.pushScope(f.span.end);
        defer w.popScope();
        var param_tps: ParamTypeParams = .{ .w = w, .from = w.locals.items.len };
        for (f.params) |p| {
            if (p.is_type_param) {
                w.declare(p.name, p.span.start, .type_param, .none);
            } else {
                p.ty.eachTypeParam(&param_tps) catch {};
            }
        }
        switch (f.return_ty) {
            .type_param => |tp| if (w.lookupTypeParam(tp.name) == null) w.declare(tp.name, tp.span.start, .type_param, .none),
            else => {},
        }
        // A method of a generic struct inherits the struct's type parameters by name: they
        // are the `$T` of the struct's header.
        const header: ?ast.TypeDecl = if (!lambda and short.len != f.name.len) blk: {
            const sid = w.cx.syms.resolveVisible(w.file, f.name[0 .. f.name.len - short.len - 1]) orelse break :blk null;
            break :blk w.cx.typeDecl(sid);
        } else null;
        for (f.type_params) |tp| {
            if (w.lookupTypeParam(tp) != null) continue;
            var pos: ?usize = null;
            if (header) |d| if (std.mem.eql(u8, d.file_name, w.file)) {
                const brace = std.mem.indexOfScalarPos(u8, w.src, d.span.start, '{') orelse d.span.end;
                pos = findWord(w.src, d.span.start + d.name.len, brace, tp);
            };
            w.declare(tp, pos, .type_param, .none);
        }
        for (f.type_constraints) |c| w.constraintRef(c);
        for (f.params) |p| {
            if (p.is_type_param) continue;
            w.walkTypeRef(p.ty);
            w.declare(p.name, paramNamePos(w.src, p), .param, .{ .ref = p.ty });
        }
        w.walkTypeRef(f.return_ty);
        if (f.error_ty) |spec| w.walkErrorSpec(spec);
        if (f.where_clause) |wc| w.walkBlock(wc);
        if (f.body) |body| w.walkBlock(body);
    }

    /// A lambda is lifted to a top level function; walk it where it is written, so the
    /// locals it captures resolve.
    fn walkLambda(w: *Walker, name: []const u8) void {
        const sid = w.cx.syms.resolveVisible(w.file, name) orelse return;
        const gop = w.cx.lambdas_done.getOrPut(w.cx.scratch, sid) catch return;
        if (gop.found_existing) return;
        const f = w.cx.fnDecl(sid) orelse return;
        w.walkFunction(f, .none, .decl);
    }

    // Statements

    fn walkBlock(w: *Walker, block: ast.Block) void {
        w.pushScope(block.span.end);
        defer w.popScope();
        for (block.statements) |s| w.walkStmt(s);
    }

    fn walkStmt(w: *Walker, s: ast.Stmt) void {
        switch (s) {
            .local_infer => |l| {
                w.walkExpr(l.value, .read, null);
                w.declare(l.name, l.span.start, .local, .{ .expr = l.value });
            },
            .local_typed => |l| {
                w.walkTypeRef(l.ty);
                w.walkExpr(l.value, .read, w.typeRefSym(l.ty));
                w.declare(l.name, l.span.start, .local, .{ .ref = l.ty });
            },
            .assign => |a| {
                w.walkExpr(a.target, .write, null);
                w.walkExpr(a.value, .read, w.typeOf(a.target));
            },
            .return_stmt => |r| if (r.value) |v| {
                w.walkExpr(v, .read, if (w.func) |f| w.funcType(f.return_ty) else null);
            },
            .fail_stmt => |fs| {
                for (fs.payload) |p| w.walkExpr(p, .read, null);
                w.failVariant(fs);
            },
            .if_stmt => |i| w.walkIf(i),
            .while_stmt => |ws| {
                w.walkExpr(ws.condition, .read, null);
                w.pushScope(ws.body.span.end);
                defer w.popScope();
                if (ws.payload_binding) |p| w.declare(p, findWord(w.src, ws.condition.span.end, ws.body.span.start, p), .local, .{ .unwrap = ws.condition });
                w.walkBlock(ws.body);
            },
            .for_range => |fr| {
                w.walkExpr(fr.start, .read, null);
                w.walkExpr(fr.end, .read, null);
                w.pushScope(fr.body.span.end);
                defer w.popScope();
                w.declare(fr.binding, findWord(w.src, fr.span.start + 3, fr.start.span.start, fr.binding), .local, .none);
                w.walkBlock(fr.body);
            },
            .for_slice => |fs| {
                w.walkExpr(fs.iter, .read, null);
                w.pushScope(fs.body.span.end);
                defer w.popScope();
                const bpos = findWord(w.src, fs.span.start + 3, fs.iter.span.start, fs.binding);
                w.declare(fs.binding, bpos, .local, .{ .elem = fs.iter });
                if (fs.index_binding) |ib| {
                    const from = if (bpos) |p| p + fs.binding.len else fs.span.start + 3;
                    w.declare(ib, findWord(w.src, from, fs.iter.span.start, ib), .local, .none);
                }
                w.walkBlock(fs.body);
            },
            .unsafe_block, .comptime_run => |b| w.walkBlock(b),
            .break_stmt, .continue_stmt => {},
            .zone_block => |z| {
                w.pushScope(z.body.span.end);
                defer w.popScope();
                w.declare(z.name, findWord(w.src, z.span.start + 4, z.body.span.start, z.name), .local, .none);
                w.walkBlock(z.body);
            },
            .defer_stmt => |d| w.walkBlock(d.body),
            .match_stmt => |m| {
                w.walkExpr(m.subject, .read, null);
                const st = w.typeOf(m.subject);
                for (m.arms) |arm| w.walkArm(arm, m.subject, st, null);
            },
            .comptime_if => |c| {
                w.walkExpr(c.condition, .read, null);
                w.walkBlock(c.then_block);
                if (c.else_block) |eb| w.walkBlock(eb);
            },
            .insert_stmt => |ins| switch (ins.operand.kind) {
                .quote => |blk| for (blk.statements) |st| w.walkStmt(st),
                else => w.walkExpr(ins.operand, .read, null),
            },
            .comptime_for => |cf| {
                w.walkExpr(cf.start, .read, null);
                w.walkExpr(cf.end, .read, null);
                w.pushScope(cf.body.span.end);
                defer w.popScope();
                w.declare(cf.binding, findWord(w.src, cf.span.start, cf.start.span.start, cf.binding), .local, .none);
                w.walkBlock(cf.body);
            },
            .expr => |e| w.walkExpr(e, .read, null),
        }
    }

    /// A type of the current function's signature, with its type parameters in scope.
    fn funcType(w: *Walker, tr: ast.TypeRef) ?SymbolId {
        return w.typeRefSym(tr);
    }

    fn walkIf(w: *Walker, i: ast.IfStmt) void {
        if (i.binding) |b| {
            w.walkExpr(b.value, .read, null);
            w.pushScope(i.then_block.span.end);
            w.declare(b.name, findWord(w.src, i.span.start + 2, b.value.span.start, b.name), .local, .{ .unwrap = b.value });
            if (i.payload_binding) |p| w.declare(p, findWord(w.src, b.value.span.end, i.then_block.span.start, p), .local, .{ .unwrap = b.value });
            w.walkBlock(i.then_block);
            w.popScope();
        } else {
            w.walkExpr(i.condition, .read, null);
            w.pushScope(i.then_block.span.end);
            if (i.payload_binding) |p| w.declare(p, findWord(w.src, i.condition.span.end, i.then_block.span.start, p), .local, .{ .unwrap = i.condition });
            w.walkBlock(i.then_block);
            w.popScope();
        }
        if (i.else_block) |eb| w.walkBlock(eb);
    }

    /// One arm of a `match` statement or expression.
    fn walkArm(w: *Walker, arm: anytype, subject: ast.Expr, subject_t: ?SymbolId, expected: ?SymbolId) void {
        var after: usize = arm.span.start;
        var bind_ty: LocalType = .none;
        switch (arm.pattern) {
            .enum_variant => |v| {
                const pos = findWord(w.src, arm.span.start, arm.span.end, v);
                if (pos) |p| after = p + v.len;
                if (subject_t) |t| {
                    if (pos) |p| if (w.cx.variantTarget(w.b, t, v)) |tid| w.b.addOcc(p, v, tid, .read, false);
                    if (w.cx.variantPayload(t, v)) |pt| bind_ty = .{ .sym = pt };
                }
            },
            .int_values => |vals| for (vals) |x| w.walkExpr(x, .read, null),
            .range => |r| {
                w.walkExpr(r.lo, .read, null);
                w.walkExpr(r.hi, .read, null);
            },
            .strings, .else_arm, .binding => {},
        }
        w.pushScope(arm.span.end);
        defer w.popScope();
        switch (arm.pattern) {
            .binding => |name| {
                const pos: ?usize = if (wordAt(w.src, arm.span.start, name)) arm.span.start else null;
                w.declare(name, pos, .local, .{ .expr = subject });
                after = arm.span.start + name.len;
            },
            else => {},
        }
        if (arm.binding) |b| w.declare(b, findWord(w.src, after, arm.span.end, b), .local, bind_ty);
        if (arm.guard) |g| w.walkExpr(g, .read, null);
        if (@hasField(@TypeOf(arm), "body")) {
            w.walkBlock(arm.body);
        } else {
            w.walkExpr(arm.value, .read, expected);
        }
    }

    /// `fail .Variant`: a variant of the function's error set.
    fn failVariant(w: *Walker, fs: ast.FailStmt) void {
        const f = w.func orelse return;
        const t = w.cx.errorType(f) orelse return;
        const pos = findWord(w.src, fs.span.start + 4, fs.span.end, fs.variant) orelse return;
        if (w.cx.variantTarget(w.b, t, fs.variant)) |tid| w.b.addOcc(pos, fs.variant, tid, .read, false);
    }

    // Expressions

    fn walkExpr(w: *Walker, e: ast.Expr, role: Role, expected: ?SymbolId) void {
        switch (e.kind) {
            .ident => |name| w.walkIdent(e, name, role, expected),
            .type_ref => |tr| w.walkTypeRef(tr),
            .int, .float, .string, .bool, .null => {},
            .quote, .quote_expr, .splice => {},
            .parse_expr => |inner| w.walkExpr(inner.*, .read, null),
            .compound_literal => |vals| {
                const s = w.literalType(e, expected);
                for (vals, 0..) |v, i| w.walkExpr(v, .read, if (s) |sid| w.cx.fieldTypeAt(sid, i) else null);
            },
            .struct_literal => |inits| {
                const s = w.literalType(e, expected);
                for (inits) |fi| {
                    if (s) |sid| if (w.cx.fieldTarget(w.b, sid, fi.name)) |t| w.b.addOcc(fi.span.start, fi.name, t, .write, false);
                    w.walkExpr(fi.value, .read, if (s) |sid| w.cx.memberType(sid, fi.name) else null);
                }
            },
            .unary => |u| w.walkExpr(u.expr.*, .read, null),
            .binary => |bin| {
                if (bin.op == .equal or bin.op == .not_equal) {
                    // `x == .red`: the bare variant has the type of the other side.
                    const rt = if (isEnumLit(bin.left.*)) w.typeOf(bin.right.*) else null;
                    const lt = if (isEnumLit(bin.right.*)) w.typeOf(bin.left.*) else null;
                    w.walkExpr(bin.left.*, .read, rt);
                    w.walkExpr(bin.right.*, .read, lt);
                } else {
                    w.walkExpr(bin.left.*, .read, null);
                    w.walkExpr(bin.right.*, .read, null);
                }
            },
            .unsafe_expr, .run_expr, .force_unwrap => |inner| w.walkExpr(inner.*, .read, expected),
            .nil_coalesce => |n| {
                w.walkExpr(n.value.*, .read, null);
                w.walkExpr(n.default.*, .read, expected);
            },
            .as_cast => |c| {
                w.walkExpr(c.value.*, .read, null);
                w.walkTypeRef(c.to);
            },
            .try_expr => |t| w.walkExpr(t.value.*, .read, null),
            .catch_expr => |c| {
                w.walkExpr(c.value.*, .read, null);
                w.pushScope(c.handler.span.end);
                defer w.popScope();
                const kw = findWord(w.src, c.value.span.end, c.handler.span.start, "catch");
                const pos = if (kw) |k| findWord(w.src, k + 5, c.handler.span.start, c.err_name) else null;
                w.declare(c.err_name, pos, .local, .{ .err = c.value.* });
                w.walkBlock(c.handler);
            },
            .call => |c| w.walkCall(c),
            .field => |f| {
                w.walkExpr(f.base.*, .read, null);
                if (e.span.end < f.name.len) return;
                const base = w.typeOf(f.base.*) orelse return;
                if (w.cx.memberTarget(w.b, base, f.name)) |t| w.b.addOcc(e.span.end - f.name.len, f.name, t, role, false);
            },
            .scope_access => |sa| w.walkScope(e, sa, role),
            .index => |ix| {
                w.walkExpr(ix.base.*, .read, null);
                w.walkExpr(ix.index.*, .read, null);
            },
            .slice => |sl| {
                w.walkExpr(sl.base.*, .read, null);
                if (sl.start) |x| w.walkExpr(x.*, .read, null);
                if (sl.end) |x| w.walkExpr(x.*, .read, null);
            },
            .match_expr => |me| {
                w.walkExpr(me.subject.*, .read, null);
                const st = w.typeOf(me.subject.*);
                for (me.arms) |arm| w.walkArm(arm, me.subject.*, st, expected);
            },
            .if_expr => |ie| {
                w.walkExpr(ie.cond, .read, null);
                w.walkExpr(ie.then_value, .read, expected);
                w.walkExpr(ie.else_value, .read, expected);
            },
        }
    }

    fn isEnumLit(e: ast.Expr) bool {
        return e.kind == .ident and e.kind.ident.len > 1 and e.kind.ident[0] == '.';
    }

    fn literalType(w: *Walker, e: ast.Expr, expected: ?SymbolId) ?SymbolId {
        if (w.cx.env.literal_types.get(e.id)) |s| return w.cx.concrete(s);
        return expected;
    }

    fn walkIdent(w: *Walker, e: ast.Expr, name: []const u8, role: Role, expected: ?SymbolId) void {
        if (name.len == 0) return;
        if (name[0] == '.') {
            // `.red`: a variant of the enum the context expects.
            const vname = name[1..];
            var t: ?SymbolId = null;
            if (w.cx.env.expr_types.get(e.id)) |ty| t = w.cx.symOfTy(ty);
            if (t == null) t = expected;
            if (t) |tid| if (w.cx.variantTarget(w.b, tid, vname)) |x| w.b.addOcc(e.span.start + 1, vname, x, .read, false);
            return;
        }
        if (isLambda(name)) return w.walkLambda(name);
        // Sema resolved it to a top level symbol, so it is not a local there.
        if (w.cx.env.expr_symbols.get(e.id)) |sid| return w.addSym(e.span.start, name, sid, role, false);
        if (w.lookupValue(name)) |l| {
            if (l.target) |t| w.b.addOcc(e.span.start, name, t, role, false);
            return;
        }
        if (w.lookupTypeParam(name)) |l| {
            if (l.target) |t| w.b.addOcc(e.span.start, name, t, role, false);
            return;
        }
        if (sema.isBuiltinValue(name)) return;
        if (w.cx.syms.resolveVisible(w.file, name)) |sid| w.addSym(e.span.start, name, sid, role, false);
    }

    fn scopeSym(w: *Walker, sa: ast.ScopeAccess) ?SymbolId {
        const base = switch (sa.base.kind) {
            .ident => |n| n,
            else => return null,
        };
        if (w.cx.syms.resolveScoped(w.file, base, sa.member)) |id| return id;
        const tid = w.cx.syms.resolveVisible(w.file, base) orelse return null;
        if (w.cx.syms.symbol(tid).kind != .type) return null;
        return w.cx.hoistedMethod(tid, sa.member);
    }

    /// `alias::member` or `Type::method`.
    fn walkScope(w: *Walker, e: ast.Expr, sa: ast.ScopeAccess, role: Role) void {
        switch (sa.base.kind) {
            .ident => |n| if (!w.isAlias(n)) w.walkExpr(sa.base.*, .read, null),
            else => w.walkExpr(sa.base.*, .read, null),
        }
        if (e.span.end < sa.member.len) return;
        const sid = w.cx.env.expr_symbols.get(e.id) orelse w.scopeSym(sa) orelse return;
        w.addSym(e.span.end - sa.member.len, sa.member, sid, role, true);
    }

    fn walkCall(w: *Walker, c: ast.CallExpr) void {
        const callee = c.callee.*;
        var fdecl: ?ast.FunctionDecl = null;
        var method = false;
        switch (callee.kind) {
            .ident => |name| {
                if (isLambda(name)) {
                    w.walkLambda(name);
                } else if (!isBuiltinCall(name)) {
                    // A call looks at the declarations before the locals (a local holding
                    // a function pointer).
                    if (w.cx.syms.resolveVisible(w.file, name)) |sid| {
                        w.addSym(callee.span.start, name, sid, .read, false);
                        fdecl = w.cx.fnDecl(sid);
                    } else if (w.lookupValue(name)) |l| {
                        if (l.target) |t| w.b.addOcc(callee.span.start, name, t, .read, false);
                    }
                }
            },
            .scope_access => |sa| {
                w.walkScope(callee, sa, .read);
                if (w.cx.env.expr_symbols.get(callee.id) orelse w.scopeSym(sa)) |sid| fdecl = w.cx.fnDecl(sid);
            },
            .field => |f| {
                w.walkExpr(f.base.*, .read, null);
                if (callee.span.end >= f.name.len) {
                    const pos = callee.span.end - f.name.len;
                    const env = w.cx.env;
                    if (env.enum_lits.contains(callee.id)) {
                        // `Shape.circle(r)`: a variant with a payload.
                        if (w.typeOf(f.base.*)) |t| if (w.cx.variantTarget(w.b, t, f.name)) |x| w.b.addOcc(pos, f.name, x, .read, false);
                    } else if (env.extension_calls.get(callee.id)) |sid| {
                        w.addSym(pos, f.name, sid, .read, false);
                        fdecl = w.cx.fnDecl(sid);
                        method = true;
                    } else if (env.impl_method_calls.get(callee.id)) |imc| {
                        if (w.cx.implMethodTarget(w.b, imc)) |x| w.b.addOcc(pos, f.name, x, .read, false);
                    } else if (w.typeOf(f.base.*)) |bt| {
                        // Not resolved by sema (a generic body, or after an error).
                        if (w.cx.hoistedMethod(bt, f.name)) |sid| {
                            w.addSym(pos, f.name, sid, .read, false);
                            fdecl = w.cx.fnDecl(sid);
                            method = true;
                        } else if (w.cx.memberTarget(w.b, bt, f.name)) |x| {
                            w.b.addOcc(pos, f.name, x, .read, false);
                        } else if (w.cx.syms.resolveVisible(w.file, f.name)) |sid| {
                            if (w.cx.fnDecl(sid)) |fd| if (firstParamIsSelf(fd)) {
                                w.addSym(pos, f.name, sid, .read, false);
                                fdecl = fd;
                                method = true;
                            };
                        }
                    }
                }
            },
            else => w.walkExpr(callee, .read, null),
        }
        var vi: usize = if (method) 1 else 0;
        for (c.args) |arg| switch (arg) {
            .positional => |v| {
                w.walkExpr(v, .read, if (fdecl) |fd| w.cx.paramType(fd, vi) else null);
                vi += 1;
            },
            .named => |n| w.walkExpr(n.value, .read, if (fdecl) |fd| w.cx.paramTypeNamed(fd, n.name) else null),
        };
    }

    // Types

    fn walkTypeRef(w: *Walker, tr: ast.TypeRef) void {
        switch (tr) {
            .named => |n| w.walkNamedType(n),
            .type_param => |n| if (w.lookupTypeParam(n.name)) |l| {
                if (l.target) |t| w.b.addOcc(n.span.start, n.name, t, .read, false);
            },
            .pointer, .many_pointer => |p| w.walkTypeRef(p.inner.*),
            .optional => |o| w.walkTypeRef(o.inner.*),
            .slice => |s| w.walkTypeRef(s.inner.*),
            .array => |a| {
                w.walkExpr(a.len.*, .read, null);
                w.walkTypeRef(a.inner.*);
            },
            .atomic => |a| w.walkTypeRef(a.inner.*),
            .borrow => |b| w.walkTypeRef(b.inner.*),
            .fn_type => |f| {
                for (f.params) |p| w.walkTypeRef(p);
                w.walkTypeRef(f.ret.*);
                if (f.error_ty) |spec| w.walkErrorSpec(spec);
            },
            .inline_error_set => |s| for (s.variants) |v| {
                if (v.payload) |p| w.walkTypeRef(p);
            },
            .generic_inst => |g| {
                if (g.namespace != null or w.lookupTypeParam(g.name) == null) {
                    const pos: ?usize = if (g.namespace) |ns| findWord(w.src, g.span.start + ns.len, g.span.end, g.name) else g.span.start;
                    const sid = if (g.namespace) |ns| w.cx.syms.resolveScoped(w.file, ns, g.name) else w.cx.syms.resolveVisible(w.file, g.name);
                    if (pos) |p| if (sid) |id| w.addSym(p, g.name, id, .read, g.namespace != null);
                }
                for (g.args) |a| w.walkTypeRef(a);
            },
            .opaque_type => {},
        }
    }

    fn walkNamedType(w: *Walker, n: ast.NamedType) void {
        if (n.namespace == null) {
            if (std.mem.eql(u8, n.name, "Self")) return;
            if (w.lookupTypeParam(n.name)) |l| {
                if (l.target) |t| w.b.addOcc(n.span.start, n.name, t, .read, false);
                return;
            }
        }
        const sid = if (n.namespace) |ns| w.cx.syms.resolveScoped(w.file, ns, n.name) else w.cx.syms.resolveVisible(w.file, n.name);
        const id = sid orelse return;
        if (n.span.end < n.name.len) return;
        const pos = if (n.namespace != null) n.span.end - n.name.len else n.span.start;
        w.addSym(pos, n.name, id, .read, n.namespace != null);
    }

    fn walkErrorSpec(w: *Walker, spec: ast.ErrorSpec) void {
        switch (spec) {
            .named => |n| w.walkNamedType(n),
            .inline_set => |s| for (s.variants) |v| {
                if (v.payload) |p| w.walkTypeRef(p);
            },
            .inferred => {},
        }
    }
};

fn occLess(_: void, a: Occ, b: Occ) bool {
    if (a.start != b.start) return a.start < b.start;
    return @intFromEnum(a.role) < @intFromEnum(b.role);
}

/// Build the reference index of every file of `an` that `want` names by path key (every
/// file outside `std` when `want` is null). The caller owns the result and its indexes.
pub fn indexAnalysis(gpa: Allocator, an: *const pipeline.Analysis, want: ?*const std.StringHashMapUnmanaged(void)) ![]*FileIndex {
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var out: std.ArrayList(*FileIndex) = .empty;
    errdefer {
        for (out.items) |idx| idx.destroy(gpa);
        out.deinit(gpa);
    }

    var files: std.StringHashMapUnmanaged(FileInfo) = .empty;
    for (an.files) |f| {
        const key = try lsp.pathKey(scratch, f.path);
        try files.put(scratch, f.path, .{ .name = f.path, .key = key, .source = f.source, .is_std = f.is_std });
    }

    // The files to index.
    var builders: std.StringHashMapUnmanaged(*Builder) = .empty;
    for (an.files) |f| {
        if (f.is_std) continue;
        const fi = files.get(f.path).?;
        if (want) |wset| if (!wset.contains(fi.key)) continue;
        if (builders.contains(f.path)) continue;
        const b = try scratch.create(Builder);
        b.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .file = f.path, .key = "", .source = f.source };
        b.key = b.alloc().dupe(u8, fi.key) catch "";
        try builders.put(scratch, f.path, b);
    }
    defer {
        // Builders not turned into an index still own their arena.
        var it = builders.valueIterator();
        while (it.next()) |b| if (b.*.file.len > 0) b.*.arena.deinit();
    }

    if (an.symbols != null and an.types != null) {
        var cx = Ctx{
            .gpa = gpa,
            .scratch = scratch,
            .an = an,
            .syms = an.symbols.?,
            .env = &an.types.?,
            .files = files,
            .builders = builders,
        };
        for (an.module.items) |item| {
            const name = item.name() orelse {
                if (item == .interface_impl) try cx.impls.append(scratch, item.interface_impl);
                continue;
            };
            const sid = cx.syms.resolveVisible(item.fileName(), name) orelse continue;
            try cx.decls.put(scratch, sid, item);
        }
        for (an.module.items) |item| {
            const b = builders.get(item.fileName()) orelse continue;
            var w = Walker.init(&cx, b);
            defer w.deinit();
            w.walkItem(item);
        }
        // Lambdas that were not reached from where they are written.
        for (an.module.items) |item| {
            const f = switch (item) {
                .function => |f| f,
                else => continue,
            };
            if (!isLambda(f.name)) continue;
            const b = builders.get(f.file_name) orelse continue;
            const sid = cx.syms.resolveVisible(f.file_name, f.name) orelse continue;
            if (cx.lambdas_done.contains(sid)) continue;
            try cx.lambdas_done.put(scratch, sid, {});
            var w = Walker.init(&cx, b);
            defer w.deinit();
            w.walkFunction(f, .none, .decl);
        }
    } else {
        // Nothing was checked (the root file does not parse). Only the files that did
        // not parse can be indexed: they have nothing in them.
        var it = builders.iterator();
        while (it.next()) |e| {
            const parsed = for (an.files) |f| {
                if (std.mem.eql(u8, f.path, e.key_ptr.*)) break f.parsed;
            } else true;
            if (parsed) e.value_ptr.*.failed = true;
        }
    }

    // Import edges, for the files each index depends on.
    var edges: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    for (an.module.items) |item| switch (item) {
        .import => |imp| {
            const to = imp.resolved_file orelse continue;
            const gop = try edges.getOrPut(scratch, imp.file_name);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(scratch, to);
        },
        else => {},
    };

    var it = builders.iterator();
    while (it.next()) |e| {
        const b = e.value_ptr.*;
        if (b.failed) continue;
        const idx = try finish(gpa, scratch, b, files, edges, if (an.symbols) |s| s else null);
        b.file = ""; // the arena now belongs to the index
        try out.append(gpa, idx);
    }
    return out.toOwnedSlice(gpa);
}

fn finish(
    gpa: Allocator,
    scratch: Allocator,
    b: *Builder,
    files: std.StringHashMapUnmanaged(FileInfo),
    edges: std.StringHashMapUnmanaged(std.ArrayList([]const u8)),
    syms: ?sema.SymbolTable,
) !*FileIndex {
    const a = b.alloc();
    std.mem.sort(Occ, b.occs.items, {}, occLess);
    // One entry per name: the same place for the same target is recorded once (a
    // declaration sorts first and wins).
    var n: usize = 0;
    for (b.occs.items) |o| {
        if (n > 0) {
            const prev = b.occs.items[n - 1];
            if (prev.start == o.start and prev.target == o.target) continue;
        }
        b.occs.items[n] = o;
        n += 1;
    }

    var visible: std.ArrayList([]const u8) = .empty;
    if (syms) |s| {
        if (s.visible_names.get(b.file)) |vis| {
            var vit = vis.keyIterator();
            while (vit.next()) |k| try visible.append(a, try a.dupe(u8, k.*));
        }
        if (s.namespaces.get(b.file)) |ns| {
            var nit = ns.keyIterator();
            while (nit.next()) |k| try visible.append(a, try a.dupe(u8, k.*));
        }
    }

    // Every non-std file this one imports, directly or not.
    var deps: std.ArrayList(Dep) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    try stack.append(scratch, b.file);
    try seen.put(scratch, b.file, {});
    while (stack.pop()) |f| {
        const list = edges.get(f) orelse continue;
        for (list.items) |to| {
            if (seen.contains(to)) continue;
            try seen.put(scratch, to, {});
            const fi = files.get(to) orelse continue;
            if (fi.is_std) continue;
            try deps.append(a, .{ .key = try a.dupe(u8, fi.key), .path = try a.dupe(u8, fi.name), .hash = textHash(fi.source) });
            try stack.append(scratch, to);
        }
    }

    const path = try a.dupe(u8, b.file);
    const idx = try gpa.create(FileIndex);
    // Everything above lives in the builder's arena, which moves into the index.
    idx.* = .{
        .arena = b.arena,
        .key = b.key,
        .path = path,
        .hash = textHash(b.source),
        .deps = deps.items,
        .targets = b.targets.items,
        .occs = b.occs.items[0..n],
        .visible = visible.items,
        .glob_from = b.globs.items,
    };
    return idx;
}

// The language server side

const DiskEntry = struct { text: []u8, hash: u64, mtime: i96, size: u64 };

const TopSym = struct { name: []const u8, container: ?[]const u8, kind: u8, start: u32, end: u32 };

const TopList = struct {
    arena: std.heap.ArenaAllocator,
    hash: u64,
    syms: []const TopSym,
};

/// What the server keeps between requests.
pub const State = struct {
    /// Reference indexes by path key.
    indexes: std.StringHashMapUnmanaged(*FileIndex) = .empty,
    /// Texts of project files read from disk, by path key.
    disk: std.StringHashMapUnmanaged(DiskEntry) = .empty,
    /// Top level declarations of a file (parsed only), for workspace symbols.
    tops: std.StringHashMapUnmanaged(*TopList) = .empty,
    /// The names the embedded runtime declares (visible in every file).
    runtime_names: std.StringHashMapUnmanaged(void) = .empty,
    /// Project roots already told that they have too many files.
    warned: std.StringHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *State, gpa: Allocator) void {
        var it = self.indexes.valueIterator();
        while (it.next()) |idx| idx.*.destroy(gpa);
        self.indexes.deinit(gpa);
        var dit = self.disk.iterator();
        while (dit.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.text);
        }
        self.disk.deinit(gpa);
        var tit = self.tops.iterator();
        while (tit.next()) |e| {
            gpa.free(e.key_ptr.*);
            var arena = e.value_ptr.*.arena;
            gpa.destroy(e.value_ptr.*);
            arena.deinit();
        }
        self.tops.deinit(gpa);
        var rit = self.runtime_names.keyIterator();
        while (rit.next()) |k| gpa.free(k.*);
        self.runtime_names.deinit(gpa);
        var wit = self.warned.keyIterator();
        while (wit.next()) |k| gpa.free(k.*);
        self.warned.deinit(gpa);
    }

    fn install(self: *State, gpa: Allocator, idx: *FileIndex) void {
        const gop = self.indexes.getOrPut(gpa, idx.key) catch {
            idx.destroy(gpa);
            return;
        };
        const old: ?*FileIndex = if (gop.found_existing) gop.value_ptr.* else null;
        gop.key_ptr.* = idx.key;
        gop.value_ptr.* = idx;
        if (old) |o| o.destroy(gpa);
    }

    fn dropDisk(self: *State, gpa: Allocator, key: []const u8) void {
        if (self.disk.fetchRemove(key)) |kv| {
            gpa.free(kv.key);
            gpa.free(kv.value.text);
        }
    }
};

/// A file of the project in one request: its current text (the editor's if it is open).
const PFile = struct { path: []const u8, key: []const u8, text: []const u8, hash: u64 };

/// The work of one request.
const Req = struct {
    server: *lsp.Server,
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    files: std.ArrayList(PFile) = .empty,
    by_key: std.StringHashMapUnmanaged(u32) = .empty,
    root: ?[]const u8 = null,
    scanned: bool = false,
    capped: bool = false,
    analyses: u32 = 0,
    std_dir: ?[]const u8 = null,

    fn init(server: *lsp.Server) Req {
        var r = Req{ .server = server, .gpa = server.gpa, .arena_state = std.heap.ArenaAllocator.init(server.gpa) };
        r.std_dir = stdDirKey(r.arena_state.allocator());
        return r;
    }

    fn deinit(r: *Req) void {
        r.arena_state.deinit();
    }

    fn a(r: *Req) Allocator {
        return r.arena_state.allocator();
    }

    fn st(r: *Req) *State {
        return &r.server.nav;
    }

    /// The project of a document: the folder with `build.fels` (or the workspace folder,
    /// as the server found it), else the document's folder.
    fn forDoc(r: *Req, doc: *lsp.Doc) ?u32 {
        r.root = doc.project_root orelse std.fs.path.dirname(doc.path);
        return r.file(doc.key, doc.path);
    }

    fn isStd(r: *Req, key: []const u8) bool {
        const d = r.std_dir orelse return false;
        return std.mem.startsWith(u8, key, d);
    }

    /// The file with this key, its text read now if it was not yet.
    fn file(r: *Req, key: []const u8, path: []const u8) ?u32 {
        if (r.by_key.get(key)) |i| return i;
        var text: []const u8 = undefined;
        var hash: u64 = 0;
        if (r.server.by_key.get(key)) |doc| {
            text = doc.text;
            hash = textHash(text);
        } else {
            const e = r.diskText(key, path) orelse return null;
            text = e.text;
            hash = e.hash;
        }
        const i: u32 = @intCast(r.files.items.len);
        const k = r.a().dupe(u8, key) catch return null;
        const p = r.a().dupe(u8, path) catch return null;
        r.files.append(r.a(), .{ .path = p, .key = k, .text = text, .hash = hash }) catch return null;
        r.by_key.put(r.a(), k, i) catch {};
        return i;
    }

    /// The text of a file on disk, read again only when its size or time changed.
    fn diskText(r: *Req, key: []const u8, path: []const u8) ?DiskEntry {
        const io = r.server.io;
        const s = r.st();
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
            s.dropDisk(r.gpa, key);
            return null;
        };
        if (s.disk.get(key)) |e| {
            if (e.mtime == stat.mtime.nanoseconds and e.size == stat.size) return e;
        }
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, r.gpa, .unlimited) catch return null;
        const entry: DiskEntry = .{ .text = text, .hash = textHash(text), .mtime = stat.mtime.nanoseconds, .size = stat.size };
        if (s.disk.getEntry(key)) |e| {
            r.gpa.free(e.value_ptr.text);
            e.value_ptr.* = entry;
        } else {
            const owned = r.gpa.dupe(u8, key) catch {
                r.gpa.free(text);
                return null;
            };
            s.disk.put(r.gpa, owned, entry) catch {
                r.gpa.free(owned);
                r.gpa.free(text);
                return null;
            };
        }
        return entry;
    }

    /// Add every `.fels` file under the project root.
    fn scan(r: *Req) void {
        if (r.scanned) return;
        r.scanned = true;
        const root = r.root orelse return;
        const io = r.server.io;
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var walker = dir.walkSelectively(r.a()) catch return;
        defer walker.deinit();
        var paths: std.ArrayList([]const u8) = .empty;
        var seen: usize = 0;
        var errors: usize = 0;
        while (true) {
            const maybe = walker.next(io) catch {
                errors += 1;
                if (errors > 64) break;
                continue;
            };
            const entry = maybe orelse break;
            seen += 1;
            if (seen > max_entries) {
                r.capped = true;
                break;
            }
            switch (entry.kind) {
                .directory => if (!skipDir(entry.basename)) walker.enter(io, entry) catch {},
                .file => {
                    if (!pipeline.isSourceFile(entry.basename)) continue;
                    if (paths.items.len >= max_files) {
                        r.capped = true;
                        break;
                    }
                    const p = std.fs.path.join(r.a(), &.{ root, entry.path }) catch continue;
                    paths.append(r.a(), p) catch {};
                },
                else => {},
            }
        }
        std.mem.sort([]const u8, paths.items, {}, lessStr);
        for (paths.items) |p| {
            const k = lsp.pathKey(r.a(), p) catch continue;
            if (r.isStd(k)) continue;
            _ = r.file(k, p);
        }
    }

    fn index(r: *Req, key: []const u8) ?*FileIndex {
        return r.st().indexes.get(key);
    }

    /// Whether an index still describes the texts of its file and of what it imports.
    fn valid(r: *Req, idx: *const FileIndex) bool {
        const i = r.file(idx.key, idx.path) orelse return false;
        if (r.files.items[i].hash != idx.hash) return false;
        for (idx.deps) |d| {
            const j = r.file(d.key, d.path) orelse return false;
            if (r.files.items[j].hash != d.hash) return false;
        }
        return true;
    }

    /// Make the indexes of these files current.
    fn ensure(r: *Req, want: []const u32) void {
        var todo: std.StringHashMapUnmanaged(void) = .empty;
        var order: std.ArrayList(u32) = .empty;
        for (want) |i| {
            const f = r.files.items[i];
            if (todo.contains(f.key)) continue;
            if (r.index(f.key)) |idx| if (r.valid(idx)) continue;
            todo.put(r.a(), f.key, {}) catch return;
            order.append(r.a(), i) catch return;
        }
        if (todo.count() == 0) return;

        // The analyses of the open documents are current: the server ran them before
        // this request.
        var dit = r.server.docs.valueIterator();
        while (dit.next()) |dp| {
            const doc = dp.*;
            if (doc.analysis == null) continue;
            var touches = todo.contains(doc.key);
            for (doc.deps) |d| {
                if (todo.contains(d)) touches = true;
            }
            if (!touches) continue;
            r.indexFrom(&doc.analysis.?, &todo);
            if (todo.count() == 0) return;
        }

        // Then analyses of our own, the files that import the others first, so one
        // analysis covers what it imports.
        r.sortByReach(order.items, &todo);
        for (order.items) |i| {
            const f = r.files.items[i];
            if (!todo.contains(f.key)) continue;
            var an = pipeline.analyzeFile(r.gpa, f.path, .{
                .reader = r.server.reader(),
                .project_root = r.root,
            }) catch continue;
            defer an.deinit();
            r.analyses += 1;
            r.indexFrom(&an, &todo);
            if (todo.contains(f.key)) {
                // Nothing came out of it: remember the file as empty, not to try again.
                r.installEmpty(f);
                _ = todo.remove(f.key);
            }
        }
    }

    fn indexFrom(r: *Req, an: *const pipeline.Analysis, todo: *std.StringHashMapUnmanaged(void)) void {
        r.noteRuntime(an);
        const list = indexAnalysis(r.gpa, an, todo) catch return;
        defer r.gpa.free(list);
        for (list) |idx| {
            if (r.valid(idx)) {
                _ = todo.remove(idx.key);
                r.st().install(r.gpa, idx);
            } else {
                idx.destroy(r.gpa);
            }
        }
    }

    fn installEmpty(r: *Req, f: PFile) void {
        const idx = r.gpa.create(FileIndex) catch return;
        idx.* = .{ .arena = std.heap.ArenaAllocator.init(r.gpa), .key = "", .path = "", .hash = f.hash };
        const ia = idx.arena.allocator();
        idx.key = ia.dupe(u8, f.key) catch "";
        idx.path = ia.dupe(u8, f.path) catch "";
        r.st().install(r.gpa, idx);
    }

    fn noteRuntime(r: *Req, an: *const pipeline.Analysis) void {
        const s = r.st();
        if (s.runtime_names.count() > 0) return;
        const syms = an.symbols orelse return;
        for (syms.symbols.items) |sym| {
            if (sym.scope_id != syms.root_scope or !std.mem.eql(u8, sym.file_name, "<runtime>")) continue;
            if (s.runtime_names.contains(sym.name)) continue;
            const owned = r.gpa.dupe(u8, sym.name) catch return;
            s.runtime_names.put(r.gpa, owned, {}) catch r.gpa.free(owned);
        }
    }

    /// Sort files so that those importing more of the others (by the `#import` lines of
    /// their text) come first.
    fn sortByReach(r: *Req, order: []u32, todo: *const std.StringHashMapUnmanaged(void)) void {
        if (order.len < 2) return;
        const reach = r.a().alloc(u32, r.files.items.len) catch return;
        @memset(reach, 0);
        for (order) |i| {
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            var stack: std.ArrayList(u32) = .empty;
            stack.append(r.a(), i) catch return;
            while (stack.pop()) |j| {
                var imports: std.ArrayList([]const u8) = .empty;
                r.textImports(r.files.items[j], &imports);
                for (imports.items) |k| {
                    if (seen.contains(k) or !todo.contains(k)) continue;
                    seen.put(r.a(), k, {}) catch return;
                    if (r.by_key.get(k)) |next| stack.append(r.a(), next) catch return;
                }
            }
            reach[i] = seen.count();
        }
        const SortCtx = struct {
            reach: []const u32,
            fn less(ctx: @This(), x: u32, y: u32) bool {
                if (ctx.reach[x] != ctx.reach[y]) return ctx.reach[x] > ctx.reach[y];
                return x < y;
            }
        };
        std.mem.sort(u32, order, SortCtx{ .reach = reach }, SortCtx.less);
    }

    /// Keys of the project files a file names in its `#import` lines (read from the text,
    /// without parsing).
    fn textImports(r: *Req, f: PFile, out: *std.ArrayList([]const u8)) void {
        var lines = std.mem.splitScalar(u8, f.text, '\n');
        while (lines.next()) |line0| {
            const line = std.mem.trimStart(u8, line0, " \t");
            if (!std.mem.startsWith(u8, line, "#import")) continue;
            const rest = std.mem.trimStart(u8, line["#import".len..], " \t");
            var end: usize = 0;
            while (end < rest.len and (isIdent(rest[end]) or rest[end] == '.')) end += 1;
            const module = std.mem.trimEnd(u8, rest[0..end], ".");
            if (module.len == 0 or std.mem.eql(u8, module, "std") or std.mem.startsWith(u8, module, "std.")) continue;
            const stem = r.a().alloc(u8, module.len) catch return;
            for (module, 0..) |c, i| stem[i] = if (c == '.') std.fs.path.sep else c;
            const bases = [_]?[]const u8{ std.fs.path.dirname(f.path), r.root };
            for ([_][]const u8{ pipeline.source_ext, pipeline.old_ext }) |ext| {
                const rel = std.mem.concat(r.a(), u8, &.{ stem, ext }) catch return;
                for (bases) |base| {
                    const b = base orelse continue;
                    const p = std.fs.path.join(r.a(), &.{ b, rel }) catch continue;
                    const k = lsp.pathKey(r.a(), p) catch continue;
                    out.append(r.a(), k) catch {};
                }
            }
        }
    }

    /// The files (by index) whose text has one of these names as a word, and the file
    /// that declares the target.
    fn candidates(r: *Req, names: []const []const u8, also: ?[]const u8, globs: bool) []u32 {
        var out: std.ArrayList(u32) = .empty;
        for (r.files.items, 0..) |f, i| {
            var hit = false;
            for (names) |n| {
                if (containsWord(f.text, n)) hit = true;
            }
            if (!hit and also != null and std.mem.eql(u8, f.key, also.?)) hit = true;
            if (!hit and globs and std.mem.indexOf(u8, f.text, ".*") != null) hit = true;
            if (hit) out.append(r.a(), @intCast(i)) catch {};
        }
        return out.items;
    }

    /// The files that can refer to `t`: its own file when it is not public, else every
    /// project file that has one of the names as a word.
    fn searchFiles(r: *Req, t: Target, names: []const []const u8, globs: bool) []const u32 {
        if (!t.public) if (r.by_key.get(t.file)) |di| {
            const one = r.a().alloc(u32, 1) catch return &.{};
            one[0] = di;
            return one;
        };
        r.scan();
        return r.candidates(names, t.file, globs);
    }

    const Hit = struct { file: u32, occ: Occ };

    /// Every name in these files that means `t`.
    fn collect(r: *Req, t: Target, files: []const u32) []Hit {
        var out: std.ArrayList(Hit) = .empty;
        for (files) |i| {
            const idx = r.index(r.files.items[i].key) orelse continue;
            for (idx.occs) |o| {
                if (idx.targets[o.target].same(t)) out.append(r.a(), .{ .file = i, .occ = o }) catch {};
            }
        }
        return out.items;
    }

    fn uriOf(r: *Req, i: u32) []const u8 {
        const f = r.files.items[i];
        if (r.server.by_key.get(f.key)) |doc| return doc.uri;
        return lsp.pathToUri(r.a(), f.path) catch f.path;
    }

    fn warnIfCapped(r: *Req) void {
        if (!r.capped) return;
        const root = r.root orelse return;
        const s = r.st();
        if (s.warned.contains(root)) return;
        const owned = r.gpa.dupe(u8, root) catch return;
        s.warned.put(r.gpa, owned, {}) catch {
            r.gpa.free(owned);
            return;
        };
        const msg = std.fmt.allocPrint(r.a(), "gabbro: the project {s} has more than {d} .fels files; references, rename and workspace symbols only look at the first {d}.", .{ root, max_files, max_files }) catch return;
        var b: std.ArrayList(u8) = .empty;
        defer b.deinit(r.gpa);
        b.appendSlice(r.gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"window/showMessage\",\"params\":{\"type\":2,\"message\":\"") catch return;
        lsp.escapeInto(&b, r.gpa, msg);
        b.appendSlice(r.gpa, "\"}}") catch return;
        lsp.send(r.server, b.items);
    }

    /// The name under the cursor of a document and what it means.
    const Here = struct { file: u32, occ: Occ, t: Target };

    fn at(r: *Req, doc: *lsp.Doc, off: usize) ?Here {
        const i = r.forDoc(doc) orelse return null;
        r.ensure(&.{i});
        const idx = r.index(doc.key) orelse return null;
        const o = idx.occAt(off) orelse return null;
        var t = idx.targets[o.target];
        // A copy that outlives a later replacement of the index.
        t.file = r.a().dupe(u8, t.file) catch return null;
        t.name = r.a().dupe(u8, t.name) catch return null;
        // A std file opened in the editor is analyzed as a root, not marked as std.
        if (t.fixed == .no and r.isStd(t.file)) t.fixed = .std_lib;
        return .{ .file = i, .occ = o, .t = t };
    }

    fn lineOf(r: *Req, i: u32, off: usize) u32 {
        return lsp.byteToPos(r.files.items[i].text, off).line + 1;
    }
};

fn skipDir(name: []const u8) bool {
    const skip = [_][]const u8{ "zig-out", ".zig-cache", "zig-cache", ".git", ".claude", "dist", "out", ".jj", "node_modules" };
    return contains(&skip, name);
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// Path key of the standard library folder, with a trailing `/`.
fn stdDirKey(a: Allocator) ?[]const u8 {
    const root = pipeline.stdlib_root_override orelse build_options.stdlib_root;
    if (root.len == 0) return null;
    const dir = std.fs.path.join(a, &.{ root, "std" }) catch return null;
    const key = lsp.pathKey(a, dir) catch return null;
    return std.fmt.allocPrint(a, "{s}/", .{key}) catch null;
}

// Requests

pub fn handles(method: []const u8) bool {
    const names = [_][]const u8{
        "textDocument/references",
        "textDocument/prepareRename",
        "textDocument/rename",
        "textDocument/documentHighlight",
        "workspace/symbol",
        "textDocument/didSave",
        "workspace/didChangeWatchedFiles",
    };
    return contains(&names, method);
}

pub fn dispatch(server: *lsp.Server, method: []const u8, id: ?json.Value, params: json.Value) void {
    const t0 = clock.monoNs();
    var r = Req.init(server);
    defer r.deinit();
    if (std.mem.eql(u8, method, "textDocument/references")) {
        references(&r, id, params);
    } else if (std.mem.eql(u8, method, "textDocument/prepareRename")) {
        prepareRename(&r, id, params);
    } else if (std.mem.eql(u8, method, "textDocument/rename")) {
        rename(&r, id, params);
    } else if (std.mem.eql(u8, method, "textDocument/documentHighlight")) {
        highlight(&r, id, params);
    } else if (std.mem.eql(u8, method, "workspace/symbol")) {
        workspaceSymbol(&r, id, params);
    } else {
        saved(server, params);
        return;
    }
    if (server.timing) {
        const ms = @as(f64, @floatFromInt(clock.sinceNs(t0))) / 1_000_000.0;
        std.debug.print("gabbro-lsp: {s} in {d:.1} ms ({d} files, {d} analyses)\n", .{ method, ms, r.files.items.len, r.analyses });
    }
}

/// A file was saved (or changed on disk): read it again next time.
fn saved(server: *lsp.Server, params: json.Value) void {
    var uris: [64][]const u8 = undefined;
    var n: usize = 0;
    if (lsp.objGet(params, "textDocument")) |td| if (lsp.getStr(td, "uri")) |u| {
        uris[n] = u;
        n += 1;
    };
    if (lsp.objGet(params, "changes")) |changes| switch (changes) {
        .array => |arr| for (arr.items) |c| {
            if (n == uris.len) break;
            if (lsp.getStr(c, "uri")) |u| {
                uris[n] = u;
                n += 1;
            }
        },
        else => {},
    };
    for (uris[0..n]) |u| {
        const path = lsp.uriToPath(server.gpa, u) catch continue;
        defer server.gpa.free(path);
        const key = lsp.pathKey(server.gpa, path) catch continue;
        defer server.gpa.free(key);
        server.nav.dropDisk(server.gpa, key);
    }
}

const code_invalid_params = -32602;
const code_request_failed = -32803;

fn sendError(server: *lsp.Server, id: ?json.Value, code: i32, msg: []const u8) void {
    const gpa = server.gpa;
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    b.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    lsp.idToBuf(&b, gpa, id);
    b.print(gpa, ",\"error\":{{\"code\":{d},\"message\":\"", .{code}) catch return;
    lsp.escapeInto(&b, gpa, msg);
    b.appendSlice(gpa, "\"}}") catch return;
    lsp.send(server, b.items);
}

fn includeDeclaration(params: json.Value) bool {
    const ctx = lsp.objGet(params, "context") orelse return true;
    const v = lsp.objGet(ctx, "includeDeclaration") orelse return true;
    return switch (v) {
        .bool => |x| x,
        else => true,
    };
}

fn appendLocation(r: *Req, b: *std.ArrayList(u8), i: u32, o: Occ) void {
    const gpa = r.gpa;
    b.appendSlice(gpa, "{\"uri\":\"") catch {};
    lsp.escapeInto(b, gpa, r.uriOf(i));
    b.appendSlice(gpa, "\",\"range\":") catch {};
    lsp.appendRange(b, gpa, r.files.items[i].text, Span.new(o.start, o.end));
    b.append(gpa, '}') catch {};
}

fn references(r: *Req, id: ?json.Value, params: json.Value) void {
    const server = r.server;
    const doc = lsp.docFromParams(server, params) orelse return lsp.sendResult(server, id, "null");
    const off = lsp.cursorOffset(doc, params) orelse return lsp.sendResult(server, id, "null");
    const here = r.at(doc, off) orelse return lsp.sendResult(server, id, "[]");
    const with_decl = includeDeclaration(params);
    const files = r.searchFiles(here.t, &.{here.t.name}, false);
    r.ensure(files);
    const hits = r.collect(here.t, files);

    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(r.gpa);
    b.append(r.gpa, '[') catch {};
    var first = true;
    // A declaration outside the project (in `std`) is still the declaration.
    if (with_decl and here.t.fixed != .runtime) {
        const has_decl = for (hits) |h| {
            if (h.occ.role == .decl) break true;
        } else false;
        if (!has_decl) if (r.file(here.t.file, here.t.file)) |di| {
            if (wordAt(r.files.items[di].text, here.t.offset, here.t.name)) {
                appendLocation(r, &b, di, .{ .start = here.t.offset, .end = @intCast(here.t.offset + here.t.name.len), .target = 0, .role = .decl });
                first = false;
            }
        };
    }
    for (hits) |h| {
        if (!with_decl and h.occ.role == .decl) continue;
        if (!first) b.append(r.gpa, ',') catch {};
        first = false;
        appendLocation(r, &b, h.file, h.occ);
    }
    b.append(r.gpa, ']') catch {};
    lsp.sendResult(server, id, b.items);
    r.warnIfCapped();
}

fn highlight(r: *Req, id: ?json.Value, params: json.Value) void {
    const server = r.server;
    const doc = lsp.docFromParams(server, params) orelse return lsp.sendResult(server, id, "null");
    const off = lsp.cursorOffset(doc, params) orelse return lsp.sendResult(server, id, "null");
    const here = r.at(doc, off) orelse return lsp.sendResult(server, id, "[]");
    const idx = r.index(doc.key) orelse return lsp.sendResult(server, id, "[]");

    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(r.gpa);
    b.append(r.gpa, '[') catch {};
    var first = true;
    for (idx.occs) |o| {
        if (!idx.targets[o.target].same(here.t)) continue;
        if (!first) b.append(r.gpa, ',') catch {};
        first = false;
        b.appendSlice(r.gpa, "{\"range\":") catch {};
        lsp.appendRange(&b, r.gpa, doc.text, Span.new(o.start, o.end));
        // DocumentHighlightKind: 2 Read, 3 Write.
        const kind: u8 = if (o.role == .read) 2 else 3;
        b.print(r.gpa, ",\"kind\":{d}}}", .{kind}) catch {};
    }
    b.append(r.gpa, ']') catch {};
    lsp.sendResult(server, id, b.items);
}

fn fixedReason(t: Target) ?[]const u8 {
    return switch (t.fixed) {
        .no => null,
        .std_lib => "it is declared in the standard library",
        .runtime => "it is part of the compiler's runtime",
        .external => "it is an `#extern` declaration",
        .exported => "it is exported under its own name (`#export`)",
        .entry => "the program is started through this name",
    };
}

fn prepareRename(r: *Req, id: ?json.Value, params: json.Value) void {
    const server = r.server;
    const doc = lsp.docFromParams(server, params) orelse return lsp.sendResult(server, id, "null");
    const off = lsp.cursorOffset(doc, params) orelse return lsp.sendResult(server, id, "null");
    const here = r.at(doc, off) orelse return sendError(server, id, code_request_failed, "There is no name to rename here.");
    if (fixedReason(here.t)) |why| {
        const msg = std.fmt.allocPrint(r.a(), "`{s}` cannot be renamed: {s}.", .{ here.t.name, why }) catch return;
        return sendError(server, id, code_request_failed, msg);
    }
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(r.gpa);
    b.appendSlice(r.gpa, "{\"range\":") catch {};
    lsp.appendRange(&b, r.gpa, doc.text, Span.new(here.occ.start, here.occ.end));
    b.appendSlice(r.gpa, ",\"placeholder\":\"") catch {};
    lsp.escapeInto(&b, r.gpa, here.t.name);
    b.appendSlice(r.gpa, "\"}") catch {};
    lsp.sendResult(server, id, b.items);
}

/// Why `name` cannot be a new name, or null.
pub fn badName(a: Allocator, name: []const u8) ?[]const u8 {
    if (name.len == 0) return "The new name is empty.";
    const ok_start = std.ascii.isAlphabetic(name[0]) or name[0] == '_';
    var ok = ok_start;
    for (name) |c| {
        if (!isIdent(c)) ok = false;
    }
    if (!ok) return std.fmt.allocPrint(a, "`{s}` is not a valid name: use letters, digits and `_`, not starting with a digit.", .{name}) catch "Not a valid name.";
    if (lexer.keywordKind(name) != .ident) return std.fmt.allocPrint(a, "`{s}` is a keyword.", .{name}) catch "A keyword.";
    if (sema.fromBuiltinName(name) != null) return std.fmt.allocPrint(a, "`{s}` is the name of a built-in type.", .{name}) catch "A built-in type.";
    if (isBuiltinCall(name)) return std.fmt.allocPrint(a, "`{s}` is the name of a compiler builtin.", .{name}) catch "A builtin.";
    return null;
}

fn rename(r: *Req, id: ?json.Value, params: json.Value) void {
    const server = r.server;
    const doc = lsp.docFromParams(server, params) orelse return lsp.sendResult(server, id, "null");
    const off = lsp.cursorOffset(doc, params) orelse return lsp.sendResult(server, id, "null");
    const new_name = lsp.getStr(params, "newName") orelse return sendError(server, id, code_invalid_params, "newName is missing.");
    const here = r.at(doc, off) orelse return sendError(server, id, code_request_failed, "There is no name to rename here.");
    if (fixedReason(here.t)) |why| {
        const msg = std.fmt.allocPrint(r.a(), "`{s}` cannot be renamed: {s}.", .{ here.t.name, why }) catch return;
        return sendError(server, id, code_request_failed, msg);
    }
    if (badName(r.a(), new_name)) |msg| return sendError(server, id, code_invalid_params, msg);
    if (std.mem.eql(u8, new_name, here.t.name)) return lsp.sendResult(server, id, "{\"changes\":{}}");

    const files = r.searchFiles(here.t, &.{ here.t.name, new_name }, true);
    r.ensure(files);
    const hits = r.collect(here.t, files);
    if (conflict(r, here.t, hits, new_name, files)) |msg| return sendError(server, id, code_request_failed, msg);

    // `{"changes":{uri:[edit,…],…}}`, the edits of one file together.
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(r.gpa);
    b.appendSlice(r.gpa, "{\"changes\":{") catch {};
    var first_file = true;
    for (files) |fi| {
        var first_edit = true;
        var last_start: u32 = std.math.maxInt(u32);
        for (hits) |h| {
            if (h.file != fi or h.occ.start == last_start) continue;
            last_start = h.occ.start;
            if (first_edit) {
                if (!first_file) b.append(r.gpa, ',') catch {};
                first_file = false;
                b.append(r.gpa, '"') catch {};
                lsp.escapeInto(&b, r.gpa, r.uriOf(fi));
                b.appendSlice(r.gpa, "\":[") catch {};
            } else b.append(r.gpa, ',') catch {};
            first_edit = false;
            b.appendSlice(r.gpa, "{\"range\":") catch {};
            lsp.appendRange(&b, r.gpa, r.files.items[fi].text, Span.new(h.occ.start, h.occ.end));
            b.appendSlice(r.gpa, ",\"newText\":\"") catch {};
            lsp.escapeInto(&b, r.gpa, new_name);
            b.appendSlice(r.gpa, "\"}") catch {};
        }
        if (!first_edit) b.append(r.gpa, ']') catch {};
    }
    b.appendSlice(r.gpa, "}}") catch {};
    lsp.sendResult(server, id, b.items);
    r.warnIfCapped();
}

/// Why renaming `t` to `n` would change what some name means, or null.
fn conflict(r: *Req, t: Target, hits: []const Req.Hit, n: []const u8, files: []const u32) ?[]const u8 {
    const a = r.a();
    const decl_file = r.by_key.get(t.file);
    switch (t.kind) {
        .field, .variant, .interface_method, .method => {
            // Another member of the same type.
            const idx = r.index(t.file) orelse return null;
            for (idx.targets) |x| {
                if (x.owner != t.owner or x.owner == no_owner or !x.kind.isMember()) continue;
                if (!std.mem.eql(u8, x.file, t.file) or !std.mem.eql(u8, x.name, n)) continue;
                const line = if (decl_file) |di| r.lineOf(di, x.offset) else 0;
                return std.fmt.allocPrint(a, "The type already has a {s} named `{s}` (line {d}).", .{ x.kind.label(), n, line }) catch "Name taken.";
            }
            // A method is found before a free function of the same name, so `x.n()` calls
            // of a function `n` would go to the renamed method.
            if (t.kind == .method and idx.isVisible(n)) {
                return std.fmt.allocPrint(a, "A function `{s}` is visible in {s}; `x.{s}()` calls of it would call the renamed method.", .{ n, std.fs.path.basename(idx.path), n }) catch "Name taken.";
            }
            return null;
        },
        .local, .param, .type_param => {
            const idx = r.index(t.file) orelse return null;
            const di = decl_file orelse return null;
            // A local named `n` declared inside the scope of `t` would hide it where it is used.
            for (idx.targets) |x| {
                if (!x.kind.isLocal() or !std.mem.eql(u8, x.name, n) or x.same(t)) continue;
                if (x.offset <= t.offset or x.offset >= t.scope_end) continue;
                for (hits) |h| {
                    if (h.file != di) continue;
                    if (h.occ.start >= x.offset and h.occ.start < x.scope_end) {
                        return std.fmt.allocPrint(a, "`{s}` is declared on line {d}, where `{s}` is used (line {d}): the rename would change what that use means.", .{ n, r.lineOf(di, x.offset), t.name, r.lineOf(di, h.occ.start) }) catch "Name taken.";
                    }
                }
            }
            // A use of `n` in the scope of `t` that means something declared outside it.
            for (idx.occs) |o| {
                if (o.start <= t.offset or o.start >= t.scope_end or o.qualified) continue;
                const x = idx.targets[o.target];
                if (!std.mem.eql(u8, x.name, n) or x.kind.isMember()) continue;
                if (std.mem.eql(u8, x.file, t.file) and x.offset >= t.offset and x.offset < t.scope_end) continue;
                return std.fmt.allocPrint(a, "`{s}` on line {d} means another {s}; it would mean the renamed `{s}` instead.", .{ n, r.lineOf(di, o.start), x.kind.label(), t.name }) catch "Name taken.";
            }
            return null;
        },
        else => {
            if (r.st().runtime_names.contains(n)) return std.fmt.allocPrint(a, "`{s}` is declared by the compiler's runtime.", .{n}) catch "Name taken.";
            for (files) |fi| {
                const f = r.files.items[fi];
                const idx = r.index(f.key) orelse continue;
                var uses = false;
                for (hits) |h| {
                    if (h.file == fi and !h.occ.qualified) uses = true;
                }
                if (!uses and !std.mem.eql(u8, f.key, t.file) and !idx.globs(t.file)) continue;
                if (idx.isVisible(n)) {
                    return std.fmt.allocPrint(a, "`{s}` is already declared or imported in {s}.", .{ n, std.fs.path.basename(f.path) }) catch "Name taken.";
                }
                // A local named `n` around a use would hide the renamed symbol.
                for (idx.targets) |x| {
                    if (!x.kind.isLocal() or !std.mem.eql(u8, x.name, n)) continue;
                    for (hits) |h| {
                        if (h.file != fi or h.occ.qualified) continue;
                        if (h.occ.start >= x.offset and h.occ.start < x.scope_end) {
                            return std.fmt.allocPrint(a, "A local `{s}` ({s} line {d}) would hide `{s}` used on line {d}.", .{ n, std.fs.path.basename(f.path), r.lineOf(fi, x.offset), t.name, r.lineOf(fi, h.occ.start) }) catch "Name taken.";
                        }
                    }
                }
            }
            return null;
        },
    }
}

// Workspace symbols

fn parseTops(gpa: Allocator, path: []const u8, text: []const u8) ?*TopList {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    var list: std.ArrayList(TopSym) = .empty;
    if (parser.Parser.init(a, path, text, 1)) |p0| {
        var p = p0;
        if (p.parseModule()) |m| {
            for (m.items) |item| {
                const name = item.name() orelse continue;
                if (isLambda(name)) continue;
                const short = shortName(name);
                const span = item.span();
                if (!wordAt(text, nameStart(text, span, short), short)) continue;
                const pos = nameStart(text, span, short);
                const container: ?[]const u8 = if (short.len != name.len) name[0 .. name.len - short.len - 1] else null;
                // SymbolKind: 5 Class, 6 Method, 10 Enum, 11 Interface, 12 Function,
                // 13 Variable, 14 Constant, 23 Struct.
                const kind: u8 = switch (item) {
                    .function => if (container != null) 6 else 12,
                    .type_decl => |d| switch (d.kind) {
                        .struct_type => 23,
                        .enum_type, .errors => 10,
                        .interface_type => 11,
                        else => 5,
                    },
                    .const_decl => |d| if (d.is_mutable) 13 else 14,
                    else => continue,
                };
                list.append(a, .{ .name = short, .container = container, .kind = kind, .start = @intCast(pos), .end = @intCast(pos + short.len) }) catch break;
            }
        } else |_| {}
    } else |_| {}
    const tl = gpa.create(TopList) catch {
        arena.deinit();
        return null;
    };
    tl.* = .{ .arena = arena, .hash = textHash(text), .syms = list.items };
    return tl;
}

fn topsFor(r: *Req, f: PFile) ?*TopList {
    const s = r.st();
    if (s.tops.get(f.key)) |tl| if (tl.hash == f.hash) return tl;
    const tl = parseTops(r.gpa, f.path, f.text) orelse return null;
    if (s.tops.getEntry(f.key)) |e| {
        var old = e.value_ptr.*.arena;
        r.gpa.destroy(e.value_ptr.*);
        old.deinit();
        e.value_ptr.* = tl;
    } else {
        const owned = r.gpa.dupe(u8, f.key) catch return null;
        s.tops.put(r.gpa, owned, tl) catch {
            r.gpa.free(owned);
            return null;
        };
    }
    return tl;
}

fn matchesQuery(name: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > name.len) return false;
    var i: usize = 0;
    while (i + query.len <= name.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(name[i .. i + query.len], query)) return true;
    }
    return false;
}

fn workspaceSymbol(r: *Req, id: ?json.Value, params: json.Value) void {
    const server = r.server;
    const query = lsp.getStr(params, "query") orelse "";
    // The projects of the open documents, and the workspace folder.
    var roots: std.ArrayList([]const u8) = .empty;
    var it = server.docs.valueIterator();
    while (it.next()) |dp| {
        const doc = dp.*;
        const root = doc.project_root orelse std.fs.path.dirname(doc.path) orelse continue;
        roots.append(r.a(), root) catch {};
    }
    if (server.workspace_root) |w| roots.append(r.a(), w) catch {};

    var seen_roots: std.StringHashMapUnmanaged(void) = .empty;
    for (roots.items) |root| {
        const k = lsp.pathKey(r.a(), root) catch continue;
        if (seen_roots.contains(k)) continue;
        seen_roots.put(r.a(), k, {}) catch {};
        r.root = root;
        r.scanned = false;
        r.scan();
        r.warnIfCapped();
        r.capped = false;
    }

    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(r.gpa);
    b.append(r.gpa, '[') catch {};
    var count: usize = 0;
    outer: for (r.files.items, 0..) |f, i| {
        const tl = topsFor(r, f) orelse continue;
        for (tl.syms) |sym| {
            if (!matchesQuery(sym.name, query)) continue;
            if (count == max_symbols) break :outer;
            if (count > 0) b.append(r.gpa, ',') catch {};
            count += 1;
            b.appendSlice(r.gpa, "{\"name\":\"") catch {};
            lsp.escapeInto(&b, r.gpa, sym.name);
            b.print(r.gpa, "\",\"kind\":{d},\"location\":", .{sym.kind}) catch {};
            appendLocation(r, &b, @intCast(i), .{ .start = sym.start, .end = sym.end, .target = 0, .role = .decl });
            if (sym.container) |c| {
                b.appendSlice(r.gpa, ",\"containerName\":\"") catch {};
                lsp.escapeInto(&b, r.gpa, c);
                b.append(r.gpa, '"') catch {};
            }
            b.append(r.gpa, '}') catch {};
        }
    }
    b.append(r.gpa, ']') catch {};
    lsp.sendResult(server, id, b.items);
}

// Tests

const testing = std.testing;

/// An in-memory project: the loader reads these files instead of the disk.
const TestFiles = struct {
    names: []const []const u8,
    texts: []const []const u8,

    fn same(name: []const u8, path: []const u8) bool {
        const rest = if (path.len > 2 and path[0] == '.' and (path[1] == '/' or path[1] == std.fs.path.sep)) path[2..] else path;
        return std.mem.eql(u8, name, rest);
    }

    fn read(ctx: ?*anyopaque, allocator: Allocator, path: []const u8) ?[]const u8 {
        const self: *TestFiles = @ptrCast(@alignCast(ctx.?));
        for (self.names, 0..) |n, i| if (same(n, path)) return allocator.dupe(u8, self.texts[i]) catch null;
        return null;
    }

    fn exists(ctx: ?*anyopaque, path: []const u8) bool {
        const self: *TestFiles = @ptrCast(@alignCast(ctx.?));
        for (self.names) |n| if (same(n, path)) return true;
        return false;
    }

    fn text(self: *TestFiles, name: []const u8) []const u8 {
        for (self.names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return self.texts[i];
        return "";
    }
};

const TestProject = struct {
    files: *TestFiles,
    list: []*FileIndex,

    fn init(files: *TestFiles, root: []const u8) !TestProject {
        var an = try pipeline.analyzeFile(testing.allocator, root, .{
            .reader = .{ .ctx = files, .readFn = TestFiles.read, .existsFn = TestFiles.exists },
            .include_runtime = false,
        });
        defer an.deinit();
        return .{ .files = files, .list = try indexAnalysis(testing.allocator, &an, null) };
    }

    fn deinit(p: *TestProject) void {
        for (p.list) |idx| idx.destroy(testing.allocator);
        testing.allocator.free(p.list);
    }

    fn index(p: *TestProject, name: []const u8) *FileIndex {
        for (p.list) |idx| if (std.mem.endsWith(u8, idx.key, name)) return idx;
        @panic("no index for the file");
    }

    /// What the `nth` (from 0) whole word `word` of file `name` means.
    fn targetAt(p: *TestProject, name: []const u8, word: []const u8, nth: usize) ?Target {
        const src = p.files.text(name);
        var count: usize = 0;
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, src, from, word)) |i| {
            from = i + 1;
            if (!wordAt(src, i, word)) continue;
            if (count == nth) {
                const o = p.index(name).occAt(i) orelse return null;
                return p.index(name).targets[o.target];
            }
            count += 1;
        }
        return null;
    }

    /// How many names in the project mean `t`.
    fn refs(p: *TestProject, t: Target) usize {
        var n: usize = 0;
        for (p.list) |idx| {
            for (idx.occs) |o| {
                if (idx.targets[o.target].same(t)) n += 1;
            }
        }
        return n;
    }
};

test "nav: references of a function used in two files" {
    var files = TestFiles{
        .names = &.{ "util.fels", "main.fels" },
        .texts = &.{
            "pub add :: fn(a: i32, b: i32) -> i32 { return a + b; }\n",
            "#import util.{ add };\nmain :: fn() -> i32 {\n    x := add(1, 2);\n    return add(x, 3);\n}\n",
        },
    };
    var p = try TestProject.init(&files, "main.fels");
    defer p.deinit();
    const t = p.targetAt("main.fels", "add", 1).?;
    try testing.expectEqual(Kind.function, t.kind);
    // The declaration, the import list and two calls.
    try testing.expectEqual(@as(usize, 4), p.refs(t));
    try testing.expect(t.same(p.targetAt("util.fels", "add", 0).?));
}

test "nav: shadowed locals are different symbols" {
    var files = TestFiles{
        .names = &.{"main.fels"},
        .texts = &.{
            "f :: fn() -> i32 {\n    x := 1;\n    y := x;\n    if y > 0 {\n        x := 2;\n        y = x;\n    }\n    return x + y;\n}\n" ++
                "g :: fn() -> i32 {\n    x := 5;\n    return x;\n}\n",
        },
    };
    var p = try TestProject.init(&files, "main.fels");
    defer p.deinit();
    const outer = p.targetAt("main.fels", "x", 0).?;
    const inner = p.targetAt("main.fels", "x", 2).?;
    const in_g = p.targetAt("main.fels", "x", 5).?;
    try testing.expectEqual(Kind.local, outer.kind);
    try testing.expect(!outer.same(inner) and !outer.same(in_g) and !inner.same(in_g));
    try testing.expectEqual(@as(usize, 3), p.refs(outer)); // x := 1, y := x, return x
    try testing.expectEqual(@as(usize, 2), p.refs(inner)); // x := 2, y = x
    try testing.expectEqual(@as(usize, 2), p.refs(in_g));
    try testing.expect(outer.same(p.targetAt("main.fels", "x", 4).?)); // `return x + y`
    // `y = x` in the inner block is a write of the outer `y`.
    const y = p.targetAt("main.fels", "y", 2).?;
    try testing.expectEqual(@as(usize, 4), p.refs(y));
    const idx = p.index("main.fels");
    const o = idx.occAt(std.mem.indexOf(u8, files.text("main.fels"), "y = x").?).?;
    try testing.expectEqual(Role.write, o.role);
}

test "nav: a struct field in a literal, an access and a method" {
    var files = TestFiles{
        .names = &.{"main.fels"},
        .texts = &.{
            "Point :: struct {\n    x: i32,\n    y: i32,\n    sum :: fn(self: *Point) -> i32 { return self.x + self.y; }\n}\n" ++
                "make :: fn() -> Point { return .{ .x = 1, .y = 2 }; }\n" ++
                "main :: fn() -> i32 {\n    p: Point = .{ .x = 3, .y = 4 };\n    q := make();\n    return p.x + q.sum();\n}\n",
        },
    };
    var p = try TestProject.init(&files, "main.fels");
    defer p.deinit();
    const x = p.targetAt("main.fels", "x", 0).?;
    try testing.expectEqual(Kind.field, x.kind);
    // The field, `self.x`, two literals and `p.x`.
    try testing.expectEqual(@as(usize, 5), p.refs(x));
    const sum = p.targetAt("main.fels", "sum", 1).?;
    try testing.expectEqual(Kind.method, sum.kind);
    try testing.expectEqual(@as(usize, 2), p.refs(sum));
    const point = p.targetAt("main.fels", "Point", 0).?;
    try testing.expectEqual(@as(usize, 4), p.refs(point));
}

test "nav: enum variants through the type the context expects" {
    var files = TestFiles{
        .names = &.{"main.fels"},
        .texts = &.{
            "Color :: enum { red, green }\n" ++
                "pick :: fn(c: Color) -> i32 {\n    match c {\n        .red => { return 1; }\n        .green => { return 2; }\n    }\n}\n" ++
                "main :: fn() -> i32 {\n    c: Color = .red;\n    d := Color.red;\n    if c == .green { return 0; }\n    return pick(.red);\n}\n",
        },
    };
    var p = try TestProject.init(&files, "main.fels");
    defer p.deinit();
    const red = p.targetAt("main.fels", "red", 0).?;
    try testing.expectEqual(Kind.variant, red.kind);
    try testing.expectEqual(@as(usize, 5), p.refs(red));
    const green = p.targetAt("main.fels", "green", 0).?;
    try testing.expectEqual(@as(usize, 3), p.refs(green));
}

test "nav: names in a generic function are found without the type check" {
    var files = TestFiles{
        .names = &.{"main.fels"},
        .texts = &.{
            "Box :: struct($T: type) {\n    item: T,\n    n: i32,\n    get :: fn(self: *Self) -> T { return self.item; }\n}\n" ++
                "count :: fn($T: type, b: *Box(T)) -> i32 { k := b.n; return k; }\n" ++
                "main :: fn() -> i32 {\n    b: Box(i32) = .{ .item = 1, .n = 2 };\n    return count(i32, &b) + b.n;\n}\n",
        },
    };
    var p = try TestProject.init(&files, "main.fels");
    defer p.deinit();
    const n = p.targetAt("main.fels", "n", 0).?;
    try testing.expectEqual(Kind.field, n.kind);
    try testing.expect(n.same(p.targetAt("main.fels", "n", 1).?)); // b.n in the generic body
    const t = p.targetAt("main.fels", "T", 1).?; // `item: T`
    try testing.expectEqual(Kind.type_param, t.kind);
    // The struct's `$T`, `item: T` and the method's `-> T`; `count` has a `T` of its own.
    try testing.expectEqual(@as(usize, 3), p.refs(t));
    try testing.expect(t.same(p.targetAt("main.fels", "T", 2).?));
    try testing.expect(!t.same(p.targetAt("main.fels", "T", 3).?));
    const item = p.targetAt("main.fels", "item", 0).?;
    try testing.expectEqual(@as(usize, 3), p.refs(item)); // field, `self.item`, `.item = 1`
    const k = p.targetAt("main.fels", "k", 1).?;
    try testing.expectEqual(@as(usize, 2), p.refs(k));
}

test "nav: a `$T` inside a parameter type declares T" {
    var files = TestFiles{
        .names = &.{"main.fels"},
        .texts = &.{
            "get :: fn(p: *$T, q: *$T) -> T { x: T = *p; return x; }\n" ++
                "main :: fn() -> i32 { y: i32 = 1; return get(&y, &y); }\n",
        },
    };
    var p = try TestProject.init(&files, "main.fels");
    defer p.deinit();
    const t = p.targetAt("main.fels", "T", 0).?; // `p: *$T`
    try testing.expectEqual(Kind.type_param, t.kind);
    // The second `$T`, `-> T` and `x: T` are uses of the first.
    try testing.expect(t.same(p.targetAt("main.fels", "T", 1).?));
    try testing.expect(t.same(p.targetAt("main.fels", "T", 2).?));
    try testing.expect(t.same(p.targetAt("main.fels", "T", 3).?));
    try testing.expectEqual(@as(usize, 4), p.refs(t));
}

test "nav: interface methods, their implementations and calls" {
    var files = TestFiles{
        .names = &.{"main.fels"},
        .texts = &.{
            "Show :: interface { val :: fn(self: *Self) -> i32; }\n" ++
                "Good :: struct { z: i32 }\n" ++
                "Good as Show { val :: fn(self: *Self) -> i32 { return self.z; } }\n" ++
                "needs :: fn($T: Show, x: *T) -> i32 { return x.val(); }\n" ++
                "direct :: fn(s: *Show) -> i32 { return s.val(); }\n" ++
                "main :: fn() -> i32 {\n    g: Good = .{ .z = 9 };\n    return needs(&g) + g.val();\n}\n",
        },
    };
    var p = try TestProject.init(&files, "main.fels");
    defer p.deinit();
    const val = p.targetAt("main.fels", "val", 0).?;
    try testing.expectEqual(Kind.interface_method, val.kind);
    // The interface, the implementation, `x.val()` (a constrained generic), `s.val()`
    // through the interface, `g.val()` on the implementing type.
    try testing.expectEqual(@as(usize, 5), p.refs(val));
    const impl = p.index("main.fels").occAt(std.mem.indexOf(u8, files.text("main.fels"), "val :: fn(self: *Self) -> i32 {").?).?;
    try testing.expectEqual(Role.impl, impl.role);
    const show = p.targetAt("main.fels", "Show", 0).?;
    try testing.expectEqual(@as(usize, 4), p.refs(show)); // declaration, `as Show`, `$T: Show`, `*Show`
}

test "nav: alias::name, a lambda capture, catch bindings and error variants" {
    var files = TestFiles{
        .names = &.{ "util.fels", "main.fels" },
        .texts = &.{
            "pub Num :: struct { v: i32 }\npub twice :: fn(n: i32) -> i32 { return n * 2; }\n",
            "#import util as u;\n" ++
                "Err :: errors { .Bad, .Worse }\n" ++
                "risky :: fn(n: i32) -> i32 ! Err {\n    if n < 0 { fail .Bad; }\n    return n;\n}\n" ++
                "main :: fn() -> i32 {\n    n: u::Num = .{ .v = 2 };\n    base := 3;\n" ++
                "    add_base := fn(x: i32) -> i32 { return x + base; };\n" ++
                "    r := risky(n.v) catch e {\n        if e == .Bad { return 1; }\n        return 2;\n    };\n" ++
                "    return u::twice(n.v) + add_base(base) + r;\n}\n",
        },
    };
    var p = try TestProject.init(&files, "main.fels");
    defer p.deinit();
    const twice = p.targetAt("main.fels", "twice", 0).?;
    try testing.expectEqual(@as(usize, 2), p.refs(twice));
    try testing.expect(twice.same(p.targetAt("util.fels", "twice", 0).?));
    const num = p.targetAt("main.fels", "Num", 0).?;
    try testing.expectEqual(@as(usize, 2), p.refs(num));
    const v = p.targetAt("util.fels", "v", 0).?;
    try testing.expectEqual(@as(usize, 4), p.refs(v)); // field, `.v = 2`, two `n.v`
    const base = p.targetAt("main.fels", "base", 0).?;
    try testing.expectEqual(@as(usize, 3), p.refs(base)); // declaration, in the lambda, argument
    const e = p.targetAt("main.fels", "e", 0).?;
    try testing.expectEqual(Kind.local, e.kind);
    try testing.expectEqual(@as(usize, 2), p.refs(e));
    const bad = p.targetAt("main.fels", "Bad", 0).?;
    try testing.expectEqual(Kind.variant, bad.kind);
    try testing.expectEqual(@as(usize, 3), p.refs(bad)); // declaration, `fail .Bad`, `e == .Bad`
}

test "nav: a method #derive generates is no reference to its struct" {
    var files = TestFiles{
        .names = &.{"main.fels"},
        .texts = &.{
            "#derive(Eq)\nPt :: struct { x: i32, t: i32 }\n" ++
                "main :: fn() -> i32 {\n    a: Pt = .{ .x = 1, .t = 2 };\n    b := a;\n    if a.eq(&b) { return 1; }\n    return 0;\n}\n",
        },
    };
    var p = try TestProject.init(&files, "main.fels");
    defer p.deinit();
    const pt = p.targetAt("main.fels", "Pt", 0).?;
    try testing.expectEqual(@as(usize, 2), p.refs(pt));
    const t = p.targetAt("main.fels", "t", 0).?;
    try testing.expectEqual(@as(usize, 2), p.refs(t));
    try testing.expect(p.targetAt("main.fels", "eq", 0) == null);
}

test "nav: names that are not valid new names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(badName(a, "while") != null);
    try testing.expect(badName(a, "i32") != null);
    try testing.expect(badName(a, "9lives") != null);
    try testing.expect(badName(a, "a-b") != null);
    try testing.expect(badName(a, "") != null);
    try testing.expect(badName(a, "total_2") == null);
}

test "nav: words are found outside comments and strings" {
    const src = "a // b\n\"b\" b";
    try testing.expectEqual(@as(?usize, 11), findWord(src, 0, src.len, "b"));
    try testing.expect(containsWord("let total = 1", "total"));
    try testing.expect(!containsWord("subtotal", "total"));
}
