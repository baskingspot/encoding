//! What every codec family shares: the results a decode or encode call
//! returns, the error modes, the output writers for UTF-8 and UTF-16, the
//! input reader encoders use, and numeric character references.
//!
//! A family (single_byte.zig, utf8.zig, ...) implements the standard's
//! decoder and encoder for its encodings over these, and codecs.zig
//! registers it. docs/slop/adding-an-encoding.md is the contract.

const std = @import("std");
const builtin = @import("builtin");

pub const Encoding = @import("encoding.zig").Encoding;

/// Why a decode call returned.
pub const DecodeStatus = enum(u8) {
    /// Every byte of `src` was read. With `last` set, the stream is
    /// finished too: a sequence it cut off has been reported.
    input_empty,
    /// The next character does not fit in what is left of `dst`. Call
    /// again with the unread input and more room.
    output_full,
    /// Fatal mode only: the input holds an error. The malformed sequence
    /// ends at `read` (it may have started in an earlier call), and the
    /// decoder can go on from there with the rest of the input.
    malformed,
};

/// What a decode call did: how many bytes of `src` it read, how many code
/// units of `dst` it wrote, and why it stopped.
pub const DecodeResult = struct {
    status: DecodeStatus,
    read: usize,
    written: usize,
};

/// Why an encode call returned.
pub const EncodeStatus = enum(u8) {
    /// Every code unit of `src` was read; with `last`, the stream is
    /// finished too.
    input_empty,
    /// The next character, or the escape that ends the stream, does not
    /// fit in what is left of `dst`.
    output_full,
    /// Fatal mode only: `unmappable` has no representation in the
    /// encoding. It is the last character of `src[0..read]`; the encoder
    /// can go on from there.
    unmappable,
};

/// What an encode call did: how many code units of `src` it read, how
/// many bytes of `dst` it wrote, and why it stopped.
pub const EncodeResult = struct {
    status: EncodeStatus,
    read: usize,
    written: usize,
    /// With `.unmappable`, the character that cannot be encoded.
    unmappable: u21 = 0,
};

/// A decoder's error mode, as the standard names them: "replacement"
/// writes U+FFFD for each error, "fatal" stops at the first.
pub const DecoderMode = enum(u1) { replacement, fatal };

/// An encoder's error mode, as the standard names them: "html" writes a
/// numeric character reference (`&#8364;`) for each character the
/// encoding cannot represent, "fatal" stops at the first.
pub const EncoderMode = enum(u1) { html, fatal };

pub const replacement_character: u21 = 0xFFFD;

/// The code units a decoder writes: `u8` for UTF-8, `u16` for UTF-16 in
/// the machine's byte order.
pub fn checkUnit(comptime Unit: type) void {
    if (Unit != u8 and Unit != u16) @compileError("decoders write u8 (UTF-8) or u16 (UTF-16)");
}

/// The code units `cp` takes in UTF-8 (`u8`) or UTF-16 (`u16`).
pub inline fn unitsOf(comptime Unit: type, cp: u21) usize {
    if (Unit == u16) return if (cp < 0x10000) 1 else 2;
    if (cp < 0x80) return 1;
    if (cp < 0x800) return 2;
    if (cp < 0x10000) return 3;
    return 4;
}

/// Writes `cp`, a scalar value, at `dst[o..]`, which has room for it, and
/// returns the units written.
pub inline fn put(comptime Unit: type, dst: []Unit, o: usize, cp: u21) usize {
    if (Unit == u16) {
        if (cp < 0x10000) {
            dst[o] = @intCast(cp);
            return 1;
        }
        const v = cp - 0x10000;
        dst[o] = @intCast(0xD800 | (v >> 10));
        dst[o + 1] = @intCast(0xDC00 | (v & 0x3FF));
        return 2;
    }
    if (cp < 0x80) {
        dst[o] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        dst[o] = @intCast(0xC0 | (cp >> 6));
        dst[o + 1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        dst[o] = @intCast(0xE0 | (cp >> 12));
        dst[o + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        dst[o + 2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
    dst[o] = @intCast(0xF0 | (cp >> 18));
    dst[o + 1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
    dst[o + 2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
    dst[o + 3] = @intCast(0x80 | (cp & 0x3F));
    return 4;
}

/// Writes `cp` at `dst[o..]` if it fits; returns the units written, or
/// null when it does not fit.
pub inline fn tryPut(comptime Unit: type, dst: []Unit, o: usize, cp: u21) ?usize {
    if (dst.len - o < unitsOf(Unit, cp)) return null;
    return put(Unit, dst, o, cp);
}

/// The longest numeric character reference, `&#1114111;`.
pub const max_ncr_len = 10;

/// Writes the standard's "html" error for `cp`, `&#` and its decimal value
/// and `;`, at `dst[o..]` if it fits; returns the bytes written or null.
pub fn putNcr(dst: []u8, o: usize, cp: u21) ?usize {
    var digits: [7]u8 = undefined;
    var n: usize = 0;
    var v: u32 = cp;
    while (true) {
        digits[digits.len - 1 - n] = @intCast('0' + v % 10);
        n += 1;
        v /= 10;
        if (v == 0) break;
    }
    const len = n + 3;
    if (dst.len - o < len) return null;
    dst[o] = '&';
    dst[o + 1] = '#';
    @memcpy(dst[o + 2 ..][0..n], digits[digits.len - n ..]);
    dst[o + 2 + n] = ';';
    return len;
}

/// One scalar value read from an encoder's input, and the code units it
/// took.
pub const Scalar = struct { cp: u21, len: usize };

/// Reads the scalar value at `src[i]`, `i < src.len`, from UTF-8 (`u8`) or
/// UTF-16 in the machine's byte order (`u16`). Ill-formed input reads as
/// U+FFFD: in UTF-8 one for each maximal subpart, as the standard's UTF-8
/// decoder does, and in UTF-16 one for each unpaired surrogate. A
/// sequence cut off by the end of `src` is ill-formed here; the encoder
/// wrappers hold one back until the next call.
pub fn readScalar(comptime Unit: type, src: []const Unit, i: usize) Scalar {
    if (Unit == u16) {
        const u = src[i];
        if (u < 0xD800 or u > 0xDFFF) return .{ .cp = u, .len = 1 };
        if (u <= 0xDBFF and i + 1 < src.len) {
            const t = src[i + 1];
            if (t >= 0xDC00 and t <= 0xDFFF) {
                return .{ .cp = 0x10000 + ((@as(u21, u) - 0xD800) << 10) + (t - 0xDC00), .len = 2 };
            }
        }
        return .{ .cp = replacement_character, .len = 1 };
    }
    const b = src[i];
    if (b < 0x80) return .{ .cp = b, .len = 1 };
    const s = utf8Step(src[i..]);
    return switch (s) {
        .scalar => |c| c,
        .invalid => |n| .{ .cp = replacement_character, .len = n },
        .incomplete => |n| .{ .cp = replacement_character, .len = n },
    };
}

/// What the standard's UTF-8 decoder makes of the bytes at the start of
/// `s`, `s.len > 0`.
pub const Utf8Step = union(enum) {
    /// A whole, well-formed character.
    scalar: Scalar,
    /// An error: one U+FFFD for the first `n` bytes (the maximal subpart),
    /// then go on after them.
    invalid: usize,
    /// The first `n` bytes, all of `s`, begin a character that the end of
    /// `s` cuts off: an error at the end of the stream, otherwise wait for
    /// more input.
    incomplete: usize,
};

/// The standard's UTF-8 decoder over one character at the start of `s`.
pub fn utf8Step(s: []const u8) Utf8Step {
    const b = s[0];
    if (b < 0x80) return .{ .scalar = .{ .cp = b, .len = 1 } };
    var need: usize = undefined;
    var lower: u8 = 0x80;
    var upper: u8 = 0xBF;
    var cp: u21 = undefined;
    switch (b) {
        0xC2...0xDF => {
            need = 1;
            cp = b & 0x1F;
        },
        0xE0...0xEF => {
            if (b == 0xE0) lower = 0xA0;
            if (b == 0xED) upper = 0x9F;
            need = 2;
            cp = b & 0xF;
        },
        0xF0...0xF4 => {
            if (b == 0xF0) lower = 0x90;
            if (b == 0xF4) upper = 0x8F;
            need = 3;
            cp = b & 0x7;
        },
        else => return .{ .invalid = 1 },
    }
    var k: usize = 1;
    while (k <= need) : (k += 1) {
        if (k == s.len) return .{ .incomplete = k };
        const c = s[k];
        if (c < lower or c > upper) return .{ .invalid = k };
        lower = 0x80;
        upper = 0xBF;
        cp = (cp << 6) | (c & 0x3F);
    }
    return .{ .scalar = .{ .cp = cp, .len = need + 1 } };
}

/// How many code units at the end of `src` begin a character that its end
/// cuts off and that later input could complete: up to three UTF-8 bytes
/// that are a prefix of a well-formed sequence, or one leading surrogate.
pub fn incompleteTail(comptime Unit: type, src: []const Unit) usize {
    if (src.len == 0) return 0;
    if (Unit == u16) {
        const u = src[src.len - 1];
        return @intFromBool(u >= 0xD800 and u <= 0xDBFF);
    }
    // The last lead byte within the last three bytes.
    const start = src.len -| 3;
    var i = src.len;
    while (i > start) {
        i -= 1;
        const b = src[i];
        if (b < 0x80) return 0;
        if (b >= 0xC0) {
            return switch (utf8Step(src[i..])) {
                .incomplete => |n| n,
                else => 0,
            };
        }
    }
    return 0;
}

pub const native_endian = builtin.cpu.arch.endian();

/// `a * b + c`, or null on overflow: the max-length functions' arithmetic.
pub fn mulAdd(a: usize, b: usize, c: usize) ?usize {
    const m = std.math.mul(usize, a, b) catch return null;
    return std.math.add(usize, m, c) catch null;
}

/// The blocks the ASCII fast paths work in.
pub const ascii_block = 16;

/// The bytes at the start of `s` in whole ASCII blocks: a multiple of
/// `ascii_block` at or below the index of the first non-ASCII byte. The
/// caller finishes the scan byte by byte.
pub inline fn asciiPrefixBlocks(s: []const u8) usize {
    const V = @Vector(ascii_block, u8);
    var i: usize = 0;
    while (s.len - i >= ascii_block) : (i += ascii_block) {
        const v: V = s[i..][0..ascii_block].*;
        if (@reduce(.Or, v >= @as(V, @splat(0x80)))) break;
    }
    return i;
}

test "put and unitsOf agree with std.unicode" {
    const cps = [_]u21{ 0, 0x41, 0x7F, 0x80, 0x7FF, 0x800, 0xFFFD, 0xFFFF, 0x10000, 0x10FFFF };
    for (cps) |cp| {
        var buf: [4]u8 = undefined;
        const n = put(u8, &buf, 0, cp);
        var want: [4]u8 = undefined;
        const m = try std.unicode.utf8Encode(cp, &want);
        try std.testing.expectEqualSlices(u8, want[0..m], buf[0..n]);
        try std.testing.expectEqual(n, unitsOf(u8, cp));
        var w: [2]u16 = undefined;
        const k = put(u16, &w, 0, cp);
        try std.testing.expectEqual(k, unitsOf(u16, cp));
        try std.testing.expectEqual(cp, readScalar(u16, w[0..k], 0).cp);
        try std.testing.expectEqual(cp, readScalar(u8, buf[0..n], 0).cp);
    }
}

test "putNcr writes the shortest decimal" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("&#0;", buf[0..putNcr(&buf, 0, 0).?]);
    try std.testing.expectEqualStrings("&#8364;", buf[0..putNcr(&buf, 0, 0x20AC).?]);
    try std.testing.expectEqualStrings("&#1114111;", buf[0..putNcr(&buf, 0, 0x10FFFF).?]);
    try std.testing.expectEqual(@as(?usize, null), putNcr(buf[0..6], 0, 0x20AC));
}

test "utf8Step follows the standard's maximal subparts" {
    const T = std.testing;
    try T.expectEqual(Utf8Step{ .invalid = 1 }, utf8Step("\x80"));
    try T.expectEqual(Utf8Step{ .invalid = 1 }, utf8Step("\xC0\x80"));
    try T.expectEqual(Utf8Step{ .invalid = 1 }, utf8Step("\xE0\x80\x80"));
    try T.expectEqual(Utf8Step{ .invalid = 2 }, utf8Step("\xE0\xA0\x41"));
    try T.expectEqual(Utf8Step{ .invalid = 1 }, utf8Step("\xED\xA0\x80"));
    try T.expectEqual(Utf8Step{ .incomplete = 2 }, utf8Step("\xF0\x90"));
    try T.expectEqual(Utf8Step{ .invalid = 3 }, utf8Step("\xF0\x90\x80\x41"));
    try T.expectEqual(Utf8Step{ .invalid = 1 }, utf8Step("\xF5\x80"));
    try T.expectEqual(@as(u21, 0x10FFFF), utf8Step("\xF4\x8F\xBF\xBF").scalar.cp);
    try T.expectEqual(@as(usize, 2), incompleteTail(u8, "ab\xF0\x90"));
    try T.expectEqual(@as(usize, 0), incompleteTail(u8, "ab\xF0\x90\x80\x80"));
    try T.expectEqual(@as(usize, 0), incompleteTail(u8, "ab\xC0"));
    try T.expectEqual(@as(usize, 1), incompleteTail(u16, &.{ 0x41, 0xD800 }));
}
