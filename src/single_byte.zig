//! The standard's single-byte decoder and encoder, shared by its 28
//! single-byte encodings: bytes below 0x80 are ASCII, and each byte from
//! 0x80 is the code point its encoding's table gives, or an error. The
//! tables are generated (src/tables/single_byte.zig, from gen/sources.zig),
//! 128 code points each. IBM 437 and 850 join with a table each.
//!
//! Decoding copies ASCII 16 bytes at a time and looks up the rest. The
//! encoder has no reverse table: a code point in the table's longest run
//! of consecutive code points is arithmetic, and any other is a vector
//! search of the 128 entries, so each encoding costs its 256-byte table
//! and nothing more.

const std = @import("std");
const codec = @import("codec.zig");
const tables = @import("tables/single_byte.zig");
const Encoding = codec.Encoding;
const DecodeResult = codec.DecodeResult;
const EncodeResult = codec.EncodeResult;

pub const encodings = [_]Encoding{
    .ibm866,       .iso_8859_2,   .iso_8859_3,     .iso_8859_4,   .iso_8859_5,
    .iso_8859_6,   .iso_8859_7,   .iso_8859_8,     .iso_8859_8_i, .iso_8859_10,
    .iso_8859_13,  .iso_8859_14,  .iso_8859_15,    .iso_8859_16,  .koi8_r,
    .koi8_u,       .macintosh,    .windows_874,    .windows_1250, .windows_1251,
    .windows_1252, .windows_1253, .windows_1254,   .windows_1255, .windows_1256,
    .windows_1257, .windows_1258, .x_mac_cyrillic,
};

pub const Table = [128]u16;

/// `e`'s table: the code point of each byte from 0x80, 0 for none.
pub fn tableOf(e: Encoding) *const Table {
    inline for (encodings) |t| {
        if (e == t) return &@field(tables, @tagName(if (t == .iso_8859_8_i) .iso_8859_8 else t));
    }
    unreachable;
}

/// The longest run of bytes whose code points go up by one with each
/// byte, which the encoder maps without searching.
const Run = struct { cp: u16, byte: u8, len: u8 };

fn longestRun(comptime table: *const Table) Run {
    @setEvalBranchQuota(100_000);
    var best: Run = .{ .cp = 0, .byte = 0, .len = 0 };
    var p: usize = 0;
    while (p < 128) {
        var n: usize = 1;
        while (p + n < 128 and table[p] != 0 and table[p + n] == table[p] + n) n += 1;
        if (table[p] != 0 and n > best.len) best = .{ .cp = table[p], .byte = 0x80 + p, .len = n };
        p += n;
    }
    // The run gives each of its code points its first byte only if none of
    // them appears earlier in the table.
    for (table[0 .. best.byte - 0x80]) |c| {
        if (c >= best.cp and c < best.cp + best.len) @compileError("single-byte run is not the first pointer");
    }
    return best;
}

fn runOf(e: Encoding) Run {
    inline for (encodings) |t| {
        if (e == t) return comptime longestRun(tableOf(t));
    }
    unreachable;
}

pub const Decoder = struct {
    table: *const Table,

    pub fn init(e: Encoding) Decoder {
        return .{ .table = tableOf(e) };
    }

    pub fn decode(
        d: *Decoder,
        comptime Unit: type,
        src: []const u8,
        dst: []Unit,
        last: bool,
        mode: codec.DecoderMode,
    ) DecodeResult {
        _ = last;
        const table = d.table;
        var i: usize = 0;
        var o: usize = 0;
        while (true) {
            // ASCII a block at a time while there is room for it.
            const n = @min(src.len - i, dst.len - o);
            const ascii = codec.asciiPrefixBlocks(src[i..][0..n]);
            if (ascii != 0) {
                copyAscii(Unit, dst[o..][0..ascii], src[i..][0..ascii]);
                i += ascii;
                o += ascii;
            }
            // Then a block's worth of bytes one at a time, at least up to
            // the first non-ASCII byte.
            const end = @min(src.len, i + codec.ascii_block);
            while (i < end) {
                const b = src[i];
                if (b < 0x80) {
                    if (o == dst.len) return .{ .status = .output_full, .read = i, .written = o };
                    dst[o] = b;
                    i += 1;
                    o += 1;
                    continue;
                }
                var cp: u21 = table[b - 0x80];
                if (cp == 0) {
                    if (mode == .fatal) return .{ .status = .malformed, .read = i + 1, .written = o };
                    cp = codec.replacement_character;
                }
                o += codec.tryPut(Unit, dst, o, cp) orelse return .{ .status = .output_full, .read = i, .written = o };
                i += 1;
            }
            if (i == src.len) return .{ .status = .input_empty, .read = i, .written = o };
        }
    }

    pub fn maxLen(d: *const Decoder, comptime Unit: type, n: usize) ?usize {
        _ = d;
        return if (Unit == u16) n else codec.mulAdd(n, 3, 0);
    }
};

/// Copies ASCII bytes to UTF-8 or widens them to UTF-16.
inline fn copyAscii(comptime Unit: type, dst: []Unit, src: []const u8) void {
    if (Unit == u8) {
        @memcpy(dst, src);
        return;
    }
    const block = codec.ascii_block;
    var k: usize = 0;
    while (k < src.len) : (k += block) {
        const v: @Vector(block, u8) = src[k..][0..block].*;
        dst[k..][0..block].* = @as(@Vector(block, u16), v);
    }
}

pub const Encoder = struct {
    table: *const Table,
    run: Run,

    pub fn init(e: Encoding) Encoder {
        return .{ .table = tableOf(e), .run = runOf(e) };
    }

    /// The byte for `cp`, a non-ASCII scalar value, or null.
    inline fn lookup(e: *const Encoder, cp: u21) ?u8 {
        const off = cp -% e.run.cp;
        if (off < e.run.len) return @intCast(e.run.byte + off);
        if (cp > 0xFFFF) return null;
        const V = @Vector(128, u16);
        const table: V = e.table.*;
        const i = std.simd.firstTrue(table == @as(V, @splat(@intCast(cp)))) orelse return null;
        return 0x80 + @as(u8, i);
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
        while (true) {
            const n = @min(src.len - i, dst.len - o);
            const ascii = asciiUnits(Unit, src[i..][0..n]);
            if (ascii != 0) {
                narrowAscii(Unit, dst[o..][0..ascii], src[i..][0..ascii]);
                i += ascii;
                o += ascii;
            }
            const end = @min(src.len, i + codec.ascii_block);
            while (i < end) {
                const c = src[i];
                if (c < 0x80) {
                    if (o == dst.len) return .{ .status = .output_full, .read = i, .written = o };
                    dst[o] = @intCast(c);
                    i += 1;
                    o += 1;
                    continue;
                }
                const s = codec.readScalar(Unit, src, i);
                if (e.lookup(s.cp)) |b| {
                    if (o == dst.len) return .{ .status = .output_full, .read = i, .written = o };
                    dst[o] = b;
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
            if (i == src.len) return .{ .status = .input_empty, .read = i, .written = o };
        }
    }

    pub fn maxLen(e: *const Encoder, comptime Unit: type, n: usize, mode: codec.EncoderMode) ?usize {
        _ = e;
        _ = Unit;
        // In html mode one unit can be an ill-formed byte or a lone
        // surrogate, U+FFFD, which no single-byte encoding has: `&#65533;`.
        return if (mode == .fatal) n else codec.mulAdd(n, 8, 0);
    }
};

/// The units at the start of `src` in whole ASCII blocks.
inline fn asciiUnits(comptime Unit: type, src: []const Unit) usize {
    if (Unit == u8) return codec.asciiPrefixBlocks(src);
    const block = codec.ascii_block;
    const V = @Vector(block, u16);
    var k: usize = 0;
    while (src.len - k >= block) : (k += block) {
        const v: V = src[k..][0..block].*;
        if (@reduce(.Or, v >= @as(V, @splat(0x80)))) break;
    }
    return k;
}

inline fn narrowAscii(comptime Unit: type, dst: []u8, src: []const Unit) void {
    if (Unit == u8) {
        @memcpy(dst, src);
        return;
    }
    const block = codec.ascii_block;
    var k: usize = 0;
    while (k < src.len) : (k += block) {
        const v: @Vector(block, u16) = src[k..][0..block].*;
        dst[k..][0..block].* = @as(@Vector(block, u8), @truncate(v));
    }
}

const testing = std.testing;

test "windows-1252 both ways" {
    var d = Decoder.init(.windows_1252);
    var out: [16]u8 = undefined;
    const r = d.decode(u8, "a\x80\x81\xff", &out, true, .replacement);
    try testing.expectEqual(DecodeResult{ .status = .input_empty, .read = 4, .written = 8 }, r);
    try testing.expectEqualStrings("a\u{20AC}\u{81}\u{FF}", out[0..r.written]);
    var e = Encoder.init(.windows_1252);
    var bytes: [16]u8 = undefined;
    const w = e.encode(u8, "a\u{20AC}\u{FF}\u{3042}", &bytes, true, .html);
    try testing.expectEqualStrings("a\x80\xff&#12354;", bytes[0..w.written]);
    const f = e.encode(u8, "a\u{3042}b", &bytes, true, .fatal);
    try testing.expectEqual(EncodeResult{ .status = .unmappable, .read = 4, .written = 1, .unmappable = 0x3042 }, f);
}

test "an unmapped byte is an error" {
    var d = Decoder.init(.windows_1253);
    var out: [16]u16 = undefined;
    // 0xAA has no code point in windows-1253.
    try testing.expectEqual(
        DecodeResult{ .status = .malformed, .read = 2, .written = 1 },
        d.decode(u16, "a\xaab", &out, true, .fatal),
    );
    const r = d.decode(u16, "a\xaab", &out, true, .replacement);
    try testing.expectEqualSlices(u16, &.{ 'a', 0xFFFD, 'b' }, out[0..r.written]);
}

test "output_full leaves the character that does not fit" {
    var d = Decoder.init(.windows_1252);
    var out: [3]u8 = undefined;
    try testing.expectEqual(
        DecodeResult{ .status = .output_full, .read = 1, .written = 1 },
        d.decode(u8, "a\x80", &out, true, .replacement),
    );
}
