//! Scratch: `Decoder` with no new type. `init` is inline, so with a
//! compile-time-known encoding it stores a pointer to that family's decode
//! only; with a run-time one it stores one of every family's.

const std = @import("std");
const codec = @import("codec.zig");
const codecs = @import("codecs.zig");
const RuntimeDecoder = @import("Decoder.zig");

pub const Encoding = codec.Encoding;

const State = codecs.DecoderState;
const Result = codec.DecodeResult;
const Mode = codec.DecoderMode;

const VTable = struct {
    decode8: *const fn (*State, []const u8, []u8, bool, Mode) Result,
    decode16: *const fn (*State, []const u8, []u16, bool, Mode) Result,
    max: *const fn (*const State, bool, usize) ?usize,
};

fn vtableOf(comptime e: Encoding) VTable {
    const fam = @tagName(codecs.family_of[@intFromEnum(e)].?);
    const S = struct {
        fn d8(s: *State, src: []const u8, dst: []u8, last: bool, mode: Mode) Result {
            return @field(s, fam).decode(u8, src, dst, last, mode);
        }
        fn d16(s: *State, src: []const u8, dst: []u16, last: bool, mode: Mode) Result {
            return @field(s, fam).decode(u16, src, dst, last, mode);
        }
        fn max(s: *const State, utf16: bool, n: usize) ?usize {
            return if (utf16) @field(s, fam).maxLen(u16, n) else @field(s, fam).maxLen(u8, n);
        }
    };
    return .{ .decode8 = S.d8, .decode16 = S.d16, .max = S.max };
}

fn vtablePtr(comptime e: Encoding) *const VTable {
    return &struct {
        const v = vtableOf(e);
    }.v;
}

pub const Decoder = struct {
    encoding: Encoding,
    mode: Mode,
    vt: *const VTable,
    state: State,

    /// Only `.keep` here: the measurement is of the dispatch.
    pub inline fn init(e: Encoding, options: RuntimeDecoder.Options) Decoder {
        std.debug.assert(options.bom == .keep);
        switch (e) {
            inline else => |c| {
                if (comptime !c.isImplemented()) @panic("encoding: not implemented");
                return .{
                    .encoding = e,
                    .mode = options.mode,
                    .vt = comptime vtablePtr(c),
                    .state = comptime codecs.initDecoder(c),
                };
            },
        }
    }

    pub fn decodeToUtf8(d: *Decoder, src: []const u8, dst: []u8, last: bool) Result {
        return d.vt.decode8(&d.state, src, dst, last, d.mode);
    }

    pub fn decodeToUtf16(d: *Decoder, src: []const u8, dst: []u16, last: bool) Result {
        return d.vt.decode16(&d.state, src, dst, last, d.mode);
    }

    pub fn maxUtf8Len(d: *const Decoder, n: usize) ?usize {
        return d.vt.max(&d.state, false, n);
    }
};
