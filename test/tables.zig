//! The single-byte encodings against the standard, IBM437 and IBM850
//! against Unicode's mappings, and x-user-defined, in full, through the
//! public API: every byte decodes to its index code point (or is an
//! error), and every scalar value encodes to the byte of its index pointer
//! (or is unmappable). The indexes and the label table
//! are read from vendor/ at run time, so this checks the generated tables
//! and the codecs together against the vendored files.

const std = @import("std");
const encoding = @import("encoding");
const Encoding = encoding.Encoding;
const Decoder = encoding.Decoder;
const Encoder = encoding.Encoder;

const testing = std.testing;
const gpa = testing.allocator;

fn readVendor(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(16 << 20));
}

/// The code point of each byte from 0x80, from an index file.
fn indexTable(path: []const u8) ![128]?u21 {
    const text = try readVendor(path);
    defer gpa.free(text);
    var table: [128]?u21 = @splat(null);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const p = try std.fmt.parseInt(usize, fields.next().?, 10);
        table[p] = try std.fmt.parseInt(u21, fields.next().?, 0);
    }
    return table;
}

/// The single-byte encodings, from the standard's label table, with the
/// index file each uses.
fn singleByteEncodings() ![]struct { Encoding, []u8 } {
    const text = try readVendor("vendor/whatwg-encoding/encodings.json");
    defer gpa.free(text);
    const Json = []const struct {
        heading: []const u8,
        encodings: []const struct { name: []const u8, labels: []const []const u8 },
    };
    const parsed = try std.json.parseFromSlice(Json, gpa, text, .{});
    defer parsed.deinit();
    var list: std.ArrayList(struct { Encoding, []u8 }) = .empty;
    for (parsed.value) |g| {
        if (!std.mem.eql(u8, g.heading, "Legacy single-byte encodings")) continue;
        for (g.encodings) |e| {
            const name = if (std.mem.eql(u8, e.name, "ISO-8859-8-I")) "ISO-8859-8" else e.name;
            const lower = try std.ascii.allocLowerString(gpa, name);
            defer gpa.free(lower);
            const path = try std.fmt.allocPrint(gpa, "vendor/whatwg-encoding/index-{s}.txt", .{lower});
            try list.append(gpa, .{ Encoding.forLabel(e.name).?, path });
        }
    }
    return list.toOwnedSlice(gpa);
}

fn freeList(list: anytype) void {
    for (list) |e| gpa.free(e[1]);
    gpa.free(list);
}

/// UTF-8 of every scalar value, in order.
fn allScalars() ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    var cp: u21 = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        if (cp >= 0xD800 and cp <= 0xDFFF) continue;
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &buf);
        try list.appendSlice(gpa, buf[0..n]);
    }
    return list.toOwnedSlice(gpa);
}

fn appendNcr(list: *std.ArrayList(u8), cp: u21) !void {
    var buf: [16]u8 = undefined;
    try list.appendSlice(gpa, try std.fmt.bufPrint(&buf, "&#{d};", .{cp}));
}

/// Checks `enc` against `decode`, the code point of each byte (null for an
/// error), and `encode`, the byte of each scalar value (null for
/// unmappable), on every byte and every scalar value.
fn checkFull(
    enc: Encoding,
    decodeByte: *const fn (u8) ?u21,
    encodeScalar: *const fn (Encoding, u21) ?u8,
    scalars: []const u8,
) !void {
    // Decode each byte alone, in fatal mode, to both outputs.
    for (0..256) |b| {
        const byte = [1]u8{@intCast(b)};
        var d: Decoder = .init(enc, .{ .mode = .fatal, .bom = .keep });
        var out16: [2]u16 = undefined;
        const r = d.decodeToUtf16(&byte, &out16, true);
        if (decodeByte(@intCast(b))) |cp| {
            try testing.expectEqual(Decoder.Status.input_empty, r.status);
            var want: [2]u16 = undefined;
            const n = try std.unicode.utf8ToUtf16Le(&want, blk: {
                var u: [4]u8 = undefined;
                break :blk u[0..try std.unicode.utf8Encode(cp, &u)];
            });
            try testing.expectEqual(n, r.written);
            for (want[0..n], out16[0..n]) |w, g| try testing.expectEqual(std.mem.littleToNative(u16, w), g);
        } else {
            try testing.expectEqual(Decoder.Status.malformed, r.status);
            try testing.expectEqual(@as(usize, 0), r.written);
        }
    }
    // All 256 bytes at once, to UTF-8, in replacement mode.
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(gpa);
    for (all) |b| {
        var u: [4]u8 = undefined;
        try want.appendSlice(gpa, u[0..try std.unicode.utf8Encode(decodeByte(b) orelse 0xFFFD, &u)]);
    }
    var d: Decoder = .init(enc, .{ .bom = .keep });
    const out = try gpa.alloc(u8, d.maxUtf8Len(all.len).?);
    defer gpa.free(out);
    const r = d.decodeToUtf8(&all, out, true);
    try testing.expectEqualStrings(want.items, out[0..r.written]);

    // Every scalar value, in html mode: its byte, or a reference.
    want.clearRetainingCapacity();
    var cp: u21 = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        if (cp >= 0xD800 and cp <= 0xDFFF) continue;
        if (encodeScalar(enc, cp)) |b| try want.append(gpa, b) else try appendNcr(&want, cp);
    }
    var e: Encoder = .init(enc, .{});
    const bytes = try gpa.alloc(u8, e.maxLenFromUtf8(scalars.len).?);
    defer gpa.free(bytes);
    const w = e.encodeFromUtf8(scalars, bytes, true);
    try testing.expectEqual(Encoder.Status.input_empty, w.status);
    try testing.expect(std.mem.eql(u8, want.items, bytes[0..w.written]));

    // And in fatal mode from UTF-16: each unmappable character in turn.
    const units = try std.unicode.utf8ToUtf16LeAlloc(gpa, scalars);
    defer gpa.free(units);
    for (units) |*u| u.* = std.mem.littleToNative(u16, u.*);
    var f: Encoder = .init(enc, .{ .mode = .fatal });
    var rest: []const u16 = units;
    var next: u21 = 0;
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(gpa);
    while (true) {
        const s = f.encodeFromUtf16(rest, bytes, true);
        try got.appendSlice(gpa, bytes[0..s.written]);
        rest = rest[s.read..];
        if (s.status == .input_empty) break;
        try testing.expectEqual(Encoder.Status.unmappable, s.status);
        // The unmappable character is the next scalar value with no byte.
        while (encodeScalar(enc, next) != null or (next >= 0xD800 and next <= 0xDFFF)) next += 1;
        try testing.expectEqual(next, s.unmappable);
        next += 1;
    }
    var mapped: std.ArrayList(u8) = .empty;
    defer mapped.deinit(gpa);
    cp = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        if (cp >= 0xD800 and cp <= 0xDFFF) continue;
        if (encodeScalar(enc, cp)) |b| try mapped.append(gpa, b);
    }
    try testing.expect(std.mem.eql(u8, mapped.items, got.items));
}

var current: [128]?u21 = undefined;
/// The standard's single-byte encoder on `current` for each BMP code
/// point: ASCII, or the byte of the first pointer.
var reverse: [0x10000]?u8 = undefined;

fn setCurrent(table: [128]?u21) void {
    current = table;
    for (&reverse, 0..) |*r, cp| r.* = if (cp < 0x80) @intCast(cp) else null;
    var p: usize = 128;
    while (p > 0) {
        p -= 1;
        if (table[p]) |cp| reverse[cp] = @intCast(0x80 + p);
    }
}

fn singleByteDecode(b: u8) ?u21 {
    return if (b < 0x80) b else current[b - 0x80];
}

fn singleByteEncode(_: Encoding, cp: u21) ?u8 {
    return if (cp < 0x10000) reverse[cp] else null;
}

test "single-byte encodings against their indexes, both ways" {
    const list = try singleByteEncodings();
    defer freeList(list);
    try testing.expectEqual(@as(usize, 28), list.len);
    const scalars = try allScalars();
    defer gpa.free(scalars);
    for (list) |entry| {
        setCurrent(try indexTable(entry[1]));
        checkFull(entry[0], singleByteDecode, singleByteEncode, scalars) catch |err| {
            std.debug.print("{s} ({s})\n", .{ entry[0].name(), entry[1] });
            return err;
        };
    }
}

/// The code point of each byte from 0x80, from one of Unicode's vendor
/// mapping files (`0x80<TAB>0x00C7<TAB>#...`), which also lists the bytes
/// below 0x80: those must be ASCII, as the single-byte decoder has them.
fn unicodeTable(path: []const u8) ![128]?u21 {
    const text = try readVendor(path);
    defer gpa.free(text);
    var table: [256]?u21 = @splat(null);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const p = fields.next().?;
        // The files end with a DOS end-of-file byte, 0x1A, alone.
        const c = fields.next() orelse continue;
        if (c[0] == '#') continue;
        table[try std.fmt.parseInt(u8, p, 0)] = try std.fmt.parseInt(u21, c, 0);
    }
    for (table[0..128], 0..) |cp, b| try testing.expectEqual(@as(?u21, @intCast(b)), cp);
    return table[128..].*;
}

test "IBM437 and IBM850 against Unicode's mappings, both ways" {
    const scalars = try allScalars();
    defer gpa.free(scalars);
    const pages = [_]struct { Encoding, []const u8 }{
        .{ .ibm437, "vendor/unicode/CP437.TXT" },
        .{ .ibm850, "vendor/unicode/CP850.TXT" },
    };
    for (pages) |entry| {
        setCurrent(try unicodeTable(entry[1]));
        checkFull(entry[0], singleByteDecode, singleByteEncode, scalars) catch |err| {
            std.debug.print("{s} ({s})\n", .{ entry[0].name(), entry[1] });
            return err;
        };
    }
}

fn xUserDefinedDecode(b: u8) ?u21 {
    return if (b < 0x80) b else 0xF780 + @as(u21, b - 0x80);
}

fn xUserDefinedEncode(_: Encoding, cp: u21) ?u8 {
    if (cp < 0x80) return @intCast(cp);
    if (cp >= 0xF780 and cp <= 0xF7FF) return @intCast(cp - 0xF780 + 0x80);
    return null;
}

test "x-user-defined, both ways" {
    const scalars = try allScalars();
    defer gpa.free(scalars);
    try checkFull(.x_user_defined, xUserDefinedDecode, xUserDefinedEncode, scalars);
}

test "the label table matches encodings.json" {
    const text = try readVendor("vendor/whatwg-encoding/encodings.json");
    defer gpa.free(text);
    const Json = []const struct {
        heading: []const u8,
        encodings: []const struct { name: []const u8, labels: []const []const u8 },
    };
    const parsed = try std.json.parseFromSlice(Json, gpa, text, .{});
    defer parsed.deinit();
    var count: usize = 0;
    for (parsed.value) |g| {
        for (g.encodings) |e| {
            const enc = Encoding.forLabel(e.name).?;
            try testing.expectEqualStrings(e.name, enc.name());
            for (e.labels) |l| {
                try testing.expectEqual(enc, Encoding.forLabel(l).?);
                const upper = try std.ascii.allocUpperString(gpa, l);
                defer gpa.free(upper);
                try testing.expectEqual(enc, Encoding.forLabel(upper).?);
                count += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 228), count);
}
