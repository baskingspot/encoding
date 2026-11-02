//! The registry of codec families. A family is a file that implements the
//! standard's decoder (and, where the standard has one, encoder) for one
//! or more encodings: utf8.zig for UTF-8, single_byte.zig for the 28
//! single-byte encodings, and so on. `Decoder` and `Encoder`
//! (src/coder.zig) hold the state of the families their set of encodings
//! needs, built from this list, and dispatch over them, so adding a family
//! is one line in `families`.
//!
//! A family file declares:
//!
//!     pub const encodings = [_]Encoding{ ... };   // the ones it decodes
//!     pub const Decoder = struct {
//!         pub fn init(e: Encoding) Decoder;
//!         pub fn decode(d: *Decoder, comptime Unit: type, src: []const u8,
//!             dst: []Unit, last: bool, mode: DecoderMode) DecodeResult;
//!         pub fn maxLen(d: *const Decoder, comptime Unit: type, n: usize) ?usize;
//!     };
//!     pub const Encoder = struct {                // unless it has none
//!         pub fn init(e: Encoding) Encoder;
//!         pub fn encode(e: *Encoder, comptime Unit: type, src: []const Unit,
//!             dst: []u8, last: bool, mode: EncoderMode) EncodeResult;
//!         pub fn maxLen(e: *const Encoder, comptime Unit: type, n: usize,
//!             mode: EncoderMode) ?usize;
//!     };
//!
//! docs/slop/adding-an-encoding.md has the rest of the contract.

const std = @import("std");
const codec = @import("codec.zig");
const Encoding = codec.Encoding;

/// Every family, one line each. The imports stay inline, against
/// ziglint's Z028, so that a family is one line.
pub const families = .{
    .utf_8 = @import("utf8.zig"), // ziglint-ignore: Z028
    .utf_16 = @import("utf16.zig"), // ziglint-ignore: Z028
    .single_byte = @import("single_byte.zig"), // ziglint-ignore: Z028
    .replacement = @import("replacement.zig"), // ziglint-ignore: Z028
    .x_user_defined = @import("x_user_defined.zig"), // ziglint-ignore: Z028

    // Wave 1, Japanese: Shift_JIS, EUC-JP, ISO-2022-JP.
    .japanese = @import("japanese.zig"), // ziglint-ignore: Z028

    // Wave 1, Chinese: GBK and gb18030, Big5.
    .gb18030 = @import("gb18030.zig"), // ziglint-ignore: Z028
    .big5 = @import("big5.zig"), // ziglint-ignore: Z028

    // Wave 1, Korean: EUC-KR.
    .euc_kr = @import("euc_kr.zig"), // ziglint-ignore: Z028
};

const family_fields = @typeInfo(@TypeOf(families)).@"struct".fields;

/// One tag per family.
pub const Family = std.meta.FieldEnum(@TypeOf(families));

const encoding_count = @typeInfo(Encoding).@"enum".fields.len;

/// The family that decodes each encoding, or null for one not implemented
/// yet.
pub const family_of: [encoding_count]?Family = blk: {
    var t: [encoding_count]?Family = @splat(null);
    for (family_fields) |f| {
        for (@field(families, f.name).encodings) |e| {
            if (t[@intFromEnum(e)] != null) @compileError("two families decode " ++ @tagName(e));
            t[@intFromEnum(e)] = @field(Family, f.name);
        }
    }
    break :blk t;
};

/// Every encoding this version implements, in `Encoding` order: what the
/// tests, fuzzers, and harnesses iterate over.
pub const implemented = blk: {
    var n: usize = 0;
    for (family_of) |f| n += @intFromBool(f != null);
    var list: [n]Encoding = undefined;
    var i: usize = 0;
    for (family_of, 0..) |f, e| {
        if (f == null) continue;
        list[i] = @enumFromInt(e);
        i += 1;
    }
    break :blk list;
};
