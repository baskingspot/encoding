//! Tests of src/coder.zig. The specialized types share the families
//! with `Decoder` and `Encoder` and repeat only their wrappers (byte order
//! marks, held bytes, split characters), so each is run in lockstep with
//! the runtime type: the same chunks and output room on both, and every
//! call's result, output, `maxUtf8Len`, and encoding must agree. Random
//! input, chunk splits, and room; every implemented encoding; both units,
//! both modes, and every byte order mark option the type takes.

const std = @import("std");
const testing = std.testing;
const specialized = @import("coder.zig");
const codecs = @import("codecs.zig");
const Decoder = specialized.DecoderFor(&codecs.implemented);
const Encoder = specialized.EncoderFor(&codecs.implemented);
const Encoding = specialized.Encoding;

const rounds = 60;

fn decodeCall(d: anytype, comptime Unit: type, src: []const u8, dst: []Unit, last: bool) Decoder.Result {
    return if (Unit == u8) d.decodeToUtf8(src, dst, last) else d.decodeToUtf16(src, dst, last);
}

fn maxLenOf(d: anytype, comptime Unit: type, n: usize) ?usize {
    return if (Unit == u8) d.maxUtf8Len(n) else d.maxUtf16Len(n);
}

/// Random bytes, ASCII-heavy, sometimes behind a byte order mark or the
/// start of one.
fn decoderInput(rng: std.Random, buf: []u8) []u8 {
    const len = rng.uintAtMost(usize, buf.len - 3);
    var n: usize = 0;
    const marks = [_][]const u8{ "\xEF\xBB\xBF", "\xFE\xFF", "\xFF\xFE", "\xEF\xBB", "\xEF", "\xFF" };
    if (rng.uintLessThan(u8, 4) == 0) {
        const m = marks[rng.uintLessThan(usize, marks.len)];
        @memcpy(buf[0..m.len], m);
        n = m.len;
    }
    for (buf[n..][0..len]) |*b| b.* = if (rng.boolean()) rng.uintLessThan(u8, 0x80) else rng.int(u8);
    return buf[0 .. n + len];
}

/// `options` as `D` takes them: without `.sniff` for a set that cannot.
fn optionsOf(comptime D: type, options: Decoder.Options) D.Options {
    if (D.Options == Decoder.Options) return options;
    return .{ .mode = options.mode, .bom = switch (options.bom) {
        .sniff => unreachable,
        .remove => .remove,
        .keep => .keep,
    } };
}

fn lockstepDecode(
    comptime D: type,
    comptime Unit: type,
    e: Encoding,
    options: Decoder.Options,
    src: []const u8,
    rng: std.Random,
) !void {
    var a: Decoder = .init(e, options);
    var b: D = .init(e, optionsOf(D, options));
    var out_a: [256]Unit = undefined;
    var out_b: [256]Unit = undefined;
    const min_room: usize = if (Unit == u8) 4 else 2;
    var i: usize = 0;
    var end: usize = 0;
    while (true) {
        if (i == end and end < src.len) end = i + 1 + rng.uintLessThan(usize, src.len - i);
        const last = end == src.len;
        try testing.expectEqual(maxLenOf(&a, Unit, end - i), maxLenOf(&b, Unit, end - i));
        const room = rng.intRangeAtMost(usize, min_room, out_a.len);
        const ra = decodeCall(&a, Unit, src[i..end], out_a[0..room], last);
        const rb = decodeCall(&b, Unit, src[i..end], out_b[0..room], last);
        try testing.expectEqual(ra, rb);
        try testing.expectEqualSlices(Unit, out_a[0..ra.written], out_b[0..rb.written]);
        try testing.expectEqual(a.encoding, b.encoding);
        i += ra.read;
        if (ra.status == .input_empty and last) return;
    }
}

/// Runs `D` against `Decoder` on every encoding in `D`'s set that the
/// caller asks for, with every byte order mark option `D` takes.
fn checkDecoder(comptime D: type, comptime es: []const Encoding, seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    var buf: [96]u8 = undefined;
    const sniffs = D.Options == Decoder.Options;
    inline for (es) |e| {
        for ([_]Decoder.Bom{ .sniff, .remove, .keep }) |bom| {
            if (bom == .sniff and !sniffs) continue;
            for ([_]Decoder.Mode{ .replacement, .fatal }) |mode| {
                for (0..rounds) |_| {
                    const src = decoderInput(rng, &buf);
                    const options: Decoder.Options = .{ .mode = mode, .bom = bom };
                    try lockstepDecode(D, u8, e, options, src, rng);
                    try lockstepDecode(D, u16, e, options, src, rng);
                }
            }
        }
    }
}

test "DecoderFor one encoding, with and without sniffing, matches Decoder" {
    inline for (codecs.implemented, 0..) |e, k| {
        try checkDecoder(specialized.DecoderFor(&.{e}), &.{e}, k);
        try checkDecoder(specialized.DecoderFor(&(.{e} ++ specialized.bom_encodings)), &.{e}, k + 1000);
    }
}

test "a set's decoder matches Decoder on each of its encodings" {
    try checkDecoder(specialized.DecoderFor(&specialized.no_cjk), &specialized.no_cjk, 1);
    try checkDecoder(specialized.DecoderFor(&codecs.implemented), &codecs.implemented, 2);
    const set = [_]Encoding{ .windows_1252, .iso_8859_15, .shift_jis };
    try checkDecoder(specialized.DecoderFor(&set), &set, 3);
}

test "the same encodings in any order are the same type" {
    try testing.expect(specialized.DecoderFor(&.{ .windows_1252, .utf_8 }) ==
        specialized.DecoderFor(&.{ .utf_8, .windows_1252, .utf_8 }));
    try testing.expect(specialized.EncoderFor(&.{ .utf_16le, .shift_jis }) ==
        specialized.EncoderFor(&.{ .shift_jis, .utf_8 }));
}

/// Random UTF-8 and UTF-16 text, with every length of sequence, cut-off
/// sequences, stray bytes, and lone surrogates.
fn encoderInput(rng: std.Random, b8: []u8, b16: []u16) struct { []u8, []u16 } {
    var n8: usize = 0;
    var n16: usize = 0;
    const chars = rng.uintAtMost(usize, b16.len / 2);
    for (0..chars) |_| {
        const cp: u21 = switch (rng.uintLessThan(u8, 8)) {
            0, 1, 2 => rng.uintLessThan(u21, 0x80),
            3 => rng.intRangeAtMost(u21, 0x80, 0x7FF),
            4 => rng.intRangeAtMost(u21, 0x800, 0xFFFF),
            5 => rng.intRangeAtMost(u21, 0x10000, 0x10FFFF),
            else => blk: {
                // Ill-formed: a stray byte in UTF-8, a lone surrogate in
                // UTF-16.
                b8[n8] = rng.intRangeAtMost(u8, 0x80, 0xFF);
                n8 += 1;
                b16[n16] = rng.intRangeAtMost(u16, 0xD800, 0xDFFF);
                n16 += 1;
                break :blk null;
            },
        } orelse continue;
        if (cp >= 0xD800 and cp <= 0xDFFF) continue;
        n8 += std.unicode.utf8Encode(cp, b8[n8..]) catch unreachable;
        if (cp < 0x10000) {
            b16[n16] = @intCast(cp);
            n16 += 1;
        } else {
            const v = cp - 0x10000;
            b16[n16] = @intCast(0xD800 | (v >> 10));
            b16[n16 + 1] = @intCast(0xDC00 | (v & 0x3FF));
            n16 += 2;
        }
    }
    return .{ b8[0..n8], b16[0..n16] };
}

fn encodeCall(e: anytype, comptime Unit: type, src: []const Unit, dst: []u8, last: bool) Encoder.Result {
    return if (Unit == u8) e.encodeFromUtf8(src, dst, last) else e.encodeFromUtf16(src, dst, last);
}

fn lockstepEncode(
    comptime E: type,
    comptime Unit: type,
    e: Encoding,
    options: Encoder.Options,
    src: []const Unit,
    rng: std.Random,
) !void {
    var a: Encoder = .init(e, options);
    var b: E = .init(e, options);
    var out_a: [512]u8 = undefined;
    var out_b: [512]u8 = undefined;
    var i: usize = 0;
    var end: usize = 0;
    while (true) {
        if (i == end and end < src.len) end = i + 1 + rng.uintLessThan(usize, src.len - i);
        const last = end == src.len;
        const ma = if (Unit == u8) a.maxLenFromUtf8(end - i) else a.maxLenFromUtf16(end - i);
        const mb = if (Unit == u8) b.maxLenFromUtf8(end - i) else b.maxLenFromUtf16(end - i);
        try testing.expectEqual(ma, mb);
        const room = rng.intRangeAtMost(usize, max_ncr_len, out_a.len);
        const ra = encodeCall(&a, Unit, src[i..end], out_a[0..room], last);
        const rb = encodeCall(&b, Unit, src[i..end], out_b[0..room], last);
        try testing.expectEqual(ra, rb);
        try testing.expectEqualSlices(u8, out_a[0..ra.written], out_b[0..rb.written]);
        i += ra.read;
        if (ra.status == .input_empty and last) return;
    }
}

const max_ncr_len = @import("codec.zig").max_ncr_len;

fn checkEncoder(comptime E: type, comptime es: []const Encoding, seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    var b8: [128]u8 = undefined;
    var b16: [64]u16 = undefined;
    inline for (es) |e| {
        for ([_]Encoder.Mode{ .html, .fatal }) |mode| {
            for (0..rounds) |_| {
                const t8, const t16 = encoderInput(rng, &b8, &b16);
                try lockstepEncode(E, u8, e, .{ .mode = mode }, t8, rng);
                try lockstepEncode(E, u16, e, .{ .mode = mode }, t16, rng);
            }
        }
    }
}

test "EncoderFor one encoding, and a set's encoder, match Encoder" {
    inline for (codecs.implemented, 0..) |e, k| {
        try checkEncoder(specialized.EncoderFor(&.{e}), &.{e}, k);
    }
    try checkEncoder(specialized.EncoderFor(&codecs.implemented), &codecs.implemented, 1);
}

test "one family's state is the family's own, with no tag" {
    const D = specialized.DecoderFor(&.{.windows_1252});
    const single_byte = @import("single_byte.zig");
    try testing.expect(@FieldType(D, "state") == single_byte.Decoder);
    try testing.expect(@sizeOf(D) < @sizeOf(Decoder));
    try testing.expect(D.Options == specialized.OptionsWithoutSniff);
    // The CJK families are not in it, so nothing reaches their tables.
    const N = specialized.DecoderFor(&specialized.no_cjk);
    try testing.expect(@typeInfo(@FieldType(N, "state")).@"union".fields.len == 5);
    try testing.expect(N.Options == Decoder.Options);
}

test "a byte order mark switches a specialized decoder to UTF-8, split anywhere" {
    const D = specialized.DecoderFor(&(.{.windows_1252} ++ specialized.bom_encodings));
    const input = "\xEF\xBB\xBF\xE2\x82\xAC";
    for (0..input.len + 1) |cut| {
        var d: D = .init(.windows_1252, .{});
        var out: [16]u8 = undefined;
        const a = d.decodeToUtf8(input[0..cut], &out, false);
        const b = d.decodeToUtf8(input[cut..], out[a.written..], true);
        try testing.expectEqualStrings("\u{20AC}", out[0 .. a.written + b.written]);
        try testing.expectEqual(Encoding.utf_8, d.encoding);
    }
}

test "a fresh decoder's buffer size is known at compile time" {
    const D = specialized.DecoderFor(&.{.windows_1252});
    const n = comptime D.init(.windows_1252, .{ .bom = .keep }).maxUtf8Len(16).?;
    var buf: [n]u8 = undefined;
    var d: D = .init(.windows_1252, .{ .bom = .keep });
    const r = d.decodeToUtf8("\x80" ** 16, &buf, true);
    try testing.expectEqual(Decoder.Result{ .status = .input_empty, .read = 16, .written = 48 }, r);
    // With sniffing, room for what UTF-8 or UTF-16 can write as well.
    const S = specialized.DecoderFor(&(.{.windows_1252} ++ specialized.bom_encodings));
    try testing.expectEqual(48, comptime S.init(.windows_1252, .{}).maxUtf8Len(16).?);
    try testing.expectEqual(16, comptime S.init(.windows_1252, .{}).maxUtf16Len(16).?);
}
