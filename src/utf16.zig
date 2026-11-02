//! UTF-16BE and UTF-16LE: the standard's shared UTF-16 decoder. Runs of
//! code units with no unpaired surrogate go through baskingspot/utf (to
//! UTF-8, transcoded; to UTF-16, copied, byte-swapped when the byte order
//! is not the machine's, and validated); each unpaired surrogate and each
//! unit split across calls goes through the standard's algorithm here.
//! Neither has an encoder: their output encoding is UTF-8.

const std = @import("std");
const utf = @import("utf");
const codec = @import("codec.zig");
const Encoding = codec.Encoding;
const DecodeResult = codec.DecodeResult;

pub const encodings = [_]Encoding{ .utf_16be, .utf_16le };

const little = codec.native_endian == .little;
const validate_native = if (little) utf.validate.utf16leWithErrors else utf.validate.utf16beWithErrors;

inline fn isLead(u: u16) bool {
    return u >= 0xD800 and u <= 0xDBFF;
}

inline fn isTrail(u: u16) bool {
    return u >= 0xDC00 and u <= 0xDFFF;
}

pub const Decoder = struct {
    /// The standard's "is UTF-16BE decoder".
    big_endian: bool,
    /// The standard's "UTF-16 leading byte".
    lead_byte: ?u8 = null,
    /// The standard's "UTF-16 leading surrogate", 0 for null.
    lead_surrogate: u16 = 0,

    pub fn init(e: Encoding) Decoder {
        return .{ .big_endian = e == .utf_16be };
    }

    inline fn unitOf(d: *const Decoder, first: u8, second: u8) u16 {
        return if (d.big_endian) @as(u16, first) << 8 | second else @as(u16, second) << 8 | first;
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
        while (true) {
            if (d.lead_byte == null and d.lead_surrogate == 0 and src.len - i >= 2) {
                const r = d.bulk(Unit, src[i..], dst[o..]);
                i += r.read;
                o += r.written;
            }
            if (i == src.len) {
                if (!last or (d.lead_byte == null and d.lead_surrogate == 0)) {
                    return .{ .status = .input_empty, .read = i, .written = o };
                }
                // The stream ends with half a unit or a leading surrogate.
                if (mode == .fatal) {
                    d.lead_byte = null;
                    d.lead_surrogate = 0;
                    return .{ .status = .malformed, .read = i, .written = o };
                }
                o += codec.tryPut(Unit, dst, o, codec.replacement_character) orelse
                    return .{ .status = .output_full, .read = i, .written = o };
                d.lead_byte = null;
                d.lead_surrogate = 0;
                return .{ .status = .input_empty, .read = i, .written = o };
            }
            // One unit by the standard's algorithm. Its bytes are taken
            // from `src` (`used` of them) only once it is handled, so a
            // unit read again, or one that does not fit, stays unread.
            var unit: u16 = undefined;
            var used: usize = undefined;
            if (d.lead_byte) |lb| {
                unit = d.unitOf(lb, src[i]);
                used = 1;
            } else if (src.len - i >= 2) {
                unit = d.unitOf(src[i], src[i + 1]);
                used = 2;
            } else {
                d.lead_byte = src[i];
                i += 1;
                continue;
            }
            if (d.lead_surrogate != 0) {
                if (isTrail(unit)) {
                    const cp = 0x10000 + ((@as(u21, d.lead_surrogate) - 0xD800) << 10) + (unit - 0xDC00);
                    o += codec.tryPut(Unit, dst, o, cp) orelse return .{
                        .status = .output_full,
                        .read = i,
                        .written = o,
                    };
                    i += used;
                    d.lead_byte = null;
                    d.lead_surrogate = 0;
                    continue;
                }
                // An error for the leading surrogate; the unit is read
                // again.
                if (mode == .fatal) {
                    d.lead_surrogate = 0;
                    return .{ .status = .malformed, .read = i, .written = o };
                }
                o += codec.tryPut(Unit, dst, o, codec.replacement_character) orelse
                    return .{ .status = .output_full, .read = i, .written = o };
                d.lead_surrogate = 0;
                continue;
            }
            if (isLead(unit)) {
                i += used;
                d.lead_byte = null;
                d.lead_surrogate = unit;
                continue;
            }
            if (isTrail(unit)) {
                if (mode == .fatal) {
                    i += used;
                    d.lead_byte = null;
                    return .{ .status = .malformed, .read = i, .written = o };
                }
                o += codec.tryPut(Unit, dst, o, codec.replacement_character) orelse
                    return .{ .status = .output_full, .read = i, .written = o };
            } else {
                o += codec.tryPut(Unit, dst, o, unit) orelse return .{
                    .status = .output_full,
                    .read = i,
                    .written = o,
                };
            }
            i += used;
            d.lead_byte = null;
        }
    }

    const Bulk = struct { read: usize, written: usize };

    /// Whole units from the start of `src` with utf, up to the first
    /// unpaired surrogate, the end of the units that fit, or a window's
    /// end. Called only between units, with no surrogate pending.
    fn bulk(d: *const Decoder, comptime Unit: type, src: []const u8, dst: []Unit) Bulk {
        if (Unit == u16) {
            const n = @min(src.len / 2, dst.len);
            if (n == 0) return .{ .read = 0, .written = 0 };
            const units = dst[0..n];
            @memcpy(std.mem.sliceAsBytes(units), src[0 .. 2 * n]);
            if (d.big_endian == little) {
                for (units) |*u| u.* = @byteSwap(u.*);
            }
            const r = validate_native(units);
            const good = if (r.err == .none) n else r.count;
            return .{ .read = 2 * good, .written = good };
        }
        // To UTF-8 through an aligned copy of the units, in their own byte
        // order, which utf converts from directly.
        var buf: [256]u16 = undefined;
        const n: usize = @min(src.len / 2, buf.len, dst.len / 3);
        if (n == 0) return .{ .read = 0, .written = 0 };
        const units = buf[0..n];
        @memcpy(std.mem.sliceAsBytes(units), src[0 .. 2 * n]);
        const r = if (d.big_endian) utf.convert.utf16beToUtf8(units, dst) else utf.convert.utf16leToUtf8(units, dst);
        return .{ .read = 2 * (if (r.err == .none) n else r.count), .written = r.written };
    }

    pub fn maxLen(d: *const Decoder, comptime Unit: type, n: usize) ?usize {
        const bytes = std.math.add(usize, n, @intFromBool(d.lead_byte != null)) catch return null;
        // A unit each, a pending surrogate's error or pair, and half a
        // unit's error at the end.
        const units = bytes / 2 + 2;
        return if (Unit == u16) units else codec.mulAdd(units, 3, 0);
    }
};

const testing = std.testing;

test "UTF-16LE and BE, with unpaired surrogates" {
    var le = Decoder.init(.utf_16le);
    var out: [16]u16 = undefined;
    const r = le.decode(u16, "a\x00\x3d\xd8\x00\xde\x00\xd8b\x00\x00\xdc", &out, true, .replacement);
    try testing.expectEqualSlices(u16, &.{ 'a', 0xD83D, 0xDE00, 0xFFFD, 'b', 0xFFFD }, out[0..r.written]);
    var be = Decoder.init(.utf_16be);
    var bytes: [32]u8 = undefined;
    const s = be.decode(u8, "\x00a\xd8\x3d\xde\x00\xd8", &bytes, true, .replacement);
    try testing.expectEqualStrings("a\u{1F600}\u{FFFD}", bytes[0..s.written]);
}

test "a pair split across calls, and fatal positions" {
    var le = Decoder.init(.utf_16le);
    var out: [4]u16 = undefined;
    try testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 3, .written = 0 },
        le.decode(u16, "\x3d\xd8\x00", &out, false, .fatal),
    );
    try testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 1, .written = 2 },
        le.decode(u16, "\xde", &out, true, .fatal),
    );
    var f = Decoder.init(.utf_16le);
    // A leading surrogate, then "a": the error ends before "a".
    try testing.expectEqual(
        DecodeResult{ .status = .malformed, .read = 2, .written = 0 },
        f.decode(u16, "\x3d\xd8a\x00", &out, true, .fatal),
    );
    try testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 2, .written = 1 },
        f.decode(u16, "a\x00", &out, true, .fatal),
    );
}
