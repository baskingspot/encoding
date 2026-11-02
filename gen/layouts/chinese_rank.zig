//! The chinese_rank layout, chosen for the Chinese indexes by plan
//! decisions 1 and 2 (docs/slop/results/chinese-layouts-20261102.md).
//! Decode is an array by pointer, u16, with a bit per pointer for code
//! points above U+FFFF (Big5's HKSCS, all in plane 2). Encode is a bit per
//! code point in blocks of 64, a block number per 64 code points, and the
//! index pointers in code point order: a code point's pointer is at its
//! block's base plus the count of bits below it.

const std = @import("std");
const index = @import("../index.zig");
const layouts = @import("../layouts.zig");
const MultiByte = @import("../sources.zig").MultiByte;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// One past the last pointer, and the plane of every code point above
/// U+FFFF (0 if there are none; two planes are not supported).
const Shape = struct { end: u32, plane: u21 };

fn shapeOf(entries: []const index.Entry) !Shape {
    var s: Shape = .{ .end = 0, .plane = 0 };
    for (entries) |e| {
        s.end = @max(s.end, e.pointer + 1);
        const plane = e.cp >> 16;
        if (plane == 0) continue;
        if (s.plane != 0 and s.plane != plane) return error.TwoAstralPlanes;
        s.plane = plane;
    }
    if (s.end >= 0xFFFF) return error.TooManyPointers;
    return s;
}

/// The code point of each pointer below `end`, 0 for none.
fn byPointer(gpa: Allocator, entries: []const index.Entry, end: u32) ![]u21 {
    const table = try gpa.alloc(u21, end);
    @memset(table, 0);
    for (entries) |e| table[e.pointer] = e.cp;
    return table;
}

/// The bit-per-entry words that mark code points above U+FFFF, for a u16
/// array of `values`.
fn astralWords(gpa: Allocator, values: []const u21) ![]u32 {
    const words = try gpa.alloc(u32, (values.len + 31) / 32);
    @memset(words, 0);
    for (values, 0..) |v, i| {
        if (v > 0xFFFF) words[i / 32] |= @as(u32, 1) << @intCast(i % 32);
    }
    return words;
}

fn writeArray(w: *Writer, comptime T: type, name: []const u8, ty: []const u8, values: []const T) !void {
    try w.print("const {s} = [{d}]{s}{{\n", .{ name, values.len, ty });
    // Lines under 120 bytes once zig fmt aligns the columns.
    const per_line = switch (@sizeOf(T)) {
        8 => 5,
        4 => 6,
        else => 12,
    };
    for (values, 0..) |v, i| {
        if (i % per_line == 0) try w.writeAll("   ");
        try w.print(" 0x{X},", .{v});
        if (i % per_line == per_line - 1 or i == values.len - 1) try w.writeAll("\n");
    }
    try w.writeAll("};\n\n");
}

/// The low 16 bits of each value.
fn low16(gpa: Allocator, values: []const u21) ![]u16 {
    const out = try gpa.alloc(u16, values.len);
    for (values, out) |v, *o| o.* = @truncate(v);
    return out;
}

/// The expression for the code point of a u16 entry `low` at astral-bit
/// index `at`, as a statement that returns it.
fn writeAstralReturn(w: *Writer, s: Shape, words: []const u8, at: []const u8) !void {
    if (s.plane == 0) return;
    try w.print(
        \\    if ({s}[{s} >> 5] >> @intCast({s} & 31) & 1 != 0) return 0x{X}0000 | low;
        \\
    , .{ words, at, at, s.plane });
}

fn emitDecodeFlat(w: *Writer, gpa: Allocator, entries: []const index.Entry) !void {
    const s = try shapeOf(entries);
    const table = try byPointer(gpa, entries, s.end);
    defer gpa.free(table);
    try w.writeAll("/// The code point of each pointer, its low 16 bits above U+FFFF; 0 for none.\n");
    const low = try low16(gpa, table);
    defer gpa.free(low);
    try writeArray(w, u16, "decode_table", "u16", low);
    if (s.plane != 0) {
        const words = try astralWords(gpa, table);
        defer gpa.free(words);
        try w.print("/// A bit for each pointer whose code point is in plane {d}.\n", .{s.plane});
        try writeArray(w, u32, "decode_astral", "u32", words);
    }
    try w.writeAll(
        \\fn decodeIndex(pointer: u32) ?u21 {
        \\    if (pointer >= decode_table.len) return null;
        \\    const low: u21 = decode_table[pointer];
        \\
    );
    try writeAstralReturn(w, s, "decode_astral", "pointer");
    try w.writeAll(
        \\    if (low == 0) return null;
        \\    return low;
        \\}
        \\
        \\
    );
}

const block_bits = 64;

fn emitEncodeRank(w: *Writer, gpa: Allocator, src: MultiByte, entries: []const index.Entry) !void {
    const pairs = try layouts.encodePairs(gpa, src, entries);
    defer gpa.free(pairs);
    const max_cp = pairs[pairs.len - 1].cp;
    const blocks = try gpa.alloc(u16, max_cp / block_bits + 1);
    defer gpa.free(blocks);
    @memset(blocks, 0);
    var bits: std.ArrayList(u64) = .empty;
    defer bits.deinit(gpa);
    var bases: std.ArrayList(u32) = .empty;
    defer bases.deinit(gpa);
    // Block 0 has no code points.
    try bits.append(gpa, 0);
    try bases.append(gpa, 0);
    const pointers = try gpa.alloc(u32, pairs.len);
    defer gpa.free(pointers);
    for (pairs, pointers, 0..) |pair, *q, i| {
        q.* = pair.pointer;
        const b = pair.cp / block_bits;
        if (blocks[b] == 0) {
            blocks[b] = @intCast(bits.items.len);
            try bits.append(gpa, 0);
            try bases.append(gpa, @intCast(i));
        }
        bits.items[blocks[b]] |= @as(u64, 1) << @intCast(pair.cp % block_bits);
    }
    try w.print("/// For each {d} code points from U+0000, its block; block 0 has none.\n", .{block_bits});
    try writeArray(w, u16, "encode_blocks", "u16", blocks);
    try w.writeAll("/// Each block's code points, a bit each.\n");
    try writeArray(w, u64, "encode_bits", "u64", bits.items);
    try w.writeAll("/// The index in `encode_pointers` of each block's first code point.\n");
    try writeArray(w, u32, "encode_base", "u16", bases.items);
    try w.writeAll("/// The index pointer of each code point, in code point order.\n");
    try writeArray(w, u32, "encode_pointers", "u16", pointers);
    try w.print(
        \\pub fn encode(cp: u21) ?u16 {{
        \\    if (cp >= encode_blocks.len * {d}) return null;
        \\    const block = encode_blocks[cp / {d}];
        \\    const bits = encode_bits[block];
        \\    const bit = @as(u64, 1) << @intCast(cp % {d});
        \\    if (bits & bit == 0) return null;
        \\    return encode_pointers[encode_base[block] + @popCount(bits & (bit - 1))];
        \\}}
        \\
    , .{ block_bits, block_bits, block_bits });
}
pub fn emit(w: *Writer, gpa: Allocator, src: MultiByte, entries: []const index.Entry) !void {
    try emitDecodeFlat(w, gpa, entries);
    if (src.decode) try w.writeAll("pub const decode = decodeIndex;\n\n");
    if (src.encode) try emitEncodeRank(w, gpa, src, entries);
}
