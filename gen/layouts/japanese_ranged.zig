//! The ranged layout, for plan decisions 1 and 2: both directions as runs
//! of consecutive keys, each run a slice of one array of values with holes
//! (gaps between keys no wider than the run's limit) filled with a
//! sentinel, found by bisecting the runs' first keys. Decoding runs over
//! pointers (jis0208 has 24 runs with no holes at all); encoding runs over
//! code points, the ranged reverse table. The hole limit for each is the
//! one that makes the table smallest.

const std = @import("std");
const index = @import("../index.zig");
const layouts = @import("../layouts.zig");
const MultiByte = @import("../sources.zig").MultiByte;

pub fn emit(w: *std.Io.Writer, gpa: std.mem.Allocator, src: MultiByte, entries: []const index.Entry) !void {
    if (src.decode) {
        const keys = try gpa.alloc(u32, entries.len);
        const values = try gpa.alloc(u32, entries.len);
        // Index files list pointers in order.
        var bmp = true;
        for (entries, keys, values) |e, *k, *v| {
            k.* = e.pointer;
            v.* = e.cp;
            bmp = bmp and e.cp <= 0xFFFF;
        }
        const r = try best(gpa, keys, values, if (bmp) 2 else 4, 2);
        try emitRuns(w, "decode", r, 0, "u16", if (bmp) "u16" else "u32");
        try w.writeAll(
            \\pub fn decode(pointer: u32) ?u21 {
            \\    const cp = decodeRun(pointer) orelse return null;
            \\    if (cp == 0) return null;
            \\    return @intCast(cp);
            \\}
            \\
            \\
        );
    }
    if (src.encode) {
        const pairs = try layouts.encodePairs(gpa, src, entries);
        const keys = try gpa.alloc(u32, pairs.len);
        const values = try gpa.alloc(u32, pairs.len);
        for (pairs, keys, values) |p, *k, *v| {
            k.* = p.cp;
            v.* = p.pointer;
        }
        const bmp = keys[keys.len - 1] <= 0xFFFF;
        const r = try best(gpa, keys, values, 2, if (bmp) 2 else 4);
        try emitRuns(w, "encode", r, 0xFFFF, if (bmp) "u16" else "u32", "u16");
        try w.writeAll(
            \\pub fn encode(cp: u21) ?u16 {
            \\    const p = encodeRun(cp) orelse return null;
            \\    if (p == 0xFFFF) return null;
            \\    return p;
            \\}
            \\
        );
    }
}

const Runs = struct {
    first: []u32,
    end: []u32,
    base: []u32,
    values: []u32,
    /// Where a hole is in `values`, which the emitter fills.
    holes: []bool,
};

/// Runs of `keys` (ascending) with holes up to `max_hole` wide.
fn runs(gpa: std.mem.Allocator, keys: []const u32, values: []const u32, max_hole: u32) !Runs {
    var first: std.ArrayList(u32) = .empty;
    var end: std.ArrayList(u32) = .empty;
    var base: std.ArrayList(u32) = .empty;
    var out: std.ArrayList(u32) = .empty;
    var holes: std.ArrayList(bool) = .empty;
    for (keys, values, 0..) |k, v, i| {
        if (i == 0 or k - keys[i - 1] - 1 > max_hole) {
            try first.append(gpa, k);
            try end.append(gpa, k);
            try base.append(gpa, @intCast(out.items.len));
        } else {
            for (0..k - keys[i - 1] - 1) |_| {
                try out.append(gpa, 0);
                try holes.append(gpa, true);
            }
        }
        try out.append(gpa, v);
        try holes.append(gpa, false);
        end.items[end.items.len - 1] = k + 1;
    }
    return .{ .first = first.items, .end = end.items, .base = base.items, .values = out.items, .holes = holes.items };
}

fn size(r: Runs, value_size: usize, key_size: usize) usize {
    return r.first.len * (2 * key_size + 2) + r.values.len * value_size;
}

fn best(gpa: std.mem.Allocator, keys: []const u32, values: []const u32, value_size: usize, key_size: usize) !Runs {
    var b: ?Runs = null;
    for ([_]u32{ 0, 1, 2, 4, 8, 16, 32, 64, 128 }) |h| {
        const r = try runs(gpa, keys, values, h);
        if (r.values.len > 0xFFFF) continue;
        if (b == null or size(r, value_size, key_size) < size(b.?, value_size, key_size)) b = r;
    }
    return b orelse error.TooManyValues;
}

fn emitRuns(
    w: *std.Io.Writer,
    comptime name: []const u8,
    r: Runs,
    hole: u32,
    key_type: []const u8,
    value_type: []const u8,
) !void {
    for (r.values, r.holes) |*v, h| {
        if (h) v.* = hole;
    }
    try w.print("/// The first key of each run.\nconst {s}_first = [{d}]{s}{{\n", .{ name, r.first.len, key_type });
    try layouts.writeHex(w, u32, r.first);
    try w.print(
        "}};\n\n/// The key after each run's last.\nconst {s}_end = [{d}]{s}{{\n",
        .{ name, r.end.len, key_type },
    );
    try layouts.writeHex(w, u32, r.end);
    try w.print(
        "}};\n\n/// Where each run starts in `{s}_values`.\nconst {s}_base = [{d}]u16{{\n",
        .{ name, name, r.base.len },
    );
    try layouts.writeHex(w, u32, r.base);
    try w.print(
        "}};\n\n/// The runs' values, holes {d}.\nconst {s}_values = [{d}]{s}{{\n",
        .{ hole, name, r.values.len, value_type },
    );
    try layouts.writeHex(w, u32, r.values);
    try w.writeAll("};\n\n");
    const value = if (std.mem.eql(u8, name, "decode")) "u32" else "u16";
    try w.writeAll("fn " ++ name ++ "Run(key: u32) ?" ++ value ++ " {\n" ++
        \\    // The last run that starts at or before `key`.
        \\    var lo: usize = 0;
        \\    var hi: usize =
    ++ " " ++ name ++ "_first.len;\n" ++
        \\    while (lo < hi) {
        \\        const mid = lo + (hi - lo) / 2;
        \\
    ++ "        if (" ++ name ++ "_first[mid] <= key) lo = mid + 1 else hi = mid;\n" ++
        \\    }
        \\    if (lo == 0) return null;
        \\    const run = lo - 1;
        \\
    ++ "    if (key >= " ++ name ++ "_end[run]) return null;\n" ++
        "    return " ++ name ++ "_values[" ++ name ++ "_base[run] + (key - " ++ name ++ "_first[run])];\n" ++
        \\}
        \\
        \\
    );
}
