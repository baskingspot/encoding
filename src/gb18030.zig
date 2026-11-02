//! GBK and gb18030: the standard's gb18030 decoder, which both share, and
//! its encoder, which GBK runs with "is GBK" set.
//!
//! A byte below 0x80 is ASCII and 0x80 is U+20AC; a lead byte from 0x81
//! starts a two-byte sequence, looked up in index gb18030
//! (src/tables/gb18030.zig), or a four-byte one when the second byte is a
//! digit, mapped by index gb18030 ranges (src/tables/gb18030_ranges.zig).
//! An error takes only the bytes the standard does not restore to the
//! stream, so within one call "restore" is reading the next byte again.
//! A sequence that a call's input cuts off is held in the decoder and
//! finished, by the same steps, on the next call.

const std = @import("std");
const codec = @import("codec.zig");
const index = @import("tables/gb18030.zig");
const ranges = @import("tables/gb18030_ranges.zig");
const Encoding = codec.Encoding;
const DecodeResult = codec.DecodeResult;
const EncodeResult = codec.EncodeResult;

pub const encodings = [_]Encoding{ .gbk, .gb18030 };

/// The index gb18030 ranges code point for `pointer`.
pub fn rangesCodePoint(pointer: u32) ?u21 {
    if ((pointer > 39419 and pointer < 189000) or pointer > 1237575) return null;
    if (pointer == 7457) return 0xE7C7;
    if (pointer >= ranges.supplementary_pointer) return @intCast(0x10000 + (pointer - ranges.supplementary_pointer));
    const k = lastAtMost(&ranges.pointers, pointer);
    return @intCast(ranges.code_points[k] + (pointer - ranges.pointers[k]));
}

/// The index gb18030 ranges pointer for `cp`, from U+0080.
pub fn rangesPointer(cp: u21) u32 {
    if (cp == 0xE7C7) return 7457;
    if (cp >= 0x10000) return ranges.supplementary_pointer + (cp - 0x10000);
    const k = lastAtMost(&ranges.code_points, cp);
    return ranges.pointers[k] + (cp - ranges.code_points[k]);
}

/// The index of the last of `items`, ascending, at most `x`; `items[0]`
/// is at most `x`.
fn lastAtMost(items: []const u16, x: u32) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid] <= x) lo = mid else hi = mid;
    }
    return lo;
}

/// What the decoder makes of the bytes at the start of a stream.
const Step = union(enum) {
    /// A code point from the first `len` bytes.
    cp: struct { cp: u21, len: u8 },
    /// An error, which takes the first `n` bytes; the rest are read again.
    err: u8,
    /// The bytes begin a sequence that only more input can finish.
    more,
};

/// The standard's decoder over the sequence at the start of `s`,
/// `s.len > 0`. `end` says that the stream ends with `s`.
inline fn step(s: []const u8, end: bool) Step {
    const b = s[0];
    if (b < 0x80) return .{ .cp = .{ .cp = b, .len = 1 } };
    if (b == 0x80) return .{ .cp = .{ .cp = 0x20AC, .len = 1 } };
    if (b == 0xFF) return .{ .err = 1 };
    // b is a lead byte, the standard's gb18030 first.
    if (s.len < 2) return if (end) .{ .err = 1 } else .more;
    const b2 = s[1];
    if (b2 >= 0x30 and b2 <= 0x39) {
        if (s.len < 3) return if (end) .{ .err = 2 } else .more;
        const b3 = s[2];
        // The second byte and this one are restored.
        if (b3 < 0x81 or b3 > 0xFE) return .{ .err = 1 };
        if (s.len < 4) return if (end) .{ .err = 3 } else .more;
        const b4 = s[3];
        // The second and third bytes and this one are restored.
        if (b4 < 0x30 or b4 > 0x39) return .{ .err = 1 };
        const pointer = (@as(u32, b) - 0x81) * (10 * 126 * 10) + (@as(u32, b2) - 0x30) * (10 * 126) +
            (@as(u32, b3) - 0x81) * 10 + b4 - 0x30;
        const cp = rangesCodePoint(pointer) orelse return .{ .err = 4 };
        return .{ .cp = .{ .cp = cp, .len = 4 } };
    }
    if ((b2 >= 0x40 and b2 <= 0x7E) or (b2 >= 0x80 and b2 <= 0xFE)) {
        const offset: u32 = if (b2 < 0x7F) 0x40 else 0x41;
        const pointer = (@as(u32, b) - 0x81) * 190 + (b2 - offset);
        if (index.decode(pointer)) |cp| return .{ .cp = .{ .cp = cp, .len = 2 } };
    }
    // An ASCII byte is restored.
    return .{ .err = if (b2 < 0x80) 1 else 2 };
}

pub const Decoder = struct {
    /// Bytes of a sequence that earlier calls' input cut off, or that an
    /// error restored after output ran out: the standard's gb18030 first,
    /// second, and third, and the bytes it restores.
    held: [3]u8 = undefined,
    held_len: u8 = 0,

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
        // The held bytes first, with as much of `src` as finishes them.
        while (d.held_len != 0) {
            const h = d.held_len;
            var buf: [4]u8 = undefined;
            @memcpy(buf[0..h], d.held[0..h]);
            const more = @min(4 - h, src.len - i);
            @memcpy(buf[h..][0..more], src[i..][0..more]);
            const s = step(buf[0 .. h + more], last and i + more == src.len);
            const n: u8, const cp: ?u21 = switch (s) {
                .more => {
                    // Everything left of `src` is part of the sequence.
                    @memcpy(d.held[h..][0..more], src[i..][0..more]);
                    d.held_len += @intCast(more);
                    return .{ .status = .input_empty, .read = src.len, .written = o };
                },
                .cp => |c| .{ c.len, c.cp },
                .err => |n| .{ n, null },
            };
            if (cp == null and mode == .fatal) {
                d.take(&i, n);
                return .{ .status = .malformed, .read = i, .written = o };
            }
            o += codec.tryPut(Unit, dst, o, cp orelse codec.replacement_character) orelse
                return .{ .status = .output_full, .read = i, .written = o };
            d.take(&i, n);
        }
        while (true) {
            // ASCII a block at a time while there is room for it.
            const room = @min(src.len - i, dst.len - o);
            const ascii = codec.asciiPrefixBlocks(src[i..][0..room]);
            if (ascii != 0) {
                copyAscii(Unit, dst[o..][0..ascii], src[i..][0..ascii]);
                i += ascii;
                o += ascii;
            }
            // Then a block's worth of characters, at least up to the first
            // non-ASCII byte.
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
                const s = step(src[i..], last);
                const n: u8, const cp: u21 = switch (s) {
                    .more => {
                        const rest = src[i..];
                        @memcpy(d.held[0..rest.len], rest);
                        d.held_len = @intCast(rest.len);
                        return .{ .status = .input_empty, .read = src.len, .written = o };
                    },
                    .cp => |c| .{ c.len, c.cp },
                    .err => |n| blk: {
                        if (mode == .fatal) return .{ .status = .malformed, .read = i + n, .written = o };
                        break :blk .{ n, codec.replacement_character };
                    },
                };
                o += codec.tryPut(Unit, dst, o, cp) orelse return .{ .status = .output_full, .read = i, .written = o };
                i += n;
            }
            if (i >= src.len) return .{ .status = .input_empty, .read = src.len, .written = o };
        }
    }

    /// Takes the first `n` bytes of the held bytes and then of
    /// `src[i.*..]`.
    fn take(d: *Decoder, i: *usize, n: u8) void {
        const h = d.held_len;
        if (n < h) {
            @memmove(d.held[0 .. h - n], d.held[n..h]);
            d.held_len = h - n;
        } else {
            i.* += n - h;
            d.held_len = 0;
        }
    }

    pub fn maxLen(d: *const Decoder, comptime Unit: type, n: usize) ?usize {
        // Each byte, held or new, ends at most one character: three UTF-8
        // bytes for one byte (U+20AC, U+FFFD) or two (the BMP), four for
        // four (above it), and a UTF-16 unit each, two for four.
        const total = std.math.add(usize, n, d.held_len) catch return null;
        return if (Unit == u16) total else codec.mulAdd(total, 3, 0);
    }
};

/// Copies ASCII bytes to UTF-8 or widens them to UTF-16.
pub inline fn copyAscii(comptime Unit: type, dst: []Unit, src: []const u8) void {
    if (Unit == u8) {
        @memcpy(dst, src);
        return;
    }
    const block = codec.ascii_block;
    var k: usize = 0;
    while (k < src.len) : (k += block) {
        const v: @Vector(block, u8) = src[k..][0..block].*;
        dst[k..][0..block].* = @as(@Vector(block, u16), v);
    }
}

/// The units at the start of `src` in whole ASCII blocks.
pub inline fn asciiUnits(comptime Unit: type, src: []const Unit) usize {
    if (Unit == u8) return codec.asciiPrefixBlocks(src);
    const block = codec.ascii_block;
    const V = @Vector(block, u16);
    var k: usize = 0;
    while (src.len - k >= block) : (k += block) {
        const v: V = src[k..][0..block].*;
        if (@reduce(.Or, v >= @as(V, @splat(0x80)))) break;
    }
    return k;
}

/// Copies ASCII units to bytes.
pub inline fn narrowAscii(comptime Unit: type, dst: []u8, src: []const Unit) void {
    if (Unit == u8) {
        @memcpy(dst, src);
        return;
    }
    const block = codec.ascii_block;
    var k: usize = 0;
    while (k < src.len) : (k += block) {
        const v: @Vector(block, u16) = src[k..][0..block].*;
        dst[k..][0..block].* = @as(@Vector(block, u8), @truncate(v));
    }
}

/// Up to four bytes of output, for an encoder's character.
pub const Bytes = struct { b: [4]u8, len: u8 };

/// The standard's encoder table for the Private Use code points
/// GB18030-2022 moved off two-byte sequences: each code point and its
/// two bytes.
fn privateUse(cp: u21) ?u16 {
    return switch (cp) {
        0xE78D => 0xA6D9,
        0xE78E => 0xA6DA,
        0xE78F => 0xA6DB,
        0xE790 => 0xA6DC,
        0xE791 => 0xA6DD,
        0xE792 => 0xA6DE,
        0xE793 => 0xA6DF,
        0xE794 => 0xA6EC,
        0xE795 => 0xA6ED,
        0xE796 => 0xA6F3,
        0xE81E => 0xFE59,
        0xE826 => 0xFE61,
        0xE82B => 0xFE66,
        0xE82C => 0xFE67,
        0xE832 => 0xFE6D,
        0xE843 => 0xFE7E,
        0xE854 => 0xFE90,
        0xE864 => 0xFEA0,
        else => null,
    };
}

pub const Encoder = struct {
    /// The standard's "is GBK".
    gbk: bool,

    pub fn init(e: Encoding) Encoder {
        return .{ .gbk = e == .gbk };
    }

    /// The bytes for `cp`, a non-ASCII scalar value, or null.
    inline fn lookup(e: *const Encoder, cp: u21) ?Bytes {
        // Index gb18030 maps 0xA3 0xA0 to U+3000, so U+E5E5 has no bytes.
        if (cp == 0xE5E5) return null;
        if (e.gbk and cp == 0x20AC) return .{ .b = .{ 0x80, 0, 0, 0 }, .len = 1 };
        if (cp >= 0xE78D and cp <= 0xE864) {
            if (privateUse(cp)) |v| return .{ .b = .{ @intCast(v >> 8), @truncate(v), 0, 0 }, .len = 2 };
        }
        if (index.encode(cp)) |pointer| {
            const trail: u8 = @intCast(pointer % 190);
            const offset: u8 = if (trail < 0x3F) 0x40 else 0x41;
            return .{ .b = .{ @intCast(pointer / 190 + 0x81), trail + offset, 0, 0 }, .len = 2 };
        }
        if (e.gbk) return null;
        var p = rangesPointer(cp);
        const b1: u8 = @intCast(p / (10 * 126 * 10));
        p %= 10 * 126 * 10;
        const b2: u8 = @intCast(p / (10 * 126));
        p %= 10 * 126;
        const b3: u8 = @intCast(p / 10);
        const b4: u8 = @intCast(p % 10);
        return .{ .b = .{ b1 + 0x81, b2 + 0x30, b3 + 0x81, b4 + 0x30 }, .len = 4 };
    }

    pub fn encode(
        e: *Encoder,
        comptime Unit: type,
        src: []const Unit,
        dst: []u8,
        last: bool,
        mode: codec.EncoderMode,
    ) EncodeResult {
        _ = last;
        var i: usize = 0;
        var o: usize = 0;
        while (true) {
            const room = @min(src.len - i, dst.len - o);
            const ascii = asciiUnits(Unit, src[i..][0..room]);
            if (ascii != 0) {
                narrowAscii(Unit, dst[o..][0..ascii], src[i..][0..ascii]);
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
                if (e.lookup(s.cp)) |out| {
                    if (dst.len - o < out.len) return .{ .status = .output_full, .read = i, .written = o };
                    @memcpy(dst[o..][0..out.len], out.b[0..out.len]);
                    o += out.len;
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
        // gb18030: four bytes for U+FFFD, which one ill-formed unit reads
        // as, and in html mode `&#58853;` for U+E5E5, one UTF-16 unit.
        // GBK: `&#65533;` for an ill-formed unit in html mode; in fatal
        // mode two bytes for a UTF-16 unit, or a UTF-8 character of two.
        if (!e.gbk) return codec.mulAdd(n, if (Unit == u16 and mode == .html) 8 else 4, 0);
        if (mode == .html) return codec.mulAdd(n, 8, 0);
        return codec.mulAdd(n, if (Unit == u16) 2 else 1, 0);
    }
};

const testing = std.testing;

fn decodeAll(comptime Unit: type, src: []const u8, mode: codec.DecoderMode, out: []Unit) DecodeResult {
    var d = Decoder.init(.gb18030);
    return d.decode(Unit, src, out, true, mode);
}

fn expectDecode(src: []const u8, want: []const u8) !void {
    var out: [64]u8 = undefined;
    const r = decodeAll(u8, src, .replacement, &out);
    try testing.expectEqual(codec.DecodeStatus.input_empty, r.status);
    try testing.expectEqualStrings(want, out[0..r.written]);
}

test "decoder: ASCII, U+20AC, two-byte and four-byte sequences" {
    try expectDecode("a\x80b", "a\u{20AC}b");
    try expectDecode("\xA3\xA0", "\u{3000}");
    try expectDecode("\xA6\xD9", "\u{FE10}");
    try expectDecode("\x81\x30\x81\x30", "\u{80}");
    try expectDecode("\x84\x31\xA4\x39", "\u{FFFF}");
    try expectDecode("\x81\x35\xF4\x37", "\u{E7C7}");
    try expectDecode("\x90\x30\x81\x30", "\u{10000}");
    try expectDecode("\xE3\x32\x9A\x35", "\u{10FFFF}");
}

test "decoder: errors restore the bytes the standard restores" {
    // Pointers past the ranges: one error for the four bytes.
    try expectDecode("\x84\x31\xA5\x30", "\u{FFFD}");
    try expectDecode("\xE3\x32\x9A\x36", "\u{FFFD}");
    // A bad fourth byte restores the second, the third, and itself: the
    // digit is ASCII, the third byte a new lead, and the fourth breaks it.
    try expectDecode("\x81\x30\x81\x20", "\u{FFFD}0\u{FFFD} ");
    // A bad third byte restores the second and itself.
    try expectDecode("\x81\x30\x20", "\u{FFFD}0 ");
    try expectDecode("\x81\x30\x81\xFF\x30", "\u{FFFD}0\u{FFFD}0");
    // A bad second byte is restored if it is ASCII.
    try expectDecode("\x81\x20", "\u{FFFD} ");
    try expectDecode("\x81\x7F", "\u{FFFD}\x7F");
    try expectDecode("\x81\xFF", "\u{FFFD}");
    try expectDecode("\xFF", "\u{FFFD}");
    // A sequence the end of the stream cuts off is one error.
    try expectDecode("\x81", "\u{FFFD}");
    try expectDecode("\x81\x30", "\u{FFFD}");
    try expectDecode("\x81\x30\x81", "\u{FFFD}");
}

test "decoder: fatal errors end just past what they take" {
    var out: [16]u8 = undefined;
    try testing.expectEqual(
        DecodeResult{ .status = .malformed, .read = 2, .written = 1 },
        decodeAll(u8, "a\x81\x30\x81\x20", .fatal, &out),
    );
    try testing.expectEqual(
        DecodeResult{ .status = .malformed, .read = 5, .written = 1 },
        decodeAll(u8, "a\x84\x31\xA5\x30", .fatal, &out),
    );
}

test "decoder: a sequence held across calls" {
    var d = Decoder.init(.gb18030);
    var out: [16]u8 = undefined;
    try testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 2, .written = 0 },
        d.decode(u8, "\x81\x30", &out, false, .replacement),
    );
    try testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 1, .written = 0 },
        d.decode(u8, "\x81", &out, false, .replacement),
    );
    // The fourth byte breaks it: U+FFFD for the first, then the digit,
    // then the held lead and the space.
    const r = d.decode(u8, " ", &out, true, .replacement);
    try testing.expectEqualStrings("\u{FFFD}0\u{FFFD} ", out[0..r.written]);
    // In fatal mode the error is in the held bytes, before this call's.
    d = Decoder.init(.gb18030);
    _ = d.decode(u8, "\x81\x30\x81", &out, false, .fatal);
    try testing.expectEqual(
        DecodeResult{ .status = .malformed, .read = 0, .written = 0 },
        d.decode(u8, " ", &out, true, .fatal),
    );
    try testing.expectEqual(
        DecodeResult{ .status = .malformed, .read = 0, .written = 1 },
        d.decode(u8, " ", &out, true, .fatal),
    );
    try testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 1, .written = 1 },
        d.decode(u8, " ", &out, true, .fatal),
    );
}

fn encodeAll(e: Encoding, src: []const u8, mode: codec.EncoderMode, out: []u8) EncodeResult {
    var enc = Encoder.init(e);
    return enc.encode(u8, src, out, true, mode);
}

fn expectEncode(e: Encoding, src: []const u8, want: []const u8) !void {
    var out: [64]u8 = undefined;
    const r = encodeAll(e, src, .html, &out);
    try testing.expectEqual(codec.EncodeStatus.input_empty, r.status);
    try testing.expectEqualStrings(want, out[0..r.written]);
}

test "encoder: gb18030 and GBK" {
    try expectEncode(.gb18030, "a\u{20AC}", "a\xA2\xE3");
    try expectEncode(.gbk, "a\u{20AC}", "a\x80");
    try expectEncode(.gb18030, "\u{3000}", "\xA1\xA1");
    try expectEncode(.gb18030, "\u{E5E5}", "&#58853;");
    try expectEncode(.gb18030, "\u{E78D}\u{FE10}\u{E864}", "\xA6\xD9\xA6\xD9\xFE\xA0");
    try expectEncode(.gb18030, "\u{80}\u{E7C7}\u{FFFF}", "\x81\x30\x81\x30\x81\x35\xF4\x37\x84\x31\xA4\x39");
    try expectEncode(.gb18030, "\u{10000}\u{10FFFF}", "\x90\x30\x81\x30\xE3\x32\x9A\x35");
    try expectEncode(.gbk, "\u{80}\u{10000}", "&#128;&#65536;");
    var out: [16]u8 = undefined;
    try testing.expectEqual(
        EncodeResult{ .status = .unmappable, .read = 4, .written = 1, .unmappable = 0xE5E5 },
        encodeAll(.gb18030, "a\u{E5E5}b", .fatal, &out),
    );
}

test "every two-byte sequence decodes, and encodes back unless another has its code point first" {
    var lead: u16 = 0x81;
    while (lead <= 0xFE) : (lead += 1) {
        var trail: u16 = 0x40;
        while (trail <= 0xFE) : (trail += 1) {
            if (trail == 0x7F) continue;
            const bytes = [2]u8{ @intCast(lead), @intCast(trail) };
            var out: [4]u8 = undefined;
            const r = decodeAll(u8, &bytes, .fatal, &out);
            try testing.expectEqual(codec.DecodeStatus.input_empty, r.status);
            var back: [8]u8 = undefined;
            const w = encodeAll(.gb18030, out[0..r.written], .fatal, &back);
            if (bytes[0] == 0xA3 and bytes[1] == 0xA0) {
                // U+3000, which 0xA1 0xA1 has first.
                try testing.expectEqual(codec.EncodeStatus.input_empty, w.status);
                try testing.expectEqualSlices(u8, "\xA1\xA1", back[0..w.written]);
                continue;
            }
            try testing.expectEqual(codec.EncodeStatus.input_empty, w.status);
            try testing.expectEqualSlices(u8, &bytes, back[0..w.written]);
        }
    }
}

test "every four-byte pointer in the ranges decodes, and encodes back unless two bytes have its code point" {
    var pointer: u32 = 0;
    while (pointer <= 1237575) : (pointer += if (pointer == 39419) 189000 - 39419 else 1) {
        var p = pointer;
        var bytes: [4]u8 = undefined;
        bytes[0] = @intCast(p / 12600 + 0x81);
        p %= 12600;
        bytes[1] = @intCast(p / 1260 + 0x30);
        p %= 1260;
        bytes[2] = @intCast(p / 10 + 0x81);
        bytes[3] = @intCast(p % 10 + 0x30);
        var out: [4]u8 = undefined;
        const r = decodeAll(u8, &bytes, .fatal, &out);
        try testing.expectEqual(codec.DecodeStatus.input_empty, r.status);
        const cp = codec.readScalar(u8, out[0..r.written], 0).cp;
        try testing.expectEqual(rangesCodePoint(pointer).?, cp);
        if (cp == 0xE5E5) continue;
        var back: [8]u8 = undefined;
        const w = encodeAll(.gb18030, out[0..r.written], .fatal, &back);
        try testing.expectEqual(codec.EncodeStatus.input_empty, w.status);
        if (w.written == 2) {
            try testing.expect(index.encode(cp) != null);
            continue;
        }
        try testing.expectEqualSlices(u8, &bytes, back[0..w.written]);
    }
}
