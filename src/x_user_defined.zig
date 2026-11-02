//! x-user-defined: bytes below 0x80 are ASCII, and each byte from 0x80 is
//! U+F780 plus its offset from 0x80. Every byte decodes; the encoder maps
//! ASCII and U+F780 to U+F7FF and nothing else.

const std = @import("std");
const codec = @import("codec.zig");
const Encoding = codec.Encoding;
const DecodeResult = codec.DecodeResult;
const EncodeResult = codec.EncodeResult;

pub const encodings = [_]Encoding{.x_user_defined};

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
        while (i < src.len) : (i += 1) {
            const b = src[i];
            const cp: u21 = if (b < 0x80) b else 0xF780 + @as(u21, b - 0x80);
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
            const s = codec.readScalar(Unit, src, i);
            if (s.cp < 0x80 or (s.cp >= 0xF780 and s.cp <= 0xF7FF)) {
                if (o == dst.len) return .{ .status = .output_full, .read = i, .written = o };
                dst[o] = if (s.cp < 0x80) @intCast(s.cp) else @intCast(s.cp - 0xF780 + 0x80);
                o += 1;
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
