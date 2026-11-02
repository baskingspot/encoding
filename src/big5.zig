//! Big5: the standard's Big5 decoder and encoder, over index Big5
//! (src/tables/big5.zig), which is Big5 with the Hong Kong Supplementary
//! Character Set and other common extensions.
//!
//! A byte below 0x80 is ASCII and a lead byte from 0x81 starts a two-byte
//! sequence. Four pointers decode to two code points each; the rest to
//! one, some above U+FFFF. The encoder skips the HKSCS pointers below
//! (0xA1 - 0x81) * 157 and takes the last pointer for six code points,
//! which the generated table's `encode` already does.

const std = @import("std");
const codec = @import("codec.zig");
const gb18030 = @import("gb18030.zig");
const index = @import("tables/big5.zig");
const Encoding = codec.Encoding;
const DecodeResult = codec.DecodeResult;
const EncodeResult = codec.EncodeResult;

pub const encodings = [_]Encoding{.big5};

/// The code points of a two-byte sequence: `second` is 0 unless the
/// pointer is one of the four that decode to two.
const Pair = struct { first: u21, second: u21 = 0 };

/// The code points of `lead` and `trail`, or null for an error.
inline fn lookup(lead: u8, trail: u8) ?Pair {
    if (!((trail >= 0x40 and trail <= 0x7E) or (trail >= 0xA1 and trail <= 0xFE))) return null;
    const offset: u32 = if (trail < 0x7F) 0x40 else 0x62;
    const pointer = (@as(u32, lead) - 0x81) * 157 + (trail - offset);
    switch (pointer) {
        1133 => return .{ .first = 0xCA, .second = 0x304 },
        1135 => return .{ .first = 0xCA, .second = 0x30C },
        1164 => return .{ .first = 0xEA, .second = 0x304 },
        1166 => return .{ .first = 0xEA, .second = 0x30C },
        else => return .{ .first = index.decode(pointer) orelse return null },
    }
}

pub const Decoder = struct {
    /// The standard's Big5 leading, 0 for none.
    lead: u8 = 0,

    pub fn init(e: Encoding) Decoder {
        _ = e;
        return .{};
    }

    pub fn decode(
        d: *Decoder,
        comptime Unit: type,
        src: []const u8,
        dst: []Unit,
        last: bool,
        mode: codec.DecoderMode,
    ) DecodeResult {
        var i: usize = 0;
        var o: usize = 0;
        if (d.lead != 0) {
            if (src.len == 0) {
                if (!last) return .{ .status = .input_empty, .read = 0, .written = 0 };
                if (mode == .fatal) {
                    d.lead = 0;
                    return .{ .status = .malformed, .read = 0, .written = 0 };
                }
                o = codec.tryPut(Unit, dst, 0, codec.replacement_character) orelse
                    return .{ .status = .output_full, .read = 0, .written = 0 };
                d.lead = 0;
                return .{ .status = .input_empty, .read = 0, .written = o };
            }
            const r = put(Unit, dst, 0, d.lead, src[0], mode) orelse
                return .{ .status = .output_full, .read = 0, .written = 0 };
            d.lead = 0;
            i = r.read - 1;
            o = r.written;
            if (r.err and mode == .fatal) return .{ .status = .malformed, .read = i, .written = o };
        }
        while (true) {
            const room = @min(src.len - i, dst.len - o);
            const ascii = codec.asciiPrefixBlocks(src[i..][0..room]);
            if (ascii != 0) {
                gb18030.copyAscii(Unit, dst[o..][0..ascii], src[i..][0..ascii]);
                i += ascii;
                o += ascii;
            }
            const end = @min(src.len, i + codec.ascii_block);
            while (i < end) {
                const b = src[i];
                if (b < 0x80) {
                    if (o == dst.len) return .{ .status = .output_full, .read = i, .written = o };
                    dst[o] = b;
                    i += 1;
                    o += 1;
                    continue;
                }
                if (b == 0x80 or b == 0xFF) {
                    if (mode == .fatal) return .{ .status = .malformed, .read = i + 1, .written = o };
                    o += codec.tryPut(Unit, dst, o, codec.replacement_character) orelse
                        return .{ .status = .output_full, .read = i, .written = o };
                    i += 1;
                    continue;
                }
                if (i + 1 == src.len) {
                    if (!last) {
                        d.lead = b;
                        return .{ .status = .input_empty, .read = src.len, .written = o };
                    }
                    if (mode == .fatal) return .{ .status = .malformed, .read = src.len, .written = o };
                    o += codec.tryPut(Unit, dst, o, codec.replacement_character) orelse
                        return .{ .status = .output_full, .read = i, .written = o };
                    return .{ .status = .input_empty, .read = src.len, .written = o };
                }
                const r = put(Unit, dst, o, b, src[i + 1], mode) orelse
                    return .{ .status = .output_full, .read = i, .written = o };
                i += r.read;
                o += r.written;
                if (r.err and mode == .fatal) return .{ .status = .malformed, .read = i, .written = o };
            }
            if (i >= src.len) return .{ .status = .input_empty, .read = src.len, .written = o };
        }
    }

    const Put = struct { read: usize, written: usize, err: bool };

    /// Decodes `lead` and `trail` into `dst[o..]`: the bytes taken (one if
    /// an error restores an ASCII trail byte), the units written, and
    /// whether it was an error (and nothing was written, in fatal mode).
    /// Null when the output does not fit.
    inline fn put(comptime Unit: type, dst: []Unit, o: usize, lead: u8, trail: u8, mode: codec.DecoderMode) ?Put {
        if (lookup(lead, trail)) |p| {
            if (p.second == 0) {
                const n = codec.tryPut(Unit, dst, o, p.first) orelse return null;
                return .{ .read = 2, .written = n, .err = false };
            }
            // Both code points are in the BMP, two UTF-8 bytes each.
            const need: usize = if (Unit == u16) 2 else 4;
            if (dst.len - o < need) return null;
            const n = codec.put(Unit, dst, o, p.first);
            return .{ .read = 2, .written = n + codec.put(Unit, dst, o + n, p.second), .err = false };
        }
        const read: usize = if (trail < 0x80) 1 else 2;
        if (mode == .fatal) return .{ .read = read, .written = 0, .err = true };
        const n = codec.tryPut(Unit, dst, o, codec.replacement_character) orelse return null;
        return .{ .read = read, .written = n, .err = true };
    }

    pub fn maxLen(d: *const Decoder, comptime Unit: type, n: usize) ?usize {
        // Each byte, held or new, ends at most one character, a UTF-16
        // unit, or three UTF-8 bytes for one (U+FFFD); two bytes are at
        // most four UTF-8 bytes (two code points, or one above U+FFFF) and
        // two units.
        const total = std.math.add(usize, n, @intFromBool(d.lead != 0)) catch return null;
        return if (Unit == u16) total else codec.mulAdd(total, 3, 0);
    }
};

pub const Encoder = struct {
    pub fn init(e: Encoding) Encoder {
        _ = e;
        return .{};
    }

    pub fn encode(
        e: *Encoder,
        comptime Unit: type,
        src: []const Unit,
        dst: []u8,
        last: bool,
        mode: codec.EncoderMode,
    ) EncodeResult {
        _ = e;
        _ = last;
        var i: usize = 0;
        var o: usize = 0;
        while (true) {
            const room = @min(src.len - i, dst.len - o);
            const ascii = gb18030.asciiUnits(Unit, src[i..][0..room]);
            if (ascii != 0) {
                gb18030.narrowAscii(Unit, dst[o..][0..ascii], src[i..][0..ascii]);
                i += ascii;
                o += ascii;
            }
            const end = @min(src.len, i + codec.ascii_block);
            while (i < end) {
                const c = src[i];
                if (c < 0x80) {
                    if (o == dst.len) return .{ .status = .output_full, .read = i, .written = o };
                    dst[o] = @intCast(c);
                    i += 1;
                    o += 1;
                    continue;
                }
                const s = codec.readScalar(Unit, src, i);
                if (index.encode(s.cp)) |pointer| {
                    if (dst.len - o < 2) return .{ .status = .output_full, .read = i, .written = o };
                    const trail: u8 = @intCast(pointer % 157);
                    const offset: u8 = if (trail < 0x3F) 0x40 else 0x62;
                    dst[o] = @intCast(pointer / 157 + 0x81);
                    dst[o + 1] = trail + offset;
                    o += 2;
                } else {
                    if (mode == .fatal) return .{
                        .status = .unmappable,
                        .read = i + s.len,
                        .written = o,
                        .unmappable = s.cp,
                    };
                    o += codec.putNcr(dst, o, s.cp) orelse return .{ .status = .output_full, .read = i, .written = o };
                }
                i += s.len;
            }
            if (i == src.len) return .{ .status = .input_empty, .read = i, .written = o };
        }
    }

    pub fn maxLen(e: *const Encoder, comptime Unit: type, n: usize, mode: codec.EncoderMode) ?usize {
        _ = e;
        // In html mode `&#65533;` for one ill-formed unit; in fatal mode two
        // bytes for a UTF-16 unit, or for a UTF-8 character of two or more.
        if (mode == .html) return codec.mulAdd(n, 8, 0);
        return codec.mulAdd(n, if (Unit == u16) 2 else 1, 0);
    }
};

const testing = std.testing;

fn decodeAll(src: []const u8, mode: codec.DecoderMode, out: []u8) DecodeResult {
    var d = Decoder.init(.big5);
    return d.decode(u8, src, out, true, mode);
}

fn expectDecode(src: []const u8, want: []const u8) !void {
    var out: [64]u8 = undefined;
    const r = decodeAll(src, .replacement, &out);
    try testing.expectEqual(codec.DecodeStatus.input_empty, r.status);
    try testing.expectEqualStrings(want, out[0..r.written]);
}

test "decoder: two-code-point pointers, astral code points, and errors" {
    try expectDecode("\x88\x62\x88\x64\x88\xA3\x88\xA5", "\u{CA}\u{304}\u{CA}\u{30C}\u{EA}\u{304}\u{EA}\u{30C}");
    try expectDecode("\x87\x40", "\u{43F0}");
    try expectDecode("\x89\x40", "\u{2A3A9}");
    try expectDecode("\xA4\x40", "\u{4E00}");
    // An ASCII trail byte is restored; another is taken with the lead.
    try expectDecode("\x81\x40", "\u{FFFD}@");
    try expectDecode("\xA4\x20", "\u{FFFD} ");
    try expectDecode("\xA4\x80", "\u{FFFD}");
    try expectDecode("\x80\xFFa", "\u{FFFD}\u{FFFD}a");
    try expectDecode("a\xA4", "a\u{FFFD}");
    var out: [16]u8 = undefined;
    try testing.expectEqual(
        DecodeResult{ .status = .malformed, .read = 2, .written = 1 },
        decodeAll("a\x81\x40", .fatal, &out),
    );
    // The pair does not fit in three bytes.
    var d = Decoder.init(.big5);
    try testing.expectEqual(
        DecodeResult{ .status = .output_full, .read = 0, .written = 0 },
        d.decode(u8, "\x88\x62", out[0..3], true, .replacement),
    );
}

test "decoder: a lead byte held across calls" {
    var d = Decoder.init(.big5);
    var out: [16]u8 = undefined;
    try testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 2, .written = 1 },
        d.decode(u8, "a\xA4", &out, false, .replacement),
    );
    try testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 2, .written = 4 },
        d.decode(u8, "\x40b", &out, false, .replacement),
    );
    try testing.expectEqualStrings("\u{4E00}b", out[0..4]);
    _ = d.decode(u8, "\xA4", &out, false, .fatal);
    // The error is the held lead; the ASCII byte is this call's.
    try testing.expectEqual(
        DecodeResult{ .status = .malformed, .read = 0, .written = 0 },
        d.decode(u8, " ", &out, true, .fatal),
    );
}

fn encodeAll(src: []const u8, mode: codec.EncoderMode, out: []u8) EncodeResult {
    var e = Encoder.init(.big5);
    return e.encode(u8, src, out, true, mode);
}

test "encoder: first pointers outside HKSCS, last for six code points" {
    var out: [64]u8 = undefined;
    const r = encodeAll("a\u{4E00}\u{2550}\u{5341}\u{43F0}\u{2A3A9}\u{CA}", .html, &out);
    try testing.expectEqualStrings("a\xA4\x40\xF9\xF9\xA4\x51&#17392;&#172969;&#202;", out[0..r.written]);
    try testing.expectEqual(
        EncodeResult{ .status = .unmappable, .read = 4, .written = 1, .unmappable = 0x43F0 },
        encodeAll("a\u{43F0}", .fatal, &out),
    );
}

test "every two-byte sequence decodes, and what encodes goes back to the same code points" {
    var lead: u16 = 0x81;
    while (lead <= 0xFE) : (lead += 1) {
        for ([_][2]u8{ .{ 0x40, 0x7E }, .{ 0xA1, 0xFE } }) |range| {
            var trail: u16 = range[0];
            while (trail <= range[1]) : (trail += 1) {
                const bytes = [2]u8{ @intCast(lead), @intCast(trail) };
                var out: [8]u8 = undefined;
                const r = decodeAll(&bytes, .fatal, &out);
                if (r.status == .malformed) {
                    const offset: u16 = if (trail < 0x7F) 0x40 else 0x62;
                    try testing.expectEqual(@as(?u21, null), index.decode((lead - 0x81) * 157 + trail - offset));
                    continue;
                }
                var back: [16]u8 = undefined;
                const w = encodeAll(out[0..r.written], .fatal, &back);
                if (w.status == .unmappable) {
                    // Only HKSCS pointers below 0xA1 have code points the
                    // encoder does not write.
                    try testing.expect(lead < 0xA1);
                    continue;
                }
                var again: [8]u8 = undefined;
                const r2 = decodeAll(back[0..w.written], .fatal, &again);
                try testing.expectEqualStrings(out[0..r.written], again[0..r2.written]);
            }
        }
    }
}
