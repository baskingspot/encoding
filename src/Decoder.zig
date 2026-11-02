//! A streaming decoder: bytes in one encoding to UTF-8 or UTF-16, in as
//! many calls as the input takes, into buffers the caller owns.
//!
//!     var decoder: Decoder = .init(.windows_1252, .{});
//!     const r = decoder.decodeToUtf8(chunk, buffer, is_last_chunk);
//!     // r.read bytes of chunk were read, r.written bytes of buffer written.
//!
//! A call reads as much of `src` as it can and stops when the input is
//! empty, when the next character does not fit in `dst` (`output_full`:
//! call again with the unread input and more room), or in fatal mode at an
//! error (`malformed`). Every call writes whole characters, so each call's
//! output is well-formed UTF-8 or UTF-16 by itself. Splitting the input
//! anywhere gives the same output as one call. A `dst` of at least
//! `maxUtf8Len(src.len)` (or `maxUtf16Len`) always takes the whole input,
//! and one of four bytes (two units) always makes progress. Set `last` on
//! the call with the end of the stream; then discard the decoder.

const Decoder = @This();

const std = @import("std");
const codec = @import("codec.zig");
const codecs = @import("codecs.zig");
const Encoding = codec.Encoding;
pub const Result = codec.DecodeResult;
pub const Status = codec.DecodeStatus;
pub const Mode = codec.DecoderMode;

/// What to do with a byte order mark at the start of the stream.
pub const Bom = enum(u2) {
    /// The standard's "decode": a UTF-8, UTF-16BE, or UTF-16LE byte order
    /// mark switches to its encoding, whatever the label said, and is
    /// removed.
    sniff,
    /// Remove this encoding's own byte order mark, if it has one, as the
    /// standard's "UTF-8 decode" does for UTF-8; switch to no other.
    remove,
    /// Decode a byte order mark like any other bytes: the standard's
    /// "decode without BOM".
    keep,
};

pub const Options = struct {
    mode: Mode = .replacement,
    bom: Bom = .sniff,
};

/// The encoding being decoded: the one given to `init` until a byte order
/// mark, with `.sniff`, switches it.
encoding: Encoding,
mode: Mode,
phase: Phase,
/// Bytes held while the byte order mark is undecided, and then until the
/// decoder has read them.
pending: [3]u8 = undefined,
pending_len: u8 = 0,
state: codecs.DecoderState,

const Phase = enum(u8) {
    /// Decoding: the hot path.
    decoding,
    sniff,
    remove,
    /// No byte order mark; `pending` goes to the decoder first.
    replay,
};

/// A decoder for `encoding`. Panics if `encoding.isImplemented()` is
/// false.
pub fn init(encoding: Encoding, options: Options) Decoder {
    const phase: Phase = switch (options.bom) {
        .sniff => .sniff,
        .remove => switch (encoding) {
            .utf_8, .utf_16be, .utf_16le => .remove,
            else => .decoding,
        },
        .keep => .decoding,
    };
    return .{ .encoding = encoding, .mode = options.mode, .phase = phase, .state = freshState(encoding) };
}

/// Every implemented encoding's fresh state, built at compile time.
/// Copying an entry is one load from read-only data. Building the state
/// with `codecs.initDecoder` at run time writes the union in one branch per
/// family, field by field, and the copy into the decoder then reads it
/// back with one wider load: a store-forwarding stall on every `init`,
/// which cost 6 to 8 ns a call (docs/slop/results/core-20261102.md).
const fresh_states = blk: {
    var t: [std.enums.values(Encoding).len]codecs.DecoderState = undefined;
    for (codecs.implemented) |e| t[@intFromEnum(e)] = codecs.initDecoder(e);
    break :blk t;
};

fn freshState(e: Encoding) codecs.DecoderState {
    if (!e.isImplemented()) std.debug.panic("encoding: {s} is not implemented yet", .{e.name()});
    return fresh_states[@intFromEnum(e)];
}

/// Decodes `src` to UTF-8 into `dst`.
pub fn decodeToUtf8(d: *Decoder, src: []const u8, dst: []u8, last: bool) Result {
    if (d.phase == .decoding) return codecs.decode(&d.state, u8, src, dst, last, d.mode);
    return d.decodeSlow(u8, src, dst, last);
}

/// Decodes `src` to UTF-16, in the machine's byte order, into `dst`.
pub fn decodeToUtf16(d: *Decoder, src: []const u8, dst: []u16, last: bool) Result {
    if (d.phase == .decoding) return codecs.decode(&d.state, u16, src, dst, last, d.mode);
    return d.decodeSlow(u16, src, dst, last);
}

/// The most UTF-8 bytes decoding `n` more bytes can write, in any split
/// and in either mode, or null if that overflows `usize`.
pub fn maxUtf8Len(d: *const Decoder, n: usize) ?usize {
    return d.maxLen(u8, n);
}

/// The most UTF-16 units decoding `n` more bytes can write, or null if
/// that overflows `usize`.
pub fn maxUtf16Len(d: *const Decoder, n: usize) ?usize {
    return d.maxLen(u16, n);
}

fn maxLen(d: *const Decoder, comptime Unit: type, n: usize) ?usize {
    const total = std.math.add(usize, n, d.pending_len) catch return null;
    var max = codecs.decoderMaxLen(&d.state, Unit, total) orelse return null;
    if (d.phase == .sniff) {
        // A byte order mark may yet switch to UTF-8 or UTF-16.
        for ([_]Encoding{ .utf_8, .utf_16le }) |e| {
            const fresh = freshState(e);
            max = @max(max, codecs.decoderMaxLen(&fresh, Unit, total) orelse return null);
        }
    }
    return max;
}

const Verdict = union(enum) { undecided, none, bom: Encoding.Bom };

/// What the held bytes say about a byte order mark.
fn verdict(d: *const Decoder) Verdict {
    const held = d.pending[0..d.pending_len];
    const marks: []const Encoding.Bom = switch (d.phase) {
        .sniff => &.{
            .{ .encoding = .utf_8, .len = 3 },
            .{ .encoding = .utf_16be, .len = 2 },
            .{ .encoding = .utf_16le, .len = 2 },
        },
        else => switch (d.encoding) {
            .utf_8 => &.{.{ .encoding = .utf_8, .len = 3 }},
            .utf_16be => &.{.{ .encoding = .utf_16be, .len = 2 }},
            else => &.{.{ .encoding = .utf_16le, .len = 2 }},
        },
    };
    var undecided = false;
    for (marks) |m| {
        const bytes = bomBytes(m.encoding);
        if (std.mem.startsWith(u8, held, bytes)) return .{ .bom = m };
        if (std.mem.startsWith(u8, bytes, held)) undecided = true;
    }
    return if (undecided) .undecided else .none;
}

fn bomBytes(e: Encoding) []const u8 {
    return switch (e) {
        .utf_8 => "\xEF\xBB\xBF",
        .utf_16be => "\xFE\xFF",
        else => "\xFF\xFE",
    };
}

fn decodeSlow(d: *Decoder, comptime Unit: type, src: []const u8, dst: []Unit, last: bool) Result {
    var i: usize = 0;
    if (d.phase == .sniff or d.phase == .remove) {
        while (true) {
            switch (d.verdict()) {
                .undecided => {
                    if (i == src.len) {
                        if (!last) return .{ .status = .input_empty, .read = i, .written = 0 };
                        break;
                    }
                    d.pending[d.pending_len] = src[i];
                    d.pending_len += 1;
                    i += 1;
                },
                .bom => |m| {
                    if (m.encoding != d.encoding) {
                        d.encoding = m.encoding;
                        d.state = freshState(m.encoding);
                    }
                    d.pending_len = 0;
                    d.phase = .decoding;
                    const r = codecs.decode(&d.state, Unit, src[i..], dst, last, d.mode);
                    return .{ .status = r.status, .read = i + r.read, .written = r.written };
                },
                .none => break,
            }
        }
        // No byte order mark. The bytes taken from `src` in this call are
        // given back; those from earlier calls go to the decoder first.
        d.pending_len -= @intCast(i);
        i = 0;
        d.phase = .replay;
    }
    var o: usize = 0;
    if (d.pending_len != 0) {
        const held = d.pending[0..d.pending_len];
        const r = codecs.decode(&d.state, Unit, held, dst, last and src.len == 0, d.mode);
        o = r.written;
        if (r.status != .input_empty) {
            @memmove(d.pending[0 .. held.len - r.read], held[r.read..]);
            d.pending_len -= @intCast(r.read);
            return .{ .status = r.status, .read = 0, .written = o };
        }
        d.pending_len = 0;
        if (src.len == 0 and last) {
            d.phase = .decoding;
            return .{ .status = .input_empty, .read = 0, .written = o };
        }
    }
    d.phase = .decoding;
    const r = codecs.decode(&d.state, Unit, src[i..], dst[o..], last, d.mode);
    return .{ .status = r.status, .read = i + r.read, .written = o + r.written };
}

const testing = std.testing;

test "a byte order mark overrides the label, split anywhere" {
    const input = "\xEF\xBB\xBF\xE2\x82\xAC";
    for (0..input.len + 1) |cut| {
        var d: Decoder = .init(.windows_1252, .{});
        var out: [16]u8 = undefined;
        const a = d.decodeToUtf8(input[0..cut], &out, false);
        try testing.expectEqual(cut, a.read);
        const b = d.decodeToUtf8(input[cut..], out[a.written..], true);
        try testing.expectEqualStrings("\u{20AC}", out[0 .. a.written + b.written]);
        try testing.expectEqual(Encoding.utf_8, d.encoding);
    }
}

test "no byte order mark: held bytes are decoded" {
    var d: Decoder = .init(.windows_1252, .{});
    var out: [16]u8 = undefined;
    try testing.expectEqual(
        Result{ .status = .input_empty, .read = 2, .written = 0 },
        d.decodeToUtf8("\xEF\xBB", &out, false),
    );
    const r = d.decodeToUtf8("x", &out, true);
    try testing.expectEqualStrings("\u{EF}\u{BB}x", out[0..r.written]);
    var e: Decoder = .init(.windows_1252, .{});
    const s = e.decodeToUtf8("\xFE", &out, true);
    try testing.expectEqualStrings("\u{FE}", out[0..s.written]);
}

test "remove strips only the encoding's own mark" {
    var d: Decoder = .init(.utf_8, .{ .bom = .remove });
    var out: [16]u16 = undefined;
    const r = d.decodeToUtf16("\xFF\xFEa", &out, true);
    try testing.expectEqualSlices(u16, &.{ 0xFFFD, 0xFFFD, 'a' }, out[0..r.written]);
    var k: Decoder = .init(.utf_8, .{ .bom = .keep });
    const s = k.decodeToUtf16("\xEF\xBB\xBFa", &out, true);
    try testing.expectEqualSlices(u16, &.{ 0xFEFF, 'a' }, out[0..s.written]);
    var l: Decoder = .init(.utf_16le, .{ .bom = .remove });
    const t = l.decodeToUtf16("\xFF\xFEa\x00", &out, true);
    try testing.expectEqualSlices(u16, &.{'a'}, out[0..t.written]);
}

test "replay that runs out of room keeps the held bytes" {
    var d: Decoder = .init(.windows_1252, .{});
    var out: [8]u8 = undefined;
    _ = d.decodeToUtf8("\xEF\xBB", &out, false);
    try testing.expectEqual(
        Result{ .status = .output_full, .read = 0, .written = 0 },
        d.decodeToUtf8("x", out[0..1], true),
    );
    try testing.expectEqual(
        Result{ .status = .output_full, .read = 0, .written = 2 },
        d.decodeToUtf8("x", out[0..3], true),
    );
    const r = d.decodeToUtf8("x", out[2..], true);
    try testing.expectEqual(Result{ .status = .input_empty, .read = 1, .written = 3 }, r);
    try testing.expectEqualStrings("\u{EF}\u{BB}x", out[0..5]);
}
