//! UTF-8: the standard's UTF-8 decoder and encoder, with the work done by
//! baskingspot/utf. Well-formed runs go through utf's SIMD validation (to
//! UTF-8) or transcoding (to UTF-16); each error utf finds is replaced
//! here, one U+FFFD per maximal subpart, as the standard's decoder does,
//! and a character cut off by the end of the input waits in the decoder
//! for the next call.

const std = @import("std");
const utf = @import("utf");
const codec = @import("codec.zig");
const Encoding = codec.Encoding;
const DecodeResult = codec.DecodeResult;
const EncodeResult = codec.EncodeResult;

pub const encodings = [_]Encoding{.utf_8};

const little = codec.native_endian == .little;
const utf8_to_native = if (little) utf.convert.utf8ToUtf16le else utf.convert.utf8ToUtf16be;
const native_to_utf8 = if (little) utf.convert.utf16leToUtf8 else utf.convert.utf16beToUtf8;

pub const Decoder = struct {
    /// The start of a character the previous call's input cut off: a
    /// prefix of a well-formed sequence, up to three bytes.
    pending: [3]u8 = undefined,
    pending_len: u8 = 0,

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
        if (d.pending_len != 0) {
            // Finish the character the last call cut off, a byte at a
            // time: the standard's decoder from where it stopped.
            var buf: [4]u8 = undefined;
            const held = d.pending_len;
            @memcpy(buf[0..held], d.pending[0..held]);
            var n: usize = held;
            while (true) {
                switch (codec.utf8Step(buf[0..n])) {
                    .incomplete => {
                        if (n - held < src.len) {
                            buf[n] = src[n - held];
                            n += 1;
                            continue;
                        }
                        if (!last) {
                            @memcpy(d.pending[0..n], buf[0..n]);
                            d.pending_len = @intCast(n);
                            return .{ .status = .input_empty, .read = src.len, .written = 0 };
                        }
                        // The stream ends inside it: one error for all of it.
                        if (mode == .fatal) {
                            d.pending_len = 0;
                            return .{ .status = .malformed, .read = src.len, .written = 0 };
                        }
                        o = codec.tryPut(Unit, dst, 0, codec.replacement_character) orelse
                            return .{ .status = .output_full, .read = 0, .written = 0 };
                        d.pending_len = 0;
                        return .{ .status = .input_empty, .read = src.len, .written = o };
                    },
                    .scalar => |s| {
                        o = codec.tryPut(Unit, dst, 0, s.cp) orelse
                            return .{ .status = .output_full, .read = 0, .written = 0 };
                        i = n - held;
                    },
                    .invalid => |k| {
                        // The held bytes are a well-formed prefix, so the
                        // error ends at or after them, in this input; the
                        // byte that broke it is read again.
                        i = k - held;
                        if (mode == .fatal) {
                            d.pending_len = 0;
                            return .{ .status = .malformed, .read = i, .written = 0 };
                        }
                        o = codec.tryPut(Unit, dst, 0, codec.replacement_character) orelse
                            return .{ .status = .output_full, .read = 0, .written = 0 };
                    },
                }
                break;
            }
            d.pending_len = 0;
        }
        const r = decodeBody(Unit, src[i..], dst[o..], last, mode);
        if (r.held != 0) {
            @memcpy(d.pending[0..r.held], src[src.len - r.held ..]);
            d.pending_len = @intCast(r.held);
        }
        return .{ .status = r.status, .read = i + r.read, .written = o + r.written };
    }

    pub fn maxLen(d: *const Decoder, comptime Unit: type, n: usize) ?usize {
        const total = std.math.add(usize, n, d.pending_len) catch return null;
        // Each byte can be an error of its own, U+FFFD, three bytes of
        // UTF-8; no byte makes more than one UTF-16 unit.
        return if (Unit == u16) total else codec.mulAdd(total, 3, 0);
    }
};

const Body = struct {
    status: codec.DecodeStatus,
    read: usize,
    written: usize,
    /// Bytes at the end of `src`, read but not decoded: the start of a
    /// character for the next call.
    held: usize = 0,
};

/// Decodes `src` from a character boundary: utf for the well-formed runs,
/// the standard's decoder for what stops it.
fn decodeBody(comptime Unit: type, src: []const u8, dst: []Unit, last: bool, mode: codec.DecoderMode) Body {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len) {
        const room = dst.len - o;
        if (room == 0) return .{ .status = .output_full, .read = i, .written = o };
        // No byte makes more than one unit of either output, so a window
        // of `room` bytes fits.
        const window = src[i..][0..@min(src.len - i, room)];
        if (Unit == u8) {
            const r = utf.validate.utf8WithErrors(window);
            const good = if (r.err == .none) window.len else r.count;
            @memcpy(dst[o..][0..good], window[0..good]);
            i += good;
            o += good;
        } else {
            // On an error utf reports where it starts and what it wrote
            // for everything before it.
            const r = utf8_to_native(window, dst[o..]);
            i += if (r.err == .none) window.len else r.count;
            o += r.written;
        }
        if (i == src.len) break;
        // An error, or a character the window or the input cuts off.
        switch (codec.utf8Step(src[i..])) {
            .scalar => |s| {
                o += codec.tryPut(Unit, dst, o, s.cp) orelse return .{
                    .status = .output_full,
                    .read = i,
                    .written = o,
                };
                i += s.len;
            },
            .invalid => |k| {
                if (mode == .fatal) return .{ .status = .malformed, .read = i + k, .written = o };
                o += codec.tryPut(Unit, dst, o, codec.replacement_character) orelse
                    return .{ .status = .output_full, .read = i, .written = o };
                i += k;
            },
            .incomplete => |k| {
                if (!last) return .{ .status = .input_empty, .read = src.len, .written = o, .held = k };
                if (mode == .fatal) return .{ .status = .malformed, .read = src.len, .written = o };
                o += codec.tryPut(Unit, dst, o, codec.replacement_character) orelse
                    return .{ .status = .output_full, .read = i, .written = o };
                i = src.len;
            },
        }
    }
    return .{ .status = .input_empty, .read = i, .written = o };
}

/// The UTF-8 encoder. Its input is whole characters (the `Encoder` wrapper
/// holds back one the input cuts off); ill-formed input reads as U+FFFD,
/// which UTF-8 encodes, so it never reports an unmappable character.
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
        _ = mode;
        if (Unit == u8) {
            const r = decodeBody(u8, src, dst, true, .replacement);
            return .{
                .status = if (r.status == .output_full) .output_full else .input_empty,
                .read = r.read,
                .written = r.written,
            };
        }
        var i: usize = 0;
        var o: usize = 0;
        while (i < src.len) {
            const room = dst.len - o;
            // Each unit makes at most three bytes.
            const n = @min(src.len - i, room / 3);
            if (n != 0) {
                const window = src[i..][0..n];
                const r = native_to_utf8(window, dst[o..]);
                o += r.written;
                if (r.err == .none) {
                    i += n;
                    continue;
                }
                i += r.count;
            }
            // An unpaired surrogate, a pair the window cuts, or too little
            // room for a window.
            const s = codec.readScalar(u16, src, i);
            o += codec.tryPut(u8, dst, o, s.cp) orelse return .{ .status = .output_full, .read = i, .written = o };
            i += s.len;
        }
        return .{ .status = .input_empty, .read = i, .written = o };
    }

    pub fn maxLen(e: *const Encoder, comptime Unit: type, n: usize, mode: codec.EncoderMode) ?usize {
        _ = e;
        _ = Unit;
        _ = mode;
        // An ill-formed byte or a lone surrogate is U+FFFD, three bytes.
        return codec.mulAdd(n, 3, 0);
    }
};

const testing = std.testing;

test "the standard's replacements" {
    var d = Decoder.init(.utf_8);
    var out: [64]u8 = undefined;
    const r = d.decode(u8, "a\xF0\x90\x80b\xE0\x80c\xED\xA0\x80", &out, true, .replacement);
    try testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}\u{FFFD}c\u{FFFD}\u{FFFD}\u{FFFD}", out[0..r.written]);
}

test "a character split across calls" {
    var d = Decoder.init(.utf_8);
    var out: [8]u16 = undefined;
    try testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 2, .written = 1 },
        d.decode(u16, "a\xF0", &out, false, .fatal),
    );
    try testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 1, .written = 0 },
        d.decode(u16, "\x9F", &out, false, .fatal),
    );
    try testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 3, .written = 3 },
        d.decode(u16, "\x98\x80z", &out, true, .fatal),
    );
    try testing.expectEqualSlices(u16, &.{ 0xD83D, 0xDE00, 'z' }, out[0..3]);
    try testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 1, .written = 0 },
        d.decode(u16, "\xE2", &out, false, .fatal),
    );
    try testing.expectEqual(
        DecodeResult{ .status = .malformed, .read = 0, .written = 0 },
        d.decode(u16, "A", &out, true, .fatal),
    );
}
