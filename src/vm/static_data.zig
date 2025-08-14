//! Reading a value the comptime VM computed back out of its zones, as data for the image.
//!
//! `X: [256]u32 = #run make_table();` runs `make_table` on the VM, which leaves its result as
//! blocks of cells in a zone. A global is not code that runs at startup, it is bytes the linker
//! places, so the result has to become a `ConstInit` — the same description of constant data a
//! `.{ ... }` literal produces. This is that conversion, guided by the declared type: a struct
//! reads one cell per field, an array reads element `i` at `i * stride`, an enum reads its tag, a
//! function pointer names its function.
//!
//! Only data survives. A pointer into compile-time memory has no address in the image, a closure
//! that captured something has no plain code address, and a slice of anything but bytes has
//! nowhere to point; each of those is refused with a message that says where in the value it is.
const std = @import("std");
const ir = @import("../ir.zig");
const value = @import("value.zig");
const engine = @import("engine.zig");
const compiler = @import("compiler.zig");

const Value = value.Value;
const IrType = ir.IrType;
const ConstInit = ir.ConstInit;

pub const Result = union(enum) {
    ok: ConstInit,
    /// The value cannot be data in the image: why, with where in the value it went wrong.
    rejected: []const u8,
};

/// Convert `result` (what the VM returned for an expression of declared type `ty`) into static
/// data. `vm` must still hold the zones the result points into; every string and list in the
/// answer is allocated with `allocator`, so it outlives the VM.
pub fn decode(
    allocator: std.mem.Allocator,
    vm: *const engine.Vm,
    module: ir.IrModule,
    result: Value,
    ty: IrType,
) std.mem.Allocator.Error!Result {
    var d: Decoder = .{ .allocator = allocator, .vm = vm, .module = module };
    const init = d.read(result, ty, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Rejected => return .{ .rejected = d.problem orelse "the value cannot be stored in static data" },
    };
    return .{ .ok = init };
}

/// One step on the way down to the part being read, so a refusal can say `.table[3].name`.
const Where = struct {
    parent: ?*const Where,
    step: union(enum) { field: []const u8, index: usize },
};

const Decoder = struct {
    allocator: std.mem.Allocator,
    vm: *const engine.Vm,
    module: ir.IrModule,
    problem: ?[]const u8 = null,

    const Error = error{ Rejected, OutOfMemory };

    fn reject(self: *Decoder, at: ?*const Where, comptime fmt: []const u8, args: anytype) Error {
        var path: std.ArrayList(u8) = .empty;
        // The steps are linked child-to-parent; collect them and write them root-first.
        var steps: [32]*const Where = undefined;
        var n: usize = 0;
        var cur = at;
        while (cur) |w| : (cur = w.parent) {
            if (n == steps.len) break;
            steps[n] = w;
            n += 1;
        }
        while (n > 0) {
            n -= 1;
            switch (steps[n].step) {
                .field => |name| path.print(self.allocator, ".{s}", .{name}) catch return error.OutOfMemory,
                .index => |i| path.print(self.allocator, "[{d}]", .{i}) catch return error.OutOfMemory,
            }
        }
        const what = std.fmt.allocPrint(self.allocator, fmt, args) catch return error.OutOfMemory;
        self.problem = if (path.items.len == 0)
            what
        else
            std.fmt.allocPrint(self.allocator, "in `{s}`: {s}", .{ path.items, what }) catch return error.OutOfMemory;
        return error.Rejected;
    }

    fn cell(self: *Decoder, p: Value.Ptr, offset: usize, at: ?*const Where) Error!Value {
        const off = std.math.add(u32, p.offset, std.math.cast(u32, offset) orelse return self.reject(at, "the value is too large", .{})) catch
            return self.reject(at, "the value is too large", .{});
        return self.vm.zone_stack.getCell(p.zone, off) catch return self.reject(at, "the value refers to memory that is gone", .{});
    }

    /// The block a struct, array or enum value points at.
    fn block(self: *Decoder, v: Value, ty: IrType, at: ?*const Where) Error!Value.Ptr {
        return switch (v) {
            .ptr => |p| p,
            .struct_ref => |r| .{ .zone = r.zone, .offset = r.offset },
            else => self.reject(at, "expected {s}, found {s}", .{ typeName(ty), kind(v) }),
        };
    }

    fn read(self: *Decoder, v: Value, ty: IrType, at: ?*const Where) Error!ConstInit {
        // A cell nothing wrote — the part of an array the program left alone, a field it never
        // set — is zero, as an omitted part of a literal is.
        if (v == .void) return switch (ty) {
            .void, .unknown => self.reject(at, "a value of type `{s}` cannot be stored in static data", .{typeName(ty)}),
            else => .zero,
        };
        switch (ty) {
            .i, .u, .byte, .usize, .isize, .addr, .rune => {
                const imm: ir.Imm = switch (v) {
                    .int => |x| .{ .int = x },
                    .uint => |x| .{ .uint = x },
                    else => return self.reject(at, "expected an integer, found {s}", .{kind(v)}),
                };
                const as_int: i128 = switch (imm) {
                    .int => |x| x,
                    .uint => |x| std.math.cast(i128, x) orelse
                        return self.reject(at, "the value {d} does not fit in `{s}`", .{ x, typeName(ty) }),
                    else => unreachable,
                };
                if (ty != .rune and !ir.intFitsType(as_int, ty))
                    return self.reject(at, "the value {d} does not fit in `{s}`", .{ as_int, typeName(ty) });
                return .{ .imm = imm };
            },
            .f32, .f64 => {
                const f: f64 = switch (v) {
                    .float => |x| x,
                    .int => |x| @floatFromInt(x),
                    .uint => |x| @floatFromInt(x),
                    else => return self.reject(at, "expected a floating-point number, found {s}", .{kind(v)}),
                };
                return .{ .imm = .{ .float = f } };
            },
            .bool => switch (v) {
                .bool => |b| return .{ .imm = .{ .bool = b } },
                else => return self.reject(at, "expected a bool, found {s}", .{kind(v)}),
            },
            .text => return self.string(v, at),
            .slice => |elem| {
                if (!isByteType(elem.*))
                    return self.reject(at, "a slice in static data must hold bytes (a string); this holds `{s}`", .{typeName(elem.*)});
                return self.string(v, at);
            },
            .ptr => switch (v) {
                .null_ptr => return .{ .imm = .null },
                else => return self.reject(at, "a pointer computed at compile time points into compile-time memory, which the program does not have; static data can hold `null` or `&NAME`", .{}),
            },
            .optional => switch (v) {
                .null_ptr => return .{ .imm = .null },
                else => return self.reject(at, "an optional that holds a value cannot be stored in static data yet; only `null`", .{}),
            },
            .fn_ptr => return self.function(v, at),
            .array => |arr| return self.array(v, ty, arr, at),
            .struct_type => |name| return self.named(v, ty, name, at),
            else => return self.reject(at, "a value of type `{s}` cannot be stored in static data", .{typeName(ty)}),
        }
    }

    /// A `[]const u8`: a string constant, a byte slice the program built, or bytes in host memory.
    fn string(self: *Decoder, v: Value, at: ?*const Where) Error!ConstInit {
        switch (v) {
            .string => |s| return .{ .imm = .{ .text = try self.allocator.dupe(u8, s) } },
            .slice => |s| {
                const bytes = try self.allocator.alloc(u8, s.len);
                for (bytes, 0..) |*out, i| {
                    const c = try self.cell(.{ .zone = s.zone, .offset = s.offset }, i, at);
                    out.* = switch (c) {
                        .int => |x| std.math.cast(u8, x) orelse return self.reject(at, "byte {d} of the string is {d}, which is not a byte", .{ i, x }),
                        .uint => |x| std.math.cast(u8, x) orelse return self.reject(at, "byte {d} of the string is {d}, which is not a byte", .{ i, x }),
                        else => return self.reject(at, "byte {d} of the string is not a number", .{i}),
                    };
                }
                return .{ .imm = .{ .text = bytes } };
            },
            .host_buf => |hb| {
                if (hb.addr == 0 or hb.len == 0) return .{ .imm = .{ .text = "" } };
                const bytes = try self.allocator.alloc(u8, hb.len);
                const src: [*]const u8 = @ptrFromInt(hb.addr);
                @memcpy(bytes, src[0..hb.len]);
                return .{ .imm = .{ .text = bytes } };
            },
            .null_ptr => return .zero,
            else => return self.reject(at, "expected a string, found {s}", .{kind(v)}),
        }
    }

    /// A function pointer: the function it names, which must have a plain code address.
    fn function(self: *Decoder, v: Value, at: ?*const Where) Error!ConstInit {
        const closure = switch (v) {
            .null_ptr => return .{ .imm = .null },
            .closure => |c| c,
            else => return self.reject(at, "expected a function, found {s}", .{kind(v)}),
        };
        if (closure.takes_env or closure.env != .none)
            return self.reject(at, "a lambda or a closure has no plain code address; declare a named function and use its name", .{});
        if (closure.fn_idx >= self.module.functions.len)
            return self.reject(at, "the function pointer names a function that does not exist", .{});
        return .{ .func_ref = self.module.functions[closure.fn_idx].name };
    }

    fn array(self: *Decoder, v: Value, ty: IrType, arr: ir.ArrayType, at: ?*const Where) Error!ConstInit {
        const base = try self.block(v, ty, at);
        const len = std.math.cast(usize, arr.len) orelse return self.reject(at, "the array is too long", .{});
        const stride = compiler.cellCountOf(self.module, arr.elem.*);
        const items = try self.allocator.alloc(ConstInit, len);
        // The elements are read in order; trailing zeros are dropped afterwards, since an array
        // literal is zero past its last element.
        var used: usize = 0;
        for (items, 0..) |*item, i| {
            const step: Where = .{ .parent = at, .step = .{ .index = i } };
            const c = try self.cell(base, i * stride, &step);
            item.* = try self.read(c, arr.elem.*, &step);
            if (!isZero(item.*)) used = i + 1;
        }
        return .{ .array_init = items[0..used] };
    }

    /// A struct (one cell per field) or an enum (`[tag, payload]`) by name.
    fn named(self: *Decoder, v: Value, ty: IrType, name: []const u8, at: ?*const Where) Error!ConstInit {
        for (self.module.structs) |def| {
            if (!std.mem.eql(u8, def.name, name)) continue;
            const base = try self.block(v, ty, at);
            const fields = try self.allocator.alloc(ir.ConstFieldInit, def.fields.len);
            for (def.fields, 0..) |field, i| {
                const step: Where = .{ .parent = at, .step = .{ .field = field.name } };
                const c = try self.cell(base, i, &step);
                fields[i] = .{ .name = field.name, .value = try self.read(c, field.ty, &step) };
            }
            return .{ .struct_init = .{ .ty_name = name, .fields = fields } };
        }
        for (self.module.variants) |def| {
            if (!std.mem.eql(u8, def.name, name)) continue;
            const base = try self.block(v, ty, at);
            const tag_cell = try self.cell(base, 0, at);
            const tag = tag_cell.asI128() orelse return self.reject(at, "the enum value has no tag", .{});
            if (tag < 0 or tag >= def.variants.len)
                return self.reject(at, "the enum value's tag {d} is not a variant of `{s}`", .{ tag, name });
            const chosen = def.variants[@intCast(tag)];
            if (chosen.payload != null)
                return self.reject(at, "a variant with a payload cannot be stored in static data yet; `{s}.{s}` carries one", .{ name, chosen.name });
            return .{ .variant_tag = @intCast(tag) };
        }
        return self.reject(at, "`{s}` is not a type whose layout is known here", .{name});
    }
};

/// Is this initializer the zero of whatever slot it fills?
fn isZero(init: ConstInit) bool {
    return switch (init) {
        .zero => true,
        .imm => |imm| switch (imm) {
            .int => |x| x == 0,
            .uint => |x| x == 0,
            .bool => |b| !b,
            .null => true,
            // `-0.0` is not the all-zero bytes, so only a positive zero counts.
            .float => |f| @as(u64, @bitCast(f)) == 0,
            .text, .rune => false,
        },
        else => false,
    };
}

fn isByteType(ty: IrType) bool {
    return switch (ty) {
        .byte => true,
        .u, .i => |bits| bits == 8,
        else => false,
    };
}

/// What a VM value is, for a message.
fn kind(v: Value) []const u8 {
    return switch (v) {
        .void => "nothing",
        .int, .uint => "an integer",
        .float => "a floating-point number",
        .bool => "a bool",
        .ptr, .struct_ref, .variant => "an aggregate",
        .slice, .host_buf => "a slice",
        .string => "a string",
        .type_val => "a type",
        .fn_ref, .closure => "a function",
        .null_ptr => "null",
        .host_ptr => "a pointer into host memory",
    };
}

fn typeName(ty: IrType) []const u8 {
    return switch (ty) {
        .i => |b| switch (b) {
            8 => "i8",
            16 => "i16",
            32 => "i32",
            64 => "i64",
            else => "an integer",
        },
        .u => |b| switch (b) {
            8 => "u8",
            16 => "u16",
            32 => "u32",
            64 => "u64",
            else => "an integer",
        },
        .byte => "u8",
        .usize => "usize",
        .isize => "isize",
        .f32 => "f32",
        .f64 => "f64",
        .bool => "bool",
        .text => "a string",
        .rune => "a character",
        .struct_type, .variant_type, .opaque_type, .interface_value => |name| name,
        .array => "an array",
        .slice => "a slice",
        .ptr => "a pointer",
        .optional => "an optional",
        .fn_ptr => "a function pointer",
        .fallible => "a fallible value",
        .list => "a list",
        .map => "a map",
        .range => "a range",
        .zone => "a zone",
        .addr => "an address",
        .void => "void",
        .unknown => "an unknown type",
    };
}
