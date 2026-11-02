//! UTF-16BE and UTF-16LE: the standard's shared UTF-16 decoder. Runs of
//! code units with no unpaired surrogate are copied 32 and then eight
//! units at a time in registers (byte-swapped when the byte order is not
//! the machine's) while they hold no surrogate, to UTF-16, and while they
//! are ASCII, to UTF-8; the rest go through baskingspot/utf a window of 256 units at a
//! time (to UTF-8, transcoded; to UTF-16, validated). Each unpaired
//! surrogate and each unit split across calls goes through the standard's
//! algorithm here. Neither has an encoder: their output encoding is UTF-8.

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

    /// The units `bulk` hands utf at a time.
    const window = 256;

    /// Whole units from the start of `src`, up to the first unpaired
    /// surrogate, the end of the units that fit, or a window's end. Called
    /// only between units, with no surrogate pending.
    fn bulk(d: *const Decoder, comptime Unit: type, src: []const u8, dst: []Unit) Bulk {
        if (Unit == u16) {
            // 32, then eight, units at a time while they hold no
            // surrogate, copied (and swapped) in registers: no call, which
            // short inputs feel.
            const n = @min(src.len / 2, dst.len);
            var k: usize = 0;
            while (n - k >= 32) {
                const u = d.load(32, src[2 * k ..][0..64]);
                if (anySurrogate(32, u)) break;
                dst[k..][0..32].* = u;
                k += 32;
            }
            while (n - k >= 8) {
                const u = d.load(8, src[2 * k ..][0..16]);
                if (anySurrogate(8, u)) break;
                dst[k..][0..8].* = u;
                k += 8;
            }
            if (n - k < 8) return .{ .read = 2 * k, .written = k };
            // Surrogates: a window through utf, which checks pairs in bulk.
            const m: usize = @min(n - k, window);
            const units = dst[k..][0..m];
            @memcpy(std.mem.sliceAsBytes(units), src[2 * k ..][0 .. 2 * m]);
            if (d.big_endian == little) {
                for (units) |*u| u.* = @byteSwap(u.*);
            }
            const r = validate_native(units);
            const good = k + if (r.err == .none) m else r.count;
            return .{ .read = 2 * good, .written = good };
        }
        // ASCII 32, then eight, units at a time, narrowed in registers.
        var k: usize = 0;
        while (src.len / 2 - k >= 32 and dst.len - k >= 32) {
            const u = d.load(32, src[2 * k ..][0..64]);
            if (@reduce(.Or, u >= @as(@Vector(32, u16), @splat(0x80)))) break;
            dst[k..][0..32].* = @as(@Vector(32, u8), @truncate(u));
            k += 32;
        }
        while (src.len / 2 - k >= 8 and dst.len - k >= 8) {
            const u = d.load(8, src[2 * k ..][0..16]);
            if (@reduce(.Or, u >= @as(@Vector(8, u16), @splat(0x80)))) break;
            dst[k..][0..8].* = @as(@Vector(8, u8), @truncate(u));
            k += 8;
        }
        // Then a window through an aligned copy of the units, in their own
        // byte order, which utf converts from directly. The copy goes
        // sixteen bytes at a time, the last few one unit at a time: a
        // `@memcpy` of a length known only at run time is a call.
        var buf: [window]u16 = undefined;
        const n: usize = @min(src.len / 2 - k, buf.len, (dst.len - k) / 3);
        if (n < 16) {
            // A few units: a call into utf costs more than they do. A
            // surrogate goes to the standard's algorithm in `decode`.
            var o = k;
            var j: usize = 0;
            while (j < n) : (j += 1) {
                const u = d.unitOf(src[2 * (k + j)], src[2 * (k + j) + 1]);
                if (u >= 0xD800 and u <= 0xDFFF) break;
                o += codec.put(u8, dst, o, u);
            }
            return .{ .read = 2 * (k + j), .written = o };
        }
        const bytes = std.mem.sliceAsBytes(buf[0..n]);
        const from = src[2 * k ..][0 .. 2 * n];
        var c: usize = 0;
        while (bytes.len - c >= 64) : (c += 64) bytes[c..][0..64].* = from[c..][0..64].*;
        while (bytes.len - c >= 16) : (c += 16) bytes[c..][0..16].* = from[c..][0..16].*;
        while (c < bytes.len) : (c += 2) bytes[c..][0..2].* = from[c..][0..2].*;
        const r = if (d.big_endian)
            utf.convert.utf16beToUtf8(buf[0..n], dst[k..])
        else
            utf.convert.utf16leToUtf8(buf[0..n], dst[k..]);
        return .{ .read = 2 * (k + if (r.err == .none) n else r.count), .written = k + r.written };
    }

    /// `n` units from `s`, in the machine's byte order.
    inline fn load(d: *const Decoder, comptime n: usize, s: *const [2 * n]u8) @Vector(n, u16) {
        const bytes: @Vector(2 * n, u8) = s.*;
        const u: @Vector(n, u16) = @bitCast(bytes);
        return if (d.big_endian == little) @byteSwap(u) else u;
    }

    inline fn anySurrogate(comptime n: usize, u: @Vector(n, u16)) bool {
        const U = @Vector(n, u16);
        return @reduce(.Or, u & @as(U, @splat(0xF800)) == @as(U, @splat(0xD800)));
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

test "a window of units with surrogates, longer than utf takes at once" {
    // 'a' x 8, then a pair and 'b' x 400: the pair sends the units after
    // the first block to utf a window at a time.
    var src: [2 * 410]u8 = undefined;
    for (0..410) |k| src[2 * k ..][0..2].* = .{ 'b', 0 };
    for (0..8) |k| src[2 * k] = 'a';
    src[16..20].* = .{ 0x3d, 0xd8, 0x00, 0xde };
    var le = Decoder.init(.utf_16le);
    var out: [410]u16 = undefined;
    const r = le.decode(u16, &src, &out, true, .fatal);
    try testing.expectEqual(DecodeResult{ .status = .input_empty, .read = 820, .written = 410 }, r);
    try testing.expectEqualSlices(u16, &.{ 'a', 0xD83D, 0xDE00, 'b' }, out[7..11]);
    try testing.expectEqual(@as(u16, 'b'), out[409]);
}
