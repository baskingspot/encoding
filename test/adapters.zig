//! The stream adapters, `DecodingReader` and `EncodingWriter`, against one
//! call of `Decoder` and `Encoder` over the whole input: the same output
//! however the input arrives and the output is taken, in random pieces
//! through every way `std.Io.Reader` and `std.Io.Writer` read and write,
//! with random buffer sizes on every side, and in fatal mode the same
//! output before the error and the same error. `just fuzz` runs the same
//! checks as its `reader` and `writer` targets.

const std = @import("std");
const encoding = @import("encoding");
const props = @import("props");
const Encoding = encoding.Encoding;
const Decoder = encoding.Decoder;
const Encoder = encoding.Encoder;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

pub const Error = error{PropertyFailed} || std.mem.Allocator.Error;

fn fail(comptime fmt: []const u8, args: anytype) error{PropertyFailed} {
    std.debug.print("property failed: " ++ fmt ++ "\n", args);
    return error.PropertyFailed;
}

/// A reader of `data` that hands it out a random number of bytes at a
/// time, into a buffer of random size.
const Trickle = struct {
    data: []const u8,
    at: usize = 0,
    rng: std.Random,
    max: usize,
    interface: Reader,

    fn init(data: []const u8, rng: std.Random, buffer: []u8) Trickle {
        return .{
            .data = data,
            .rng = rng,
            .max = 1 + rng.uintLessThan(usize, 40),
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    fn stream(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
        const t: *Trickle = @fieldParentPtr("interface", r);
        if (t.at == t.data.len) return error.EndOfStream;
        const n = limit.minInt(@min(t.data.len - t.at, t.rng.uintAtMost(usize, t.max)));
        const written = try w.write(t.data[t.at..][0..n]);
        t.at += written;
        return written;
    }
};

/// A writer with a buffer of random size that passes everything on to
/// `out`.
const Relay = struct {
    out: *Writer,
    interface: Writer,

    fn init(out: *Writer, buffer: []u8) Relay {
        return .{ .out = out, .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const relay: *Relay = @fieldParentPtr("interface", w);
        try relay.out.writeAll(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try relay.out.writeAll(d);
            n += d.len;
        }
        try relay.out.splatBytesAll(data[data.len - 1], splat);
        return n + data[data.len - 1].len * splat;
    }
};

fn randomBuffer(gpa: std.mem.Allocator, rng: std.Random) ![]u8 {
    const sizes = [_]usize{ 0, 1, 2, 3, 4, 5, 7, 9, 10, 11, 16, 64, 300, 4096 };
    return gpa.alloc(u8, sizes[rng.uintLessThan(usize, sizes.len)]);
}

/// Random decoder options, as `Decoder` takes them.
pub fn decoderOptions(rng: std.Random) Decoder.Options {
    return .{
        .mode = if (rng.boolean()) .replacement else .fatal,
        .bom = switch (rng.uintLessThan(u8, 3)) {
            0 => .sniff,
            1 => .remove,
            else => .keep,
        },
    };
}

/// Decodes `src` through a `DecodingReader` read in random ways, and checks
/// the output against one call of `Decoder`; in fatal mode, the output
/// before the first error, then `error.ReadFailed` with `malformed` within
/// three bytes of where one call reports it (a byte the decoder reads again
/// may have come in an earlier read).
pub fn checkReader(
    gpa: std.mem.Allocator,
    rng: std.Random,
    enc: Encoding,
    src: []const u8,
    options: Decoder.Options,
) Error!void {
    var whole: Decoder = .init(enc, options);
    const want = try gpa.alloc(u8, whole.maxUtf8Len(src.len).?);
    defer gpa.free(want);
    const one = whole.decodeToUtf8(src, want, true);
    if (one.status == .output_full) return fail("{s}: maxUtf8Len too small", .{enc.name()});
    const expected = want[0..one.written];

    const in_buf = try gpa.alloc(u8, 1 + rng.uintLessThan(usize, 64));
    defer gpa.free(in_buf);
    var trickle: Trickle = .init(src, rng, in_buf);
    const buf = try randomBuffer(gpa, rng);
    defer gpa.free(buf);
    var dr: encoding.DecodingReader(Decoder) = .init(&trickle.interface, .init(enc, options), buf);
    const r = &dr.interface;

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(gpa);
    var scratch: [128]u8 = undefined;
    // readSliceShort, readVec, and discard drop what they took from the
    // buffer when the next read fails, so fatal mode does without them.
    const ops: u8 = if (options.mode == .fatal) 4 else 7;
    const end: Reader.Error = while (true) {
        const step: Reader.Error!void = switch (rng.uintLessThan(u8, ops)) {
            0 => if (buf.len == 0) {} else if (r.takeByte()) |b| try got.append(gpa, b) else |e| e,
            1 => blk: {
                // A fixed writer fails a write it cannot take whole.
                const room = 1 + rng.uintLessThan(usize, scratch.len);
                var fw: Writer = .fixed(scratch[0..room]);
                const limit: std.Io.Limit = .limited(1 + rng.uintLessThan(usize, room));
                _ = r.stream(&fw, limit) catch |e| break :blk switch (e) {
                    error.WriteFailed => return fail("stream into a fixed writer failed", .{}),
                    error.ReadFailed, error.EndOfStream => |x| x,
                };
                try got.appendSlice(gpa, fw.buffered());
            },
            2 => blk: {
                var sink: Writer.Allocating = .init(gpa);
                defer sink.deinit();
                const relay_buf = try randomBuffer(gpa, rng);
                defer gpa.free(relay_buf);
                var relay: Relay = .init(&sink.writer, relay_buf);
                const limit: std.Io.Limit = .limited(1 + rng.uintLessThan(usize, 300));
                const n = r.stream(&relay.interface, limit) catch |e| break :blk switch (e) {
                    error.WriteFailed => return fail("stream into a relay failed", .{}),
                    error.ReadFailed, error.EndOfStream => |x| x,
                };
                relay.interface.flush() catch return fail("relay flush failed", .{});
                if (sink.written().len != n) return fail("stream returned {d}, wrote {d}", .{ n, sink.written().len });
                try got.appendSlice(gpa, sink.written());
            },
            3 => if (buf.len == 0) {} else blk: {
                const n = 1 + rng.uintLessThan(usize, buf.len);
                const peeked = r.peekGreedy(n) catch |e| switch (e) {
                    // Fewer than n bytes are left: take one.
                    error.EndOfStream => break :blk if (r.takeByte()) |b| try got.append(gpa, b) else |x| x,
                    error.ReadFailed => break :blk e,
                };
                const k = rng.uintAtMost(usize, peeked.len);
                try got.appendSlice(gpa, peeked[0..k]);
                r.toss(k);
            },
            4 => blk: {
                const want_n = 1 + rng.uintLessThan(usize, scratch.len);
                const n = r.readSliceShort(scratch[0..want_n]) catch |e| break :blk e;
                try got.appendSlice(gpa, scratch[0..n]);
                if (n < want_n) break :blk error.EndOfStream;
            },
            5 => blk: {
                var vec: [2][]u8 = .{
                    scratch[0..rng.uintAtMost(usize, 20)],
                    scratch[20..][0 .. 1 + rng.uintLessThan(usize, 44)],
                };
                const first = vec[0].len;
                const n = r.readVec(&vec) catch |e| break :blk e;
                try got.appendSlice(gpa, scratch[0..@min(n, first)]);
                if (n > first) try got.appendSlice(gpa, scratch[20..][0 .. n - first]);
            },
            else => blk: {
                // What `discard` skips is copied from `expected`, to keep
                // `got` in step; at the end of the stream it has skipped
                // what was buffered.
                const buffered = r.bufferedLen();
                const n = r.discard(.limited(1 + rng.uintLessThan(usize, 20))) catch |e| {
                    if (got.items.len + buffered > expected.len) return fail("discarded past the end", .{});
                    try got.appendSlice(gpa, expected[got.items.len..][0..buffered]);
                    break :blk e;
                };
                if (got.items.len + n > expected.len) return fail("discarded past the end", .{});
                try got.appendSlice(gpa, expected[got.items.len..][0..n]);
            },
        };
        step catch |e| break e;
    };
    // After an error, what the reader holds is still to be read.
    try got.appendSlice(gpa, r.buffered());

    if (!std.mem.eql(u8, got.items, expected)) {
        return fail("{s} {any}: reader gave {d} bytes, one call {d}\n  reader: {x}\n  one call: {x}", .{
            enc.name(), options, got.items.len, expected.len, got.items, expected,
        });
    }
    switch (one.status) {
        .malformed => {
            if (end != error.ReadFailed)
                return fail("{s}: ended with {t}, not ReadFailed at an error", .{ enc.name(), end });
            const at = dr.malformed orelse return fail("{s}: ReadFailed without malformed", .{enc.name()});
            if (@max(at, one.read) - @min(at, one.read) > 3)
                return fail("{s}: malformed at {d}, one call at {d}", .{ enc.name(), at, one.read });
        },
        else => if (end != error.EndOfStream or dr.malformed != null)
            return fail("{s}: ended with {t}, malformed {any}", .{ enc.name(), end, dr.malformed }),
    }
}

/// Writes `utf8` to an `EncodingWriter` in random pieces through random
/// `std.Io.Writer` calls, flushing now and then, ends it, and checks the
/// bytes against one call of `Encoder` over what was written (with splats
/// repeated); in fatal mode, the bytes before the first unmappable
/// character, then `error.WriteFailed` with `unmappable` as one call
/// reports it.
pub fn checkWriter(
    gpa: std.mem.Allocator,
    rng: std.Random,
    enc: Encoding,
    utf8: []const u8,
    options: Encoder.Options,
) Error!void {
    var sink: Writer.Allocating = .init(gpa);
    defer sink.deinit();
    const relay_buf = try randomBuffer(gpa, rng);
    defer gpa.free(relay_buf);
    var relay: Relay = .init(&sink.writer, relay_buf);
    const buf = try randomBuffer(gpa, rng);
    defer gpa.free(buf);
    var ew: encoding.EncodingWriter(Encoder) = .init(&relay.interface, .init(enc, options), buf);
    const w = &ew.interface;

    // Everything written, in order.
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    var at: usize = 0;
    const result: Writer.Error!void = while (at < utf8.len) {
        const piece = utf8[at..][0..@min(utf8.len - at, rng.uintAtMost(usize, 50))];
        at += piece.len;
        const op = rng.uintLessThan(u8, 6);
        const splat = if (op == 3) rng.uintAtMost(usize, 3) else 1;
        for (0..splat) |_| try stream.appendSlice(gpa, piece);
        const step: Writer.Error!void = switch (op) {
            0 => w.writeAll(piece),
            1 => for (piece) |b| w.writeByte(b) catch |e| break e,
            2 => w.print("{s}", .{piece}),
            3 => w.splatBytesAll(piece, splat),
            4 => blk: {
                const cut = rng.uintAtMost(usize, piece.len);
                var vec: [2][]const u8 = .{ piece[0..cut], piece[cut..] };
                break :blk w.writeVecAll(&vec);
            },
            else => blk: {
                w.writeAll(piece) catch |e| break :blk e;
                break :blk w.flush();
            },
        };
        step catch |e| break e;
    } else ew.end();
    relay.interface.flush() catch return fail("relay flush failed", .{});

    var whole: Encoder = .init(enc, options);
    const want = try gpa.alloc(u8, whole.maxLenFromUtf8(stream.items.len).?);
    defer gpa.free(want);
    const one = whole.encodeFromUtf8(stream.items, want, true);
    if (one.status == .output_full) return fail("{s}: maxLenFromUtf8 too small", .{enc.name()});
    const expected = want[0..one.written];
    if (!std.mem.eql(u8, sink.written(), expected)) {
        return fail("{s} {any}: writer gave {d} bytes, one call {d}\n  writer: {x}\n  one call: {x}", .{
            enc.name(), options, sink.written().len, expected.len, sink.written(), expected,
        });
    }
    switch (one.status) {
        .unmappable => {
            if (result != error.WriteFailed)
                return fail("{s}: no WriteFailed at an unmappable character", .{enc.name()});
            const u = ew.unmappable orelse return fail("{s}: WriteFailed without unmappable", .{enc.name()});
            if (u.code_point != one.unmappable or u.end != one.read)
                return fail("{s}: unmappable {any}, one call U+{X} ending at {d}", .{
                    enc.name(), u, one.unmappable, one.read,
                });
        },
        else => {
            result catch |e| return fail("{s}: {t}, unmappable {any}", .{ enc.name(), e, ew.unmappable });
        },
    }
}

/// Random encoder options.
pub fn encoderOptions(rng: std.Random) Encoder.Options {
    return .{ .mode = if (rng.boolean()) .html else .fatal };
}

const testing = std.testing;

test "DecodingReader: random reads give one call's output" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const rng = prng.random();
    for (encoding.implemented) |enc| {
        for (0..30) |_| {
            const src = try props.decoderInput(testing.allocator, rng, 400);
            defer testing.allocator.free(src);
            checkReader(testing.allocator, rng, enc, src, decoderOptions(rng)) catch |err| {
                std.debug.print("input ({d} bytes): {x}\n", .{ src.len, src });
                return err;
            };
        }
    }
}

test "EncodingWriter: random writes give one call's output" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const rng = prng.random();
    for (encoding.implemented) |enc| {
        if (enc.outputEncoding() != enc) continue;
        for (0..30) |_| {
            const t = try props.encoderInput(testing.allocator, rng, 150);
            defer testing.allocator.free(t.utf8);
            defer testing.allocator.free(t.utf16);
            checkWriter(testing.allocator, rng, enc, t.utf8, encoderOptions(rng)) catch |err| {
                std.debug.print("input: {x}\n", .{t.utf8});
                return err;
            };
        }
    }
}
