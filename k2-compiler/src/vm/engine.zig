const std = @import("std");
const instructions = @import("instructions.zig");
const value = @import("value.zig");
const zones = @import("zones.zig");

const Instr = instructions.Instr;
const Opcode = instructions.Opcode;
const BytecodeFunction = instructions.BytecodeFunction;
const BytecodeModule = instructions.BytecodeModule;
const Value = value.Value;

pub const VmError = error{
    DivisionByZero,
    InvalidInstruction,
    StackOverflow,
    StepLimitExceeded,
    OutOfBounds,
    TypeMismatch,
    Unsupported,
    NoModule,
    Trap,
    OutOfMemory,
    NoActiveZone,
    ZoneUnderflow,
};

/// One activation record. Registers are SSA-style temporaries (one per IR
/// result + scratch); locals are the named, mutable parameter/local slots.
const Frame = struct {
    func: *const BytecodeFunction,
    regs: []Value,
    locals: []Value,
    /// Zone-stack depth on entry; the frame unwinds back to this on return.
    zone_watermark: usize,
};

/// The K2 compile-time virtual machine.
pub const Vm = struct {
    allocator: std.mem.Allocator,
    /// Function table for resolving `call`. Optional: a standalone function with
    /// no calls can run without one.
    module: ?*const BytecodeModule = null,
    zone_stack: zones.ZoneStack,
    call_depth: usize = 0,
    max_call_depth: usize = 512,
    /// Guard against runaway comptime loops (mirrors the tree-walker's cap).
    steps: u64 = 0,
    step_limit: u64 = 100_000_000,

    pub fn init(allocator: std.mem.Allocator) Vm {
        return .{ .allocator = allocator, .zone_stack = zones.ZoneStack.init(allocator) };
    }

    pub fn initModule(allocator: std.mem.Allocator, module: *const BytecodeModule) Vm {
        return .{
            .allocator = allocator,
            .module = module,
            .zone_stack = zones.ZoneStack.init(allocator),
        };
    }

    pub fn deinit(self: *Vm) void {
        self.zone_stack.deinit();
    }

    /// Execute a standalone function with no arguments. Kept for the simple
    /// hand-assembled smoke tests.
    pub fn execute(self: *Vm, function: BytecodeFunction) VmError!Value {
        return self.runTop(&function, &.{});
    }

    /// Like `execute`, but does NOT unwind the root zone on the way out, so the
    /// caller can still read the result's zone cells — used by the reifier to
    /// turn a comptime-built `AstBlock` back into front-end AST. All zone
    /// memory is freed by `deinit`.
    pub fn executeKeepZones(self: *Vm, function: BytecodeFunction) VmError!Value {
        if (self.zone_stack.depth() == 0) _ = try self.zone_stack.push("__root");
        return self.run(&function, &.{});
    }

    /// Look up a function by name in the bound module and run it with `args`.
    pub fn call(self: *Vm, name: []const u8, args: []const Value) VmError!Value {
        const mod = self.module orelse return error.NoModule;
        const f = mod.find(name) orelse return error.InvalidInstruction;
        return self.runTop(f, args);
    }

    /// Outermost entry: guarantee an active "root" zone so aggregate/`new`
    /// allocations always have somewhere to live, then unwind it on the way out.
    /// (Nested `call` opcodes reuse the existing zone stack and do not add one.)
    fn runTop(self: *Vm, func: *const BytecodeFunction, args: []const Value) VmError!Value {
        const root_mark = self.zone_stack.depth();
        if (root_mark == 0) _ = try self.zone_stack.push("__root");
        defer self.zone_stack.popTo(root_mark);
        return self.run(func, args);
    }

    /// Run `func`, binding `args` to its parameter slots.
    pub fn run(self: *Vm, func: *const BytecodeFunction, args: []const Value) VmError!Value {
        if (self.call_depth >= self.max_call_depth) return error.StackOverflow;
        self.call_depth += 1;
        defer self.call_depth -= 1;

        const regs = try self.allocator.alloc(Value, func.num_regs);
        defer self.allocator.free(regs);
        @memset(regs, .void);

        const locals = try self.allocator.alloc(Value, func.num_locals);
        defer self.allocator.free(locals);
        @memset(locals, .void);

        // Bind arguments to the leading parameter slots.
        const nparams = @min(args.len, func.num_params);
        for (args[0..nparams], 0..) |arg, i| locals[i] = arg;

        var frame = Frame{
            .func = func,
            .regs = regs,
            .locals = locals,
            .zone_watermark = self.zone_stack.depth(),
        };
        // On any early exit (error), make sure zones this frame opened are freed.
        errdefer self.zone_stack.popTo(frame.zone_watermark);

        return self.interpret(&frame);
    }

    fn interpret(self: *Vm, frame: *Frame) VmError!Value {
        const code = frame.func.instrs;
        const consts = frame.func.constants;
        var pc: usize = 0;

        while (pc < code.len) {
            self.steps += 1;
            if (self.steps > self.step_limit) return error.StepLimitExceeded;

            const inst = code[pc];
            pc += 1;

            switch (inst.op) {
                .nop => {},

                .load_imm => frame.regs[inst.a] = .{ .int = inst.imm },
                .load_const => frame.regs[inst.a] = consts[@intCast(inst.imm)],
                .copy => frame.regs[inst.a] = frame.regs[inst.b],

                // ── Integer arithmetic ───────────────────────────────────
                .add_i, .sub_i, .mul_i, .div_i, .rem_i => {
                    const l = frame.regs[inst.b].asI128() orelse return error.TypeMismatch;
                    const r = frame.regs[inst.c].asI128() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .int = switch (inst.op) {
                        .add_i => l +% r,
                        .sub_i => l -% r,
                        .mul_i => l *% r,
                        .div_i => if (r == 0) return error.DivisionByZero else @divTrunc(l, r),
                        .rem_i => if (r == 0) return error.DivisionByZero else @rem(l, r),
                        else => unreachable,
                    } };
                },
                .neg_i => {
                    const v = frame.regs[inst.b].asI128() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .int = -%v };
                },

                // ── Float arithmetic ─────────────────────────────────────
                .add_f, .sub_f, .mul_f, .div_f => {
                    const l = frame.regs[inst.b].asF64() orelse return error.TypeMismatch;
                    const r = frame.regs[inst.c].asF64() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .float = switch (inst.op) {
                        .add_f => l + r,
                        .sub_f => l - r,
                        .mul_f => l * r,
                        .div_f => l / r,
                        else => unreachable,
                    } };
                },
                .neg_f => {
                    const v = frame.regs[inst.b].asF64() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .float = -v };
                },

                // ── Bitwise & logic ──────────────────────────────────────
                .bit_and, .bit_or, .bit_xor, .shl, .shr => {
                    const l = frame.regs[inst.b].asI128() orelse return error.TypeMismatch;
                    const r = frame.regs[inst.c].asI128() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .int = switch (inst.op) {
                        .bit_and => l & r,
                        .bit_or => l | r,
                        .bit_xor => l ^ r,
                        .shl => l << @as(u7, @intCast(r & 0x7f)),
                        .shr => l >> @as(u7, @intCast(r & 0x7f)),
                        else => unreachable,
                    } };
                },
                .bitnot => {
                    const v = frame.regs[inst.b].asI128() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .int = ~v };
                },
                .not_b => frame.regs[inst.a] = .{ .bool = !frame.regs[inst.b].truthy() },

                // ── Comparison (int) ─────────────────────────────────────
                .eq_i, .ne_i, .lt_i, .le_i, .gt_i, .ge_i => {
                    const l = frame.regs[inst.b].asI128() orelse return error.TypeMismatch;
                    const r = frame.regs[inst.c].asI128() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .bool = switch (inst.op) {
                        .eq_i => l == r,
                        .ne_i => l != r,
                        .lt_i => l < r,
                        .le_i => l <= r,
                        .gt_i => l > r,
                        .ge_i => l >= r,
                        else => unreachable,
                    } };
                },

                // ── Comparison (float) ───────────────────────────────────
                .eq_f, .ne_f, .lt_f, .le_f, .gt_f, .ge_f => {
                    const l = frame.regs[inst.b].asF64() orelse return error.TypeMismatch;
                    const r = frame.regs[inst.c].asF64() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .bool = switch (inst.op) {
                        .eq_f => l == r,
                        .ne_f => l != r,
                        .lt_f => l < r,
                        .le_f => l <= r,
                        .gt_f => l > r,
                        .ge_f => l >= r,
                        else => unreachable,
                    } };
                },

                // ── Casts ────────────────────────────────────────────────
                .cast_to_float => {
                    const v = frame.regs[inst.b].asF64() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .float = v };
                },
                .cast_to_int => {
                    frame.regs[inst.a] = switch (frame.regs[inst.b]) {
                        .float => |f| .{ .int = @intFromFloat(f) },
                        .int => |v| .{ .int = v },
                        .uint => |v| .{ .int = std.math.cast(i128, v) orelse @bitCast(v) },
                        .bool => |bb| .{ .int = @intFromBool(bb) },
                        else => return error.TypeMismatch,
                    };
                },

                // ── Locals ───────────────────────────────────────────────
                .load_local => frame.regs[inst.a] = frame.locals[@intCast(inst.imm)],
                .store_local => frame.locals[@intCast(inst.imm)] = frame.regs[inst.b],

                .load_global, .store_global => return error.Unsupported,

                // ── Control flow ─────────────────────────────────────────
                .jmp => pc = @intCast(inst.imm),
                .br_if => if (frame.regs[inst.a].truthy()) {
                    pc = @intCast(inst.imm);
                },
                .br_if_not => if (!frame.regs[inst.a].truthy()) {
                    pc = @intCast(inst.imm);
                },
                .call => {
                    const mod = self.module orelse return error.NoModule;
                    const idx: usize = @intCast(inst.imm);
                    if (idx >= mod.functions.len) return error.InvalidInstruction;
                    const callee = &mod.functions[idx];
                    const argc: usize = inst.c;
                    const base: usize = inst.b;
                    // Snapshot args (callee.run allocates its own frame).
                    var buf: [16]Value = undefined;
                    const arg_slice = if (argc <= buf.len) buf[0..argc] else try self.allocator.alloc(Value, argc);
                    defer if (argc > buf.len) self.allocator.free(arg_slice);
                    for (0..argc) |i| arg_slice[i] = frame.regs[base + i];
                    frame.regs[inst.a] = try self.run(callee, arg_slice);
                },
                .call_indirect => {
                    const mod = self.module orelse return error.NoModule;
                    const idx: usize = switch (frame.regs[inst.b]) {
                        .fn_ref => |fr| fr,
                        else => return error.TypeMismatch,
                    };
                    if (idx >= mod.functions.len) return error.InvalidInstruction;
                    const callee = &mod.functions[idx];
                    const argc: usize = @intCast(inst.imm);
                    const base: usize = inst.c;
                    var buf: [16]Value = undefined;
                    const arg_slice = if (argc <= buf.len) buf[0..argc] else try self.allocator.alloc(Value, argc);
                    defer if (argc > buf.len) self.allocator.free(arg_slice);
                    for (0..argc) |i| arg_slice[i] = frame.regs[base + i];
                    frame.regs[inst.a] = try self.run(callee, arg_slice);
                },

                .ret => {
                    const result = frame.regs[inst.a];
                    self.zone_stack.popTo(frame.zone_watermark);
                    return result;
                },
                .ret_void => {
                    self.zone_stack.popTo(frame.zone_watermark);
                    return .void;
                },

                // ── Zones ────────────────────────────────────────────────
                .zone_push => {
                    const name = constName(consts, inst.imm);
                    _ = try self.zone_stack.push(name);
                },
                .zone_pop => try self.zone_stack.pop(),
                .zone_alloc => {
                    frame.regs[inst.a] = try self.zone_stack.alloc(@intCast(inst.imm));
                },
                .field_addr => {
                    const base = try asPtr(frame.regs[inst.b]);
                    frame.regs[inst.a] = .{ .ptr = .{
                        .zone = base.zone,
                        .offset = base.offset + @as(u32, @intCast(inst.imm)),
                    } };
                },
                .load_cell => {
                    const base = try asPtr(frame.regs[inst.b]);
                    frame.regs[inst.a] = try self.zone_stack.getCell(base.zone, base.offset + @as(u32, @intCast(inst.imm)));
                },
                .store_cell => {
                    const base = try asPtr(frame.regs[inst.a]);
                    try self.zone_stack.setCell(base.zone, base.offset + @as(u32, @intCast(inst.imm)), frame.regs[inst.b]);
                },
                .index_addr => {
                    const base = try asPtr(frame.regs[inst.b]);
                    const index = frame.regs[inst.c].asI128() orelse return error.TypeMismatch;
                    const stride: i128 = @intCast(inst.imm);
                    frame.regs[inst.a] = .{ .ptr = .{
                        .zone = base.zone,
                        .offset = base.offset + @as(u32, @intCast(index * stride)),
                    } };
                },
                .slice_make => {
                    const base = try asPtr(frame.regs[inst.b]);
                    const len = frame.regs[inst.c].asI128() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .slice = .{
                        .zone = base.zone,
                        .offset = base.offset,
                        .len = @intCast(len),
                    } };
                },
                .slice_len => {
                    frame.regs[inst.a] = switch (frame.regs[inst.b]) {
                        .slice => |s| .{ .uint = s.len },
                        else => return error.TypeMismatch,
                    };
                },
                .opt_is_some => frame.regs[inst.a] = .{ .bool = switch (frame.regs[inst.b]) {
                    .null_ptr => false,
                    else => true,
                } },
                .interface_method => {
                    const mod = self.module orelse return error.NoModule;
                    const iface = try asPtr(frame.regs[inst.b]);
                    const vt_cell = try self.zone_stack.getCell(iface.zone, iface.offset + 1);
                    const vt_idx: usize = switch (vt_cell) {
                        .uint => |u| @intCast(u),
                        .int => |i| @intCast(i),
                        else => return error.TypeMismatch,
                    };
                    const method_idx: usize = @intCast(inst.imm);
                    if (vt_idx >= mod.vtables.len) return error.InvalidInstruction;
                    const vt = mod.vtables[vt_idx];
                    if (method_idx >= vt.len) return error.InvalidInstruction;
                    frame.regs[inst.a] = .{ .fn_ref = vt[method_idx] };
                },

                // ── System ───────────────────────────────────────────────
                .sys_print => printValue(frame.regs[inst.a]),
                .trap => return error.Trap,
            }
        }

        // Fell off the end without an explicit terminator.
        self.zone_stack.popTo(frame.zone_watermark);
        return .void;
    }
};

fn asPtr(v: Value) VmError!Value.Ptr {
    return switch (v) {
        .ptr => |p| p,
        .struct_ref => |r| .{ .zone = r.zone, .offset = r.offset },
        .slice => |s| .{ .zone = s.zone, .offset = s.offset },
        else => error.TypeMismatch,
    };
}

fn constName(consts: []const Value, imm: i64) []const u8 {
    if (imm < 0 or imm >= consts.len) return "<zone>";
    return switch (consts[@intCast(imm)]) {
        .string => |s| s,
        else => "<zone>",
    };
}

fn printValue(v: Value) void {
    switch (v) {
        .int => |x| std.debug.print("{d}\n", .{x}),
        .uint => |x| std.debug.print("{d}\n", .{x}),
        .float => |x| std.debug.print("{d}\n", .{x}),
        .bool => |x| std.debug.print("{}\n", .{x}),
        .string => |x| std.debug.print("{s}\n", .{x}),
        else => std.debug.print("{any}\n", .{v}),
    }
}
