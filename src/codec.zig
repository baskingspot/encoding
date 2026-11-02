//! What every codec family shares: the results a decode or encode call
//! returns, the error modes, the output writers for UTF-8 and UTF-16, the
//! input reader encoders use, and numeric character references.
//!
//! A family (single_byte.zig, utf8.zig, ...) implements the standard's
//! decoder and encoder for its encodings over these, and codecs.zig
//! registers it. docs/slop/adding-an-encoding.md is the contract.

const std = @import("std");
const builtin = @import("builtin");
const utf = @import("utf");

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

/// The units at the start of `s`, bytes or UTF-16 units, in whole ASCII
/// blocks: a multiple of `ascii_block` at or below the index of the first
/// non-ASCII unit. The caller finishes the scan unit by unit.
pub inline fn asciiPrefixBlocks(comptime Unit: type, s: []const Unit) usize {
    const V = @Vector(ascii_block, Unit);
    var i: usize = 0;
    while (s.len - i >= ascii_block) : (i += ascii_block) {
        const v: V = s[i..][0..ascii_block].*;
        if (@reduce(.Or, v >= @as(V, @splat(0x80)))) break;
    }
    return i;
}

/// Copies ASCII bytes to UTF-8, or widens them to UTF-16. `src.len` is a
/// multiple of `ascii_block`.
pub inline fn copyAscii(comptime Unit: type, dst: []Unit, src: []const u8) void {
    if (Unit == u8) {
        @memcpy(dst, src);
        return;
    }
    var k: usize = 0;
    while (k < src.len) : (k += ascii_block) {
        const v: @Vector(ascii_block, u8) = src[k..][0..ascii_block].*;
        dst[k..][0..ascii_block].* = @as(@Vector(ascii_block, u16), v);
    }
}

/// Copies ASCII UTF-8 to bytes, or narrows ASCII UTF-16 units to them.
/// `src.len` is a multiple of `ascii_block`.
pub inline fn narrowAscii(comptime Unit: type, dst: []u8, src: []const Unit) void {
    if (Unit == u8) {
        @memcpy(dst, src);
        return;
    }
    var k: usize = 0;
    while (k < src.len) : (k += ascii_block) {
        const v: @Vector(ascii_block, u16) = src[k..][0..ascii_block].*;
        dst[k..][0..ascii_block].* = @as(@Vector(ascii_block, u8), @truncate(v));
    }
}

/// A bit for each lane of `mask`, lane 0 in the lowest bit. A bool vector
/// bitcasts lane 0 to the highest bit on big-endian targets.
pub inline fn highBits(mask: @Vector(ascii_block, bool)) u16 {
    const bits: u16 = @bitCast(mask);
    return if (native_endian == .little) bits else @bitReverse(bits);
}

/// Copies the ASCII bytes at the start of `src`, which starts with one,
/// to `dst`, widened for UTF-16, a block at a time while both have a block
/// left, and returns how many it copied. `dst` may hold more after them,
/// which the caller overwrites.
pub inline fn asciiRun(comptime Unit: type, src: []const u8, dst: []Unit) usize {
    const V = @Vector(ascii_block, u8);
    var k: usize = 0;
    while (src.len - k >= ascii_block and dst.len - k >= ascii_block) {
        const v: V = src[k..][0..ascii_block].*;
        dst[k..][0..ascii_block].* = if (Unit == u8) v else @as(@Vector(ascii_block, u16), v);
        const high = highBits(v >= @as(V, @splat(0x80)));
        if (high != 0) return k + @ctz(high);
        k += ascii_block;
    }
    return k;
}

/// Copies the ASCII units at the start of `src`, UTF-8 or UTF-16 that
/// starts with one, to `dst`, narrowed, a block at a time while both have
/// a block left, and returns how many it copied. `dst` may hold more after
/// them, which the caller overwrites.
pub inline fn asciiRunOut(comptime Unit: type, src: []const Unit, dst: []u8) usize {
    const V = @Vector(ascii_block, Unit);
    var k: usize = 0;
    while (src.len - k >= ascii_block and dst.len - k >= ascii_block) {
        const v: V = src[k..][0..ascii_block].*;
        dst[k..][0..ascii_block].* = if (Unit == u8) v else @as(@Vector(ascii_block, u8), @truncate(v));
        const high = highBits(v >= @as(V, @splat(0x80)));
        if (high != 0) return k + @ctz(high);
        k += ascii_block;
    }
    return k;
}

/// Copies whole blocks of ASCII bytes from the start of `src` to `dst`,
/// widened for UTF-16, while both have a block left, and returns how many
/// it copied: 0 when the first block holds a byte from 0x80. After one
/// block, more ASCII likely follows, so it goes on two blocks at a time.
pub inline fn asciiBlocks(comptime Unit: type, src: []const u8, dst: []Unit) usize {
    const V = @Vector(ascii_block, u8);
    const v: V = src[0..ascii_block].*;
    if (@reduce(.Or, v >= @as(V, @splat(0x80)))) return 0;
    dst[0..ascii_block].* = if (Unit == u8) v else @as(@Vector(ascii_block, u16), v);
    var k: usize = ascii_block;
    const P = @Vector(2 * ascii_block, u8);
    while (src.len - k >= 2 * ascii_block and dst.len - k >= 2 * ascii_block) : (k += 2 * ascii_block) {
        const p: P = src[k..][0 .. 2 * ascii_block].*;
        if (@reduce(.Or, p >= @as(P, @splat(0x80)))) break;
        dst[k..][0 .. 2 * ascii_block].* = if (Unit == u8) p else @as(@Vector(2 * ascii_block, u16), p);
    }
    return k;
}

/// `asciiBlocks` from UTF-8 or UTF-16 to bytes, narrowed.
pub inline fn asciiBlocksOut(comptime Unit: type, src: []const Unit, dst: []u8) usize {
    const V = @Vector(ascii_block, Unit);
    const v: V = src[0..ascii_block].*;
    if (@reduce(.Or, v >= @as(V, @splat(0x80)))) return 0;
    dst[0..ascii_block].* = if (Unit == u8) v else @as(@Vector(ascii_block, u8), @truncate(v));
    var k: usize = ascii_block;
    const P = @Vector(2 * ascii_block, Unit);
    while (src.len - k >= 2 * ascii_block and dst.len - k >= 2 * ascii_block) : (k += 2 * ascii_block) {
        const p: P = src[k..][0 .. 2 * ascii_block].*;
        if (@reduce(.Or, p >= @as(P, @splat(0x80)))) break;
        dst[k..][0 .. 2 * ascii_block].* = if (Unit == u8) p else @as(@Vector(2 * ascii_block, u8), @truncate(p));
    }
    return k;
}

/// The UTF-16 units a decoder that has no SIMD UTF-8 path of its own
/// (single_byte.zig, x_user_defined.zig) stages at a time: it decodes up
/// to this many to UTF-16 a block at a time, then `bmpToUtf8` transcodes
/// them with utf's SIMD.
pub const stage_len = 256;

/// What `bmpToUtf8` did: the units it read and the bytes it wrote.
pub const Converted = struct { read: usize, written: usize };

const native_to_utf8 = if (native_endian == .little) utf.convert.utf16leToUtf8 else utf.convert.utf16beToUtf8;

/// utf's checked UTF-8 to UTF-16 in the machine's byte order: an encoder
/// that has no SIMD UTF-8 path of its own stages its input with it.
pub const utf8_to_native = if (native_endian == .little) utf.convert.utf8ToUtf16le else utf.convert.utf8ToUtf16be;

/// Transcodes `src`, UTF-16 in the machine's byte order with no surrogates,
/// to UTF-8 at the start of `dst`, as many characters as fit whole.
pub fn bmpToUtf8(src: []const u16, dst: []u8) Converted {
    const r = native_to_utf8(src, dst);
    return .{ .read = if (r.err == .none) src.len else r.count, .written = r.written };
}

/// Whether `s`, UTF-8, holds three or more characters from U+0080, or
/// two from U+0800: more than `encodeStaged` costs to start. Sparser
/// text, as Latin with the odd accented letter, goes faster a character
/// at a time between ASCII runs.
pub inline fn denseUtf8(s: *const [ascii_block]u8) bool {
    const v: @Vector(ascii_block, u8) = s.*;
    return @popCount(highBits(v >= @as(@Vector(ascii_block, u8), @splat(0x80)))) >= 6;
}

/// Encodes UTF-8 from the start of `src` into `dst` through UTF-16, for
/// an encoder whose characters are one byte each and that has no SIMD
/// UTF-8 path of its own: utf transcodes up to `stage_len` bytes, and
/// `coder` encodes the units, `coder.encodeBlock(s, d)` a block at a time
/// (the lane of the first unit it cannot map, or `ascii_block`) and
/// `coder.byteOf(u)` one non-ASCII unit at a time (0 for none). In html
/// mode a character the encoding lacks becomes a numeric character
/// reference here too, so that a run of them does not go back through
/// utf one at a time. Stops at the first such character in fatal mode, at
/// ill-formed UTF-8 (which utf ends the units at), and when `dst` is full;
/// returns the bytes read and written.
pub noinline fn encodeStaged(coder: anytype, src: []const u8, dst: []u8, mode: EncoderMode) Converted {
    const W = @Vector(ascii_block, u16);
    var stage: [stage_len]u16 = undefined;
    const units = utf8_to_native(src[0..@min(src.len, stage.len)], &stage).written;
    var k: usize = 0;
    var r: usize = 0;
    var w: usize = 0;
    while (k < units) {
        if (units - k >= ascii_block and dst.len - w >= ascii_block) {
            const a = asciiBlocksOut(u16, stage[k..units], dst[w..]);
            if (a != 0) {
                k += a;
                r += a;
                w += a;
                continue;
            }
            const u: W = stage[k..][0..ascii_block].*;
            const n = coder.encodeBlock(stage[k..][0..ascii_block], dst[w..][0..ascii_block]);
            // A unit from U+0080 took two bytes of UTF-8, from U+0800 three.
            const done: u16 = if (n == ascii_block) 0xFFFF else (@as(u16, 1) << @intCast(n)) - 1;
            r += n + @as(usize, @popCount(highBits(u >= @as(W, @splat(0x80))) & done)) +
                @popCount(highBits(u >= @as(W, @splat(0x800))) & done);
            k += n;
            w += n;
            if (n == ascii_block) continue;
        } else {
            const u = stage[k];
            const b: u8 = if (u < 0x80) @intCast(u) else coder.byteOf(u);
            if (b != 0 or u == 0) {
                if (w == dst.len) break;
                dst[w] = b;
                w += 1;
                k += 1;
                r += unitsOf(u8, u);
                continue;
            }
        }
        // `stage[k]` is a character the encoding lacks: a code point in
        // the BMP, or a pair of surrogates, which utf writes only whole.
        if (mode == .fatal) break;
        const u = stage[k];
        const pair = u >= 0xD800 and u <= 0xDBFF;
        const cp: u21 = if (pair) 0x10000 + ((@as(u21, u) - 0xD800) << 10) + (stage[k + 1] - 0xDC00) else u;
        w += putNcr(dst, w, cp) orelse break;
        k += if (pair) 2 else 1;
        r += unitsOf(u8, cp);
    }
    return .{ .read = r, .written = w };
}

/// A scalar value an encoder read, and the units it took, as plain
/// integers. The code point is a `u32`, not a `u21`: LLVM merges a `u21`
/// from two paths through a three-byte store and a four-byte load, a
/// store-forwarding stall on every character.
pub const Read = struct { cp: u32, len: u32 };

/// The scalar value at `src[i]`, `src[i] >= 0x80`, as `readScalar` reads
/// it, with well-formed two- and three-byte UTF-8 sequences inline.
/// `first` is the length the caller sees most, whose check comes first:
/// 2 for the Latin, Greek, Cyrillic, Hebrew, and Arabic text of the
/// single-byte encodings, 3 for CJK. Each check costs the other's
/// characters a compare and a branch, which on short characters shows.
pub inline fn read(comptime Unit: type, src: []const Unit, i: usize, comptime first: u2) Read {
    if (Unit == u8) {
        const c = src[i];
        inline for (if (first == 2) .{ 2, 3 } else .{ 3, 2 }) |n| {
            if (n == 2 and c >= 0xC2 and c <= 0xDF and src.len - i >= 2) {
                const c1 = src[i + 1];
                if (c1 & 0xC0 == 0x80) return .{ .cp = @as(u32, c & 0x1F) << 6 | (c1 & 0x3F), .len = 2 };
            }
            // E0 needs second bytes from A0 (no overlong forms), ED up to
            // 9F (no surrogates), the others any continuation byte; E0
            // second, as only scripts below U+1000 have it.
            if (n == 3 and src.len - i >= 3) {
                const c1 = src[i + 1];
                const c2 = src[i + 2];
                const tail = c1 & 0xC0 == 0x80 and c2 & 0xC0 == 0x80;
                if ((c >= 0xE1 and c <= 0xEF and c != 0xED and tail) or (c == 0xE0 and c1 >= 0xA0 and tail)) {
                    return .{ .cp = @as(u32, c & 0xF) << 12 | @as(u32, c1 & 0x3F) << 6 | (c2 & 0x3F), .len = 3 };
                }
            }
        }
    } else {
        const u = src[i];
        if (u < 0xD800 or u > 0xDFFF) return .{ .cp = u, .len = 1 };
    }
    const s = readScalar(Unit, src, i);
    return .{ .cp = s.cp, .len = @intCast(s.len) };
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

test "read agrees with readScalar on every two- and three-byte prefix" {
    var buf: [3]u8 = undefined;
    for (0x80..0x100) |a| for (0..0x100) |b| for (0..0x100) |c| {
        if (c != 0 and (a < 0xE0 or a > 0xEF)) break;
        buf = .{ @intCast(a), @intCast(b), @intCast(c) };
        // With the third byte and without it, so a cut sequence is seen.
        for ([_][]const u8{ buf[0..3], buf[0..2] }) |s| {
            const want = readScalar(u8, s, 0);
            inline for (.{ 2, 3 }) |first| {
                const got = read(u8, s, 0, first);
                try std.testing.expectEqual(@as(u32, want.cp), got.cp);
                try std.testing.expectEqual(want.len, got.len);
            }
        }
    };
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
