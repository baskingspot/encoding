//! The standard's single-byte decoder and encoder, shared by its 28
//! single-byte encodings and by IBM code pages 437 and 850, which the
//! standard does not define: bytes below 0x80 are ASCII, and each byte
//! from 0x80 is the code point its encoding's table gives, or an error.
//! The tables are generated (src/tables/single_byte.zig, from
//! gen/sources.zig), 128 code points each; the IBM ones come from
//! Unicode's mappings of Microsoft's tables, which map every byte.
//!
//! Both directions go 16 bytes or units at a time, with no loop over
//! single bytes but for the last few of a call, so that their speed does
//! not hinge on where the linker places them
//! (docs/slop/results/single-byte-20261102.md). Decoding copies ASCII
//! blocks (widened for UTF-16), two blocks a step once one is ASCII, and
//! looks up any other block whole: with AVX-512BW's `vpermi2w`, or lane by
//! lane without it. To UTF-8, those blocks go to UTF-16 first, up to
//! `codec.stage_len` bytes, which utf transcodes.
//!
//! The encoder has no reverse table: a code point in the table's longest
//! run of consecutive code points (in a block, also its second longest)
//! is arithmetic, and any other is a vector search of the 128 entries, so
//! each encoding costs its 256-byte table and nothing more. From UTF-16, a block's ASCII and runs' lanes are
//! arithmetic on all lanes at once and the rest are searched for lane by
//! lane; from UTF-8, utf transcodes long input to UTF-16 first.

const std = @import("std");
const builtin = @import("builtin");
const codec = @import("codec.zig");
const tables = @import("tables/single_byte.zig");
const Encoding = codec.Encoding;
const DecodeResult = codec.DecodeResult;
const EncodeResult = codec.EncodeResult;

const block = codec.ascii_block;
const V = @Vector(block, u8);
const W = @Vector(block, u16);

pub const encodings = [_]Encoding{
    .ibm866,       .iso_8859_2,   .iso_8859_3,     .iso_8859_4,   .iso_8859_5,
    .iso_8859_6,   .iso_8859_7,   .iso_8859_8,     .iso_8859_8_i, .iso_8859_10,
    .iso_8859_13,  .iso_8859_14,  .iso_8859_15,    .iso_8859_16,  .koi8_r,
    .koi8_u,       .macintosh,    .windows_874,    .windows_1250, .windows_1251,
    .windows_1252, .windows_1253, .windows_1254,   .windows_1255, .windows_1256,
    .windows_1257, .windows_1258, .x_mac_cyrillic, .ibm437,       .ibm850,
};

pub const Table = [128]u16;

/// `e`'s table: the code point of each byte from 0x80, 0 for none.
pub fn tableOf(e: Encoding) *const Table {
    inline for (encodings) |t| {
        if (e == t) return &@field(tables, @tagName(if (t == .iso_8859_8_i) .iso_8859_8 else t));
    }
    unreachable;
}

/// A run of bytes whose code points go up by one with each byte, which
/// the encoder maps without searching.
const Run = struct { cp: u16, byte: u8, len: u8 };

/// The table's two longest runs: one script's capital and small letters
/// are often two (x-mac-cyrillic's are).
fn longestRuns(comptime table: *const Table) [2]Run {
    @setEvalBranchQuota(100_000);
    var best: [2]Run = @splat(.{ .cp = 0, .byte = 0x80, .len = 0 });
    var p: usize = 0;
    while (p < 128) {
        var n: usize = 1;
        while (p + n < 128 and table[p] != 0 and table[p + n] == table[p] + n) n += 1;
        // Less the C1 controls, U+0080 to U+009F, which the ISO-8859
        // tables map to themselves in a run longer than their script's
        // letters, and which text does not use.
        const c1: usize = if (table[p] >= 0x80 and table[p] < 0xA0) @min(n, 0xA0 - table[p]) else 0;
        const run: Run = .{ .cp = table[p] + c1, .byte = 0x80 + p + c1, .len = n - c1 };
        if (table[p] != 0 and run.len > best[0].len) {
            best[1] = best[0];
            best[0] = run;
        } else if (table[p] != 0 and run.len > best[1].len) {
            best[1] = run;
        }
        p += n;
    }
    // A run gives each of its code points its first byte only if none of
    // them appears earlier in the table.
    for (best) |r| {
        for (table[0 .. r.byte - 0x80]) |c| {
            if (c >= r.cp and c < r.cp + r.len) @compileError("single-byte run is not the first pointer");
        }
    }
    return best;
}

fn runsOf(e: Encoding) [2]Run {
    inline for (encodings) |t| {
        if (e == t) return comptime longestRuns(tableOf(t));
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
        if (Unit == u16) {
            // A byte is one unit, so a block of input takes a block of
            // output.
            while (src.len - i >= block and dst.len - o >= block) {
                const a = codec.asciiBlocks(u16, src[i..], dst[o..]);
                i += a;
                o += a;
                if (a != 0) continue;
                const k = decodeBlock(table, src[i..][0..block], dst[o..][0..block], mode);
                if (k != block) return .{ .status = .malformed, .read = i + k + 1, .written = o + k };
                i += block;
                o += block;
            }
        } else {
            var stage: [codec.stage_len]u16 = undefined;
            while (src.len - i >= block and dst.len - o >= block) {
                const a = codec.asciiBlocks(u8, src[i..], dst[o..]);
                i += a;
                o += a;
                if (a != 0) continue;
                // Up to `stage_len` bytes, whole blocks, to UTF-16, then
                // utf transcodes them, as far as they fit.
                const n = @min(stage.len, (src.len - i) / block * block);
                var len: usize = 0;
                while (len < n) : (len += block) {
                    const k = decodeBlock(table, src[i + len ..][0..block], stage[len..][0..block], mode);
                    if (k != block) {
                        len += k;
                        break;
                    }
                }
                const c = codec.bmpToUtf8(stage[0..len], dst[o..]);
                i += c.read;
                o += c.written;
                if (c.read != len) break;
                if (len != n) return .{ .status = .malformed, .read = i + 1, .written = o };
            }
        }
        // The last bytes, fewer than a block, or all that is left once the
        // output is short of room: one at a time.
        while (i < src.len) {
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
        return .{ .status = .input_empty, .read = i, .written = o };
    }

    pub fn maxLen(d: *const Decoder, comptime Unit: type, n: usize) ?usize {
        _ = d;
        return if (Unit == u16) n else codec.mulAdd(n, 3, 0);
    }
};

/// Decodes the block at `s` to UTF-16 at `d`, one unit per byte, and
/// returns `block`; in fatal mode, at a byte with no code point, returns
/// its lane instead, with the units before it written.
inline fn decodeBlock(table: *const Table, s: *const [block]u8, d: *[block]u16, mode: codec.DecoderMode) usize {
    const v: V = s.*;
    const wide: W = v;
    const high = v >= @as(V, @splat(0x80));
    if (vector_lookup) {
        // Every lane looked up, no branch on the bytes: ASCII lanes take
        // their byte, the rest their table entry.
        const cps = lookup(table, v);
        var out = @select(u16, high, cps, wide);
        const bad = @select(bool, high, cps == @as(W, @splat(0)), @as(@Vector(block, bool), @splat(false)));
        const bad_bits = codec.highBits(bad);
        if (bad_bits != 0) {
            if (mode == .fatal) {
                d.* = out;
                return @ctz(bad_bits);
            }
            out = @select(u16, bad, @as(W, @splat(codec.replacement_character)), out);
        }
        d.* = out;
        return block;
    }
    // The ASCII lanes widened, then the others one by one.
    d.* = wide;
    var m = codec.highBits(high);
    while (m != 0) : (m &= m - 1) {
        const k = @ctz(m);
        var c = table[s[k] - 0x80];
        if (c == 0) {
            if (mode == .fatal) return k;
            c = codec.replacement_character;
        }
        d[k] = c;
    }
    return block;
}

/// Whether `lookup` is a vector permute: AVX-512BW's `vpermi2w`, under the
/// LLVM backend, which the intrinsic needs.
const vector_lookup = builtin.zig_backend == .stage2_llvm and builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512bw);

extern fn @"llvm.x86.avx512.vpermi2var.hi.512"(
    @Vector(32, u16),
    @Vector(32, u16),
    @Vector(32, u16),
) callconv(.{ .x86_64_sysv = .{} }) @Vector(32, u16);

/// `table[b & 0x7F]` for each lane's byte `b`: two two-register permutes,
/// each over 64 entries, and bit 6 picks between them.
inline fn lookup(table: *const Table, v: V) W {
    const permute = @"llvm.x86.avx512.vpermi2var.hi.512";
    const t: [4]@Vector(32, u16) = @bitCast(table.*);
    const wide: W = v;
    const idx = @shuffle(u16, wide, undefined, std.simd.iota(i32, 32) & @as(@Vector(32, i32), @splat(block - 1)));
    const lo = permute(t[0], idx, t[1]);
    const hi = permute(t[2], idx, t[3]);
    const both = @select(u16, idx & @as(@Vector(32, u16), @splat(0x40)) != @as(@Vector(32, u16), @splat(0)), hi, lo);
    return @shuffle(u16, both, undefined, std.simd.iota(i32, block));
}

pub const Encoder = struct {
    table: *const Table,
    run: Run,
    run2: Run,

    pub fn init(e: Encoding) Encoder {
        const runs = runsOf(e);
        return .{ .table = tableOf(e), .run = runs[0], .run2 = runs[1] };
    }

    /// The byte for `cp`, a non-ASCII scalar value, or 0 for none. The
    /// second run is for blocks only: tested here too, it made the speed
    /// of the one-character loop swing with code placement.
    inline fn lookup(e: *const Encoder, cp: u32) u8 {
        const off = cp -% e.run.cp;
        if (off < e.run.len) return @intCast(e.run.byte + off);
        if (cp > 0xFFFF) return 0;
        return e.search(@intCast(cp));
    }

    /// The first byte whose table entry is `cp`, a non-ASCII code point,
    /// or 0 for none: a vector compare of all 128 entries.
    inline fn search(e: *const Encoder, cp: u16) u8 {
        const T = @Vector(128, u16);
        const table: T = e.table.*;
        const i = std.simd.firstTrue(table == @as(T, @splat(cp))) orelse return 0;
        return 0x80 + @as(u8, i);
    }

    /// Encodes the block of UTF-16 at `s` into `d` and returns `block`, or
    /// the lane of the first unit the table lacks (or a surrogate), with
    /// the lanes before it encoded. ASCII and the encoding's runs are
    /// arithmetic on every lane at once, the second run only when a lane
    /// is in neither ASCII nor the first; the other lanes are searched for
    /// one by one.
    pub inline fn encodeBlock(e: *const Encoder, s: *const [block]u16, d: *[block]u8) usize {
        const u: W = s.*;
        const ascii = u < @as(W, @splat(0x80));
        const off = u -% @as(W, @splat(e.run.cp));
        const in_run = off < @as(W, @splat(e.run.len));
        const bytes: V = @truncate(@select(u16, ascii, u, off +% @as(W, @splat(e.run.byte))));
        d.* = bytes;
        var miss = ~(codec.highBits(ascii) | codec.highBits(in_run));
        if (miss != 0) {
            const off2 = u -% @as(W, @splat(e.run2.cp));
            const in_run2 = off2 < @as(W, @splat(e.run2.len));
            const bytes2: V = @truncate(off2 +% @as(W, @splat(e.run2.byte)));
            d.* = @select(u8, in_run2, bytes2, bytes);
            miss &= ~codec.highBits(in_run2);
        }
        while (miss != 0) : (miss &= miss - 1) {
            const j = @ctz(miss);
            const b = e.search(s[j]);
            if (b == 0) return j;
            d[j] = b;
        }
        return block;
    }

    /// Encodes whole blocks of UTF-16 from the start of `src` while `dst`
    /// has room for one, up to the first unit `encodeBlock` stops at, and
    /// returns how many units it encoded.
    inline fn encodeBlocks(e: *const Encoder, src: []const u16, dst: []u8) usize {
        var k: usize = 0;
        while (src.len - k >= block and dst.len - k >= block) {
            const a = codec.asciiBlocksOut(u16, src[k..], dst[k..]);
            k += a;
            if (a != 0) continue;
            const n = e.encodeBlock(src[k..][0..block], dst[k..][0..block]);
            k += n;
            if (n != block) break;
        }
        return k;
    }

    /// The byte for `u`, a non-ASCII unit, or 0 for none: `lookup` for
    /// `codec.encodeStaged`.
    pub inline fn byteOf(e: *const Encoder, u: u16) u8 {
        return e.lookup(u);
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
        while (i < src.len) {
            const c = src[i];
            if (Unit == u16) {
                const k = e.encodeBlocks(src[i..], dst[o..]);
                if (k != 0) {
                    i += k;
                    o += k;
                    continue;
                }
            } else if (c < 0x80) {
                // A run of ASCII, straight; a lone ASCII byte between
                // other characters goes faster on its own, below.
                if (src.len - i >= 2 and src[i + 1] < 0x80) {
                    const k = codec.asciiRunOut(u8, src[i..], dst[o..]);
                    if (k != 0) {
                        i += k;
                        o += k;
                        continue;
                    }
                }
            } else if (src.len - i >= 4 * block and dst.len - o >= block and codec.denseUtf8(src[i..][0..block])) {
                // Text with more than the odd accented letter through
                // UTF-16, but for the last few units, where a call into
                // utf costs more than they do.
                const r = codec.encodeStaged(e, src[i..], dst[o..], mode);
                if (r.read != 0) {
                    i += r.read;
                    o += r.written;
                    continue;
                }
            }
            // One character: the one a block stopped at, or one of the
            // last, fewer than a block or than the room left.
            if (c < 0x80) {
                if (o == dst.len) return .{ .status = .output_full, .read = i, .written = o };
                dst[o] = @intCast(c);
                i += 1;
                o += 1;
                continue;
            }
            // Thai's letters are three bytes of UTF-8, every other
            // script's here two: test the run's length first.
            const s = if (e.run.cp >= 0x800) codec.read(Unit, src, i, 3) else codec.read(Unit, src, i, 2);
            const b = e.lookup(s.cp);
            if (b != 0) {
                if (o == dst.len) return .{ .status = .output_full, .read = i, .written = o };
                dst[o] = b;
                o += 1;
            } else {
                if (mode == .fatal) return .{
                    .status = .unmappable,
                    .read = i + s.len,
                    .written = o,
                    .unmappable = @intCast(s.cp),
                };
                o += codec.putNcr(dst, o, @intCast(s.cp)) orelse
                    return .{ .status = .output_full, .read = i, .written = o };
            }
            i += s.len;
        }
        return .{ .status = .input_empty, .read = i, .written = o };
    }

    pub fn maxLen(e: *const Encoder, comptime Unit: type, n: usize, mode: codec.EncoderMode) ?usize {
        _ = e;
        _ = Unit;
        // In html mode one unit can be an ill-formed byte or a lone
        // surrogate, U+FFFD, which no single-byte encoding has: `&#65533;`.
        return if (mode == .fatal) n else codec.mulAdd(n, 8, 0);
    }
};

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

test "a whole block: NUL stays NUL, an unmapped byte is U+FFFD or the error's lane" {
    // 0xAA has no code point in windows-1253; 0xC1 is U+0391.
    const src = "\x00a\xc1\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xaa\x00\xc1" ++ "\x00" ** 16;
    var d = Decoder.init(.windows_1253);
    var out: [32]u16 = undefined;
    const r = d.decode(u16, src, &out, true, .replacement);
    try testing.expectEqual(DecodeResult{ .status = .input_empty, .read = 32, .written = 32 }, r);
    var want: [32]u16 = @splat(0);
    want[1] = 'a';
    want[2] = 0x391;
    want[13] = 0xFFFD;
    want[15] = 0x391;
    try testing.expectEqualSlices(u16, &want, &out);
    try testing.expectEqual(
        DecodeResult{ .status = .malformed, .read = 14, .written = 13 },
        d.decode(u16, src, &out, true, .fatal),
    );
    var bytes: [96]u8 = undefined;
    try testing.expectEqual(
        DecodeResult{ .status = .malformed, .read = 14, .written = 14 },
        d.decode(u8, src, &bytes, true, .fatal),
    );
    var e = Encoder.init(.windows_1253);
    var back: [32]u8 = undefined;
    const w = e.encode(u16, &want, &back, true, .fatal);
    try testing.expectEqual(EncodeResult{ .status = .unmappable, .read = 14, .written = 13, .unmappable = 0xFFFD }, w);
}
