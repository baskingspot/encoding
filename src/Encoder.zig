//! A streaming encoder: UTF-8 or UTF-16 to bytes in an encoding, in as
//! many calls as the input takes, into buffers the caller owns.
//!
//!     var encoder: Encoder = .init(.shift_jis, .{});
//!     const r = encoder.encodeFromUtf8(chunk, buffer, is_last_chunk);
//!
//! The encoder is the standard's encoder for the encoding's output
//! encoding: UTF-8 for replacement, UTF-16BE, and UTF-16LE. Ill-formed
//! input reads as U+FFFD, as the standard's UTF-8 decoder reads it (one for
//! each maximal subpart) and as an unpaired surrogate converts to a scalar
//! value; a character that a call's input cuts off waits for the next call.
//! In html mode a character the encoding lacks is written as a numeric
//! character reference, `&#` and its decimal value and `;`; in fatal mode
//! the call stops after it with `unmappable`. A call stops with
//! `output_full` when the next character (or reference) does not fit; a
//! `dst` of `maxLenFromUtf8(src.len)` (or `maxLenFromUtf16`) bytes always
//! takes the whole input, and one of `codec.max_ncr_len` (10) bytes always
//! makes progress. Set `last` on the call with the end of the stream.

const Encoder = @This();

const std = @import("std");
const codec = @import("codec.zig");
const codecs = @import("codecs.zig");
const Encoding = codec.Encoding;
pub const Result = codec.EncodeResult;
pub const Status = codec.EncodeStatus;
pub const Mode = codec.EncoderMode;

pub const Options = struct {
    mode: Mode = .html,
};

/// The encoding written: the output encoding of the one given to `init`.
encoding: Encoding,
mode: Mode,
/// The start of a character the last call's input cut off: up to three
/// UTF-8 bytes, or one leading surrogate in `pending16`.
pending: [3]u8 = undefined,
pending16: u16 = 0,
pending_len: u8 = 0,
state: codecs.EncoderState,

/// An encoder for `encoding`'s output encoding. Panics if
/// `encoding.isImplemented()` is false.
pub fn init(encoding: Encoding, options: Options) Encoder {
    const out = encoding.outputEncoding();
    if (!out.isImplemented()) std.debug.panic("encoding: {s} is not implemented yet", .{out.name()});
    return .{ .encoding = out, .mode = options.mode, .state = fresh_states[@intFromEnum(out)] };
}

/// Every implemented output encoding's fresh state, built at compile time,
/// for the reason `Decoder`'s are: copied from read-only data, the state
/// costs one load, where building it at run time stalls on store
/// forwarding.
const fresh_states = blk: {
    var t: [std.enums.values(Encoding).len]codecs.EncoderState = undefined;
    for (codecs.implemented) |e| {
        if (e.outputEncoding() == e) t[@intFromEnum(e)] = codecs.initEncoder(e);
    }
    break :blk t;
};

/// Encodes `src`, UTF-8, into `dst`.
pub fn encodeFromUtf8(e: *Encoder, src: []const u8, dst: []u8, last: bool) Result {
    return e.encode(u8, src, dst, last);
}

/// Encodes `src`, UTF-16 in the machine's byte order, into `dst`.
pub fn encodeFromUtf16(e: *Encoder, src: []const u16, dst: []u8, last: bool) Result {
    return e.encode(u16, src, dst, last);
}

/// The most bytes encoding `n` more bytes of UTF-8 can write, in the
/// encoder's mode and any split, or null if that overflows `usize`.
pub fn maxLenFromUtf8(e: *const Encoder, n: usize) ?usize {
    const total = std.math.add(usize, n, e.pending_len) catch return null;
    return codecs.encoderMaxLen(&e.state, u8, total, e.mode);
}

/// The most bytes encoding `n` more units of UTF-16 can write.
pub fn maxLenFromUtf16(e: *const Encoder, n: usize) ?usize {
    const total = std.math.add(usize, n, e.pending_len) catch return null;
    return codecs.encoderMaxLen(&e.state, u16, total, e.mode);
}

fn encode(e: *Encoder, comptime Unit: type, src: []const Unit, dst: []u8, last: bool) Result {
    var i: usize = 0;
    var o: usize = 0;
    if (e.pending_len != 0) {
        // Finish the held character with units from `src`, then encode it
        // on its own.
        var buf: [4]Unit = undefined;
        var n: usize = e.pending_len;
        if (Unit == u8) {
            @memcpy(buf[0..n], e.pending[0..n]);
            while (n < 4 and i < src.len and codec.utf8Step(buf[0..n]) == .incomplete) {
                buf[n] = src[i];
                n += 1;
                i += 1;
            }
            switch (codec.utf8Step(buf[0..n])) {
                .incomplete => if (!last) {
                    @memcpy(e.pending[0..n], buf[0..n]);
                    e.pending_len = @intCast(n);
                    return .{ .status = .input_empty, .read = src.len, .written = 0 };
                },
                // The byte that broke the sequence is read again.
                .invalid => |k| {
                    i -= n - k;
                    n = k;
                },
                .scalar => {},
            }
        } else {
            buf[0] = e.pending16;
            if (i < src.len and src[0] >= 0xDC00 and src[0] <= 0xDFFF) {
                buf[1] = src[0];
                n = 2;
                i = 1;
            } else if (src.len == 0 and !last) {
                return .{ .status = .input_empty, .read = 0, .written = 0 };
            }
        }
        const r = codecs.encode(&e.state, Unit, buf[0..n], dst, false, e.mode);
        if (r.status == .output_full) return .{ .status = .output_full, .read = 0, .written = r.written };
        e.pending_len = 0;
        o = r.written;
        if (r.status == .unmappable) return .{
            .status = .unmappable,
            .read = i,
            .written = o,
            .unmappable = r.unmappable,
        };
    }
    const end = if (last) src.len else src.len - codec.incompleteTail(Unit, src[i..]);
    const r = codecs.encode(&e.state, Unit, src[i..end], dst[o..], last, e.mode);
    if (r.status != .input_empty) return .{
        .status = r.status,
        .read = i + r.read,
        .written = o + r.written,
        .unmappable = r.unmappable,
    };
    if (end != src.len) {
        const tail = src[end..];
        if (Unit == u8) @memcpy(e.pending[0..tail.len], tail) else e.pending16 = tail[0];
        e.pending_len = @intCast(tail.len);
    }
    return .{ .status = .input_empty, .read = src.len, .written = o + r.written };
}

const testing = std.testing;

test "output encodings" {
    const e: Encoder = .init(.utf_16le, .{});
    try testing.expectEqual(Encoding.utf_8, e.encoding);
}

test "a character split across calls" {
    var e: Encoder = .init(.windows_1252, .{});
    var out: [32]u8 = undefined;
    try testing.expectEqual(
        Result{ .status = .input_empty, .read = 2, .written = 1 },
        e.encodeFromUtf8("a\xE2", &out, false),
    );
    try testing.expectEqual(
        Result{ .status = .input_empty, .read = 1, .written = 0 },
        e.encodeFromUtf8("\x82", &out, false),
    );
    try testing.expectEqual(
        Result{ .status = .input_empty, .read = 2, .written = 2 },
        e.encodeFromUtf8("\xACb", &out, true),
    );
    try testing.expectEqualStrings("\x80b", out[0..2]);
    // A sequence broken by the next byte: U+FFFD, then the byte.
    try testing.expectEqual(
        Result{ .status = .input_empty, .read = 1, .written = 0 },
        e.encodeFromUtf8("\xE2", &out, false),
    );
    const r = e.encodeFromUtf8("c", &out, true);
    try testing.expectEqualStrings("&#65533;c", out[0..r.written]);
}

test "a surrogate pair split across calls, and a lone one" {
    var e: Encoder = .init(.utf_8, .{});
    var out: [16]u8 = undefined;
    try testing.expectEqual(
        Result{ .status = .input_empty, .read = 1, .written = 0 },
        e.encodeFromUtf16(&.{0xD83D}, &out, false),
    );
    try testing.expectEqual(
        Result{ .status = .input_empty, .read = 1, .written = 4 },
        e.encodeFromUtf16(&.{0xDE00}, &out, false),
    );
    try testing.expectEqualStrings("\u{1F600}", out[0..4]);
    _ = e.encodeFromUtf16(&.{0xD83D}, &out, false);
    const r = e.encodeFromUtf16(&.{'x'}, &out, true);
    try testing.expectEqualStrings("\u{FFFD}x", out[0..r.written]);
}

test "fatal mode stops after the unmappable character" {
    var e: Encoder = .init(.iso_8859_2, .{ .mode = .fatal });
    var out: [16]u8 = undefined;
    const r = e.encodeFromUtf16(&.{ 'a', 0x20AC, 'b' }, &out, true);
    try testing.expectEqual(Result{ .status = .unmappable, .read = 2, .written = 1, .unmappable = 0x20AC }, r);
    try testing.expectEqual(
        Result{ .status = .input_empty, .read = 1, .written = 1 },
        e.encodeFromUtf16(&.{'b'}, out[1..], true),
    );
}
