//! The halves the Chinese family's layouts are built from, measured for
//! plan decisions 1 and 2 (docs/slop/results/chinese-layouts-20261102.md).
//! Each layout file pairs one decode half with one encode half:
//!
//! - Decode: `flat` (an array by pointer, u16 with a bit per pointer for
//!   code points above U+FFFF), `paged` (pages of 32 pointers, each a base
//!   code point and a byte per pointer when its code points are within 255
//!   of each other, otherwise u16, identical pages shared), and `ranged`
//!   (runs where the code point goes up with the pointer stored as a start
//!   and a code point, the rest as a flat array, found by bisection).
//! - Encode: `rank` (a bit per code point in blocks of 64, and the index
//!   pointers in code point order, found by counting the bits below),
//!   `hash` (a perfect hash of the code points to slots holding their
//!   pointers, checked by decoding the pointer), and `ranged` (runs where
//!   the pointer goes up with the code point, found by bisection).
//!
//! A decode half emits `fn decodeIndex(pointer: u32) ?u21`, which the
//! layout makes `pub const decode` when the source decodes; the hash
//! checks its slots with it whether or not it does.

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

pub fn emitDecodeFlat(w: *Writer, gpa: Allocator, entries: []const index.Entry) !void {
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

const page_size = 32;

pub fn emitDecodePaged(w: *Writer, gpa: Allocator, entries: []const index.Entry) !void {
    const s = try shapeOf(entries);
    const table = try byPointer(gpa, entries, s.end);
    defer gpa.free(table);
    const pages = (s.end + page_size - 1) / page_size;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    var words: std.ArrayList(u21) = .empty;
    defer words.deinit(gpa);
    const desc = try gpa.alloc(u32, pages);
    defer gpa.free(desc);
    for (desc, 0..) |*d, k| {
        var page: [page_size]u21 = @splat(0);
        const n = @min(page_size, s.end - k * page_size);
        @memcpy(page[0..n], table[k * page_size ..][0..n]);
        var lo: u21 = std.math.maxInt(u21);
        var hi: u21 = 0;
        for (page) |c| {
            if (c == 0) continue;
            lo = @min(lo, c);
            hi = @max(hi, c);
        }
        if (hi == 0) {
            // No code points: a byte page of nothing, from base 1.
            lo = 1;
            hi = 1;
        }
        if (hi - lo < 0xFF) {
            var p: [page_size]u8 = undefined;
            for (page, &p) |c, *b| b.* = if (c == 0) 0xFF else @intCast(c - lo);
            const slot = findPage(u8, bytes.items, &p) orelse blk: {
                try bytes.appendSlice(gpa, &p);
                break :blk bytes.items.len / page_size - 1;
            };
            if (slot >= 1 << 11) return error.TooManyPages;
            d.* = @as(u32, @intCast(slot)) << 21 | lo;
        } else {
            const slot = findPage(u21, words.items, &page) orelse blk: {
                try words.appendSlice(gpa, &page);
                break :blk words.items.len / page_size - 1;
            };
            if (slot >= 1 << 11) return error.TooManyPages;
            d.* = @as(u32, @intCast(slot)) << 21;
        }
    }
    try w.print(
        \\/// Each page of {d} pointers: its slot in `page_bytes` and its base code
        \\/// point, or, with base 0, its slot in `page_words`.
        \\
    , .{page_size});
    try writeArray(w, u32, "page_desc", "u32", desc);
    try w.writeAll("/// Byte pages: each pointer's code point less the base, 0xFF for none.\n");
    try writeArray(w, u8, "page_bytes", "u8", bytes.items);
    const low = try low16(gpa, words.items);
    defer gpa.free(low);
    if (low.len != 0) {
        try w.writeAll("/// Word pages: each pointer's code point, its low 16 bits above U+FFFF; 0 for none.\n");
        try writeArray(w, u16, "page_words", "u16", low);
    }
    if (s.plane != 0) {
        const astral = try astralWords(gpa, words.items);
        defer gpa.free(astral);
        try w.print("/// A bit for each word whose code point is in plane {d}.\n", .{s.plane});
        try writeArray(w, u32, "page_astral", "u32", astral);
    }
    try w.print(
        \\fn decodeIndex(pointer: u32) ?u21 {{
        \\    if (pointer >= {d}) return null;
        \\    const d = page_desc[pointer / {d}];
        \\    const base: u21 = @truncate(d);
        \\    const at = (d >> 21) * {d} + pointer % {d};
        \\
    , .{ s.end, page_size, page_size, page_size });
    if (words.items.len == 0) {
        try w.writeAll(
            \\    const b = page_bytes[at];
            \\    if (b == 0xFF) return null;
            \\    return base + b;
            \\}
            \\
            \\
        );
        return;
    }
    try w.writeAll(
        \\    if (base != 0) {
        \\        const b = page_bytes[at];
        \\        if (b == 0xFF) return null;
        \\        return base + b;
        \\    }
        \\    const low: u21 = page_words[at];
        \\
    );
    try writeAstralReturn(w, s, "page_astral", "at");
    try w.writeAll(
        \\    if (low == 0) return null;
        \\    return low;
        \\}
        \\
        \\
    );
}

fn findPage(comptime T: type, data: []const T, page: *const [page_size]T) ?usize {
    var k: usize = 0;
    while (k < data.len) : (k += page_size) {
        if (std.mem.eql(T, data[k..][0..page_size], page)) return k / page_size;
    }
    return null;
}

/// A run of consecutive pointers whose code points go up by one each.
const Run = struct { start: u32, len: u32 };

pub fn emitDecodeRanged(w: *Writer, gpa: Allocator, entries: []const index.Entry) !void {
    const s = try shapeOf(entries);
    const table = try byPointer(gpa, entries, s.end);
    defer gpa.free(table);
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(gpa);
    var p: u32 = 0;
    while (p < s.end) {
        var n: u32 = 1;
        while (p + n < s.end and table[p] != 0 and table[p + n] == table[p] + @as(u21, @intCast(n))) n += 1;
        if (table[p] != 0) try runs.append(gpa, .{ .start = p, .len = n });
        p += n;
    }
    // The shortest run worth a segment: the threshold that makes the
    // tables smallest. A run segment and the table segment after it cost
    // six bytes each; a run saves two bytes a pointer.
    var best_min: u32 = 0;
    var best_size: usize = std.math.maxInt(usize);
    var min: u32 = 2;
    while (min <= 64) : (min += 1) {
        var size: usize = 0;
        var covered: usize = 0;
        for (runs.items) |r| {
            if (r.len < min) continue;
            size += 12;
            covered += r.len;
        }
        size += 2 * (s.end - covered);
        if (size < best_size) {
            best_size = size;
            best_min = min;
        }
    }
    var starts: std.ArrayList(u32) = .empty;
    defer starts.deinit(gpa);
    var info: std.ArrayList(u32) = .empty;
    defer info.deinit(gpa);
    var flat: std.ArrayList(u21) = .empty;
    defer flat.deinit(gpa);
    p = 0;
    for (runs.items) |r| {
        if (r.len < best_min) continue;
        if (p < r.start) {
            try starts.append(gpa, p);
            try info.append(gpa, @intCast(flat.items.len));
            try flat.appendSlice(gpa, table[p..r.start]);
        }
        try starts.append(gpa, r.start);
        try info.append(gpa, 1 << 31 | @as(u32, table[r.start]));
        p = r.start + r.len;
    }
    if (p < s.end) {
        try starts.append(gpa, p);
        try info.append(gpa, @intCast(flat.items.len));
        try flat.appendSlice(gpa, table[p..s.end]);
    }
    try w.writeAll("/// The first pointer of each segment, ascending.\n");
    try writeArray(w, u32, "segment_starts", "u16", starts.items);
    try w.writeAll(
        \\/// Each segment: with the top bit, a run whose first pointer is this
        \\/// code point and each next pointer the next; otherwise the index in
        \\/// `segment_table` of its first pointer.
        \\
    );
    try writeArray(w, u32, "segment_info", "u32", info.items);
    try w.writeAll("/// The table segments' code points, their low 16 bits above U+FFFF; 0 for none.\n");
    const low = try low16(gpa, flat.items);
    defer gpa.free(low);
    try writeArray(w, u16, "segment_table", "u16", low);
    if (s.plane != 0) {
        const astral = try astralWords(gpa, flat.items);
        defer gpa.free(astral);
        try w.print("/// A bit for each entry whose code point is in plane {d}.\n", .{s.plane});
        try writeArray(w, u32, "segment_astral", "u32", astral);
    }
    try w.print(
        \\fn decodeIndex(pointer: u32) ?u21 {{
        \\    if (pointer >= {d}) return null;
        \\    var lo: usize = 0;
        \\    var hi: usize = segment_starts.len;
        \\    while (hi - lo > 1) {{
        \\        const mid = lo + (hi - lo) / 2;
        \\        if (segment_starts[mid] <= pointer) lo = mid else hi = mid;
        \\    }}
        \\    const d = segment_info[lo];
        \\    const off = pointer - segment_starts[lo];
        \\    if (d >> 31 != 0) return @intCast((d & 0x1FFFFF) + off);
        \\    const at = d + off;
        \\    const low: u21 = segment_table[at];
        \\
    , .{s.end});
    try writeAstralReturn(w, s, "segment_astral", "at");
    try w.writeAll(
        \\    if (low == 0) return null;
        \\    return low;
        \\}
        \\
        \\
    );
}

const block_bits = 64;

pub fn emitEncodeRank(w: *Writer, gpa: Allocator, src: MultiByte, entries: []const index.Entry) !void {
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

fn mix(x0: u32) u32 {
    var x = x0;
    x ^= x >> 16;
    x *%= 0x85EBCA6B;
    x ^= x >> 13;
    x *%= 0xC2B2AE35;
    x ^= x >> 16;
    return x;
}

fn bucketOf(cp: u21, buckets: usize) usize {
    return @intCast((@as(u64, @as(u32, cp) *% 0x9E3779B1) * buckets) >> 32);
}

fn slotOf(cp: u21, pilot: u32, slots: usize) usize {
    return @intCast((@as(u64, mix(@as(u32, cp) ^ (pilot *% 0x9E3779B1) ^ 0x5BD1E995)) * slots) >> 32);
}

pub fn emitEncodeHash(w: *Writer, gpa: Allocator, src: MultiByte, entries: []const index.Entry) !void {
    const pairs = try layouts.encodePairs(gpa, src, entries);
    defer gpa.free(pairs);
    // Three code points a bucket on average, and the fullest table whose
    // buckets all find a pilot below 256.
    const buckets = pairs.len / 3 + 1;
    var percent: usize = 90;
    while (percent >= 50) : (percent -= 1) {
        const slots = pairs.len * 100 / percent + 1;
        if (try placeHash(gpa, pairs, buckets, slots)) |placed| {
            defer gpa.free(placed.pilots);
            defer gpa.free(placed.slots);
            try w.writeAll("/// Each bucket's pilot, which picks its code points' slots.\n");
            try writeArray(w, u8, "encode_pilots", "u8", placed.pilots);
            try w.writeAll("/// The index pointer in each slot, 0xFFFF for none.\n");
            try writeArray(w, u16, "encode_slots", "u16", placed.slots);
            try w.writeAll(
                \\fn mix(x0: u32) u32 {
                \\    var x = x0;
                \\    x ^= x >> 16;
                \\    x *%= 0x85EBCA6B;
                \\    x ^= x >> 13;
                \\    x *%= 0xC2B2AE35;
                \\    x ^= x >> 16;
                \\    return x;
                \\}
                \\
                \\pub fn encode(cp: u21) ?u16 {
                \\    const bucket = (@as(u64, @as(u32, cp) *% 0x9E3779B1) * encode_pilots.len) >> 32;
                \\    const pilot: u32 = encode_pilots[@intCast(bucket)];
                \\    const h = mix(@as(u32, cp) ^ (pilot *% 0x9E3779B1) ^ 0x5BD1E995);
                \\    const pointer = encode_slots[@intCast((@as(u64, h) * encode_slots.len) >> 32)];
                \\    const c = decodeIndex(pointer) orelse return null;
                \\    return if (c == cp) pointer else null;
                \\}
                \\
            );
            return;
        }
    }
    return error.NoPerfectHash;
}

const Placed = struct { pilots: []u8, slots: []u16 };

fn placeHash(gpa: Allocator, pairs: []const layouts.Pair, buckets: usize, nslots: usize) !?Placed {
    const members = try gpa.alloc(std.ArrayList(usize), buckets);
    defer {
        for (members) |*m| m.deinit(gpa);
        gpa.free(members);
    }
    @memset(members, .empty);
    for (pairs, 0..) |p, i| try members[bucketOf(p.cp, buckets)].append(gpa, i);
    const order = try gpa.alloc(usize, buckets);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, members, struct {
        fn lt(m: []std.ArrayList(usize), a: usize, b: usize) bool {
            const la = m[a].items.len;
            const lb = m[b].items.len;
            return la > lb or (la == lb and a < b);
        }
    }.lt);
    const pilots = try gpa.alloc(u8, buckets);
    errdefer gpa.free(pilots);
    @memset(pilots, 0);
    const slots = try gpa.alloc(u16, nslots);
    errdefer gpa.free(slots);
    @memset(slots, 0xFFFF);
    var chosen: [64]usize = undefined;
    for (order) |b| {
        const keys = members[b].items;
        if (keys.len == 0) continue;
        if (keys.len > chosen.len) return error.BucketTooBig;
        const pilot: u32 = for (0..256) |pilot| {
            var ok = true;
            for (keys, 0..) |k, j| {
                const s = slotOf(pairs[k].cp, @intCast(pilot), nslots);
                if (slots[s] != 0xFFFF or std.mem.findScalar(usize, chosen[0..j], s) != null) {
                    ok = false;
                    break;
                }
                chosen[j] = s;
            }
            if (ok) break @intCast(pilot);
        } else {
            gpa.free(pilots);
            gpa.free(slots);
            return null;
        };
        pilots[b] = @intCast(pilot);
        for (keys, 0..) |k, j| slots[chosen[j]] = @intCast(pairs[k].pointer);
    }
    return .{ .pilots = pilots, .slots = slots };
}

pub fn emitEncodeRanged(w: *Writer, gpa: Allocator, src: MultiByte, entries: []const index.Entry) !void {
    const pairs = try layouts.encodePairs(gpa, src, entries);
    defer gpa.free(pairs);
    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(gpa);
    var ptrs: std.ArrayList(u32) = .empty;
    defer ptrs.deinit(gpa);
    var lens: std.ArrayList(u8) = .empty;
    defer lens.deinit(gpa);
    var i: usize = 0;
    while (i < pairs.len) {
        var n: usize = 1;
        while (i + n < pairs.len and n < 255 and pairs[i + n].cp == pairs[i].cp + n and
            pairs[i + n].pointer == pairs[i].pointer + n) n += 1;
        try cps.append(gpa, pairs[i].cp);
        try ptrs.append(gpa, pairs[i].pointer);
        try lens.append(gpa, @intCast(n));
        i += n;
    }
    const cp_type = if (cps.items[cps.items.len - 1] > 0xFFFF) "u32" else "u16";
    try w.writeAll("/// The first code point of each run, ascending.\n");
    try writeArray(w, u21, "run_cps", cp_type, cps.items);
    try w.writeAll("/// The index pointer of each run's first code point.\n");
    try writeArray(w, u32, "run_pointers", "u16", ptrs.items);
    try w.writeAll("/// How many code points each run has, each the next pointer.\n");
    try writeArray(w, u8, "run_lens", "u8", lens.items);
    try w.writeAll(
        \\pub fn encode(cp: u21) ?u16 {
        \\    if (cp < run_cps[0]) return null;
        \\    var lo: usize = 0;
        \\    var hi: usize = run_cps.len;
        \\    while (hi - lo > 1) {
        \\        const mid = lo + (hi - lo) / 2;
        \\        if (run_cps[mid] <= cp) lo = mid else hi = mid;
        \\    }
        \\    const off = cp - run_cps[lo];
        \\    if (off >= run_lens[lo]) return null;
        \\    return @intCast(run_pointers[lo] + off);
        \\}
        \\
    );
}

/// No encode table: a vector search of `emitDecodeFlat`'s table for the
/// first pointer outside `exclude` with the code point (the last, for one
/// in `last`), as the standard defines the index pointer.
pub fn emitEncodeScan(w: *Writer, src: MultiByte, entries: []const index.Entry) !void {
    const s = try shapeOf(entries);
    // An excluded prefix, as Big5's, is not searched; other excluded
    // pointers, as Shift_JIS's, are skipped.
    var lo: u32 = 0;
    for (src.exclude) |r| {
        if (r[0] == 0) lo = @max(lo, r[1] + 1);
    }
    try w.print(
        \\const scan_start = {d};
        \\const ScanV = @Vector(32, u16);
        \\
        \\fn isAt(p: usize, cp: u21) bool {{
        \\    if (excluded(p)) return false;
        \\    return (decodeIndex(@intCast(p)) orelse return false) == cp;
        \\}}
        \\
    , .{lo});
    var middle = false;
    for (src.exclude) |r| middle = middle or r[0] != 0;
    if (!middle) try w.writeAll("fn excluded(_: usize) bool {\n    return false") else {
        try w.writeAll("fn excluded(p: usize) bool {\n    return false");
        for (src.exclude) |r| {
            if (r[0] != 0) try w.print(" or (p >= {d} and p <= {d})", .{ r[0], r[1] });
        }
    }
    try w.writeAll(
        \\;
        \\}
        \\
        \\/// The first pointer from `scan_start` whose entry is `low` and code point `cp`.
        \\fn scanForward(cp: u21, low: u16) ?u16 {
        \\    const want: ScanV = @splat(low);
        \\    var at: usize = scan_start;
        \\    while (decode_table.len - at >= 32) : (at += 32) {
        \\        const v: ScanV = decode_table[at..][0..32].*;
        \\        var mask: u32 = @bitCast(v == want);
        \\        while (mask != 0) : (mask &= mask - 1) {
        \\            if (isAt(at + @ctz(mask), cp)) return @intCast(at + @ctz(mask));
        \\        }
        \\    }
        \\    while (at < decode_table.len) : (at += 1) {
        \\        if (decode_table[at] == low and isAt(at, cp)) return @intCast(at);
        \\    }
        \\    return null;
        \\}
        \\
        \\/// The last such pointer.
        \\fn scanBackward(cp: u21, low: u16) ?u16 {
        \\    const want: ScanV = @splat(low);
        \\    var end: usize = decode_table.len;
        \\    while (end - scan_start >= 32) : (end -= 32) {
        \\        const v: ScanV = decode_table[end - 32 ..][0..32].*;
        \\        var mask: u32 = @bitCast(v == want);
        \\        while (mask != 0) {
        \\            const j: u5 = @intCast(31 - @clz(mask));
        \\            if (isAt(end - 32 + j, cp)) return @intCast(end - 32 + j);
        \\            mask &= ~(@as(u32, 1) << j);
        \\        }
        \\    }
        \\    while (end > scan_start) {
        \\        end -= 1;
        \\        if (decode_table[end] == low and isAt(end, cp)) return @intCast(end);
        \\    }
        \\    return null;
        \\}
        \\
        \\pub fn encode(cp: u21) ?u16 {
        \\
    );
    if (s.plane == 0) try w.writeAll("    if (cp > 0xFFFF) return null;\n");
    try w.writeAll("    if (cp == 0) return null;\n");
    if (src.last.len != 0) {
        try w.writeAll("    switch (cp) {");
        for (src.last, 0..) |cp, i| try w.print("{s}0x{X}", .{ if (i == 0) " " else ", ", cp });
        try w.writeAll(" => return scanBackward(cp, @truncate(cp)), else => {} }\n");
    }
    try w.writeAll(
        \\    return scanForward(cp, @truncate(cp));
        \\}
        \\
    );
}

/// The `pub const decode` a layout gives a source that decodes.
pub fn emitDecodePub(w: *Writer, src: MultiByte) !void {
    if (src.decode) try w.writeAll("pub const decode = decodeIndex;\n\n");
}
