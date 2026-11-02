//! The paged layout, for plan decisions 1 and 2. Decoding: the pointers
//! in pages of 32, 64, or 128, whichever makes the index smallest; a page
//! with no code point is left out, and a page index (u8 when there are
//! few enough pages) gives each page of pointers its place among the
//! pages kept, every empty one sharing one page of zeros. A lookup is a
//! shift, a page number, and a cell, with no check within the page.
//! Encoding: the code points in blocks of 64, a block index for each, and
//! for each block that has any a 64-bit map of them and where its pointers
//! start in a list of pointers in code point order; a lookup is a block, a
//! bit test, and a popcount.

const std = @import("std");
const index = @import("../index.zig");
const layouts = @import("../layouts.zig");
const MultiByte = @import("../sources.zig").MultiByte;

pub fn emit(w: *std.Io.Writer, gpa: std.mem.Allocator, src: MultiByte, entries: []const index.Entry) !void {
    if (src.decode) try emitDecode(w, gpa, entries);
    if (src.encode) try emitEncode(w, gpa, src, entries);
}

const Pages = struct { shift: u5, page_of: []u32, cells: []u21 };

fn build(gpa: std.mem.Allocator, entries: []const index.Entry, shift: u5) !Pages {
    const size = @as(u32, 1) << shift;
    var end: u32 = 0;
    for (entries) |e| end = @max(end, e.pointer + 1);
    const page_of = try gpa.alloc(u32, (end + size - 1) / size);
    @memset(page_of, 0);
    // Page 0 is the empty page.
    var kept: u32 = 1;
    for (entries) |e| {
        if (page_of[e.pointer >> shift] == 0) {
            page_of[e.pointer >> shift] = kept;
            kept += 1;
        }
    }
    const cells = try gpa.alloc(u21, kept * size);
    @memset(cells, 0);
    for (entries) |e| cells[page_of[e.pointer >> shift] << shift | (e.pointer & (size - 1))] = e.cp;
    return .{ .shift = shift, .page_of = page_of, .cells = cells };
}

fn bytes(p: Pages, cp_size: usize) usize {
    const index_size: usize = if (p.cells.len >> p.shift <= 256) 1 else 2;
    return p.page_of.len * index_size + p.cells.len * cp_size;
}

fn emitDecode(w: *std.Io.Writer, gpa: std.mem.Allocator, entries: []const index.Entry) !void {
    var bmp = true;
    for (entries) |e| bmp = bmp and e.cp <= 0xFFFF;
    const cp_size: usize = if (bmp) 2 else 4;
    var best: ?Pages = null;
    for ([_]u5{ 5, 6, 7 }) |shift| {
        const p = try build(gpa, entries, shift);
        if (best == null or bytes(p, cp_size) < bytes(best.?, cp_size)) best = p;
    }
    const p = best.?;
    try w.print(
        \\const shift = {d};
        \\
        \\/// The page of each `1 << shift` pointers in `cells`; 0, a page of
        \\/// zeros, for those with no code point.
        \\const page_of = [{d}]{s}{{
        \\
    , .{ p.shift, p.page_of.len, if (p.cells.len >> p.shift <= 256) "u8" else "u16" });
    try layouts.writeHex(w, u32, p.page_of);
    try w.print(
        \\}};
        \\
        \\/// The code points of the pages, one after another; 0 for none.
        \\const cells = [{d}]{s}{{
        \\
    , .{ p.cells.len, if (bmp) "u16" else "u32" });
    try layouts.writeHex(w, u21, p.cells);
    try w.writeAll(
        \\};
        \\
        \\pub fn decode(pointer: u32) u32 {
        \\    if (pointer >> shift >= page_of.len) return 0;
        \\    const page: u32 = page_of[pointer >> shift];
        \\    return cells[page << shift | (pointer & ((1 << shift) - 1))];
        \\}
        \\
        \\
    );
}

fn emitEncode(w: *std.Io.Writer, gpa: std.mem.Allocator, src: MultiByte, entries: []const index.Entry) !void {
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
