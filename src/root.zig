//! Legacy text encodings in Zig with no C: the WHATWG Encoding Standard's
//! decoders and encoders, streaming and allocation-free.
//!
//!     const enc = encoding.Encoding.forLabel("latin1") orelse return error.UnknownLabel;
//!     var decoder: encoding.Decoder = .init(enc, .{});
//!     const r = decoder.decodeToUtf8(bytes, out, true);
//!
//! `Encoding` names an encoding and maps labels to it. `Decoder` turns its
//! bytes into UTF-8 or UTF-16, and `Encoder` turns UTF-8 or UTF-16 into its
//! bytes, both over buffers the caller owns, in as many calls as the input
//! takes.

const std = @import("std");
const codec = @import("codec.zig");

pub const Encoding = @import("encoding.zig").Encoding;
const coder = @import("coder.zig");
pub const DecoderFor = coder.DecoderFor;
pub const EncoderFor = coder.EncoderFor;
pub const bom_encodings = coder.bom_encodings;
pub const OptionsWithoutSniff = coder.OptionsWithoutSniff;
/// A decoder for every implemented encoding, chosen at run time.
pub const Decoder = DecoderFor(&implemented);
/// An encoder for every implemented encoding, chosen at run time.
pub const Encoder = EncoderFor(&implemented);
pub const DecodeResult = codec.DecodeResult;
pub const DecodeStatus = codec.DecodeStatus;
pub const EncodeResult = codec.EncodeResult;
pub const EncodeStatus = codec.EncodeStatus;

/// The longest numeric character reference an encoder in html mode writes
/// for one character, `&#1114111;`: an output buffer this long always
/// takes at least one character.
pub const max_ncr_len = codec.max_ncr_len;

/// Every encoding this version implements, for tests and harnesses that
/// cover each one.
pub const implemented = @import("codecs.zig").implemented;

/// Charset detection: a guess at the encoding of bytes with no label.
pub const detect = @import("detect.zig");
/// The charset detector: feed it bytes, then ask for its guess.
pub const Detector = detect.Detector;

const convert = @import("convert.zig");
pub const decodeToUtf8 = convert.decodeToUtf8;
pub const decodeToUtf16 = convert.decodeToUtf16;
pub const encodeFromUtf8 = convert.encodeFromUtf8;
pub const encodeFromUtf16 = convert.encodeFromUtf16;
pub const Decoded = convert.Decoded;
pub const Encoded = convert.Encoded;

test {
    std.testing.refAllDecls(@This());
    _ = codec;
    // The families' tests come in through `codecs.families`.
    _ = @import("codecs.zig");
    _ = coder;
    _ = @import("specialized_test.zig");
    _ = detect;
    _ = convert;
}
