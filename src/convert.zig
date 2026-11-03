//! One-call conversions of a whole buffer into a buffer the caller owns:
//! decode bytes in an encoding to UTF-8 or UTF-16, and encode UTF-8 or
//! UTF-16 to an encoding.
//!
//!     const r = try encoding.decodeToUtf8(encoding.Decoder, enc, bytes, &buf, .{});
//!     // r.text is the UTF-8 in buf, r.encoding what was decoded.
//!
//!     const Sjis = encoding.EncoderFor(&.{.shift_jis});
//!     const out = try encoding.encodeFromUtf8(Sjis, .shift_jis, text, &buf, .{});
//!
//! The first parameter is the decoder or encoder type, `Decoder` for an
//! encoding chosen at run time or a `DecoderFor` over the encodings a
//! program names, so a conversion links what that type links and takes its
//! options. The options select the standard's entry points: a decoder's
//! default, `.bom = .sniff` in replacement mode, is its "decode" (a byte
//! order mark picks the encoding); `.utf_8` with `.bom = .remove` is
//! "UTF-8 decode", `.bom = .keep` "decode without BOM", and that with
//! `.mode = .fatal` "UTF-8 decode without BOM or fail". An encoder's
//! default, html mode, is "encode", and `.mode = .fatal` "encode or fail".
//!
//! A call converts all of `src` or fails with `error.NoSpaceLeft`, leaving
//! `dst` unspecified. A `dst` as long as the type's max length for `src`
//! never fails that way, and can be sized at compile time:
//! `D.init(enc, options).maxUtf8Len(src.len)` (`maxUtf16Len`, and an
//! encoder's `maxLenFromUtf8` and `maxLenFromUtf16`), null when the
//! length overflows `usize`. In fatal mode a call returns the output before
//! the first error and where the error is in `src`.

const std = @import("std");
const codec = @import("codec.zig");

const Encoding = codec.Encoding;

/// What a whole-buffer decode wrote.
pub fn Decoded(comptime Unit: type) type {
    return struct {
        /// The output in `dst`: all of `src` decoded, or in fatal mode
        /// what came before the first error.
        text: []Unit,
        /// The encoding decoded: the one given, or with `.bom = .sniff` the
        /// one a byte order mark named.
        encoding: Encoding,
        /// Fatal mode: the offset in `src` just past the first malformed
        /// sequence; null when there was none.
        malformed: ?usize = null,
    };
}

/// What a whole-buffer encode wrote.
pub const Encoded = struct {
    /// The output in `dst`: all of `src` encoded, or in fatal mode what
    /// came before the first character the encoding lacks.
    bytes: []u8,
    /// Fatal mode: the first character the encoding lacks; null when there
    /// was none.
    unmappable: ?Unmappable = null,

    pub const Unmappable = struct {
        code_point: u21,
        /// The offset in `src` just past the character.
        end: usize,
    };
};

/// Decodes all of `src`, in `enc`, to UTF-8 in `dst` with a decoder of
/// type `D` (`Decoder` or a `DecoderFor`). `enc` must be in `D`'s set.
pub fn decodeToUtf8(
    comptime D: type,
    enc: Encoding,
    src: []const u8,
    dst: []u8,
    options: D.Options,
) error{NoSpaceLeft}!Decoded(u8) {
    return decode(D, u8, enc, src, dst, options);
}

/// Decodes all of `src`, in `enc`, to UTF-16 in the machine's byte order in
/// `dst` with a decoder of type `D`.
pub fn decodeToUtf16(
    comptime D: type,
    enc: Encoding,
    src: []const u8,
    dst: []u16,
    options: D.Options,
) error{NoSpaceLeft}!Decoded(u16) {
    return decode(D, u16, enc, src, dst, options);
}

/// Encodes all of `src`, UTF-8, to `enc`'s output encoding in `dst` with an
/// encoder of type `E` (`Encoder` or an `EncoderFor`). Ill-formed UTF-8
/// reads as U+FFFD.
pub fn encodeFromUtf8(
    comptime E: type,
    enc: Encoding,
    src: []const u8,
    dst: []u8,
    options: E.Options,
) error{NoSpaceLeft}!Encoded {
    return encode(E, u8, enc, src, dst, options);
}

/// Encodes all of `src`, UTF-16 in the machine's byte order, to `enc`'s
/// output encoding in `dst` with an encoder of type `E`. An unpaired
/// surrogate reads as U+FFFD.
pub fn encodeFromUtf16(
    comptime E: type,
    enc: Encoding,
    src: []const u16,
    dst: []u8,
    options: E.Options,
) error{NoSpaceLeft}!Encoded {
    return encode(E, u16, enc, src, dst, options);
}

fn decode(
    comptime D: type,
    comptime Unit: type,
    enc: Encoding,
    src: []const u8,
    dst: []Unit,
    options: D.Options,
) error{NoSpaceLeft}!Decoded(Unit) {
    var d: D = .init(enc, options);
    const r = if (Unit == u8) d.decodeToUtf8(src, dst, true) else d.decodeToUtf16(src, dst, true);
    return switch (r.status) {
        .input_empty => .{ .text = dst[0..r.written], .encoding = d.encoding },
        .output_full => error.NoSpaceLeft,
        .malformed => .{ .text = dst[0..r.written], .encoding = d.encoding, .malformed = r.read },
    };
}

fn encode(
    comptime E: type,
    comptime Unit: type,
    enc: Encoding,
    src: []const Unit,
    dst: []u8,
    options: E.Options,
) error{NoSpaceLeft}!Encoded {
    var e: E = .init(enc, options);
    const r = if (Unit == u8) e.encodeFromUtf8(src, dst, true) else e.encodeFromUtf16(src, dst, true);
    return switch (r.status) {
        .input_empty => .{ .bytes = dst[0..r.written] },
        .output_full => error.NoSpaceLeft,
        .unmappable => .{
            .bytes = dst[0..r.written],
            .unmappable = .{ .code_point = r.unmappable, .end = r.read },
        },
    };
}

const testing = std.testing;
const coder = @import("coder.zig");
const Decoder = coder.DecoderFor(&coder.implemented);
const Encoder = coder.EncoderFor(&coder.implemented);

test "decode: the standard's decode, UTF-8 decode, and decode without BOM" {
    var buf: [32]u8 = undefined;
    // decode: a byte order mark overrides the label and is removed.
    const a = try decodeToUtf8(Decoder, .windows_1252, "\xEF\xBB\xBF\xE2\x82\xAC\x80", &buf, .{});
    try testing.expectEqualStrings("\u{20AC}\u{FFFD}", a.text);
    try testing.expectEqual(Encoding.utf_8, a.encoding);
    try testing.expectEqual(@as(?usize, null), a.malformed);
    // UTF-8 decode: only UTF-8's mark is removed.
    const b = try decodeToUtf8(Decoder, .utf_8, "\xEF\xBB\xBFx", &buf, .{ .bom = .remove });
    try testing.expectEqualStrings("x", b.text);
    // decode without BOM: the mark is a character.
    const c = try decodeToUtf8(Decoder, .utf_8, "\xEF\xBB\xBFx", &buf, .{ .bom = .keep });
    try testing.expectEqualStrings("\u{FEFF}x", c.text);
    // No mark: the label's encoding.
    const d = try decodeToUtf8(Decoder, .windows_1252, "\x80", &buf, .{});
    try testing.expectEqualStrings("\u{20AC}", d.text);
    try testing.expectEqual(Encoding.windows_1252, d.encoding);
}

test "decode: fatal mode reports the output before the error and where it ends" {
    var buf: [32]u16 = undefined;
    // Shift_JIS 0x81 0x20 is malformed; the error ends after 0x81, and the
    // space is read again.
    const r = try decodeToUtf16(Decoder, .shift_jis, "ab\x81 c", &buf, .{ .mode = .fatal });
    try testing.expectEqualSlices(u16, &.{ 'a', 'b' }, r.text);
    try testing.expectEqual(@as(?usize, 3), r.malformed);
    // A sequence the input cuts off is an error at the end.
    var b8: [8]u8 = undefined;
    const t = try decodeToUtf8(Decoder, .utf_8, "a\xE2\x82", &b8, .{ .mode = .fatal, .bom = .keep });
    try testing.expectEqualStrings("a", t.text);
    try testing.expectEqual(@as(?usize, 3), t.malformed);
}

test "decode: a buffer of the max length always fits, one shorter may not" {
    const src = "\xA4\xA2\xA4\xA4"; // two hiragana in EUC-JP: 6 bytes of UTF-8
    const D = coder.DecoderFor(&.{.euc_jp});
    const max = comptime D.init(.euc_jp, .{ .bom = .keep }).maxUtf8Len(src.len).?;
    var buf: [max]u8 = undefined;
    const r = try decodeToUtf8(D, .euc_jp, src, &buf, .{ .bom = .keep });
    try testing.expectEqualStrings("\u{3042}\u{3044}", r.text);
    try testing.expectError(error.NoSpaceLeft, decodeToUtf8(D, .euc_jp, src, buf[0..5], .{ .bom = .keep }));
    try testing.expectEqual(6, (try decodeToUtf8(D, .euc_jp, src, buf[0..6], .{ .bom = .keep })).text.len);
}

test "encode: html mode, fatal mode, and room" {
    var buf: [32]u8 = undefined;
    const a = try encodeFromUtf8(Encoder, .iso_8859_2, "a\u{20AC}b", &buf, .{});
    try testing.expectEqualStrings("a&#8364;b", a.bytes);
    try testing.expectEqual(@as(?Encoded.Unmappable, null), a.unmappable);
    const b = try encodeFromUtf16(Encoder, .iso_8859_2, &.{ 'a', 0xD83D, 0xDE00, 'b' }, &buf, .{ .mode = .fatal });
    try testing.expectEqualStrings("a", b.bytes);
    try testing.expectEqual(Encoded.Unmappable{ .code_point = 0x1F600, .end = 3 }, b.unmappable.?);
    // UTF-16LE's output encoding is UTF-8.
    const c = try encodeFromUtf16(Encoder, .utf_16le, &.{0xD800}, &buf, .{});
    try testing.expectEqualStrings("\u{FFFD}", c.bytes);
    try testing.expectError(error.NoSpaceLeft, encodeFromUtf8(Encoder, .iso_8859_2, "\u{20AC}", buf[0..6], .{}));
    // ISO-2022-JP's return to ASCII at the end is part of the output.
    const E = coder.EncoderFor(&.{.iso_2022_jp});
    const max = comptime E.init(.iso_2022_jp, .{}).maxLenFromUtf8(3).?;
    var jis: [max]u8 = undefined;
    const d = try encodeFromUtf8(E, .iso_2022_jp, "\u{3042}", &jis, .{});
    try testing.expectEqualStrings("\x1B$B$\"\x1B(B", d.bytes);
}
