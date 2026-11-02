//! The two-level layout, for plan decisions 1 and 2. Decoding: the
//! pointers in rows of 64 or 128, whichever makes the index smaller, each
//! row trimmed to the cells it has, and one u32 per row saying where its
//! cells start and which they are; a lookup is a shift, a row, and a
//! cell. (Rows of the indexes' own widths, 94, 157, or 190, save under 1%
//! more and cost a division.) Encoding: the code points in blocks of 64,
//! a block index for each, and for each block that has any a 64-bit map of
//! them and where its pointers start in a list of pointers in code point
//! order; a lookup is a block, a bit test, and a popcount.

const std = @import("std");
const index = @import("../index.zig");
const layouts = @import("../layouts.zig");
const MultiByte = @import("../sources.zig").MultiByte;

pub fn emit(w: *std.Io.Writer, gpa: std.mem.Allocator, src: MultiByte, entries: []const index.Entry) !void {
    if (src.decode) try emitDecode(w, gpa, entries);
    if (src.encode) try emitEncode(w, gpa, src, entries);
}

/// The row widths tried.
const widths = [_]u32{ 64, 128 };

const Rows = struct { width: u32, rows: []u32, cells: []u21 };

fn buildRows(gpa: std.mem.Allocator, entries: []const index.Entry, width: u32) !Rows {
    var end: u32 = 0;
    for (entries) |e| end = @max(end, e.pointer + 1);
    const n = (end + width - 1) / width;
    const lo = try gpa.alloc(u32, n);
    defer gpa.free(lo);
    const hi = try gpa.alloc(u32, n);
    defer gpa.free(hi);
    @memset(lo, std.math.maxInt(u32));
    @memset(hi, 0);
    for (entries) |e| {
        const r = e.pointer / width;
        lo[r] = @min(lo[r], e.pointer % width);
        hi[r] = @max(hi[r], e.pointer % width + 1);
    }
    const rows = try gpa.alloc(u32, n);
    var total: u32 = 0;
    for (rows, lo, hi) |*row, l, h| {
        if (h == 0) {
            row.* = 0;
            continue;
        }
        if (total > 0xFFFF) return error.TooManyCells;
        row.* = total << 16 | l << 8 | (h - l);
        total += h - l;
    }
    const cells = try gpa.alloc(u21, total);
    @memset(cells, 0);
    for (entries) |e| {
        const row = rows[e.pointer / width];
        cells[(row >> 16) + e.pointer % width - (row >> 8 & 0xFF)] = e.cp;
    }
    return .{ .width = width, .rows = rows, .cells = cells };
}

/// `decode`: the rows, at the width that takes the fewest bytes.
pub fn emitDecode(w: *std.Io.Writer, gpa: std.mem.Allocator, entries: []const index.Entry) !void {
    var bmp = true;
    for (entries) |e| bmp = bmp and e.cp <= 0xFFFF;
    const cp_size: usize = if (bmp) 2 else 4;
    var best: ?Rows = null;
    for (widths) |width| {
        const r = buildRows(gpa, entries, width) catch |err| switch (err) {
            error.TooManyCells => continue,
            else => return err,
        };
        const bytes = r.rows.len * 4 + r.cells.len * cp_size;
        if (best == null or bytes < best.?.rows.len * 4 + best.?.cells.len * cp_size) best = r;
    }
    const r = best orelse return error.TooManyCells;
    try w.print(
        \\const shift = {d};
        \\
        \\/// Each row of `1 << shift` pointers: where its cells start in `cells`
        \\/// (the high 16 bits), its first cell (8 bits), and how many it has
        \\/// (the low 8 bits).
        \\const rows = [{d}]u32{{
        \\
    , .{ std.math.log2_int(u32, r.width), r.rows.len });
    try layouts.writeHex(w, u32, r.rows);
    try w.print(
        \\}};
        \\
        \\/// The code points of the rows' cells; 0 for none.
        \\const cells = [{d}]{s}{{
        \\
    , .{ r.cells.len, if (bmp) "u16" else "u32" });
    try layouts.writeHex(w, u21, r.cells);
    try w.writeAll(
        \\};
        \\
        \\pub fn decode(pointer: u32) ?u21 {
        \\    const r = pointer >> shift;
        \\    if (r >= rows.len) return null;
        \\    const row = rows[r];
        \\    const k = (pointer & ((1 << shift) - 1)) -% (row >> 8 & 0xFF);
        \\    if (k >= (row & 0xFF)) return null;
        \\    const cp = cells[(row >> 16) + k];
        \\    // An early return: `if (cp == 0) null else cp` costs callers a
        \\    // trip through memory for the optional.
        \\    if (cp == 0) return null;
        \\    return @intCast(cp);
        \\}
        \\
        \\
    );
}

pub fn emitEncode(w: *std.Io.Writer, gpa: std.mem.Allocator, src: MultiByte, entries: []const index.Entry) !void {
    const pairs = try layouts.encodePairs(gpa, src, entries);
    defer gpa.free(pairs);
    const top_len = pairs[pairs.len - 1].cp / 64 + 1;
    const top = try gpa.alloc(u32, top_len);
    defer gpa.free(top);
    @memset(top, 0);
    // Block 0 is the empty block every block with no code point uses.
    var bits: std.ArrayList(u64) = .empty;
    defer bits.deinit(gpa);
    var bases: std.ArrayList(u32) = .empty;
    defer bases.deinit(gpa);
    try bits.append(gpa, 0);
    try bases.append(gpa, 0);
    const pointers = try gpa.alloc(u32, pairs.len);
    defer gpa.free(pointers);
    for (pairs, 0..) |p, i| {
        const b = p.cp / 64;
        if (top[b] == 0) {
            top[b] = @intCast(bits.items.len);
            try bits.append(gpa, 0);
            try bases.append(gpa, @intCast(i));
        }
        bits.items[top[b]] |= @as(u64, 1) << @intCast(p.cp % 64);
        pointers[i] = p.pointer;
    }
    try w.print(
        \\/// The block of each 64 code points, 0 for one with none.
        \\const block_of = [{d}]{s}{{
        \\
    , .{ top_len, if (bits.items.len <= 256) "u8" else "u16" });
    try layouts.writeHex(w, u32, top);
    try w.print(
        \\}};
        \\
        \\/// Each block's code points, a bit each.
        \\const block_bits = [{d}]u64{{
        \\
    , .{bits.items.len});
    // Four to a line: `layouts.writeHex`'s dozen is too wide for u64.
    for (bits.items, 0..) |v, i| {
        if (i % 4 == 0) try w.writeAll("   ");
        try w.print(" 0x{X:0>16},", .{v});
        if (i % 4 == 3 or i == bits.items.len - 1) try w.writeAll("\n");
    }
    try w.print(
        \\}};
        \\
        \\/// Where each block's pointers start in `encode_pointers`.
        \\const block_base = [{d}]u16{{
        \\
    , .{bases.items.len});
    try layouts.writeHex(w, u32, bases.items);
    try w.print(
        \\}};
        \\
        \\/// The index pointer of each code point, in code point order.
        \\const encode_pointers = [{d}]u16{{
        \\
    , .{pointers.len});
    try layouts.writeHex(w, u32, pointers);
    try w.writeAll(
        \\};
        \\
        \\pub fn encode(cp: u21) ?u16 {
        \\    const hi = cp >> 6;
        \\    if (hi >= block_of.len) return null;
        \\    const b = block_of[hi];
        \\    const map = block_bits[b];
        \\    const bit = @as(u64, 1) << @intCast(cp & 63);
        \\    if (map & bit == 0) return null;
        \\    return encode_pointers[block_base[b] + @popCount(map & (bit - 1))];
        \\}
        \\
    );
}
