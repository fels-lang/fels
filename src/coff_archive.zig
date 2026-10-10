//! Write a static library (`.lib`): a `!<arch>` archive holding COFF objects and a symbol
//! table, the format lld-link and link.exe read. `b.static(...)` in build.fels uses it.

const std = @import("std");

pub const Member = struct {
    /// The member's name inside the archive (shown by the linker in messages).
    name: []const u8,
    /// The COFF object file.
    data: []const u8,
};

const header_len = 60;

/// An index entry that marks an archive written by `gabbro build`. No object defines it, so it
/// never pulls a member in; the build reads it to tell a Gabbro library from a C library (which
/// needs the C runtime).
pub const gabbro_marker = "__gabbro_static_library";

/// The external symbols an object defines (what another object can link against).
pub fn definedSymbols(arena: std.mem.Allocator, obj: []const u8) ![]const []const u8 {
    if (obj.len < 20) return error.NotCoff;
    const sym_ptr = std.mem.readInt(u32, obj[8..12], .little);
    const sym_count = std.mem.readInt(u32, obj[12..16], .little);
    const strtab = std.math.add(usize, sym_ptr, std.math.mul(usize, sym_count, 18) catch return error.NotCoff) catch return error.NotCoff;
    if (strtab > obj.len) return error.NotCoff;

    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < sym_count) : (i += 1) {
        const s = obj[sym_ptr + i * 18 ..][0..18];
        const section = std.mem.readInt(i16, s[12..14], .little);
        const storage_class = s[16];
        const aux = s[17];
        // IMAGE_SYM_CLASS_EXTERNAL in a section (a definition, not an undefined reference).
        if (storage_class == 2 and section > 0) {
            const name = if (std.mem.readInt(u32, s[0..4], .little) == 0) blk: {
                const off = strtab + std.mem.readInt(u32, s[4..8], .little);
                if (off >= obj.len) return error.NotCoff;
                break :blk std.mem.sliceTo(obj[off..], 0);
            } else std.mem.sliceTo(s[0..8], 0);
            try out.append(arena, name);
        }
        i += aux;
    }
    return out.toOwnedSlice(arena);
}

fn writeHeader(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, name: []const u8, size: usize) !void {
    var h: [header_len]u8 = @splat(' ');
    @memcpy(h[0..name.len], name);
    h[16] = '0'; // date
    h[28] = '0'; // uid
    h[34] = '0'; // gid
    @memcpy(h[40..43], "644"); // mode
    _ = std.fmt.bufPrint(h[48..58], "{d}", .{size}) catch unreachable;
    h[58] = '`';
    h[59] = '\n';
    try buf.appendSlice(gpa, &h);
}

/// The short name of a member: at most 15 characters and a trailing `/`.
fn memberName(name: []const u8, out: *[16]u8) []const u8 {
    const base = std.fs.path.basename(name);
    const n = @min(base.len, 15);
    @memcpy(out[0..n], base[0..n]);
    out[n] = '/';
    return out[0 .. n + 1];
}

/// Build the archive bytes for `members`. The caller owns the result.
pub fn write(gpa: std.mem.Allocator, members: []const Member) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const syms = try arena.alloc([]const []const u8, members.len);
    var sym_total: usize = 0;
    var names_len: usize = 0;
    for (members, syms, 0..) |m, *s, i| {
        const defined = try definedSymbols(arena, m.data);
        // The marker goes with the first member.
        s.* = if (i == 0) try std.mem.concat(arena, []const u8, &.{ &.{gabbro_marker}, defined }) else defined;
        sym_total += s.len;
        for (s.*) |n| names_len += n.len + 1;
    }

    // The first linker member: a big-endian count, the offset of the member holding each
    // symbol, then the symbol names.
    const table_size = 4 + 4 * sym_total + names_len;
    var offset: usize = 8 + header_len + table_size + (table_size & 1);
    const offsets = try arena.alloc(usize, members.len);
    for (members, offsets) |m, *o| {
        o.* = offset;
        offset += header_len + m.data.len + (m.data.len & 1);
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "!<arch>\n");
    try writeHeader(&buf, gpa, "/", table_size);
    var be: [4]u8 = undefined;
    std.mem.writeInt(u32, &be, @intCast(sym_total), .big);
    try buf.appendSlice(gpa, &be);
    for (syms, offsets) |s, o| for (s) |_| {
        std.mem.writeInt(u32, &be, @intCast(o), .big);
        try buf.appendSlice(gpa, &be);
    };
    for (syms) |s| for (s) |n| {
        try buf.appendSlice(gpa, n);
        try buf.append(gpa, 0);
    };
    if (table_size & 1 != 0) try buf.append(gpa, '\n');

    for (members) |m| {
        var name_buf: [16]u8 = undefined;
        try writeHeader(&buf, gpa, memberName(m.name, &name_buf), m.data.len);
        try buf.appendSlice(gpa, m.data);
        if (m.data.len & 1 != 0) try buf.append(gpa, '\n');
    }
    return buf.toOwnedSlice(gpa);
}

test "an archive lists the defined external symbols of its object" {
    // A minimal COFF object: a header, no sections, three symbols and a string table.
    var obj: [20 + 3 * 18 + 4 + 24]u8 = @splat(0);
    std.mem.writeInt(u32, obj[8..12], 20, .little); // symbol table right after the header
    std.mem.writeInt(u32, obj[12..16], 3, .little);
    const syms = obj[20..];
    // 1. `add`, defined in section 1, external.
    @memcpy(syms[0..3], "add");
    std.mem.writeInt(i16, syms[12..14], 1, .little);
    syms[16] = 2;
    // 2. `puts`, undefined (section 0): not listed.
    @memcpy(syms[18..22], "puts");
    syms[18 + 16] = 2;
    // 3. a long name from the string table, defined.
    std.mem.writeInt(u32, syms[36 + 4 ..][0..4], 4, .little);
    std.mem.writeInt(i16, syms[36 + 12 ..][0..2], 1, .little);
    syms[36 + 16] = 2;
    const strtab = obj[20 + 54 ..];
    std.mem.writeInt(u32, strtab[0..4], 28, .little);
    @memcpy(strtab[4..24], "a_rather_long_symbol");

    const lib = try write(std.testing.allocator, &.{.{ .name = "util.o", .data = &obj }});
    defer std.testing.allocator.free(lib);

    try std.testing.expectEqualStrings("!<arch>\n", lib[0..8]);
    try std.testing.expectEqualStrings("/ ", lib[8..10]);
    const table = lib[8 + header_len ..];
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, table[0..4], .big));
    const member_at = std.mem.readInt(u32, table[4..8], .big);
    try std.testing.expectEqual(member_at, std.mem.readInt(u32, table[8..12], .big));
    try std.testing.expectEqual(member_at, std.mem.readInt(u32, table[12..16], .big));
    const names = gabbro_marker ++ "\x00add\x00a_rather_long_symbol\x00";
    try std.testing.expectEqualStrings(names, table[16 .. 16 + names.len]);
    try std.testing.expectEqualStrings("util.o/ ", lib[member_at..][0..8]);
    try std.testing.expectEqualSlices(u8, &obj, lib[member_at + header_len ..][0..obj.len]);
}
