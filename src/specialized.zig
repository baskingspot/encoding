//! Decoders and encoders specialized at compile time to a set of encodings
//! (docs/slop/comptime.md):
//!
//!     var decoder: DecoderFor(&.{.windows_1252}) = .init(.windows_1252, .{ .bom = .remove });
//!     const r = decoder.decodeToUtf8(chunk, buffer, is_last_chunk);
//!
//! `DecoderFor(encodings)` holds the state of only the families that decode
//! one of `encodings` and dispatches over only those, so a program that
//! uses it links only their code and tables: one family's decoder is a
//! direct call with no tag, and a single-byte encoding links its own
//! 256-byte table and no other. The streaming contract, the results, and
//! the families are `Decoder`'s and `Encoder`'s. With every implemented
//! encoding, these are the runtime types, which the plan is for `Decoder`
//! and `Encoder` to become.
//!
//! An encoding outside the set panics in `init`, as an unimplemented one
//! does in `Decoder.init`. A byte order mark with `.bom = .sniff` can switch
//! to UTF-8, UTF-16BE, or UTF-16LE, so only a set with all three
//! (`bom_encodings`) takes `Decoder.Options`; any other set takes
//! `OptionsWithoutSniff`, whose `bom` has no `.sniff` and no default.

const std = @import("std");
const codec = @import("codec.zig");
const codecs = @import("codecs.zig");
const RuntimeDecoder = @import("Decoder.zig");
const RuntimeEncoder = @import("Encoder.zig");

pub const Encoding = codec.Encoding;

/// Every encoding this version implements.
pub const implemented = codecs.implemented;

/// The encodings a byte order mark names: add them to a decoder's set for
/// `.bom = .sniff`, the standard's "decode".
pub const bom_encodings = [_]Encoding{ .utf_8, .utf_16be, .utf_16le };

/// Every implemented encoding but Chinese, Japanese, and Korean ones,
/// whose tables are most of the package's size.
pub const no_cjk = blk: {
    const cjk: Set = .initMany(&.{ .shift_jis, .euc_jp, .iso_2022_jp, .gbk, .gb18030, .big5, .euc_kr });
    var list: []const Encoding = &.{};
    for (implemented) |e| {
        if (!cjk.contains(e)) list = list ++ .{e};
    }
    break :blk list[0..list.len].*;
};

/// The options of a decoder whose set lacks one of `bom_encodings`.
pub const OptionsWithoutSniff = struct {
    mode: RuntimeDecoder.Mode = .replacement,
    /// `.remove`, the standard's "UTF-8 decode" and TextDecoder's default,
    /// or `.keep`, "decode without BOM". No default, so that code moved
    /// from `Decoder`, whose default is `.sniff`, says which it means.
    bom: enum { remove, keep },
};

/// A set of encodings: the types' canonical parameter, so that the same
/// encodings in any order or repeated give the same type.
pub const Set = std.EnumSet(Encoding);

/// A decoder for `encodings`, in any order.
pub fn DecoderFor(comptime encodings: []const Encoding) type {
    @setEvalBranchQuota(100_000);
    return Decoder(.initMany(encodings));
}

/// An encoder for the output encodings of `encodings`.
pub fn EncoderFor(comptime encodings: []const Encoding) type {
    @setEvalBranchQuota(100_000);
    var set: Set = .empty;
    for (encodings) |e| set.insert(e.outputEncoding());
    return Encoder(set);
}

const bom_set: Set = .initMany(&bom_encodings);

const encoding_count = @typeInfo(Encoding).@"enum".fields.len;
const family_fields = @typeInfo(@TypeOf(codecs.families)).@"struct".fields;

/// The families with a `decl` ("Decoder" or "Encoder") for an encoding in
/// `set`: their state, a fresh state for each encoding, and the dispatch.
/// One family's state is that family's own type, with no tag to switch
/// on; more are a tagged union of just those families.
fn Families(comptime set: Set, comptime decl: []const u8) type {
    @setEvalBranchQuota(100_000);
    if (set.count() == 0) @compileError("encoding: an empty set of encodings");
    var it = set.iterator();
    while (it.next()) |e| {
        if (!e.isImplemented()) @compileError("encoding: " ++ e.name() ++ " is not implemented yet");
    }
    var names: [family_fields.len][]const u8 = undefined;
    var types: [family_fields.len]type = undefined;
    var attrs: [family_fields.len]std.builtin.Type.UnionField.Attributes = undefined;
    // The family's one encoding in the set, if it has just one.
    var known: [family_fields.len]?Encoding = undefined;
    var n: usize = 0;
    for (family_fields) |f| {
        const module = @field(codecs.families, f.name);
        var count: usize = 0;
        for (module.encodings) |e| {
            if (!set.contains(e)) continue;
            if (!@hasDecl(module, decl)) @compileError("encoding: " ++ e.name() ++ " has no " ++ decl);
            known[n] = e;
            count += 1;
        }
        if (count == 0) continue;
        if (count > 1) known[n] = null;
        names[n] = f.name;
        types[n] = @field(module, decl);
        attrs[n] = .{};
        n += 1;
    }
    const single = n == 1;
    const known_of = known;
    const Tag = @Enum(u8, .exhaustive, names[0..n], &std.simd.iota(u8, n));
    const StateType = if (single) types[0] else @Union(.auto, Tag, names[0..n], types[0..n], attrs[0..n]);

    return struct {
        pub const State = StateType;

        const first = blk: {
            var es = set.iterator();
            break :blk es.next().?;
        };

        fn build(comptime e: Encoding) State {
            const family = @tagName(codecs.family_of[@intFromEnum(e)].?);
            const T = @field(@field(codecs.families, family), decl);
            return if (single) T.init(e) else @unionInit(State, family, T.init(e));
        }

        /// Each encoding's fresh state, built at compile time, so that a
        /// fresh one is a copy from read-only data (the core orb measured
        /// building it at run time as a store-forwarding stall).
        const fresh_states = blk: {
            var t: [encoding_count]State = undefined;
            var es = set.iterator();
            while (es.next()) |e| t[@intFromEnum(e)] = build(e);
            break :blk t;
        };

        /// A bit for each encoding in the set, as an immediate for `fresh`'s
        /// check: an `EnumSet` read at run time is loaded from memory.
        const members: u64 = blk: {
            if (encoding_count > 64) @compileError("encoding: more than 64 encodings");
            var m: u64 = 0;
            var es = set.iterator();
            while (es.next()) |e| m |= @as(u64, 1) << @intFromEnum(e);
            break :blk m;
        };

        /// A fresh state for `e`; panics if `e` is not in the set.
        pub inline fn fresh(e: Encoding) State {
            const in_set = members >> @as(u6, @intCast(@intFromEnum(e))) & 1 != 0;
            if (!in_set) @panic("encoding: not in this decoder's or encoder's set of encodings");
            if (comptime set.count() == 1) return comptime build(first);
            return fresh_states[@intFromEnum(e)];
        }

        pub inline fn decode(
            state: *State,
            comptime Unit: type,
            src: []const u8,
            dst: []Unit,
            last: bool,
            mode: codec.DecoderMode,
        ) codec.DecodeResult {
            if (single) return decodeIn(0, state, Unit, src, dst, last, mode);
            switch (state.*) {
                inline else => |*s, tag| return decodeIn(@intFromEnum(tag), s, Unit, src, dst, last, mode),
            }
        }

        /// A family that tells its encodings apart at run time can declare
        /// `decodeAs` and `encodeAs`, `decode` and `encode` with the
        /// encoding as a compile-time parameter; with one of its encodings
        /// in the set, they are called instead, so the others' code and
        /// tables are not linked.
        inline fn decodeIn(
            comptime k: usize,
            s: anytype,
            comptime Unit: type,
            src: []const u8,
            dst: []Unit,
            last: bool,
            mode: codec.DecoderMode,
        ) codec.DecodeResult {
            const e = comptime known_of[k];
            if (e != null and @hasDecl(@TypeOf(s.*), "decodeAs")) return s.decodeAs(Unit, e.?, src, dst, last, mode);
            return s.decode(Unit, src, dst, last, mode);
        }

        pub fn decoderMaxLen(state: *const State, comptime Unit: type, n_: usize) ?usize {
            if (single) return state.maxLen(Unit, n_);
            switch (state.*) {
                inline else => |s| return s.maxLen(Unit, n_),
            }
        }

        pub inline fn encode(
            state: *State,
            comptime Unit: type,
            src: []const Unit,
            dst: []u8,
            last: bool,
            mode: codec.EncoderMode,
        ) codec.EncodeResult {
            if (single) return encodeIn(0, state, Unit, src, dst, last, mode);
            switch (state.*) {
                inline else => |*s, tag| return encodeIn(@intFromEnum(tag), s, Unit, src, dst, last, mode),
            }
        }

        inline fn encodeIn(
            comptime k: usize,
            s: anytype,
            comptime Unit: type,
            src: []const Unit,
            dst: []u8,
            last: bool,
            mode: codec.EncoderMode,
        ) codec.EncodeResult {
            const e = comptime known_of[k];
            if (e != null and @hasDecl(@TypeOf(s.*), "encodeAs")) return s.encodeAs(Unit, e.?, src, dst, last, mode);
            return s.encode(Unit, src, dst, last, mode);
        }

        pub fn encoderMaxLen(state: *const State, comptime Unit: type, n_: usize, mode: codec.EncoderMode) ?usize {
            if (single) return state.maxLen(Unit, n_, mode);
            switch (state.*) {
                inline else => |s| return s.maxLen(Unit, n_, mode),
            }
        }
    };
}

/// A streaming decoder for the encodings in `set`, with `Decoder`'s
/// contract (src/Decoder.zig): the same `init`, calls, and results.
pub fn Decoder(comptime set: Set) type {
    const F = Families(set, "Decoder");
    const can_sniff = set.supersetOf(bom_set);
    return struct {
        const Self = @This();

        pub const Result = codec.DecodeResult;
        pub const Status = codec.DecodeStatus;
        pub const Mode = codec.DecoderMode;
        pub const Bom = RuntimeDecoder.Bom;
        pub const Options = if (can_sniff) RuntimeDecoder.Options else OptionsWithoutSniff;
        /// The encodings this type decodes.
        pub const encodings = set;

        /// The encoding being decoded: the one given to `init` until a
        /// byte order mark, with `.sniff`, switches it.
        encoding: Encoding,
        mode: Mode,
        phase: Phase,
        /// Bytes held while the byte order mark is undecided, and then
        /// until the decoder has read them.
        pending: [3]u8 = undefined,
        pending_len: u8 = 0,
        state: F.State,

        const Phase = enum(u8) { decoding, sniff, remove, replay };

        /// A decoder for `encoding`. Panics if `encoding` is not in the
        /// set.
        pub fn init(encoding: Encoding, options: Options) Self {
            const bom: Bom = if (can_sniff) options.bom else switch (options.bom) {
                .remove => .remove,
                .keep => .keep,
            };
            const phase: Phase = switch (bom) {
                .sniff => .sniff,
                .remove => switch (encoding) {
                    .utf_8, .utf_16be, .utf_16le => .remove,
                    else => .decoding,
                },
                .keep => .decoding,
            };
            return .{ .encoding = encoding, .mode = options.mode, .phase = phase, .state = F.fresh(encoding) };
        }

        /// Decodes `src` to UTF-8 into `dst`.
        pub fn decodeToUtf8(d: *Self, src: []const u8, dst: []u8, last: bool) Result {
            if (d.phase == .decoding) return F.decode(&d.state, u8, src, dst, last, d.mode);
            return d.decodeSlow(u8, src, dst, last);
        }

        /// Decodes `src` to UTF-16, in the machine's byte order, into `dst`.
        pub fn decodeToUtf16(d: *Self, src: []const u8, dst: []u16, last: bool) Result {
            if (d.phase == .decoding) return F.decode(&d.state, u16, src, dst, last, d.mode);
            return d.decodeSlow(u16, src, dst, last);
        }

        /// The most UTF-8 bytes decoding `n` more bytes can write, in any
        /// split and in either mode, or null if that overflows `usize`.
        pub fn maxUtf8Len(d: *const Self, n: usize) ?usize {
            return d.maxLen(u8, n);
        }

        /// The most UTF-16 units decoding `n` more bytes can write, or
        /// null if that overflows `usize`.
        pub fn maxUtf16Len(d: *const Self, n: usize) ?usize {
            return d.maxLen(u16, n);
        }

        fn maxLen(d: *const Self, comptime Unit: type, n: usize) ?usize {
            const total = std.math.add(usize, n, d.pending_len) catch return null;
            var max = F.decoderMaxLen(&d.state, Unit, total) orelse return null;
            if (can_sniff and d.phase == .sniff) {
                // A byte order mark may yet switch to UTF-8 or UTF-16.
                inline for (.{ Encoding.utf_8, Encoding.utf_16le }) |e| {
                    const fresh = comptime F.fresh(e);
                    max = @max(max, F.decoderMaxLen(&fresh, Unit, total) orelse return null);
                }
            }
            return max;
        }

        const Verdict = union(enum) { undecided, none, bom: Encoding.Bom };

        fn verdict(d: *const Self) Verdict {
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

        fn decodeSlow(d: *Self, comptime Unit: type, src: []const u8, dst: []Unit, last: bool) Result {
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
                                // Only `.sniff` switches, and only a set
                                // that can sniff starts in that phase.
                                if (!can_sniff) unreachable;
                                d.encoding = m.encoding;
                                d.state = F.fresh(m.encoding);
                            }
                            d.pending_len = 0;
                            d.phase = .decoding;
                            const r = F.decode(&d.state, Unit, src[i..], dst, last, d.mode);
                            return .{ .status = r.status, .read = i + r.read, .written = r.written };
                        },
                        .none => break,
                    }
                }
                // No byte order mark. The bytes taken from `src` in this
                // call are given back; those from earlier calls go to the
                // decoder first.
                d.pending_len -= @intCast(i);
                i = 0;
                d.phase = .replay;
            }
            var o: usize = 0;
            if (d.pending_len != 0) {
                const held = d.pending[0..d.pending_len];
                const r = F.decode(&d.state, Unit, held, dst, last and src.len == 0, d.mode);
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
            const r = F.decode(&d.state, Unit, src[i..], dst[o..], last, d.mode);
            return .{ .status = r.status, .read = i + r.read, .written = o + r.written };
        }
    };
}

fn bomBytes(e: Encoding) []const u8 {
    return switch (e) {
        .utf_8 => "\xEF\xBB\xBF",
        .utf_16be => "\xFE\xFF",
        else => "\xFF\xFE",
    };
}

/// A streaming encoder for the output encodings in `set`, with `Encoder`'s
/// contract (src/Encoder.zig).
pub fn Encoder(comptime set: Set) type {
    @setEvalBranchQuota(100_000);
    var it = set.iterator();
    while (it.next()) |e| {
        if (e.outputEncoding() != e) @compileError("encoding: " ++ e.name() ++ " encodes as UTF-8; use EncoderFor");
    }
    const F = Families(set, "Encoder");
    return struct {
        const Self = @This();

        pub const Result = codec.EncodeResult;
        pub const Status = codec.EncodeStatus;
        pub const Mode = codec.EncoderMode;
        pub const Options = RuntimeEncoder.Options;
        /// The output encodings this type encodes.
        pub const encodings = set;

        /// The encoding written: the output encoding of the one given to
        /// `init`.
        encoding: Encoding,
        mode: Mode,
        /// The start of a character the last call's input cut off: up to
        /// three UTF-8 bytes, or one leading surrogate in `pending16`.
        pending: [3]u8 = undefined,
        pending16: u16 = 0,
        pending_len: u8 = 0,
        state: F.State,

        /// An encoder for `encoding`'s output encoding. Panics if that is
        /// not in the set.
        pub fn init(encoding: Encoding, options: Options) Self {
            const out = encoding.outputEncoding();
            return .{ .encoding = out, .mode = options.mode, .state = F.fresh(out) };
        }

        /// Encodes `src`, UTF-8, into `dst`.
        pub fn encodeFromUtf8(e: *Self, src: []const u8, dst: []u8, last: bool) Result {
            return e.encode(u8, src, dst, last);
        }

        /// Encodes `src`, UTF-16 in the machine's byte order, into `dst`.
        pub fn encodeFromUtf16(e: *Self, src: []const u16, dst: []u8, last: bool) Result {
            return e.encode(u16, src, dst, last);
        }

        /// The most bytes encoding `n` more bytes of UTF-8 can write, in
        /// the encoder's mode and any split, or null if that overflows.
        pub fn maxLenFromUtf8(e: *const Self, n: usize) ?usize {
            const total = std.math.add(usize, n, e.pending_len) catch return null;
            return F.encoderMaxLen(&e.state, u8, total, e.mode);
        }

        /// The most bytes encoding `n` more units of UTF-16 can write.
        pub fn maxLenFromUtf16(e: *const Self, n: usize) ?usize {
            const total = std.math.add(usize, n, e.pending_len) catch return null;
            return F.encoderMaxLen(&e.state, u16, total, e.mode);
        }

        fn encode(e: *Self, comptime Unit: type, src: []const Unit, dst: []u8, last: bool) Result {
            var i: usize = 0;
            var o: usize = 0;
            if (e.pending_len != 0) {
                // Finish the held character with units from `src`, then
                // encode it on its own.
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
                const r = F.encode(&e.state, Unit, buf[0..n], dst, false, e.mode);
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
            const r = F.encode(&e.state, Unit, src[i..end], dst[o..], last, e.mode);
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
    };
}
