//! EUC-KR: the standard's EUC-KR decoder and encoder, over index EUC-KR
//! (src/tables/euc_kr.zig), which is KS X 1001 with the Unified Hangul
//! Code extension (windows-949).
//!
//! A byte below 0x80 is ASCII and a lead byte from 0x81 to 0xFE starts a
//! two-byte sequence, a trail byte from 0x41 to 0xFE: pointer
//! (lead - 0x81) * 190 + (trail - 0x41), one code point each, all in the
//! BMP. An error restores an ASCII trail byte to the stream, so within one
//! call it is read again; a lead byte that a call's input cuts off is held
//! in the decoder and finished on the next call.

const std = @import("std");
const codec = @import("codec.zig");
const gb18030 = @import("gb18030.zig");
const index = @import("tables/euc_kr.zig");
const Encoding = codec.Encoding;
const DecodeResult = codec.DecodeResult;
const EncodeResult = codec.EncodeResult;

pub const encodings = [_]Encoding{.euc_kr};

/// The index code point of `lead`, from 0x81 to 0xFE, and `trail`, or
/// null for an error.
inline fn lookup(lead: u8, trail: u8) ?u21 {
    if (trail < 0x41 or trail == 0xFF) return null;
    return index.decode((@as(u32, lead) - 0x81) * 190 + (trail - 0x41));
}

/// Writes `cp`, an index code point, at `dst[o..]` and returns the units
/// written, or 0 when it does not fit. Every index code point is from
/// U+00A1 to U+FFE6: one UTF-16 unit, or two or three UTF-8 bytes. Not an
/// optional: LLVM merges the two paths of one through memory.
inline fn putIndex(comptime Unit: type, dst: []Unit, o: usize, cp: u32) usize {
    if (Unit == u16) {
        if (o == dst.len) return 0;
        dst[o] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        if (dst.len - o < 2) return 0;
        dst[o..][0..2].* = .{ @intCast(0xC0 | cp >> 6), @intCast(0x80 | (cp & 0x3F)) };
        return 2;
    }
    if (dst.len - o < 3) return 0;
    dst[o..][0..3].* = .{ @intCast(0xE0 | cp >> 12), @intCast(0x80 | (cp >> 6 & 0x3F)), @intCast(0x80 | (cp & 0x3F)) };
    return 3;
}

pub const Decoder = struct {
    /// The standard's EUC-KR lead, 0 for none.
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
        while (i < src.len) {
            const b = src[i];
            if (b < 0x80) {
                if (src.len - i >= codec.ascii_block and dst.len - o >= codec.ascii_block) {
                    const n = gb18030.asciiRun(Unit, src[i..], dst[o..]);
                    i += n;
                    o += n;
                    continue;
                }
                if (o == dst.len) return .{ .status = .output_full, .read = i, .written = o };
                dst[o] = b;
                i += 1;
                o += 1;
                continue;
            }
            // A two-byte sequence in the index, the common case.
            if (b != 0x80 and b != 0xFF and src.len - i >= 2) {
                const t = src[i + 1];
                if (t >= 0x41 and t != 0xFF) {
                    // Unwrapped to a u32 at once: a captured `?u21` goes
                    // through a stack slot on every character.
                    const cp: u32 = index.decode((@as(u32, b) - 0x81) * 190 + (t - 0x41)) orelse 0;
                    if (cp != 0) {
                        const n = putIndex(Unit, dst, o, cp);
                        if (n == 0) return .{ .status = .output_full, .read = i, .written = o };
                        i += 2;
                        o += n;
                        continue;
                    }
                }
            }
            var at: Pos = .{ .i = i, .o = o };
            if (d.slowStep(Unit, src, dst, last, mode, &at)) |r| return r;
            i = at.i;
            o = at.o;
        }
        return .{ .status = .input_empty, .read = src.len, .written = o };
    }

    const Pos = struct { i: usize, o: usize };

    /// The standard's steps on the bytes at `src[at.i]`, `src[at.i] >= 0x80`,
    /// everything the two-byte path does not take, out of line. Moves `at`
    /// past them, or returns the call's result.
    noinline fn slowStep(
        d: *Decoder,
        comptime Unit: type,
        src: []const u8,
        dst: []Unit,
        last: bool,
        mode: codec.DecoderMode,
        at: *Pos,
    ) ?DecodeResult {
        const i = at.i;
        const o = at.o;
        const b = src[i];
        if (b == 0x80 or b == 0xFF) {
            if (mode == .fatal) return .{ .status = .malformed, .read = i + 1, .written = o };
            at.o += codec.tryPut(Unit, dst, o, codec.replacement_character) orelse
                return .{ .status = .output_full, .read = i, .written = o };
            at.i += 1;
            return null;
        }
        if (i + 1 == src.len) {
            if (!last) {
                d.lead = b;
                return .{ .status = .input_empty, .read = src.len, .written = o };
            }
            if (mode == .fatal) return .{ .status = .malformed, .read = src.len, .written = o };
            const n = codec.tryPut(Unit, dst, o, codec.replacement_character) orelse
                return .{ .status = .output_full, .read = i, .written = o };
            return .{ .status = .input_empty, .read = src.len, .written = o + n };
        }
        const r = put(Unit, dst, o, b, src[i + 1], mode) orelse
            return .{ .status = .output_full, .read = i, .written = o };
        at.i += r.read;
        at.o += r.written;
        if (r.err and mode == .fatal) return .{ .status = .malformed, .read = at.i, .written = at.o };
        return null;
    }

    const Put = struct { read: usize, written: usize, err: bool };

    /// Decodes `lead` and `trail` into `dst[o..]`: the bytes taken (one if
    /// an error restores an ASCII trail byte), the units written, and
    /// whether it was an error (and nothing was written, in fatal mode).
    /// Null when the output does not fit.
    inline fn put(comptime Unit: type, dst: []Unit, o: usize, lead: u8, trail: u8, mode: codec.DecoderMode) ?Put {
        if (lookup(lead, trail)) |cp| {
            const n = codec.tryPut(Unit, dst, o, cp) orelse return null;
            return .{ .read = 2, .written = n, .err = false };
        }
        const read: usize = if (trail < 0x80) 1 else 2;
        if (mode == .fatal) return .{ .read = read, .written = 0, .err = true };
        const n = codec.tryPut(Unit, dst, o, codec.replacement_character) orelse return null;
        return .{ .read = read, .written = n, .err = true };
    }

    pub fn maxLen(d: *const Decoder, comptime Unit: type, n: usize) ?usize {
        // Each byte, held or new, ends at most one character, all in the
        // BMP: a UTF-16 unit, or three UTF-8 bytes.
        const total = std.math.add(usize, n, @intFromBool(d.lead != 0)) catch return null;
        return if (Unit == u16) total else codec.mulAdd(total, 3, 0);
    }
};

/// `codec.putNcr`, out of line.
noinline fn putNcr(dst: []u8, o: usize, cp: u21) ?usize {
    return codec.putNcr(dst, o, cp);
}

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
        while (i < src.len) {
            const c = src[i];
            if (c < 0x80) {
                if (src.len - i >= codec.ascii_block and dst.len - o >= codec.ascii_block) {
                    const n = gb18030.asciiRunOut(Unit, src[i..], dst[o..]);
                    i += n;
                    o += n;
                    continue;
                }
                if (o == dst.len) return .{ .status = .output_full, .read = i, .written = o };
                dst[o] = @intCast(c);
                i += 1;
                o += 1;
                continue;
            }
            const s = gb18030.readScalar(Unit, src, i);
            const cp: u21 = @intCast(s.cp);
            if (index.encode(cp)) |pointer| {
                if (dst.len - o < 2) return .{ .status = .output_full, .read = i, .written = o };
                dst[o..][0..2].* = .{ @intCast(pointer / 190 + 0x81), @intCast(pointer % 190 + 0x41) };
                i += s.len;
                o += 2;
                continue;
            }
            if (mode == .fatal) return .{
                .status = .unmappable,
                .read = i + s.len,
                .written = o,
                .unmappable = cp,
            };
            o += putNcr(dst, o, cp) orelse return .{ .status = .output_full, .read = i, .written = o };
            i += s.len;
        }
        return .{ .status = .input_empty, .read = i, .written = o };
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
    var d = Decoder.init(.euc_kr);
    return d.decode(u8, src, out, true, mode);
}

fn expectDecode(src: []const u8, want: []const u8) !void {
    var out: [64]u8 = undefined;
    const r = decodeAll(src, .replacement, &out);
    try testing.expectEqual(codec.DecodeStatus.input_empty, r.status);
    try testing.expectEqualStrings(want, out[0..r.written]);
}

test "decoder: KS X 1001, the UHC extension, and errors" {
    try expectDecode("a\xB0\xA1b", "a\u{AC00}b");
    try expectDecode("\x81\x41\xFD\xFE", "\u{AC02}\u{8A70}");
    // A trail byte below 0x41, or 0x7F in range with no index entry, is
    // ASCII and restored; a non-ASCII one is taken with the lead.
    try expectDecode("\x81\x40", "\u{FFFD}@");
    try expectDecode("\xB0\x7F", "\u{FFFD}\x7F");
    try expectDecode("\xB0\x5B", "\u{FFFD}[");
    try expectDecode("\xC9\xA1", "\u{FFFD}");
    try expectDecode("\xFE\xA1", "\u{FFFD}");
    try expectDecode("\xB0\xFF", "\u{FFFD}");
    try expectDecode("\xB0\x80", "\u{FFFD}");
    try expectDecode("\x80\xFFa", "\u{FFFD}\u{FFFD}a");
    // A non-ASCII trail byte is taken even where it could lead the next
    // sequence: 0xB0 0xA1 alone is U+AC00.
    try expectDecode("\xC9\xB0\xA1", "\u{FFFD}\u{FFFD}");
    try expectDecode("a\xB0", "a\u{FFFD}");
    var out: [16]u8 = undefined;
    try testing.expectEqual(
        DecodeResult{ .status = .malformed, .read = 2, .written = 1 },
        decodeAll("a\x81\x40", .fatal, &out),
    );
    try testing.expectEqual(
        DecodeResult{ .status = .malformed, .read = 3, .written = 1 },
        decodeAll("a\xC9\xA1", .fatal, &out),
    );
    try testing.expectEqual(
        DecodeResult{ .status = .malformed, .read = 2, .written = 1 },
        decodeAll("a\xB0", .fatal, &out),
    );
    // The character does not fit in two bytes.
    var d = Decoder.init(.euc_kr);
    try testing.expectEqual(
        DecodeResult{ .status = .output_full, .read = 1, .written = 1 },
        d.decode(u8, "a\xB0\xA1", out[0..2], true, .replacement),
    );
}

test "decoder: a lead byte held across calls" {
    var d = Decoder.init(.euc_kr);
    var out: [16]u8 = undefined;
    try testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 2, .written = 1 },
        d.decode(u8, "a\xB0", &out, false, .replacement),
    );
    try testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 2, .written = 4 },
        d.decode(u8, "\xA1b", &out, false, .replacement),
    );
    try testing.expectEqualStrings("\u{AC00}b", out[0..4]);
    // An ASCII byte after the held lead is restored.
    _ = d.decode(u8, "\xB0", &out, false, .replacement);
    const r = d.decode(u8, "@", &out, true, .replacement);
    try testing.expectEqualStrings("\u{FFFD}@", out[0..r.written]);
    // In fatal mode the error is the held lead; the ASCII byte is this call's.
    _ = d.decode(u8, "\xB0", &out, false, .fatal);
    try testing.expectEqual(
        DecodeResult{ .status = .malformed, .read = 0, .written = 0 },
        d.decode(u8, " ", &out, true, .fatal),
    );
    try testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 1, .written = 1 },
        d.decode(u8, " ", &out, true, .fatal),
    );
    // A held lead the stream ends on.
    _ = d.decode(u8, "\xB0", &out, false, .replacement);
    try testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 0, .written = 3 },
        d.decode(u8, "", &out, true, .replacement),
    );
}

fn encodeAll(src: []const u8, mode: codec.EncoderMode, out: []u8) EncodeResult {
    var e = Encoder.init(.euc_kr);
    return e.encode(u8, src, out, true, mode);
}

test "encoder: index pointers and errors" {
    var out: [64]u8 = undefined;
    const r = encodeAll("a\u{AC00}\u{AC02}\u{8A70}\u{80}\u{1F600}", .html, &out);
    try testing.expectEqualStrings("a\xB0\xA1\x81\x41\xFD\xFE&#128;&#128512;", out[0..r.written]);
    try testing.expectEqual(
        EncodeResult{ .status = .unmappable, .read = 3, .written = 1, .unmappable = 0x80 },
        encodeAll("a\u{80}b", .fatal, &out),
    );
    try testing.expectEqual(
        EncodeResult{ .status = .output_full, .read = 1, .written = 1 },
        encodeAll("a\u{AC00}", .html, out[0..2]),
    );
}

test "every two-byte sequence decodes to its index code point, and encodes back" {
    var lead: u16 = 0x81;
    while (lead <= 0xFE) : (lead += 1) {
        var trail: u16 = 0x41;
        while (trail <= 0xFE) : (trail += 1) {
            const bytes = [2]u8{ @intCast(lead), @intCast(trail) };
            var out: [4]u8 = undefined;
            const r = decodeAll(&bytes, .fatal, &out);
            const want = index.decode((lead - 0x81) * 190 + trail - 0x41);
            if (want == null) {
                try testing.expectEqual(codec.DecodeStatus.malformed, r.status);
                try testing.expectEqual(@as(usize, if (trail < 0x80) 1 else 2), r.read);
                continue;
            }
            try testing.expectEqual(codec.DecodeStatus.input_empty, r.status);
            try testing.expectEqual(want.?, codec.readScalar(u8, out[0..r.written], 0).cp);
            // Index EUC-KR has no code point twice.
            var back: [4]u8 = undefined;
            const w = encodeAll(out[0..r.written], .fatal, &back);
            try testing.expectEqual(codec.EncodeStatus.input_empty, w.status);
            try testing.expectEqualSlices(u8, &bytes, back[0..w.written]);
        }
    }
}
