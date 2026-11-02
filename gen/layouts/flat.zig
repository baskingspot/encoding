//! The flat layout, the baseline: the decode table an array of code
//! points indexed by pointer (u16, or u32 for an index with astral code
//! points), and the encode table every code point sorted, with its
//! pointer, searched by bisection.

const std = @import("std");
const index = @import("../index.zig");
const layouts = @import("../layouts.zig");
const MultiByte = @import("../sources.zig").MultiByte;

pub fn emit(w: *std.Io.Writer, gpa: std.mem.Allocator, src: MultiByte, entries: []const index.Entry) !void {
    var end: u32 = 0;
    var bmp = true;
    for (entries) |e| {
        end = @max(end, e.pointer + 1);
        if (e.cp > 0xFFFF) bmp = false;
    }
    const cp_type = if (bmp) "u16" else "u32";
    if (src.decode) {
        const table = try gpa.alloc(u21, end);
        defer gpa.free(table);
        @memset(table, 0);
        for (entries) |e| table[e.pointer] = e.cp;
        try w.print(
            \\/// The code point of each pointer; 0 for none.
            \\const decode_table = [{d}]{s}{{
            \\
        , .{ end, cp_type });
        try layouts.writeHex(w, u21, table);
        try w.writeAll(
            \\};
            \\
            \\pub fn decode(pointer: u32) u32 {
            \\    if (pointer >= decode_table.len) return 0;
            \\    return decode_table[pointer];
            \\}
            \\
            \\
        );
    }
    if (src.encode) {
        const pairs = try layouts.encodePairs(gpa, src, entries);
        defer gpa.free(pairs);
        const cps = try gpa.alloc(u21, pairs.len);
        defer gpa.free(cps);
        const ptrs = try gpa.alloc(u21, pairs.len);
        defer gpa.free(ptrs);
        for (pairs, cps, ptrs) |p, *c, *q| {
            c.* = p.cp;
            q.* = @intCast(p.pointer);
        }
        try w.print(
            "/// Each code point in the index, sorted.\nconst encode_cps = [{d}]{s}{{\n",
            .{ pairs.len, cp_type },
        );
        try layouts.writeHex(w, u21, cps);
        try w.print(
            "}};\n\n/// The index pointer of each of `encode_cps`.\nconst encode_pointers = [{d}]u16{{\n",
            .{pairs.len},
        );
        try layouts.writeHex(w, u21, ptrs);
        try w.writeAll(
            \\};
            \\
            \\pub fn encode(cp: u21) ?u16 {
            \\    var lo: usize = 0;
            \\    var hi: usize = encode_cps.len;
            \\    while (lo < hi) {
            \\        const mid = lo + (hi - lo) / 2;
            \\        const c = encode_cps[mid];
            \\        if (c == cp) return encode_pointers[mid];
            \\        if (c < cp) lo = mid + 1 else hi = mid;
            \\    }
            \\    return null;
            \\}
            \\
        );
    }
}
