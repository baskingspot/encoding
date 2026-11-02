//! The paged layout, for plan decisions 1 and 2. Decoding: the pointers
//! in pages of 32, 64, or 128, whichever makes the index smallest; a page
//! with no code point is left out, and a page index (u8 when there are
//! few enough pages) gives each page of pointers its place among the
//! pages kept, every empty one sharing one page of zeros. A lookup is a
//! shift, a page number, and a cell, with no check within the page.
//! Encoding: as the two-level layout does (japanese_rows.zig), a 64-bit
//! map of each 64 code points and a popcount into the pointers in code
//! point order.

const std = @import("std");
const index = @import("../index.zig");
const layouts = @import("../layouts.zig");
const rows = @import("japanese_rows.zig");
const MultiByte = @import("../sources.zig").MultiByte;

pub fn emit(w: *std.Io.Writer, gpa: std.mem.Allocator, src: MultiByte, entries: []const index.Entry) !void {
    if (src.decode) try emitDecode(w, gpa, entries);
    if (src.encode) try rows.emitEncode(w, gpa, src, entries);
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
        \\pub fn decode(pointer: u32) ?u21 {
        \\    if (pointer >> shift >= page_of.len) return null;
        \\    const page: u32 = page_of[pointer >> shift];
        \\    const cp = cells[page << shift | (pointer & ((1 << shift) - 1))];
        \\    // An early return: `if (cp == 0) null else cp` costs callers a
        \\    // trip through memory for the optional.
        \\    if (cp == 0) return null;
        \\    return @intCast(cp);
        \\}
        \\
        \\
    );
}
