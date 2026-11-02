//! The properties every codec must have, as checks the streaming tests
//! (test/stream.zig) and the fuzz driver (test/fuzz/main.zig) run on their
//! inputs:
//!
//! - Decoding writes well-formed UTF-8 and UTF-16, and the two agree.
//! - Any split of the input into chunks, and any output buffer down to four
//!   bytes (two units), gives the output of one call, with fatal mode's
//!   errors after the same output.
//! - A buffer of `maxUtf8Len` (`maxUtf16Len`, `maxLenFromUtf8`, ...) takes
//!   the whole input in one call, and a call short of room still makes
//!   progress.
//! - Encoding from UTF-8 and from UTF-16 gives the same bytes, and the same
//!   unmappable characters in fatal mode.
//!
//! Each check returns `error.PropertyFailed` after printing what differs.

const std = @import("std");
const encoding = @import("encoding");
const Encoding = encoding.Encoding;
const Decoder = encoding.Decoder;
const Encoder = encoding.Encoder;

pub const Error = error{PropertyFailed} || std.mem.Allocator.Error;

fn fail(comptime fmt: []const u8, args: anytype) error{PropertyFailed} {
    std.debug.print("property failed: " ++ fmt ++ "\n", args);
    return error.PropertyFailed;
}

/// Where fatal mode reported an error: the input offset (`read`) and the
/// output written before it. The output offset is the same however the
/// input is split; the input offset can be up to three bytes later when a
/// byte the decoder reads again came in an earlier call, as with half a
/// UTF-16 code unit held at the end of a chunk.
pub const Mark = struct { in: usize, out: usize };

fn sameMarks(a: []const Mark, b: []const Mark) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.out != y.out) return false;
        if (@max(x.in, y.in) - @min(x.in, y.in) > 3) return false;
    }
    return true;
}

/// What a whole stream decodes to: the output, and in fatal mode where
/// each error was reported.
pub fn Decoded(comptime Unit: type) type {
    return struct {
        units: []Unit,
        errors: []Mark,
        /// The encoding in use at the end, after any byte order mark.
        encoding: Encoding,
    };
}

/// Decodes `src` in chunks that end at each of `cuts` (ascending offsets)
/// and at its end, into output buffers of `room` units, or of what
/// `maxUtf8Len` says when `room` is 0, going on after each error.
pub fn decode(
    comptime Unit: type,
    gpa: std.mem.Allocator,
    enc: Encoding,
    options: Decoder.Options,
    src: []const u8,
    cuts: []const usize,
    room: usize,
) Error!Decoded(Unit) {
    var d: Decoder = .init(enc, options);
    var units: std.ArrayList(Unit) = .empty;
    var errors: std.ArrayList(Mark) = .empty;
    var buf: []Unit = &.{};
    defer gpa.free(buf);
    var start: usize = 0;
    var k: usize = 0;
    while (true) {
        const end = if (k < cuts.len) cuts[k] else src.len;
        k += 1;
        const last = k > cuts.len;
        var chunk = src[start..end];
        var pos = start;
        var stalls: usize = 0;
        while (true) {
            const max = if (Unit == u8) d.maxUtf8Len(chunk.len) else d.maxUtf16Len(chunk.len);
            const cap = if (room != 0) room else max orelse
                return fail("{s}: max length overflows for {d} bytes", .{ enc.name(), chunk.len });
            if (buf.len < cap) {
                gpa.free(buf);
                buf = try gpa.alloc(Unit, cap);
            }
            const r = if (Unit == u8)
                d.decodeToUtf8(chunk, buf[0..cap], last)
            else
                d.decodeToUtf16(chunk, buf[0..cap], last);
            if (r.read > chunk.len or r.written > cap) return fail(
                "{s}: read {d} of {d}, wrote {d} of {d}",
                .{ enc.name(), r.read, chunk.len, r.written, cap },
            );
            try units.appendSlice(gpa, buf[0..r.written]);
            chunk = chunk[r.read..];
            pos += r.read;
            switch (r.status) {
                .input_empty => {
                    if (chunk.len != 0) return fail(
                        "{s}: input_empty with {d} bytes unread",
                        .{ enc.name(), chunk.len },
                    );
                    break;
                },
                .output_full => {
                    if (room == 0) return fail(
                        "{s}: output_full in a buffer of the max length ({d}) at offset {d}",
                        .{ enc.name(), cap, pos },
                    );
                    if (r.read == 0 and r.written == 0) {
                        stalls += 1;
                        if (stalls > 2) return fail(
                            "{s}: no progress with {d} units of room at offset {d}",
                            .{ enc.name(), room, pos },
                        );
                    } else stalls = 0;
                },
                .malformed => {
                    if (options.mode != .fatal) return fail("{s}: malformed in replacement mode", .{enc.name()});
                    try errors.append(gpa, .{ .in = pos, .out = units.items.len });
                },
            }
        }
        start = end;
        if (last) break;
    }
    return .{ .units = try units.toOwnedSlice(gpa), .errors = try errors.toOwnedSlice(gpa), .encoding = d.encoding };
}

fn freeDecoded(gpa: std.mem.Allocator, d: anytype) void {
    gpa.free(d.units);
    gpa.free(d.errors);
}

/// Whether `units` is well-formed UTF-16.
pub fn wellFormedUtf16(units: []const u16) bool {
    var i: usize = 0;
    while (i < units.len) : (i += 1) {
        const u = units[i];
        if (u >= 0xDC00 and u <= 0xDFFF) return false;
        if (u >= 0xD800 and u <= 0xDBFF) {
            if (i + 1 == units.len or units[i + 1] < 0xDC00 or units[i + 1] > 0xDFFF) return false;
            i += 1;
        }
    }
    return true;
}

/// Ascending offsets in `0..len`, for chunk boundaries.
fn randomCuts(gpa: std.mem.Allocator, rng: std.Random, len: usize, n: usize) ![]usize {
    const cuts = try gpa.alloc(usize, n);
    for (cuts) |*c| c.* = rng.uintAtMost(usize, len);
    std.mem.sort(usize, cuts, {}, std.sort.asc(usize));
    return cuts;
}

fn everyOffset(gpa: std.mem.Allocator, len: usize) ![]usize {
    const cuts = try gpa.alloc(usize, len);
    for (cuts, 0..) |*c, i| c.* = i;
    return cuts;
}

/// How hard a check works: `splits` random splits, and every two-way split
/// of inputs up to `exhaustive` bytes.
pub const Effort = struct {
    splits: usize = 4,
    exhaustive: usize = 64,
};

/// The decoder properties for `enc` on `src`, in both modes, both
/// outputs, and the byte order mark options.
pub fn checkDecoder(
    gpa: std.mem.Allocator,
    rng: std.Random,
    enc: Encoding,
    src: []const u8,
    effort: Effort,
) Error!void {
    for ([_]Decoder.Mode{ .replacement, .fatal }) |mode| {
        for ([_]Decoder.Bom{ .sniff, .keep, .remove }) |bom| {
            const options: Decoder.Options = .{ .mode = mode, .bom = bom };
            const ref8 = try decode(u8, gpa, enc, options, src, &.{}, 0);
            defer freeDecoded(gpa, ref8);
            if (!std.unicode.utf8ValidateSlice(ref8.units)) {
                return fail("{s} {t} {t}: UTF-8 output is ill-formed", .{ enc.name(), mode, bom });
            }
            const ref16 = try decode(u16, gpa, enc, options, src, &.{}, 0);
            defer freeDecoded(gpa, ref16);
            if (!wellFormedUtf16(ref16.units)) return fail(
                "{s} {t} {t}: UTF-16 output is ill-formed",
                .{ enc.name(), mode, bom },
            );
            // The two outputs are the same text.
            const as16 = std.unicode.utf8ToUtf16LeAlloc(gpa, ref8.units) catch return fail(
                "{s}: UTF-8 output does not convert",
                .{enc.name()},
            );
            defer gpa.free(as16);
            for (as16) |*u| u.* = std.mem.littleToNative(u16, u.*);
            if (!std.mem.eql(u16, as16, ref16.units)) return fail(
                "{s} {t} {t}: UTF-8 and UTF-16 outputs differ on {d} bytes",
                .{ enc.name(), mode, bom, src.len },
            );
            if (ref8.errors.len != ref16.errors.len) return fail(
                "{s} {t} {t}: UTF-8 and UTF-16 error counts differ",
                .{ enc.name(), mode, bom },
            );
            for (ref8.errors, ref16.errors) |a, b| {
                if (a.in != b.in) return fail(
                    "{s} {t} {t}: UTF-8 and UTF-16 errors at different offsets",
                    .{ enc.name(), mode, bom },
                );
            }

            // Splits and short buffers. The byte order mark options matter
            // at the start only, so most of the work is on one of them.
            const full = bom == .sniff;
            var variants: std.ArrayList(struct { cuts: []usize, room8: usize, room16: usize }) = .empty;
            defer {
                for (variants.items) |v| gpa.free(v.cuts);
                variants.deinit(gpa);
            }
            try variants.append(gpa, .{ .cuts = try gpa.alloc(usize, 0), .room8 = 4, .room16 = 2 });
            try variants.append(gpa, .{ .cuts = try everyOffset(gpa, src.len), .room8 = 0, .room16 = 0 });
            if (full) {
                try variants.append(gpa, .{ .cuts = try everyOffset(gpa, src.len), .room8 = 4, .room16 = 2 });
                if (src.len <= effort.exhaustive) {
                    for (0..src.len + 1) |cut| {
                        const c = try gpa.alloc(usize, 1);
                        c[0] = cut;
                        try variants.append(gpa, .{ .cuts = c, .room8 = 0, .room16 = 0 });
                    }
                }
                for (0..effort.splits) |_| {
                    const n = rng.uintAtMost(usize, @min(src.len, 16));
                    try variants.append(gpa, .{
                        .cuts = try randomCuts(gpa, rng, src.len, n),
                        .room8 = if (rng.boolean()) 0 else 4 + rng.uintLessThan(usize, 64),
                        .room16 = if (rng.boolean()) 0 else 2 + rng.uintLessThan(usize, 32),
                    });
                }
            }
            for (variants.items) |v| {
                const got8 = try decode(u8, gpa, enc, options, src, v.cuts, v.room8);
                defer freeDecoded(gpa, got8);
                if (!std.mem.eql(u8, got8.units, ref8.units) or !sameMarks(got8.errors, ref8.errors))
                    return fail(
                        "{s} {t} {t}: UTF-8 output differs with cuts {any} and room {d}",
                        .{ enc.name(), mode, bom, v.cuts, v.room8 },
                    );
                const got16 = try decode(u16, gpa, enc, options, src, v.cuts, v.room16);
                defer freeDecoded(gpa, got16);
                if (!std.mem.eql(u16, got16.units, ref16.units) or !sameMarks(got16.errors, ref16.errors))
                    return fail(
                        "{s} {t} {t}: UTF-16 output differs with cuts {any} and room {d}",
                        .{ enc.name(), mode, bom, v.cuts, v.room16 },
                    );
            }
        }
    }
}

/// What a whole stream encodes to: the bytes, and in fatal mode each
/// unmappable character.
pub const Encoded = struct {
    bytes: []u8,
    unmappable: []u21,
};

/// Encodes `src`, UTF-8 or UTF-16 units, in chunks ending at each of
/// `cuts`, into buffers of `room` bytes (0: what `maxLenFrom*` says).
pub fn encode(
    comptime Unit: type,
    gpa: std.mem.Allocator,
    enc: Encoding,
    mode: Encoder.Mode,
    src: []const Unit,
    cuts: []const usize,
    room: usize,
) Error!Encoded {
    var e: Encoder = .init(enc, .{ .mode = mode });
    var bytes: std.ArrayList(u8) = .empty;
    var unmappable: std.ArrayList(u21) = .empty;
    var buf: []u8 = &.{};
    defer gpa.free(buf);
    var start: usize = 0;
    var k: usize = 0;
    while (true) {
        const end = if (k < cuts.len) cuts[k] else src.len;
        k += 1;
        const last = k > cuts.len;
        var chunk = src[start..end];
        var stalls: usize = 0;
        while (true) {
            const max = if (Unit == u8) e.maxLenFromUtf8(chunk.len) else e.maxLenFromUtf16(chunk.len);
            const cap = if (room != 0) room else max orelse
                return fail("{s}: encoder max length overflows", .{enc.name()});
            if (buf.len < cap) {
                gpa.free(buf);
                buf = try gpa.alloc(u8, cap);
            }
            const r = if (Unit == u8)
                e.encodeFromUtf8(chunk, buf[0..cap], last)
            else
                e.encodeFromUtf16(chunk, buf[0..cap], last);
            if (r.read > chunk.len or r.written > cap) return fail(
                "{s}: encoder read {d} of {d}, wrote {d} of {d}",
                .{ enc.name(), r.read, chunk.len, r.written, cap },
            );
            try bytes.appendSlice(gpa, buf[0..r.written]);
            chunk = chunk[r.read..];
            switch (r.status) {
                .input_empty => {
                    if (chunk.len != 0) return fail(
                        "{s}: encoder input_empty with {d} units unread",
                        .{ enc.name(), chunk.len },
                    );
                    break;
                },
                .output_full => {
                    if (room == 0) return fail("{s}: encoder output_full in a buffer of the max length", .{enc.name()});
                    if (r.read == 0 and r.written == 0) {
                        stalls += 1;
                        if (stalls > 2) return fail(
                            "{s}: encoder makes no progress with {d} bytes of room",
                            .{ enc.name(), room },
                        );
                    } else stalls = 0;
                },
                .unmappable => {
                    if (mode != .fatal) return fail("{s}: unmappable in html mode", .{enc.name()});
                    try unmappable.append(gpa, r.unmappable);
                },
            }
        }
        start = end;
        if (last) break;
    }
    return .{ .bytes = try bytes.toOwnedSlice(gpa), .unmappable = try unmappable.toOwnedSlice(gpa) };
}

fn freeEncoded(gpa: std.mem.Allocator, e: Encoded) void {
    gpa.free(e.bytes);
    gpa.free(e.unmappable);
}

/// The encoder properties for `enc` on the same text as UTF-8 (`text8`)
/// and UTF-16 (`text16`), each with the same ill-formed parts in it.
pub fn checkEncoder(
    gpa: std.mem.Allocator,
    rng: std.Random,
    enc: Encoding,
    text8: []const u8,
    text16: []const u16,
    effort: Effort,
) Error!void {
    for ([_]Encoder.Mode{ .html, .fatal }) |mode| {
        const ref8 = try encode(u8, gpa, enc, mode, text8, &.{}, 0);
        defer freeEncoded(gpa, ref8);
        const ref16 = try encode(u16, gpa, enc, mode, text16, &.{}, 0);
        defer freeEncoded(gpa, ref16);
        if (!std.mem.eql(u8, ref8.bytes, ref16.bytes) or !std.mem.eql(u21, ref8.unmappable, ref16.unmappable))
            return fail("{s} {t}: encoding from UTF-8 and from UTF-16 differ", .{ enc.name(), mode });
        inline for (.{ u8, u16 }) |Unit| {
            const text = if (Unit == u8) text8 else text16;
            const ref = if (Unit == u8) ref8 else ref16;
            var variants: std.ArrayList(struct { cuts: []usize, room: usize }) = .empty;
            defer {
                for (variants.items) |v| gpa.free(v.cuts);
                variants.deinit(gpa);
            }
            try variants.append(gpa, .{ .cuts = try gpa.alloc(usize, 0), .room = encoding.max_ncr_len });
            try variants.append(gpa, .{ .cuts = try everyOffset(gpa, text.len), .room = 0 });
            try variants.append(gpa, .{ .cuts = try everyOffset(gpa, text.len), .room = encoding.max_ncr_len });
            if (text.len <= effort.exhaustive) {
                for (0..text.len + 1) |cut| {
                    const c = try gpa.alloc(usize, 1);
                    c[0] = cut;
                    try variants.append(gpa, .{ .cuts = c, .room = 0 });
                }
            }
            for (0..effort.splits) |_| {
                const n = rng.uintAtMost(usize, @min(text.len, 16));
                try variants.append(gpa, .{
                    .cuts = try randomCuts(gpa, rng, text.len, n),
                    .room = if (rng.boolean()) 0 else encoding.max_ncr_len + rng.uintLessThan(usize, 64),
                });
            }
            for (variants.items) |v| {
                const got = try encode(Unit, gpa, enc, mode, text, v.cuts, v.room);
                defer freeEncoded(gpa, got);
                if (!std.mem.eql(u8, got.bytes, ref.bytes) or !std.mem.eql(u21, got.unmappable, ref.unmappable))
                    return fail(
                        "{s} {t}: encoding from {s} differs with cuts {any} and room {d}",
                        .{ enc.name(), mode, if (Unit == u8) "UTF-8" else "UTF-16", v.cuts, v.room },
                    );
            }
        }
    }
}

// Inputs.

/// Bytes for a decoder: random, mostly ASCII with high bytes among it, the
/// bytes of real characters in UTF-8 or UTF-16 with errors among them,
/// runs that cross SIMD blocks, and byte order marks in front.
pub fn decoderInput(gpa: std.mem.Allocator, rng: std.Random, max_len: usize) ![]u8 {
    // Mostly short, sometimes up to the limit.
    const len = rng.uintAtMost(usize, if (rng.uintLessThan(u8, 4) == 0) max_len else @min(max_len, 80));
    var out: std.ArrayList(u8) = .empty;
    switch (rng.uintLessThan(u8, 6)) {
        0 => try out.appendSlice(gpa, "\xEF\xBB\xBF"),
        1 => try out.appendSlice(gpa, if (rng.boolean()) "\xFE\xFF" else "\xFF\xFE"),
        2 => try out.appendSlice(
            gpa,
            ([_][]const u8{ "\xEF", "\xEF\xBB", "\xFE", "\xFF" })[rng.uintLessThan(usize, 4)],
        ),
        else => {},
    }
    const style = rng.uintLessThan(u8, 5);
    while (out.items.len < len) {
        switch (style) {
            0 => try out.append(gpa, rng.int(u8)),
            1 => {
                // ASCII runs, long enough to cross the SIMD blocks.
                const run = rng.uintLessThan(usize, 80);
                for (0..run) |_| try out.append(gpa, 0x20 + rng.uintLessThan(u8, 0x5F));
                try out.append(gpa, 0x80 | rng.int(u8));
            },
            2 => {
                // UTF-8: characters, sometimes cut short or broken.
                var buf: [4]u8 = undefined;
                const cp = randomScalar(rng);
                const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
                const keep = if (rng.uintLessThan(u8, 8) == 0) rng.uintAtMost(usize, n) else n;
                try out.appendSlice(gpa, buf[0..keep]);
                if (rng.uintLessThan(u8, 16) == 0) try out.append(gpa, rng.int(u8));
            },
            3 => {
                // UTF-16 code units in either byte order, with surrogates.
                const u: u16 = switch (rng.uintLessThan(u8, 4)) {
                    0 => 0xD800 + rng.uintLessThan(u16, 0x800),
                    1 => rng.uintLessThan(u16, 0x80),
                    else => rng.int(u16),
                };
                var b: [2]u8 = undefined;
                std.mem.writeInt(u16, &b, u, if (rng.boolean()) .little else .big);
                try out.appendSlice(gpa, &b);
            },
            else => {
                // Bytes from a small alphabet: lead bytes, trail bytes,
                // ASCII, and the bytes that end sequences.
                const alphabet = [_]u8{
                    0x00, 0x41, 0x7F, 0x80, 0xA0, 0xBF, 0xC2, 0xDF, 0xE0, 0xED, 0xEF,
                    0xF0, 0xF4, 0xFE, 0xFF, 0x1B, 0x8E, 0x8F, 0xA1, 0xFD, 0x40, 0x5C,
                };
                try out.append(gpa, alphabet[rng.uintLessThan(usize, alphabet.len)]);
            },
        }
    }
    return out.toOwnedSlice(gpa);
}

/// A scalar value, weighted toward the ranges encoders care about: ASCII,
/// Latin, the BMP, the private use areas, and the supplementary planes.
pub fn randomScalar(rng: std.Random) u21 {
    while (true) {
        const cp: u21 = switch (rng.uintLessThan(u8, 8)) {
            0, 1 => rng.uintLessThan(u21, 0x80),
            2 => 0x80 + rng.uintLessThan(u21, 0x780),
            3 => 0x2000 + rng.uintLessThan(u21, 0x600),
            4 => 0xF700 + rng.uintLessThan(u21, 0x900),
            5 => 0x10000 + rng.uintLessThan(u21, 0x100000),
            else => rng.uintLessThan(u21, 0x10000),
        };
        if (cp < 0xD800 or cp > 0xDFFF) return cp;
    }
}

/// The same text as UTF-8 and as UTF-16, scalar values with ill-formed
/// parts among them, each of which reads as one U+FFFD in both: a stray
/// byte or a cut-off sequence in UTF-8, an unpaired surrogate in UTF-16.
pub const Text = struct { utf8: []u8, utf16: []u16 };

pub fn encoderInput(gpa: std.mem.Allocator, rng: std.Random, max_chars: usize) !Text {
    var t8: std.ArrayList(u8) = .empty;
    var t16: std.ArrayList(u16) = .empty;
    const n = rng.uintAtMost(usize, if (rng.uintLessThan(u8, 4) == 0) max_chars else @min(max_chars, 40));
    const supported = blk: {
        // Mostly characters the encoding could have: a narrow range.
        const base = randomScalar(rng);
        break :blk base;
    };
    for (0..n) |_| {
        switch (rng.uintLessThan(u8, 12)) {
            0 => {
                // An ill-formed part, then ASCII so it cannot run on.
                const pieces = [_][]const u8{
                    "\x80", "\xBF", "\xC0", "\xC1", "\xF5", "\xFF", "\xE2\x82", "\xF0\x9F\x98", "\xED", "\xE0",
                };
                try t8.appendSlice(gpa, pieces[rng.uintLessThan(usize, pieces.len)]);
                try t8.append(gpa, 'x');
                try t16.append(gpa, 0xD800 + rng.uintLessThan(u16, 0x800));
                try t16.append(gpa, 'x');
            },
            1, 2, 3 => try appendScalar(gpa, &t8, &t16, rng.uintLessThan(u21, 0x80)),
            4, 5 => {
                const near = supported +% rng.uintLessThan(u21, 64);
                try appendScalar(
                    gpa,
                    &t8,
                    &t16,
                    if (near > 0x10FFFF or (near >= 0xD800 and near <= 0xDFFF)) 'y' else near,
                );
            },
            else => try appendScalar(gpa, &t8, &t16, randomScalar(rng)),
        }
    }
    return .{ .utf8 = try t8.toOwnedSlice(gpa), .utf16 = try t16.toOwnedSlice(gpa) };
}

fn appendScalar(gpa: std.mem.Allocator, t8: *std.ArrayList(u8), t16: *std.ArrayList(u16), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
    try t8.appendSlice(gpa, buf[0..n]);
    if (cp < 0x10000) {
        try t16.append(gpa, @intCast(cp));
    } else {
        const v = cp - 0x10000;
        try t16.append(gpa, @intCast(0xD800 | (v >> 10)));
        try t16.append(gpa, @intCast(0xDC00 | (v & 0x3FF)));
    }
}
