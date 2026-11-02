//! The encode half of the flat_runs layout: chinese_rank's
//! rank table (a block number per 64 code points, a bit per code point of
//! each block, and the index pointers in code point order), with runs
//! (docs/slop/results/cjk-tables-20261102.md).
//!
//! Where most of a block's code points have consecutive pointers, as
//! GBK's extension hanzi and the UHC Hangul do among the hanzi and Hangul
//! of GB2312 and KS X 1001, the block keeps only the first pointer of that
//! run. Its other code points keep theirs, ranked by `encode_bits` as in
//! chinese_rank, so a lookup of one of them is the same as there; the run
//! has a word of its own, `encode_runs`, read only when `encode_bits`
//! lacks the code point. A run is left out where it is less than half of
//! its block, or all of it: there it would put common characters (GB2312's
//! punctuation, its full-width forms) on the second path, a branch that
//! text takes and leaves every few characters. Runs are emitted only when
//! they save more than their words cost.

const std = @import("std");
const index = @import("../index.zig");
const layouts = @import("../layouts.zig");
const MultiByte = @import("../sources.zig").MultiByte;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Block = struct {
    /// The block's code points outside its run, a bit each.
    bits: u64 = 0,
    /// The code points of its run.
    run: u64 = 0,
    /// Where its entries start in the encode pairs, and how many.
    start: u32 = 0,
    len: u32 = 0,
};

/// The longest run in `pairs`, one block's entries in code point order:
/// entries, not necessarily adjacent, whose pointers go up by one each.
/// Each code point has one pointer, so from any first entry the run is
/// the greedy one.
fn longestRun(pairs: []const layouts.Pair) u64 {
    var best: u64 = 0;
    var best_len: u32 = 0;
    for (pairs, 0..) |first, i| {
        var mask: u64 = @as(u64, 1) << @intCast(first.cp % 64);
        var len: u32 = 1;
        var want = first.pointer + 1;
        for (pairs[i + 1 ..]) |p| {
            if (p.pointer != want) continue;
            mask |= @as(u64, 1) << @intCast(p.cp % 64);
            len += 1;
            want += 1;
        }
        if (len > best_len) {
            best = mask;
            best_len = len;
        }
    }
    return best;
}

fn writeArray(w: *Writer, comptime T: type, doc: []const u8, name: []const u8, values: []const T) !void {
    try w.print("/// {s}\nconst {s} = [{d}]{s}{{\n", .{ doc, name, values.len, @typeName(T) });
    const per_line: usize = if (T == u64) 4 else 12;
    for (values, 0..) |v, i| {
        if (i % per_line == 0) try w.writeAll("   ");
        if (T == u64) try w.print(" 0x{X:0>16},", .{v}) else try w.print(" 0x{X},", .{v});
        if (i % per_line == per_line - 1 or i == values.len - 1) try w.writeAll("\n");
    }
    try w.writeAll("};\n\n");
}

pub fn emitEncode(w: *Writer, gpa: Allocator, src: MultiByte, entries: []const index.Entry) !void {
    const pairs = try layouts.encodePairs(gpa, src, entries);
    defer gpa.free(pairs);

    // The blocks with code points, in code point order; block 0 is empty.
    const max_cp = pairs[pairs.len - 1].cp;
    const numbers = try gpa.alloc(u16, max_cp / 64 + 1);
    defer gpa.free(numbers);
    @memset(numbers, 0);
    var blocks: std.ArrayList(Block) = .empty;
    defer blocks.deinit(gpa);
    try blocks.append(gpa, .{});
    for (pairs, 0..) |p, i| {
        const n = &numbers[p.cp / 64];
        if (n.* == 0) {
            n.* = @intCast(blocks.items.len);
            try blocks.append(gpa, .{ .start = @intCast(i) });
        }
        const blk = &blocks.items[n.*];
        blk.bits |= @as(u64, 1) << @intCast(p.cp % 64);
        blk.len += 1;
    }

    // Runs where they are at least half their block but not all of it,
    // and only if they pay for their words.
    var saves: usize = 0;
    for (blocks.items) |*blk| {
        const run = longestRun(pairs[blk.start..][0..blk.len]);
        const n = @popCount(run);
        if (n < 2 or n == blk.len or 2 * n < blk.len) continue;
        blk.run = run;
        blk.bits &= ~run;
        saves += 2 * (n - 1);
    }
    const use_runs = saves > 8 * blocks.items.len;
    if (!use_runs) for (blocks.items) |*blk| {
        blk.bits |= blk.run;
        blk.run = 0;
    };

    // Per block: where its pointers start, then the pointers of its code
    // points outside its run in code point order, then its run's first.
    var bits: std.ArrayList(u64) = .empty;
    defer bits.deinit(gpa);
    var runs: std.ArrayList(u64) = .empty;
    defer runs.deinit(gpa);
    var base: std.ArrayList(u16) = .empty;
    defer base.deinit(gpa);
    var pointers: std.ArrayList(u16) = .empty;
    defer pointers.deinit(gpa);
    for (blocks.items) |blk| {
        try bits.append(gpa, blk.bits);
        try runs.append(gpa, blk.run);
        try base.append(gpa, @intCast(pointers.items.len));
        var run_first: ?u32 = null;
        for (pairs[blk.start..][0..blk.len]) |p| {
            if (blk.run >> @intCast(p.cp % 64) & 1 != 0) {
                if (run_first == null) run_first = p.pointer;
                continue;
            }
            try pointers.append(gpa, @intCast(p.pointer));
        }
        if (run_first) |f| try pointers.append(gpa, @intCast(f));
    }

    const blocks_doc = "For each 64 code points from U+0000, its block; block 0 has none.";
    try writeArray(w, u16, blocks_doc, "encode_blocks", numbers);
    if (use_runs) {
        try writeArray(w, u64, "Each block's code points outside its run, a bit each.", "encode_bits", bits.items);
        try writeArray(w, u64, "Each block's run, a bit for each of its code points.", "encode_runs", runs.items);
        try writeArray(w, u16, "Where each block's pointers start in `encode_pointers`.", "encode_base", base.items);
        try writeArray(w, u16, "Each block's pointers: those of its code points outside its run, in " ++
            "code point order, then its run's first.", "encode_pointers", pointers.items);
        try w.writeAll(
            \\pub fn encode(cp: u21) ?u16 {
            \\    if (cp >= encode_blocks.len * 64) return null;
            \\    const block = encode_blocks[cp / 64];
            \\    const bit = @as(u64, 1) << @intCast(cp % 64);
            \\    const bits = encode_bits[block];
            \\    if (bits & bit != 0) return encode_pointers[encode_base[block] + @popCount(bits & (bit - 1))];
            \\    const run = encode_runs[block];
            \\    if (run & bit == 0) return null;
            \\    return encode_pointers[encode_base[block] + @popCount(bits)] + @popCount(run & (bit - 1));
            \\}
            \\
        );
    } else {
        try writeArray(w, u64, "Each block's code points, a bit each.", "encode_bits", bits.items);
        try writeArray(w, u16, "Where each block's pointers start in `encode_pointers`.", "encode_base", base.items);
        const pointers_doc = "The index pointer of each code point, in code point order.";
        try writeArray(w, u16, pointers_doc, "encode_pointers", pointers.items);
        try w.writeAll(
            \\pub fn encode(cp: u21) ?u16 {
            \\    if (cp >= encode_blocks.len * 64) return null;
            \\    const block = encode_blocks[cp / 64];
            \\    const bits = encode_bits[block];
            \\    const bit = @as(u64, 1) << @intCast(cp % 64);
            \\    if (bits & bit == 0) return null;
            \\    return encode_pointers[encode_base[block] + @popCount(bits & (bit - 1))];
            \\}
            \\
        );
    }
}
