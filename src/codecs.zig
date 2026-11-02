//! The registry of codec families. A family is a file that implements the
//! standard's decoder (and, where the standard has one, encoder) for one
//! or more encodings: utf8.zig for UTF-8, single_byte.zig for the 28
//! single-byte encodings, and so on. `Decoder` and `Encoder` hold a
//! family's state in a union built from this list and dispatch on it, so
//! adding a family is one line in `families`.
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

    // Wave 1, Korean: EUC-KR.
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

fn FamilyDecl(comptime f: std.builtin.Type.StructField, comptime decl: []const u8) type {
    const module = @field(families, f.name);
    return if (@hasDecl(module, decl)) @field(module, decl) else void;
}

fn StateUnion(comptime decl: []const u8) type {
    var names: [family_fields.len][]const u8 = undefined;
    var types: [family_fields.len]type = undefined;
    var attrs: [family_fields.len]std.builtin.Type.UnionField.Attributes = undefined;
    for (family_fields, 0..) |f, i| {
        names[i] = f.name;
        types[i] = FamilyDecl(f, decl);
        attrs[i] = .{};
    }
    return @Union(.auto, Family, &names, &types, &attrs);
}

/// A decoder's state: its family's `Decoder`.
pub const DecoderState = StateUnion("Decoder");
/// An encoder's state: its family's `Encoder`, `void` for a family with
/// none.
pub const EncoderState = StateUnion("Encoder");

fn familyOf(e: Encoding) Family {
    return family_of[@intFromEnum(e)] orelse std.debug.panic("encoding: {s} is not implemented yet", .{e.name()});
}

/// A fresh decoder for `e`. Panics if `e` is not implemented yet.
pub fn initDecoder(e: Encoding) DecoderState {
    switch (familyOf(e)) {
        inline else => |tag| {
            const T = @field(families, @tagName(tag)).Decoder;
            return @unionInit(DecoderState, @tagName(tag), T.init(e));
        },
    }
}

/// A fresh encoder for `e`, an output encoding. Panics if `e` is not
/// implemented yet.
pub fn initEncoder(e: Encoding) EncoderState {
    std.debug.assert(e.outputEncoding() == e);
    switch (familyOf(e)) {
        inline else => |tag| {
            const T = @FieldType(EncoderState, @tagName(tag));
            if (T == void) unreachable;
            return @unionInit(EncoderState, @tagName(tag), T.init(e));
        },
    }
}

pub inline fn decode(
    state: *DecoderState,
    comptime Unit: type,
    src: []const u8,
    dst: []Unit,
    last: bool,
    mode: codec.DecoderMode,
) codec.DecodeResult {
    switch (state.*) {
        inline else => |*s| return s.decode(Unit, src, dst, last, mode),
    }
}

pub fn decoderMaxLen(state: *const DecoderState, comptime Unit: type, n: usize) ?usize {
    switch (state.*) {
        inline else => |*s| return s.maxLen(Unit, n),
    }
}

pub inline fn encode(
    state: *EncoderState,
    comptime Unit: type,
    src: []const Unit,
    dst: []u8,
    last: bool,
    mode: codec.EncoderMode,
) codec.EncodeResult {
    switch (state.*) {
        inline else => |*s| {
            if (@TypeOf(s.*) == void) unreachable;
            return s.encode(Unit, src, dst, last, mode);
        },
    }
}

pub fn encoderMaxLen(state: *const EncoderState, comptime Unit: type, n: usize, mode: codec.EncoderMode) ?usize {
    switch (state.*) {
        inline else => |*s| {
            if (@TypeOf(s.*) == void) unreachable;
            return s.maxLen(Unit, n, mode);
        },
    }
}

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
