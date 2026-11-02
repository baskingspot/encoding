//! The standard's Japanese encodings: Shift_JIS, EUC-JP, and ISO-2022-JP,
//! decoders and encoders. All three map two-byte sequences through index
//! jis0208 (src/tables/jis0208.zig); EUC-JP also decodes index jis0212's
//! three-byte sequences, and ISO-2022-JP's encoder maps half-width
//! katakana through index ISO-2022-JP katakana. The tables are generated
//! in a layout gen/sources.zig names; every layout has the same `decode`
//! and `encode`, so nothing here depends on which.
//!
//! Shift_JIS and EUC-JP decode in a fast loop over ASCII (a block at a
//! time) and the two-byte characters of index jis0208, with room for the
//! output checked once for many characters; anything else goes through a
//! step function that sees the bytes ahead (`sjisStep`, `eucStep`), the
//! standard's decoder for one sequence. A sequence a call's input cuts
//! off is held, as the standard holds its leading byte, and finished on
//! the next call. ISO-2022-JP's decoder is the standard's state machine,
//! byte by byte, with fast paths for ASCII and for two-byte runs. The
//! encoders run the same way: a fast loop over ASCII and the characters
//! the encoding has, and the rest one at a time.
//!
//! Two things about Zig 0.16's code generation shape the hot paths: an
//! optional built with `if (x) null else y` and a u21 inside a struct both
//! go through memory (the u21 as three bytes stored and four loaded), so
//! the fast paths pass plain integers (0 for none, u32 code points).
//!
//! Shift_JIS encodes with index jis0208's pointer except where that
//! pointer falls in 8272 to 8835, which the standard's "index Shift_JIS
//! pointer" excludes: those code points (NEC's selection of IBM's
//! extensions) all appear again among IBM's extensions at 10716 to 11103,
//! and the encoder finds them there, so Shift_JIS needs no table of its
//! own.

const std = @import("std");
const codec = @import("codec.zig");
const jis0208 = @import("tables/jis0208.zig");
const jis0212 = @import("tables/jis0212.zig");
const katakana = @import("tables/iso_2022_jp_katakana.zig");
const Encoding = codec.Encoding;
const DecodeResult = codec.DecodeResult;
const EncodeResult = codec.EncodeResult;

pub const encodings = [_]Encoding{ .euc_jp, .iso_2022_jp, .shift_jis };

const Kind = enum(u8) { euc_jp, iso_2022_jp, shift_jis };

fn kindOf(e: Encoding) Kind {
    return switch (e) {
        .euc_jp => .euc_jp,
        .iso_2022_jp => .iso_2022_jp,
        .shift_jis => .shift_jis,
        else => unreachable,
    };
}

/// A step's code point when the step is an error.
const err: u21 = std.math.maxInt(u21);

/// One sequence at the start of the input: its code point (or `err`) and
/// the bytes it takes. A byte the standard restores to the queue after an
/// error is not taken. `len` 0 means the input ends inside the sequence.
const Step = struct { cp: u21, len: u8 };

inline fn errStep(trail: u8, len: u8) Step {
    // An ASCII byte that ends a sequence in error is read again.
    return .{ .cp = err, .len = if (trail < 0x80) len - 1 else len };
}

/// The Shift_JIS decoder on the sequence at the start of `s`.
inline fn sjisStep(s: []const u8) Step {
    const b = s[0];
    if (b <= 0x80) return .{ .cp = b, .len = 1 };
    if (b >= 0xA1 and b <= 0xDF) return .{ .cp = 0xFF61 - 0xA1 + @as(u21, b), .len = 1 };
    if (!((b >= 0x81 and b <= 0x9F) or (b >= 0xE0 and b <= 0xFC))) return .{ .cp = err, .len = 1 };
    if (s.len < 2) return .{ .cp = err, .len = 0 };
    const t = s[1];
    if ((t >= 0x40 and t <= 0x7E) or (t >= 0x80 and t <= 0xFC)) {
        const offset: u32 = if (t < 0x7F) 0x40 else 0x41;
        const lead_offset: u32 = if (b < 0xA0) 0x81 else 0xC1;
        const p = (b - lead_offset) * 188 + t - offset;
        // EUDC: Windows' private use mapping.
        if (p >= 8836 and p <= 10715) return .{ .cp = @intCast(0xE000 - 8836 + p), .len = 2 };
        const cp = jis0208.decode(p);
        if (cp != 0) return .{ .cp = @intCast(cp), .len = 2 };
    }
    return errStep(t, 2);
}

/// The EUC-JP decoder on the sequence at the start of `s`.
inline fn eucStep(s: []const u8) Step {
    const b = s[0];
    if (b < 0x80) return .{ .cp = b, .len = 1 };
    if (!(b == 0x8E or b == 0x8F or (b >= 0xA1 and b <= 0xFE))) return .{ .cp = err, .len = 1 };
    if (s.len < 2) return .{ .cp = err, .len = 0 };
    const t = s[1];
    if (b == 0x8E) {
        if (t >= 0xA1 and t <= 0xDF) return .{ .cp = 0xFF61 - 0xA1 + @as(u21, t), .len = 2 };
        return errStep(t, 2);
    }
    if (t < 0xA1 or t == 0xFF) return errStep(t, 2);
    if (b == 0x8F) {
        if (s.len < 3) return .{ .cp = err, .len = 0 };
        const u = s[2];
        if (u >= 0xA1 and u <= 0xFE) {
            const cp = jis0212.decode((@as(u32, t) - 0xA1) * 94 + u - 0xA1);
            if (cp != 0) return .{ .cp = @intCast(cp), .len = 3 };
        }
        return errStep(u, 3);
    }
    const cp = jis0208.decode((@as(u32, b) - 0xA1) * 94 + t - 0xA1);
    if (cp != 0) return .{ .cp = @intCast(cp), .len = 2 };
    return .{ .cp = err, .len = 2 };
}

/// Writes `cp`, from U+0080 to U+FFFF, at `dst[o..]`, which has room for
/// it, and returns the units written: index jis0208's code points, without
/// `codec.put`'s branches for the lengths they never have.
inline fn putBmp(comptime Unit: type, dst: []Unit, o: usize, cp: u32) usize {
    if (Unit == u16) {
        dst[o] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        dst[o..][0..2].* = .{ @intCast(0xC0 | cp >> 6), @intCast(0x80 | (cp & 0x3F)) };
        return 2;
    }
    dst[o..][0..3].* = .{ @intCast(0xE0 | cp >> 12), @intCast(0x80 | (cp >> 6 & 0x3F)), @intCast(0x80 | (cp & 0x3F)) };
    return 3;
}

/// Shift_JIS's common case for the fast path: the code point of a lead
/// byte `b` (from 0x81) and a trail byte `t` in index jis0208, or 0 for
/// anything else, which `sjisStep` decodes. (A plain integer: an optional
/// here costs the loop a trip through memory.)
inline fn sjisPair(b: u8, t: u8) u21 {
    if (!((b >= 0x81 and b <= 0x9F) or (b >= 0xE0 and b <= 0xEA))) return 0;
    if (t < 0x40 or t == 0x7F or t > 0xFC) return 0;
    const offset: u32 = if (t < 0x7F) 0x40 else 0x41;
    const lead_offset: u32 = if (b < 0xA0) 0x81 else 0xC1;
    return @intCast(jis0208.decode((b - lead_offset) * 188 + t - offset));
}

/// EUC-JP's common case: the code point of `b` and `t`, both from 0xA1,
/// in index jis0208, or 0 for anything else, which `eucStep` decodes.
inline fn eucPair(b: u8, t: u8) u21 {
    if (b < 0xA1 or b == 0xFF or t < 0xA1 or t == 0xFF) return 0;
    return @intCast(jis0208.decode((@as(u32, b) - 0xA1) * 94 + t - 0xA1));
}

/// ISO-2022-JP's decoder states, as the standard names them.
const IsoState = enum(u8) { ascii, roman, katakana, lead_byte, trail_byte, escape_start, escape };

/// ISO-2022-JP's decoder: the standard's variables, and a byte it restored
/// to the queue that an earlier call read.
const Iso = struct {
    state: IsoState = .ascii,
    output_state: IsoState = .ascii,
    leading: u8 = 0,
    output: bool = false,
    /// An escape's 0x24 or 0x28, from an earlier call, that an error put
    /// back in front of the input; 0 for none.
    replay: u8 = 0,
};

const IsoOut = struct {
    iso: Iso,
    kind: enum(u2) { none, char, err, finished },
    cp: u21 = 0,
    /// Whether the step takes the byte; false when the standard restores
    /// it to the queue.
    takes: bool = true,
    /// An escape's leading byte, which goes back in front of the byte.
    restore: u8 = 0,
};

/// The ISO-2022-JP decoder's handler on `byte` (null for end-of-queue).
fn isoStep(iso: Iso, byte: ?u8) IsoOut {
    var st = iso;
    switch (st.state) {
        .ascii, .roman, .katakana, .lead_byte => {
            const b = byte orelse return .{ .iso = st, .kind = .finished, .takes = false };
            if (b == 0x1B) {
                st.state = .escape_start;
                return .{ .iso = st, .kind = .none };
            }
            st.output = false;
            switch (st.state) {
                .ascii => if (b <= 0x7F and b != 0x0E and b != 0x0F) return .{ .iso = st, .kind = .char, .cp = b },
                .roman => {
                    if (b == 0x5C) return .{ .iso = st, .kind = .char, .cp = 0xA5 };
                    if (b == 0x7E) return .{ .iso = st, .kind = .char, .cp = 0x203E };
                    if (b <= 0x7F and b != 0x0E and b != 0x0F) return .{ .iso = st, .kind = .char, .cp = b };
                },
                .katakana => if (b >= 0x21 and b <= 0x5F) {
                    return .{ .iso = st, .kind = .char, .cp = 0xFF61 - 0x21 + @as(u21, b) };
                },
                .lead_byte => if (b >= 0x21 and b <= 0x7E) {
                    st.leading = b;
                    st.state = .trail_byte;
                    return .{ .iso = st, .kind = .none };
                },
                else => unreachable,
            }
            return .{ .iso = st, .kind = .err };
        },
        .trail_byte => {
            const b = byte orelse {
                st.state = .lead_byte;
                return .{ .iso = st, .kind = .err, .takes = false };
            };
            if (b == 0x1B) {
                st.state = .escape_start;
                return .{ .iso = st, .kind = .err };
            }
            st.state = .lead_byte;
            if (b >= 0x21 and b <= 0x7E) {
                const p = (@as(u32, st.leading) - 0x21) * 94 + b - 0x21;
                const cp = jis0208.decode(p);
                if (cp != 0) return .{ .iso = st, .kind = .char, .cp = @intCast(cp) };
            }
            return .{ .iso = st, .kind = .err };
        },
        .escape_start => {
            if (byte) |b| if (b == 0x24 or b == 0x28) {
                st.leading = b;
                st.state = .escape;
                return .{ .iso = st, .kind = .none };
            };
            st.output = false;
            st.state = st.output_state;
            return .{ .iso = st, .kind = .err, .takes = false };
        },
        .escape => {
            const leading = st.leading;
            st.leading = 0;
            var state: ?IsoState = null;
            if (byte) |b| {
                if (leading == 0x28 and b == 0x42) state = .ascii;
                if (leading == 0x28 and b == 0x4A) state = .roman;
                if (leading == 0x28 and b == 0x49) state = .katakana;
                if (leading == 0x24 and (b == 0x40 or b == 0x42)) state = .lead_byte;
            }
            if (state) |s| {
                st.state = s;
                st.output_state = s;
                const output = st.output;
                st.output = true;
                return .{ .iso = st, .kind = if (output) .err else .none };
            }
            st.output = false;
            st.state = st.output_state;
            return .{ .iso = st, .kind = .err, .takes = false, .restore = leading };
        },
    }
}

pub const Decoder = struct {
    kind: Kind,
    /// Shift_JIS and EUC-JP: the start of a sequence the last call's input
    /// cut off, which the standard keeps as its leading byte (and EUC-JP's
    /// jis0212 flag).
    held: [2]u8 = undefined,
    held_len: u8 = 0,
    iso: Iso = .{},

    pub fn init(e: Encoding) Decoder {
        return .{ .kind = kindOf(e) };
    }

    pub fn decode(
        d: *Decoder,
        comptime Unit: type,
        src: []const u8,
        dst: []Unit,
        last: bool,
        mode: codec.DecoderMode,
    ) DecodeResult {
        return switch (d.kind) {
            inline else => |k| d.decodeAs(Unit, @field(Encoding, @tagName(k)), src, dst, last, mode),
        };
    }

    /// `decode` for a decoder known at compile time to be `e`'s, so that
    /// it links only `e`'s code and tables (src/coder.zig).
    pub inline fn decodeAs(
        d: *Decoder,
        comptime Unit: type,
        comptime e: Encoding,
        src: []const u8,
        dst: []Unit,
        last: bool,
        mode: codec.DecoderMode,
    ) DecodeResult {
        // One function each, so that each has only its own registers to
        // save: short inputs feel the prologue.
        return switch (comptime kindOf(e)) {
            .shift_jis => @call(.never_inline, decodeSteps, .{ d, Unit, sjisStep, sjisPair, src, dst, last, mode }),
            .euc_jp => @call(.never_inline, decodeSteps, .{ d, Unit, eucStep, eucPair, src, dst, last, mode }),
            .iso_2022_jp => @call(.never_inline, decodeIso, .{ d, Unit, src, dst, last, mode }),
        };
    }

    pub fn maxLen(d: *const Decoder, comptime Unit: type, n: usize) ?usize {
        // Every character is in the BMP and takes a byte at least, except
        // that ISO-2022-JP can hold an escape's two bytes and write an
        // error for them besides what follows.
        const held: usize = if (d.kind == .iso_2022_jp) 2 else d.held_len;
        const chars = std.math.add(usize, n, held) catch return null;
        return if (Unit == u16) chars else codec.mulAdd(chars, 3, 0);
    }

    fn decodeSteps(
        d: *Decoder,
        comptime Unit: type,
        comptime step: fn ([]const u8) callconv(.@"inline") Step,
        comptime pair: fn (u8, u8) callconv(.@"inline") u21,
        src: []const u8,
        dst: []Unit,
        last: bool,
        mode: codec.DecoderMode,
    ) DecodeResult {
        var i: usize = 0;
        var o: usize = 0;
        if (d.held_len != 0) {
            // Finish the held sequence with bytes from `src`. The held
            // bytes are read already; the sequence takes at least them.
            const h = d.held_len;
            var buf: [3]u8 = undefined;
            @memcpy(buf[0..h], d.held[0..h]);
            const take = @min(src.len, buf.len - h);
            @memcpy(buf[h..][0..take], src[0..take]);
            var s = step(buf[0 .. h + take]);
            if (s.len == 0) {
                if (!last) {
                    @memcpy(d.held[h..][0..take], src[0..take]);
                    d.held_len = @intCast(h + take);
                    return .{ .status = .input_empty, .read = src.len, .written = 0 };
                }
                s = .{ .cp = err, .len = @intCast(h + take) };
            }
            var cp = s.cp;
            if (cp == err) {
                if (mode == .fatal) {
                    d.held_len = 0;
                    return .{ .status = .malformed, .read = s.len - h, .written = 0 };
                }
                cp = codec.replacement_character;
            }
            o = codec.tryPut(Unit, dst, 0, cp) orelse return .{ .status = .output_full, .read = 0, .written = 0 };
            d.held_len = 0;
            i = s.len - h;
        }
        const block = codec.ascii_block;
        const per: usize = if (Unit == u16) 1 else 3;
        while (true) {
            // The fast path: ASCII, a block at a time where it can, and
            // the two-byte characters `pair` maps. Every sequence takes a
            // byte at least and writes three UTF-8 bytes or one UTF-16
            // unit at most, so below `limit` there is room for whatever
            // starts there, and the byte after it is input. (ASCII blocks
            // check their own room, and may run past `limit`.)
            const limit = i + @min((src.len - i) -| 1, (dst.len - o) / per);
            while (i < limit) {
                const b = src[i];
                if (b < 0x80) {
                    // A lone ASCII byte between non-ASCII ones, as a space
                    // or digit in CJK text, costs no block.
                    if (src[i + 1] >= 0x80) {
                        dst[o] = b;
                        i += 1;
                        o += 1;
                        continue;
                    }
                    if (src.len - i >= block and dst.len - o >= block) {
                        // A run that ends inside a block costs one block.
                        const n = codec.asciiRun(Unit, src[i..], dst[o..]);
                        i += n;
                        o += n;
                        continue;
                    }
                    dst[o] = b;
                    i += 1;
                    o += 1;
                    continue;
                }
                const cp = pair(b, src[i + 1]);
                if (cp == 0) break;
                o += putBmp(Unit, dst, o, cp);
                i += 2;
            }
            if (i == src.len) return .{ .status = .input_empty, .read = i, .written = o };
            // Then one sequence by the decoder's whole algorithm.
            var s = step(src[i..]);
            if (s.len == 0) {
                // The input ends inside the sequence.
                const rest = src.len - i;
                if (!last) {
                    @memcpy(d.held[0..rest], src[i..]);
                    d.held_len = @intCast(rest);
                    return .{ .status = .input_empty, .read = src.len, .written = o };
                }
                s = .{ .cp = err, .len = @intCast(rest) };
            }
            var cp = s.cp;
            if (cp == err) {
                if (mode == .fatal) return .{ .status = .malformed, .read = i + s.len, .written = o };
                cp = codec.replacement_character;
            }
            o += codec.tryPut(Unit, dst, o, cp) orelse return .{ .status = .output_full, .read = i, .written = o };
            i += s.len;
        }
    }

    fn decodeIso(
        d: *Decoder,
        comptime Unit: type,
        src: []const u8,
        dst: []Unit,
        last: bool,
        mode: codec.DecoderMode,
    ) DecodeResult {
        var i: usize = 0;
        var o: usize = 0;
        while (true) {
            if (d.iso.replay == 0) while (true) {
                switch (d.iso.state) {
                    .ascii => {
                        // ASCII, short of the bytes that are errors or
                        // escapes.
                        const start = i;
                        while (true) {
                            const n = @min(src.len - i, dst.len - o);
                            const k = isoAsciiUnits(u8, src[i..][0..n]);
                            codec.copyAscii(Unit, dst[o..][0..k], src[i..][0..k]);
                            i += k;
                            o += k;
                            while (i < src.len and o < dst.len) : (i += 1) {
                                const b = src[i];
                                if (b >= 0x80 or b == 0x0E or b == 0x0F or b == 0x1B) break;
                                dst[o] = b;
                                o += 1;
                            }
                            // A byte that is an error in this state, in
                            // replacement mode: what the standard's step
                            // does with it (U+FFFD, output unset), here.
                            if (mode == .fatal or src.len - i == 0 or dst.len - o < 3 / @sizeOf(Unit)) break;
                            const b = src[i];
                            if (b < 0x80 and b != 0x0E and b != 0x0F) break;
                            o += codec.put(Unit, dst, o, codec.replacement_character);
                            i += 1;
                        }
                        if (i != start) d.iso.output = false;
                    },
                    .lead_byte => {
                        // Two-byte characters.
                        const start = i;
                        while (src.len - i >= 2) {
                            const a = src[i];
                            const b = src[i + 1];
                            if (a < 0x21 or a > 0x7E or b < 0x21 or b > 0x7E) break;
                            const cp = jis0208.decode((@as(u32, a) - 0x21) * 94 + b - 0x21);
                            if (cp == 0) break;
                            o += codec.tryPut(Unit, dst, o, @intCast(cp)) orelse break;
                            i += 2;
                        }
                        if (i != start) d.iso.output = false;
                    },
                    .roman, .katakana => {},
                    else => break,
                }
                // A whole escape sequence after output: what the escape
                // start and escape states do with it, in one step. (Right
                // after another escape it is an error; the slow path has
                // it.)
                if (src.len - i < 3 or src[i] != 0x1B or d.iso.output) break;
                const state: IsoState = switch (@as(u16, src[i + 1]) << 8 | src[i + 2]) {
                    0x2842 => .ascii,
                    0x284A => .roman,
                    0x2849 => .katakana,
                    0x2440, 0x2442 => .lead_byte,
                    else => break,
                };
                d.iso.state = state;
                d.iso.output_state = state;
                d.iso.output = true;
                i += 3;
            };
            // One byte by the standard's algorithm, the state committed
            // only once its output fits.
            const replayed = d.iso.replay != 0;
            var byte: ?u8 = null;
            if (replayed) {
                byte = d.iso.replay;
            } else if (i < src.len) {
                byte = src[i];
            } else if (!last) {
                return .{ .status = .input_empty, .read = i, .written = o };
            }
            const r = isoStep(d.iso, byte);
            var fatal = false;
            switch (r.kind) {
                .finished => return .{ .status = .input_empty, .read = i, .written = o },
                .none => {},
                .char, .err => {
                    if (r.kind == .err and mode == .fatal) {
                        fatal = true;
                    } else {
                        const cp = if (r.kind == .err) codec.replacement_character else r.cp;
                        o += codec.tryPut(Unit, dst, o, cp) orelse
                            return .{ .status = .output_full, .read = i, .written = o };
                    }
                },
            }
            d.iso = r.iso;
            if (r.takes) {
                if (replayed) d.iso.replay = 0 else i += 1;
            }
            if (r.restore != 0) {
                // The escape's leading byte goes back in front: unread it
                // if this call read it, or replay it on the next step.
                // In the escape state the byte before is never a replay.
                if (i > 0) i -= 1 else d.iso.replay = r.restore;
            }
            if (fatal) return .{ .status = .malformed, .read = i, .written = o };
        }
    }
};

/// What a code point encodes to: up to two bytes, `len` 0 when it has
/// none.
const Bytes = struct { b: [2]u8 = undefined, len: u8 };

inline fn one(b: u21) Bytes {
    return .{ .b = .{ @intCast(b), 0 }, .len = 1 };
}

/// The standard's "index Shift_JIS pointer" for `cp`.
fn shiftJisPointer(cp: u21) ?u16 {
    const p = jis0208.encode(cp) orelse return null;
    if (p < 8272 or p > 8835) return p;
    // index jis0208 without 8272 to 8835: these code points' next
    // pointers are among IBM's extensions, 10716 to 11103.
    var q: u16 = 10716;
    while (q <= 11103) : (q += 1) {
        if (jis0208.decode(q) == cp) return q;
    }
    return null;
}

/// The Shift_JIS encoder on a code point.
inline fn sjisBytes(cp: u21) Bytes {
    if (cp <= 0x80) return one(cp);
    if (cp == 0xA5) return one(0x5C);
    if (cp == 0x203E) return one(0x7E);
    if (cp >= 0xFF61 and cp <= 0xFF9F) return one(cp - 0xFF61 + 0xA1);
    const p = shiftJisPointer(if (cp == 0x2212) 0xFF0D else cp) orelse return .{ .len = 0 };
    const lead = p / 188;
    const lead_offset: u16 = if (lead < 0x1F) 0x81 else 0xC1;
    const trail = p % 188;
    const offset: u16 = if (trail < 0x3F) 0x40 else 0x41;
    return .{ .b = .{ @intCast(lead + lead_offset), @intCast(trail + offset) }, .len = 2 };
}

/// The EUC-JP encoder on a code point.
inline fn eucBytes(cp: u21) Bytes {
    if (cp < 0x80) return one(cp);
    if (cp == 0xA5) return one(0x5C);
    if (cp == 0x203E) return one(0x7E);
    if (cp >= 0xFF61 and cp <= 0xFF9F) return .{ .b = .{ 0x8E, @intCast(cp - 0xFF61 + 0xA1) }, .len = 2 };
    const p = jis0208.encode(if (cp == 0x2212) 0xFF0D else cp) orelse return .{ .len = 0 };
    return .{ .b = .{ @intCast(p / 94 + 0xA1), @intCast(p % 94 + 0xA1) }, .len = 2 };
}

/// ISO-2022-JP's encoder states.
const IsoEncState = enum(u8) { ascii, roman, jis0208 };

pub const Encoder = struct {
    kind: Kind,
    /// ISO-2022-JP's encoder state.
    state: IsoEncState = .ascii,

    pub fn init(e: Encoding) Encoder {
        return .{ .kind = kindOf(e) };
    }

    pub fn encode(
        e: *Encoder,
        comptime Unit: type,
        src: []const Unit,
        dst: []u8,
        last: bool,
        mode: codec.EncoderMode,
    ) EncodeResult {
        return switch (e.kind) {
            inline else => |k| e.encodeAs(Unit, @field(Encoding, @tagName(k)), src, dst, last, mode),
        };
    }

    /// `encode` for an encoder known at compile time to be `enc`'s.
    pub inline fn encodeAs(
        e: *Encoder,
        comptime Unit: type,
        comptime enc: Encoding,
        src: []const Unit,
        dst: []u8,
        last: bool,
        mode: codec.EncoderMode,
    ) EncodeResult {
        // One function each, as the decoders have.
        return switch (comptime kindOf(enc)) {
            .shift_jis => @call(.never_inline, encodeTwoByte, .{ Unit, sjisBytes, src, dst, mode }),
            .euc_jp => @call(.never_inline, encodeTwoByte, .{ Unit, eucBytes, src, dst, mode }),
            .iso_2022_jp => @call(.never_inline, encodeIso, .{ e, Unit, src, dst, last, mode }),
        };
    }

    pub fn maxLen(e: *const Encoder, comptime Unit: type, n: usize, mode: codec.EncoderMode) ?usize {
        // In html mode one unit can be an ill-formed byte or a lone
        // surrogate, U+FFFD, which none of the three has: `&#65533;`.
        // ISO-2022-JP can write a three-byte escape before any character
        // and one to end the stream.
        if (e.kind != .iso_2022_jp) {
            if (mode == .html) return codec.mulAdd(n, 8, 0);
            return codec.mulAdd(n, if (Unit == u16) 2 else 1, 0);
        }
        if (mode == .html) return codec.mulAdd(n, 3 + 8, 3);
        return codec.mulAdd(n, if (Unit == u16) 3 + 2 else 3 + 1, 3);
    }

    fn encodeIso(
        e: *Encoder,
        comptime Unit: type,
        src: []const Unit,
        dst: []u8,
        last: bool,
        mode: codec.EncoderMode,
    ) EncodeResult {
        var i: usize = 0;
        var o: usize = 0;
        while (i < src.len) {
            if (e.state == .ascii) {
                // ASCII, short of SO, SI, and ESC.
                const n = @min(src.len - i, dst.len - o);
                const k = isoAsciiUnits(Unit, src[i..][0..n]);
                codec.narrowAscii(Unit, dst[o..][0..k], src[i..][0..k]);
                i += k;
                o += k;
                while (i < src.len and o < dst.len) : (i += 1) {
                    const c = src[i];
                    if (c >= 0x80 or c == 0x0E or c == 0x0F or c == 0x1B) break;
                    dst[o] = @intCast(c);
                    o += 1;
                }
                if (i == src.len) break;
            } else if (e.state == .jis0208) {
                // Characters index jis0208 has, other than those the
                // handler changes first.
                while (i < src.len and dst.len - o >= 2) {
                    const s = codec.read(Unit, src, i, 3);
                    if (s.cp < 0x80 or s.cp == 0xA5 or s.cp == 0x203E or s.cp == 0x2212 or
                        (s.cp >= 0xFF61 and s.cp <= 0xFF9F)) break;
                    const p = jis0208.encode(@intCast(s.cp)) orelse break;
                    dst[o] = @intCast(p / 94 + 0x21);
                    dst[o + 1] = @intCast(p % 94 + 0x21);
                    o += 2;
                    i += s.len;
                }
                if (i == src.len) break;
            }
            const s = codec.read(Unit, src, i, 3);
            // The standard's handler; an escape restores the code point to
            // the queue, so it runs again in the new state.
            const unmappable: u21 = while (true) {
                const cp: u21 = @intCast(s.cp);
                if (e.state != .jis0208 and (cp == 0x0E or cp == 0x0F or cp == 0x1B)) break 0xFFFD;
                if (e.state == .ascii and cp < 0x80) {
                    if (o == dst.len) return .{ .status = .output_full, .read = i, .written = o };
                    dst[o] = @intCast(cp);
                    o += 1;
                    break 0;
                }
                if (e.state == .roman and ((cp < 0x80 and cp != 0x5C and cp != 0x7E) or cp == 0xA5 or cp == 0x203E)) {
                    if (o == dst.len) return .{ .status = .output_full, .read = i, .written = o };
                    dst[o] = switch (cp) {
                        0xA5 => 0x5C,
                        0x203E => 0x7E,
                        else => @intCast(cp),
                    };
                    o += 1;
                    break 0;
                }
                var next: IsoEncState = undefined;
                if (cp < 0x80) {
                    next = .ascii;
                } else if (cp == 0xA5 or cp == 0x203E) {
                    next = .roman;
                } else {
                    var c = cp;
                    if (c == 0x2212) c = 0xFF0D;
                    if (c >= 0xFF61 and c <= 0xFF9F) c = @intCast(katakana.decode(c - 0xFF61));
                    if (jis0208.encode(c)) |p| {
                        if (e.state == .jis0208) {
                            if (dst.len - o < 2) return .{ .status = .output_full, .read = i, .written = o };
                            dst[o] = @intCast(p / 94 + 0x21);
                            dst[o + 1] = @intCast(p % 94 + 0x21);
                            o += 2;
                            break 0;
                        }
                        next = .jis0208;
                    } else {
                        if (e.state != .jis0208) break c;
                        next = .ascii;
                    }
                }
                if (dst.len - o < 3) return .{ .status = .output_full, .read = i, .written = o };
                dst[o..][0..3].* = switch (next) {
                    .ascii => "\x1B(B".*,
                    .roman => "\x1B(J".*,
                    .jis0208 => "\x1B$B".*,
                };
                o += 3;
                e.state = next;
            };
            if (unmappable != 0) {
                if (mode == .fatal) return .{
                    .status = .unmappable,
                    .read = i + s.len,
                    .written = o,
                    .unmappable = unmappable,
                };
                o += codec.putNcr(dst, o, unmappable) orelse
                    return .{ .status = .output_full, .read = i, .written = o };
            }
            i += s.len;
        }
        if (last and e.state != .ascii) {
            if (dst.len - o < 3) return .{ .status = .output_full, .read = i, .written = o };
            dst[o..][0..3].* = "\x1B(B".*;
            o += 3;
            e.state = .ascii;
        }
        return .{ .status = .input_empty, .read = i, .written = o };
    }
};

/// Shift_JIS's and EUC-JP's encoder loop: ASCII a block at a time, then
/// each character through `map`.
fn encodeTwoByte(
    comptime Unit: type,
    comptime map: fn (u21) callconv(.@"inline") Bytes,
    src: []const Unit,
    dst: []u8,
    mode: codec.EncoderMode,
) EncodeResult {
    var i: usize = 0;
    var o: usize = 0;
    const block = codec.ascii_block;
    // A character the encoding has takes no more bytes than it took
    // units of UTF-8, or twice its units of UTF-16.
    const per: usize = if (Unit == u8) 1 else 2;
    while (true) {
        // The fast path: ASCII, a block at a time where it can, and the
        // characters `map` has. A character that starts below `limit` has
        // room, however far past it it runs.
        const limit = i + @min(src.len - i, ((dst.len - o) / per) -| 3);
        while (i < limit) {
            const c = src[i];
            if (c < 0x80) {
                const start = i;
                while (src.len - i >= block and dst.len - o >= block) {
                    const v: @Vector(block, Unit) = src[i..][0..block].*;
                    if (@reduce(.Or, v >= @as(@Vector(block, Unit), @splat(0x80)))) break;
                    codec.narrowAscii(Unit, dst[o..][0..block], src[i..][0..block]);
                    i += block;
                    o += block;
                }
                if (i == start) {
                    dst[o] = @intCast(c);
                    i += 1;
                    o += 1;
                }
                continue;
            }
            const s = codec.read(Unit, src, i, 3);
            const bytes = map(@intCast(s.cp));
            if (bytes.len == 0) break;
            dst[o] = bytes.b[0];
            dst[o + 1] = bytes.b[1];
            o += bytes.len;
            i += s.len;
        }
        if (i == src.len) return .{ .status = .input_empty, .read = i, .written = o };
        // Then one character with room checks, or an error.
        const s = codec.read(Unit, src, i, 3);
        const bytes = map(@intCast(s.cp));
        if (bytes.len != 0) {
            if (dst.len - o < bytes.len) return .{ .status = .output_full, .read = i, .written = o };
            dst[o] = bytes.b[0];
            if (bytes.len == 2) dst[o + 1] = bytes.b[1];
            o += bytes.len;
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
}

/// The units at the start of `src`, bytes or UTF-16 units, in whole
/// blocks of ASCII with no 0x0E, 0x0F, or 0x1B: what ISO-2022-JP's ASCII
/// state copies, decoding or encoding.
inline fn isoAsciiUnits(comptime Unit: type, src: []const Unit) usize {
    const block = codec.ascii_block;
    const V = @Vector(block, Unit);
    var k: usize = 0;
    while (src.len - k >= block) : (k += block) {
        const v: V = src[k..][0..block].*;
        const bad = (v >= @as(V, @splat(0x80))) | (v == @as(V, @splat(0x0E))) |
            (v == @as(V, @splat(0x0F))) | (v == @as(V, @splat(0x1B)));
        if (@reduce(.Or, bad)) break;
    }
    return k;
}

const testing = std.testing;

/// `src` decoded in one call, in replacement mode, to UTF-8.
fn decodeAll(e: Encoding, src: []const u8, buf: []u8) []const u8 {
    var d = Decoder.init(e);
    const r = d.decode(u8, src, buf, true, .replacement);
    std.debug.assert(r.status == .input_empty);
    std.debug.assert(r.read == src.len);
    return buf[0..r.written];
}

fn expectDecodes(e: Encoding, cases: []const [2][]const u8) !void {
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        testing.expectEqualStrings(c[1], decodeAll(e, c[0], &buf)) catch |x| {
            std.debug.print("{s}: {x}\n", .{ e.name(), c[0] });
            return x;
        };
    }
}

/// `src` (UTF-8) encoded in one call, in html mode.
fn encodeAll(e: Encoding, src: []const u8, buf: []u8) []const u8 {
    var enc = Encoder.init(e);
    const r = enc.encode(u8, src, buf, true, .html);
    std.debug.assert(r.status == .input_empty);
    std.debug.assert(r.read == src.len);
    return buf[0..r.written];
}

fn expectEncodes(e: Encoding, cases: []const [2][]const u8) !void {
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        testing.expectEqualStrings(c[1], encodeAll(e, c[0], &buf)) catch |x| {
            std.debug.print("{s}: {s}\n", .{ e.name(), c[0] });
            return x;
        };
    }
}

test "Shift_JIS decoder: single bytes, EUDC, and which bytes an error takes" {
    try expectDecodes(.shift_jis, &.{
        .{ "\x80\xA1\xDF", "\u{80}\u{FF61}\u{FF9F}" },
        .{ "\xA0\xFD\xFE\xFF", "\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}" },
        .{ "\x81\x40\x81\x7C\xFA\x5C", "\u{3000}\u{FF0D}\u{7E8A}" },
        // Pointers 8836 to 10715 are the private use area.
        .{ "\xF0\x40\xF9\xFC", "\u{E000}\u{E757}" },
        // An ASCII trail byte is read again; any other is taken.
        .{ "\x81\x7Fa", "\u{FFFD}\x7Fa" },
        .{ "\x81\xFDa", "\u{FFFD}a" },
        .{ "\x81\xB5a", "\u{FFFD}a" },
        .{ "a\x81", "a\u{FFFD}" },
    });
    var d = Decoder.init(.shift_jis);
    var out: [8]u8 = undefined;
    try testing.expectEqual(
        DecodeResult{ .status = .malformed, .read = 1, .written = 0 },
        d.decode(u8, "\x81\x7F", &out, true, .fatal),
    );
}

test "EUC-JP decoder: half-width katakana, jis0212, and errors" {
    try expectDecodes(.euc_jp, &.{
        .{ "\x8E\xA1\x8E\xDF\xA1\xA1", "\u{FF61}\u{FF9F}\u{3000}" },
        .{ "\x8F\xA2\xAF", "\u{02D8}" },
        // 0x8E takes a non-ASCII byte outside A1 to DF with it.
        .{ "\x8E\xE0a", "\u{FFFD}a" },
        .{ "\x8E\x41", "\u{FFFD}A" },
        .{ "\x8F\x41", "\u{FFFD}A" },
        .{ "\x8F\xA1\x41", "\u{FFFD}A" },
        // An unmapped jis0212 pointer takes all three bytes.
        .{ "\x8F\xA1\xA1a", "\u{FFFD}a" },
        // jis0212 applies to one character only.
        .{ "\x8F\xA2\xAF\xA1\xA1", "\u{02D8}\u{3000}" },
        .{ "\x8F\xA2", "\u{FFFD}" },
        .{ "\x80\xFF", "\u{FFFD}\u{FFFD}" },
    });
    var d = Decoder.init(.euc_jp);
    var out: [8]u8 = undefined;
    try testing.expectEqual(
        DecodeResult{ .status = .malformed, .read = 2, .written = 0 },
        d.decode(u8, "\x8F\xA2 ", &out, false, .fatal),
    );
    // Held across calls: 0x8F, then A2, then AF.
    d = Decoder.init(.euc_jp);
    try testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 1, .written = 0 },
        d.decode(u8, "\x8F", &out, false, .fatal),
    );
    try testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 1, .written = 0 },
        d.decode(u8, "\xA2", &out, false, .fatal),
    );
    try testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 1, .written = 2 },
        d.decode(u8, "\xAF", &out, true, .fatal),
    );
    try testing.expectEqualStrings("\u{02D8}", out[0..2]);
}

test "ISO-2022-JP decoder: its states and escapes" {
    try expectDecodes(.iso_2022_jp, &.{
        .{ "a\x1B$B\x30\x21\x1B(Bb", "a\u{4E9C}b" },
        .{ "\x1B$@\x30\x21", "\u{4E9C}" },
        .{ "\x1B(J\\~a", "\u{A5}\u{203E}a" },
        .{ "\x1B(I\x21\x5F\x60", "\u{FF61}\u{FF9F}\u{FFFD}" },
        // SO, SI, and bytes from 0x80 are errors in every state.
        .{ "\x0E\x0F\x80", "\u{FFFD}\u{FFFD}\u{FFFD}" },
        // Two escapes in a row: the second is an error.
        .{ "\x1B(B\x1B(Ba", "\u{FFFD}a" },
        .{ "\x1B(Ba\x1B(Bb", "ab" },
        // A bad escape is an error, and its bytes after ESC are read
        // again in the state before it.
        .{ "\x1Bxa", "\u{FFFD}xa" },
        .{ "\x1B$x", "\u{FFFD}$x" },
        .{ "\x1B(I\x1B$x", "\u{FFFD}\u{FF64}\u{FFFD}" },
        .{ "\x1B", "\u{FFFD}" },
        .{ "\x1B(", "\u{FFFD}(" },
        .{ "\x1B(I", "" },
        // ESC as a trail byte: an error, then an escape.
        .{ "\x1B$B\x30\x1B(Ba", "\u{FFFD}a" },
        .{ "\x1B$B\x30", "\u{FFFD}" },
        .{ "\x1B$B\x30\x7F", "\u{FFFD}" },
        .{ "\x1B$B\x22\x2F", "\u{FFFD}" },
    });
}

test "ISO-2022-JP decoder: an escape's leading byte from an earlier call is replayed" {
    var out: [16]u8 = undefined;
    var d = Decoder.init(.iso_2022_jp);
    try testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 2, .written = 0 },
        d.decode(u8, "\x1B$", &out, false, .fatal),
    );
    // "x" is not an escape: an error, and "$" and "x" are read again.
    try testing.expectEqual(
        DecodeResult{ .status = .malformed, .read = 0, .written = 0 },
        d.decode(u8, "x", &out, false, .fatal),
    );
    try testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 1, .written = 2 },
        d.decode(u8, "x", &out, true, .fatal),
    );
    try testing.expectEqualStrings("$x", out[0..2]);
    // In one call the leading byte is unread instead.
    d = Decoder.init(.iso_2022_jp);
    try testing.expectEqual(
        DecodeResult{ .status = .malformed, .read = 1, .written = 0 },
        d.decode(u8, "\x1B$x", &out, true, .fatal),
    );
}

test "Shift_JIS encoder" {
    try expectEncodes(.shift_jis, &.{
        .{ "a\u{80}\u{A5}\u{203E}", "a\x80\x5C\x7E" },
        .{ "\u{FF61}\u{FF9F}", "\xA1\xDF" },
        .{ "\u{2212}\u{FF0D}\u{2252}", "\x81\x7C\x81\x7C\x81\xE0" },
        // NEC's selection of IBM's extensions encodes as IBM's.
        .{ "\u{7E8A}", "\xFA\x5C" },
        .{ "\u{E000}\u{02D8}", "&#57344;&#728;" },
    });
}

test "EUC-JP encoder" {
    try expectEncodes(.euc_jp, &.{
        .{ "a\u{A5}\u{203E}\u{80}", "a\x5C\x7E&#128;" },
        .{ "\u{FF61}\u{2212}\u{7E8A}", "\x8E\xA1\xA1\xDD\xF9\xA1" },
        // jis0212 is decode-only.
        .{ "\u{02D8}", "&#728;" },
    });
}

test "ISO-2022-JP encoder: escapes, katakana, and errors" {
    try expectEncodes(.iso_2022_jp, &.{
        .{ "a", "a" },
        .{ "\u{A5}\u{A5}a", "\x1B(J\x5C\x5Ca\x1B(B" },
        .{ "\\\u{A5}\\", "\\\x1B(J\x5C\x1B(B\\" },
        .{ "\u{4E9C}a", "\x1B$B\x30\x21\x1B(Ba" },
        .{ "\u{FF61}\u{2212}", "\x1B$B\x21\x23\x21\x5D\x1B(B" },
        // In the jis0208 state an unmappable character switches to ASCII
        // for its reference.
        .{ "\u{4E9C}\u{20AC}", "\x1B$B\x30\x21\x1B(B&#8364;" },
        // SO, SI, and ESC are errors reported as U+FFFD.
        .{ "\x0E\x1B", "&#65533;&#65533;" },
        .{ "\u{4E9C}\x0F", "\x1B$B\x30\x21\x1B(B&#65533;" },
    });
    var e = Encoder.init(.iso_2022_jp);
    var out: [16]u8 = undefined;
    try testing.expectEqual(
        EncodeResult{ .status = .unmappable, .read = 1, .written = 0, .unmappable = 0xFFFD },
        e.encode(u8, "\x1B", &out, true, .fatal),
    );
    // The closing escape when only it does not fit.
    e = Encoder.init(.iso_2022_jp);
    try testing.expectEqual(
        EncodeResult{ .status = .output_full, .read = 3, .written = 5 },
        e.encode(u8, "\u{4E9C}", out[0..6], true, .html),
    );
    try testing.expectEqual(
        EncodeResult{ .status = .input_empty, .read = 0, .written = 3 },
        e.encode(u8, "", &out, true, .html),
    );
}

test "every code point encodes to the standard's index pointer" {
    // The index pointer from the decode table: the first pointer for each
    // code point, and for Shift_JIS the first outside 8272 to 8835.
    const Ref = [0x10000]u16;
    const first = try testing.allocator.create(Ref);
    defer testing.allocator.destroy(first);
    const sjis = try testing.allocator.create(Ref);
    defer testing.allocator.destroy(sjis);
    @memset(first, 0xFFFF);
    @memset(sjis, 0xFFFF);
    var p: u32 = 12000;
    while (p > 0) {
        p -= 1;
        const cp = jis0208.decode(p);
        if (cp == 0) continue;
        first[cp] = @intCast(p);
        if (p < 8272 or p > 8835) sjis[cp] = @intCast(p);
    }
    var cp: u21 = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        const want: ?u16 = if (cp < 0x10000 and first[cp] != 0xFFFF) first[cp] else null;
        try testing.expectEqual(want, jis0208.encode(cp));
        const want_sjis: ?u16 = if (cp < 0x10000 and sjis[cp] != 0xFFFF) sjis[cp] else null;
        try testing.expectEqual(want_sjis, shiftJisPointer(cp));
    }
}
