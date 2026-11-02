//! x-user-defined: bytes below 0x80 are ASCII, and each byte from 0x80 is
//! U+F780 plus its offset from 0x80. Every byte decodes; the encoder maps
//! ASCII and U+F780 to U+F7FF and nothing else.
//!
//! Both directions are arithmetic on 16 lanes at once: a byte from 0x80
//! is its code point's low byte, so decoding adds 0xF700 to those lanes
//! and encoding truncates every lane it can map. Decoding to UTF-8 stages
//! the UTF-16 for utf to transcode, as single_byte.zig does.

const std = @import("std");
const codec = @import("codec.zig");
const Encoding = codec.Encoding;
const DecodeResult = codec.DecodeResult;
const EncodeResult = codec.EncodeResult;

pub const encodings = [_]Encoding{.x_user_defined};

const block = codec.ascii_block;
const V = @Vector(block, u8);
const W = @Vector(block, u16);

/// The code point of each byte of a block.
inline fn decodeBlock(s: *const [block]u8) W {
    const v: V = s.*;
    const wide: W = v;
    return @select(u16, v < @as(V, @splat(0x80)), wide, wide + @as(W, @splat(0xF700)));
}

pub const Decoder = struct {
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
        _ = d;
        _ = last;
        _ = mode;
        var i: usize = 0;
        var o: usize = 0;
        if (Unit == u16) {
            while (src.len - i >= block and dst.len - o >= block) {
                dst[o..][0..block].* = decodeBlock(src[i..][0..block]);
                i += block;
                o += block;
            }
        } else {
            // A block with a byte from 0x80 takes up to 48 bytes, and
            // each byte's four-byte store reaches one past its character.
            while (src.len - i >= block and dst.len - o >= 3 * block + 1) {
                const v: V = src[i..][0..block].*;
                dst[o..][0..block].* = v;
                if (codec.highBits(v >= @as(V, @splat(0x80))) == 0) {
                    i += block;
                    o += block;
                    continue;
                }
                if (src.len - i >= 4 * block) {
                    // Long input: up to `stage_len` bytes, whole blocks, to
                    // UTF-16, which utf transcodes as far as it fits.
                    var stage: [codec.stage_len]u16 = undefined;
                    const n = @min(stage.len, (src.len - i) / block * block);
                    var k: usize = 0;
                    while (k < n) : (k += block) stage[k..][0..block].* = decodeBlock(src[i + k ..][0..block]);
                    const c = codec.bmpToUtf8(stage[0..n], dst[o..]);
                    i += c.read;
                    o += c.written;
                    if (c.read != n) break;
                    continue;
                }
                // Short input, where a call into utf costs more than the
                // bytes: each byte as its UTF-8, little-endian in a `u32`:
                // itself, or EF, 9E or 9F, and 80 plus its low six bits.
                const wide: @Vector(block, u32) = v;
                const three = @as(@Vector(block, u32), @splat(0x80_9E_EF)) |
                    (wide >> @splat(6) & @as(@Vector(block, u32), @splat(1))) << @splat(8) |
                    (wide & @as(@Vector(block, u32), @splat(0x3F))) << @splat(16);
                const high = v >= @as(V, @splat(0x80));
                const words: [block]u32 = @select(u32, high, three, wide);
                const lens: [block]u8 = @select(u8, high, @as(V, @splat(3)), @as(V, @splat(1)));
                inline for (words, lens) |w, n| {
                    std.mem.writeInt(u32, dst[o..][0..4], w, .little);
                    o += n;
                }
                i += block;
            }
        }
        // The last bytes, fewer than a block, or all that is left once the
        // output is short of room.
        while (i < src.len) : (i += 1) {
            const b = src[i];
            const cp: u21 = if (b < 0x80) b else 0xF700 + @as(u21, b);
            o += codec.tryPut(Unit, dst, o, cp) orelse return .{ .status = .output_full, .read = i, .written = o };
        }
        return .{ .status = .input_empty, .read = i, .written = o };
    }

    pub fn maxLen(d: *const Decoder, comptime Unit: type, n: usize) ?usize {
        _ = d;
        return if (Unit == u16) n else codec.mulAdd(n, 3, 0);
    }
};

pub const Encoder = struct {
    pub fn init(e: Encoding) Encoder {
        _ = e;
        return .{};
    }

    /// Encodes the block of UTF-16 at `s` into `d` and returns
    /// `block`, or the lane of the first unit that is not ASCII or U+F780
    /// to U+F7FF, with the lanes before it encoded.
    pub inline fn encodeBlock(e: *const Encoder, s: *const [block]u16, d: *[block]u8) usize {
        _ = e;
        const u: W = s.*;
        const bytes: V = @truncate(u);
        d.* = bytes;
        const ascii = codec.highBits(u < @as(W, @splat(0x80)));
        const private = codec.highBits(u & @as(W, @splat(0xFF80)) == @as(W, @splat(0xF780)));
        const miss = ~(ascii | private);
        return if (miss == 0) block else @ctz(miss);
    }

    /// The byte for `u`, a non-ASCII unit, or 0 for none.
    pub inline fn byteOf(e: *const Encoder, u: u16) u8 {
        _ = e;
        return if (u & 0xFF80 == 0xF780) @truncate(u) else 0;
    }

    /// Encodes whole blocks of UTF-16 from the start of `src` while `dst`
    /// has room for one, up to the first unit `encodeBlock` stops at, and
    /// returns how many units it encoded.
    inline fn encodeBlocks(e: *const Encoder, src: []const u16, dst: []u8) usize {
        var k: usize = 0;
        while (src.len - k >= block and dst.len - k >= block) {
            const n = e.encodeBlock(src[k..][0..block], dst[k..][0..block]);
            k += n;
            if (n != block) break;
        }
        return k;
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
        while (i < src.len) {
            const c = src[i];
            if (Unit == u16 or (c < 0x80 and src.len - i >= 2 and src[i + 1] < 0x80)) {
                const k = if (Unit == u16)
                    e.encodeBlocks(src[i..], dst[o..])
                else
                    codec.asciiRunOut(u8, src[i..], dst[o..]);
                if (k != 0) {
                    i += k;
                    o += k;
                    continue;
                }
            } else if (src.len - i >= 4 * block and dst.len - o >= block and codec.denseUtf8(src[i..][0..block])) {
                const r = codec.encodeStaged(e, src[i..], dst[o..], mode);
                if (r.read != 0) {
                    i += r.read;
                    o += r.written;
                    continue;
                }
            }
            // One character: the one a block stopped at, or one of the
            // last, fewer than a block or than the room left.
            if (c < 0x80) {
                if (o == dst.len) return .{ .status = .output_full, .read = i, .written = o };
                dst[o] = @intCast(c);
                i += 1;
                o += 1;
                continue;
            }
            // U+F780 to U+F7FF in UTF-8 are EF, 9E or 9F, and a
            // continuation byte: the only three-byte characters this
            // encoding maps, inline.
            if (Unit == u8 and c == 0xEF and src.len - i >= 3 and
                src[i + 1] & 0xFE == 0x9E and src[i + 2] & 0xC0 == 0x80)
            {
                if (o == dst.len) return .{ .status = .output_full, .read = i, .written = o };
                dst[o] = 0x80 | (src[i + 1] & 1) << 6 | (src[i + 2] & 0x3F);
                i += 3;
                o += 1;
                continue;
            }
            const s = codec.read(Unit, src, i, 3);
            if (s.cp >= 0xF780 and s.cp <= 0xF7FF) {
                if (o == dst.len) return .{ .status = .output_full, .read = i, .written = o };
                dst[o] = @truncate(s.cp);
                o += 1;
            } else {
                if (mode == .fatal) return .{
                    .status = .unmappable,
                    .read = i + s.len,
                    .written = o,
                    .unmappable = @intCast(s.cp),
                };
                o += codec.putNcr(dst, o, @intCast(s.cp)) orelse
                    return .{ .status = .output_full, .read = i, .written = o };
            }
            i += s.len;
        }
        return .{ .status = .input_empty, .read = i, .written = o };
    }

    pub fn maxLen(e: *const Encoder, comptime Unit: type, n: usize, mode: codec.EncoderMode) ?usize {
        _ = e;
        _ = Unit;
        return if (mode == .fatal) n else codec.mulAdd(n, 8, 0);
    }
};

test "x-user-defined both ways" {
    var d = Decoder.init(.x_user_defined);
    var out: [8]u16 = undefined;
    const r = d.decode(u16, "a\x80\xff", &out, true, .fatal);
    try std.testing.expectEqualSlices(u16, &.{ 'a', 0xF780, 0xF7FF }, out[0..r.written]);
    var e = Encoder.init(.x_user_defined);
    var bytes: [16]u8 = undefined;
    const w = e.encode(u16, &.{ 'a', 0xF780, 0xF7FF, 0xF800 }, &bytes, true, .html);
    try std.testing.expectEqualStrings("a\x80\xff&#63488;", bytes[0..w.written]);
}
