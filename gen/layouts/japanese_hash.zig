//! The perfect-hash layout, for plan decision 2: decoding as the two-level
//! layout does (japanese_rows.zig); encoding through a minimal perfect
//! hash of the code points, built by hash and displace: a code point's
//! product with one constant picks its bucket, and its product with
//! another, mixed with its bucket's seed, its slot; the seeds are chosen,
//! biggest bucket first, so that every code point has a slot of its own.
//! A slot holds the pointer only when the index decodes, and the lookup
//! checks that the pointer decodes to the code point; otherwise it holds
//! the code point too.

const std = @import("std");
const index = @import("../index.zig");
const layouts = @import("../layouts.zig");
const rows = @import("japanese_rows.zig");
const MultiByte = @import("../sources.zig").MultiByte;

pub fn emit(w: *std.Io.Writer, gpa: std.mem.Allocator, src: MultiByte, entries: []const index.Entry) !void {
    if (src.decode) try rows.emitDecode(w, gpa, entries);
    if (src.encode) try emitEncode(w, gpa, src, entries);
}

const bucket_multiplier: u64 = 0x9E3779B97F4A7C15;
const slot_multiplier: u64 = 0xD6E8FEB86659FD93;

fn bucketOf(cp: u32, buckets: u32) u32 {
    return @intCast(((@as(u64, cp) *% bucket_multiplier) >> 32) % buckets);
}

fn slotOf(cp: u32, seed: u32, slots: u32) u32 {
    var h = (@as(u64, cp) | @as(u64, seed) << 21) *% bucket_multiplier;
    h ^= h >> 32;
    return @intCast(((h *% slot_multiplier) >> 32) % slots);
}

fn emitEncode(w: *std.Io.Writer, gpa: std.mem.Allocator, src: MultiByte, entries: []const index.Entry) !void {
    const pairs = try layouts.encodePairs(gpa, src, entries);
    const n: u32 = @intCast(pairs.len);
    const slots = n;
    const buckets = (n + 3) / 4;
    // Buckets, biggest first.
    const Bucket = struct { id: u32, keys: std.ArrayList(u32) = .empty };
    const list = try gpa.alloc(Bucket, buckets);
    for (list, 0..) |*b, i| b.* = .{ .id = @intCast(i) };
    for (pairs, 0..) |p, i| try list[bucketOf(p.cp, buckets)].keys.append(gpa, @intCast(i));
    std.mem.sort(Bucket, list, {}, struct {
        fn gt(_: void, a: Bucket, b: Bucket) bool {
            return a.keys.items.len > b.keys.items.len;
        }
    }.gt);
    const taken = try gpa.alloc(bool, slots);
    @memset(taken, false);
    const slot_pair = try gpa.alloc(u32, slots);
    const seed = try gpa.alloc(u32, buckets);
    @memset(seed, 0);
    for (list) |b| {
        if (b.keys.items.len == 0) break;
        var d: u32 = 0;
        search: while (d <= 0xFFFF) : (d += 1) {
            for (b.keys.items, 0..) |k, j| {
                const s = slotOf(pairs[k].cp, d, slots);
                if (taken[s]) continue :search;
                // Two keys of the bucket in one slot.
                for (b.keys.items[0..j]) |k2| {
                    if (slotOf(pairs[k2].cp, d, slots) == s) continue :search;
                }
            }
            break;
        } else return error.NoSeed;
        seed[b.id] = d;
        for (b.keys.items) |k| {
            const s = slotOf(pairs[k].cp, d, slots);
            taken[s] = true;
            slot_pair[s] = k;
        }
    }
    const verify = src.decode;
    const bmp = pairs[pairs.len - 1].cp <= 0xFFFF;
    try w.print(
        \\const buckets = {d};
        \\const slots = {d};
        \\
        \\/// Each bucket's seed.
        \\const seed = [{d}]u16{{
        \\
    , .{ buckets, slots, buckets });
    try layouts.writeHex(w, u32, seed);
    try w.print(
        \\}};
        \\
        \\/// The pointer in each slot.
        \\const slot_pointer = [{d}]u16{{
        \\
    , .{slots});
    const values = try gpa.alloc(u32, slots);
    for (values, slot_pair) |*v, k| v.* = pairs[k].pointer;
    try layouts.writeHex(w, u32, values);
    try w.writeAll("};\n\n");
    if (!verify) {
        const cp_type = if (bmp) "u16" else "u32";
        try w.print("/// The code point in each slot.\nconst slot_cp = [{d}]{s}{{\n", .{ slots, cp_type });
        for (values, slot_pair) |*v, k| v.* = pairs[k].cp;
        try layouts.writeHex(w, u32, values);
        try w.writeAll("};\n\n");
    }
    try w.print(
        \\pub fn encode(cp: u21) ?u16 {{
        \\    const bucket = ((@as(u64, cp) *% 0x{X}) >> 32) % buckets;
        \\    var h = (@as(u64, cp) | @as(u64, seed[bucket]) << 21) *% 0x{X};
        \\    h ^= h >> 32;
        \\    const slot = ((h *% 0x{X}) >> 32) % slots;
        \\    const p = slot_pointer[slot];
        \\
    , .{ bucket_multiplier, bucket_multiplier, slot_multiplier });
    try w.writeAll(if (verify)
        \\    if (decode(p) != cp) return null;
        \\    return p;
        \\}
        \\
    else
        \\    if (slot_cp[slot] != cp) return null;
        \\    return p;
        \\}
        \\
    );
}
