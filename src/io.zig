//! Transcoding streams over `std.Io`: a `std.Io.Reader` that decodes bytes
//! in some encoding read from another reader to UTF-8, and a
//! `std.Io.Writer` that encodes the UTF-8 written to it into some encoding
//! on another writer. Neither allocates; the caller gives each its buffer.
//!
//!     var dr: encoding.DecodingReader(encoding.Decoder) = .init(in, .init(enc, .{}), &buf);
//!     const n = try dr.interface.streamRemaining(stdout);
//!
//!     const Sjis = encoding.EncoderFor(&.{.shift_jis});
//!     var ew: encoding.EncodingWriter(Sjis) = .init(stdout, .init(.shift_jis, .{}), &buf);
//!     try ew.interface.print("{s}\n", .{text});
//!     try ew.end();
//!     try stdout.flush();
//!
//! Both run the streaming `Decoder` and `Encoder` underneath, so the output
//! is what one call over the whole stream gives, however the reads and
//! writes split it.

const std = @import("std");
const codec = @import("codec.zig");

const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Limit = std.Io.Limit;

/// A `std.Io.Reader`, `interface`, of UTF-8 decoded with a decoder of type
/// `D` (`Decoder` or a `DecoderFor`) from the bytes `input` reads. Any
/// buffer works, even an empty one; `input` needs a buffer of at least one
/// byte. A `stream` call (as `streamRemaining` makes) decodes straight into
/// the writer's buffer, draining it until four bytes are free, so a
/// `Writer.fixed` with one to three bytes left fails it with
/// `error.WriteFailed`; reading into a slice takes any length.
///
/// In fatal mode, the output before the first malformed sequence is read
/// and then reads fail with `error.ReadFailed` and `malformed` set. A read
/// that fails because `input` failed leaves `malformed` null.
pub fn DecodingReader(comptime D: type) type {
    return struct {
        const Self = @This();

        input: *Reader,
        decoder: D,
        interface: Reader,
        /// The bytes of `input` decoded so far.
        read: u64 = 0,
        /// Fatal mode: the offset in the input just past the first
        /// malformed sequence, once decoding has reached it; up to three
        /// bytes later when a read ended inside the sequence and the
        /// decoder held bytes it reads again.
        malformed: ?u64 = null,
        phase: Phase = .reading,
        /// Output decoded into a call's scratch space that did not fit the
        /// caller's: the rest of one character, given out first next time.
        spill: [3]u8 = undefined,
        spill_len: u8 = 0,

        const Phase = enum(u8) { reading, input_ended, done, failed };

        /// A reader of the UTF-8 `decoder` decodes from `input`.
        pub fn init(input: *Reader, decoder: D, buffer: []u8) Self {
            return .{
                .input = input,
                .decoder = decoder,
                .interface = .{
                    .vtable = &.{ .stream = stream, .readVec = readVec },
                    .buffer = buffer,
                    .seek = 0,
                    .end = 0,
                },
            };
        }

        fn stream(r: *Reader, w: *Writer, limit: Limit) Reader.StreamError!usize {
            const self: *Self = @alignCast(@fieldParentPtr("interface", r));
            if (limit == .nothing) return 0;
            if (w.buffer.len == 0) {
                var tmp: [256]u8 = undefined;
                const n = try self.decodeInto(limit.slice(&tmp));
                try w.writeAll(tmp[0..n]);
                return n;
            }
            // Room for any character: less would take a call of its own
            // for the sliver at the end of the buffer.
            const n = try self.decodeInto(limit.slice(try w.writableSliceGreedy(@min(4, w.buffer.len))));
            w.advance(n);
            return n;
        }

        /// Decodes into `data[0]` or the reader's own buffer, whichever has
        /// more room.
        fn readVec(r: *Reader, data: [][]u8) Reader.Error!usize {
            const self: *Self = @alignCast(@fieldParentPtr("interface", r));
            if (data[0].len >= r.buffer.len - r.end) return self.decodeInto(data[0]);
            r.end += try self.decodeInto(r.buffer[r.end..]);
            return 0;
        }

        /// Decodes into `dst`, which is not empty: at least one byte, or
        /// the end of the stream or an error.
        fn decodeInto(self: *Self, dst: []u8) Reader.Error!usize {
            if (self.spill_len != 0) {
                const n = @min(dst.len, self.spill_len);
                @memcpy(dst[0..n], self.spill[0..n]);
                @memmove(self.spill[0 .. self.spill_len - n], self.spill[n..self.spill_len]);
                self.spill_len -= @intCast(n);
                return n;
            }
            // Four bytes always take a character.
            if (dst.len >= 4) return self.decodeSome(dst);
            var tmp: [4]u8 = undefined;
            const n = try self.decodeSome(&tmp);
            const k = @min(n, dst.len);
            @memcpy(dst[0..k], tmp[0..k]);
            @memcpy(self.spill[0 .. n - k], tmp[k..n]);
            self.spill_len = @intCast(n - k);
            return k;
        }

        /// Decodes into `dst`, at least four bytes long, until it writes
        /// something.
        fn decodeSome(self: *Self, dst: []u8) Reader.Error!usize {
            while (true) {
                switch (self.phase) {
                    .done => return error.EndOfStream,
                    .failed => return error.ReadFailed,
                    .input_ended => {},
                    .reading => if (self.input.bufferedLen() == 0) {
                        self.input.fillMore() catch |err| switch (err) {
                            error.EndOfStream => self.phase = .input_ended,
                            error.ReadFailed => return error.ReadFailed,
                        };
                        continue;
                    },
                }
                // Once `input` has ended, nothing is buffered: the last
                // call has no input and finishes the stream.
                const last = self.phase == .input_ended;
                const r = self.decoder.decodeToUtf8(self.input.buffered(), dst, last);
                self.input.toss(r.read);
                self.read += r.read;
                switch (r.status) {
                    .input_empty => if (last) {
                        self.phase = .done;
                    },
                    .output_full => {},
                    .malformed => {
                        self.malformed = self.read;
                        self.phase = .failed;
                    },
                }
                if (r.written != 0) return r.written;
            }
        }
    };
}

/// A `std.Io.Writer`, `interface`, that encodes the UTF-8 written to it
/// with an encoder of type `E` (`Encoder` or an `EncoderFor`) and writes
/// the bytes to `output`. Any buffer works; a larger one makes fewer,
/// longer encode calls. `output` is fastest with a buffer of at least
/// `max_ncr_len` (10) bytes, which the encoder then writes into directly.
///
/// `flush` encodes what is buffered and writes it to `output`, holding back
/// a character the writes so far cut off; `end` finishes the stream, as
/// `last` does for `Encoder`: a character cut off becomes U+FFFD's
/// encoding (a numeric character reference where the encoding lacks it),
/// and ISO-2022-JP returns to ASCII. Neither flushes `output`. In fatal
/// mode, a character the encoding lacks fails the write with
/// `error.WriteFailed` and sets `unmappable`, after the output before it;
/// the writer then fails every call.
pub fn EncodingWriter(comptime E: type) type {
    return struct {
        const Self = @This();

        output: *Writer,
        encoder: E,
        interface: Writer,
        /// The bytes of UTF-8 encoded so far.
        written: u64 = 0,
        /// Fatal mode: the first character the encoding lacks, and the
        /// offset in the UTF-8 written just past it.
        unmappable: ?Unmappable = null,

        pub const Unmappable = struct { code_point: u21, end: u64 };

        /// A writer that encodes with `encoder` into `output`.
        pub fn init(output: *Writer, encoder: E, buffer: []u8) Self {
            return .{
                .output = output,
                .encoder = encoder,
                .interface = .{
                    .vtable = &.{ .drain = drain, .flush = flush },
                    .buffer = buffer,
                },
            };
        }

        /// Encodes what is buffered and ends the stream, writing the
        /// encoder's last bytes to `output`. Does not flush `output`. The
        /// writer fails every call after.
        pub fn end(self: *Self) Writer.Error!void {
            defer self.interface = .failing;
            try self.encode(self.interface.buffered(), true);
        }

        fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
            const self: *Self = @alignCast(@fieldParentPtr("interface", w));
            errdefer w.* = .failing;
            try self.encode(w.buffered(), false);
            w.end = 0;
            // Small writes go to the buffer, to be encoded with the next
            // ones in one call.
            if (Writer.countSplat(data, splat) <= w.buffer.len) return w.writeSplat(data, splat);
            var n: usize = 0;
            for (data[0 .. data.len - 1]) |bytes| {
                try self.encode(bytes, false);
                n += bytes.len;
            }
            const pattern = data[data.len - 1];
            for (0..splat) |_| try self.encode(pattern, false);
            return n + pattern.len * splat;
        }

        fn flush(w: *Writer) Writer.Error!void {
            const self: *Self = @alignCast(@fieldParentPtr("interface", w));
            errdefer w.* = .failing;
            try self.encode(w.buffered(), false);
            w.end = 0;
        }

        fn encode(self: *Self, src: []const u8, last: bool) Writer.Error!void {
            var rest = src;
            while (true) {
                const direct = self.output.buffer.len >= codec.max_ncr_len;
                var tmp: [64]u8 = undefined;
                const dst = if (direct) try self.output.writableSliceGreedy(codec.max_ncr_len) else &tmp;
                const r = self.encoder.encodeFromUtf8(rest, dst, last);
                if (direct) self.output.advance(r.written) else try self.output.writeAll(tmp[0..r.written]);
                rest = rest[r.read..];
                self.written += r.read;
                switch (r.status) {
                    .input_empty => return,
                    .output_full => {},
                    .unmappable => {
                        self.unmappable = .{ .code_point = r.unmappable, .end = self.written };
                        return error.WriteFailed;
                    },
                }
            }
        }
    };
}

const testing = std.testing;
const coder = @import("coder.zig");
const Decoder = coder.DecoderFor(&coder.implemented);
const Encoder = coder.EncoderFor(&coder.implemented);

test "DecodingReader: Shift_JIS to UTF-8, read a byte at a time" {
    // ｱ (half-width katakana) and 日本.
    var input: Reader = .fixed("a\xB1\x93\xFA\x96\x7B");
    var buf: [1]u8 = undefined;
    var dr: DecodingReader(Decoder) = .init(&input, .init(.shift_jis, .{}), &buf);
    var out: [16]u8 = undefined;
    var n: usize = 0;
    while (dr.interface.takeByte()) |b| : (n += 1) {
        out[n] = b;
    } else |err| try testing.expectEqual(error.EndOfStream, err);
    try testing.expectEqualStrings("a\u{FF71}\u{65E5}\u{672C}", out[0..n]);
    try testing.expectEqual(6, dr.read);
}

test "DecodingReader: a sequence cut off at the end, into an unbuffered writer" {
    var input: Reader = .fixed("x\xE2\x82");
    var dr: DecodingReader(Decoder) = .init(&input, .init(.utf_8, .{}), &.{});
    var out: [16]u8 = undefined;
    var fw: Writer = .fixed(&out);
    var unbuffered: Unbuffered = .{ .out = &fw };
    try testing.expectEqual(4, try dr.interface.streamRemaining(&unbuffered.writer));
    try testing.expectEqualStrings("x\u{FFFD}", fw.buffered());
}

/// A writer with no buffer, passing everything to `out`.
const Unbuffered = struct {
    out: *Writer,
    writer: Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const u: *Unbuffered = @fieldParentPtr("writer", w);
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try u.out.writeAll(d);
            n += d.len;
        }
        for (0..splat) |_| try u.out.writeAll(data[data.len - 1]);
        return n + data[data.len - 1].len * splat;
    }
};

test "DecodingReader: fatal mode reads up to the error, then fails" {
    var input: Reader = .fixed("ok\xFFno");
    var buf: [8]u8 = undefined;
    var dr: DecodingReader(Decoder) = .init(&input, .init(.utf_8, .{ .mode = .fatal }), &buf);
    var out: [8]u8 = undefined;
    try testing.expectEqual(2, try dr.interface.readSliceShort(out[0..2]));
    try testing.expectEqualStrings("ok", out[0..2]);
    try testing.expectError(error.ReadFailed, dr.interface.readSliceShort(&out));
    try testing.expectEqual(@as(?u64, 3), dr.malformed);
    try testing.expectError(error.ReadFailed, dr.interface.takeByte());
}

test "EncodingWriter: ISO-2022-JP across writes, ended" {
    var out: [64]u8 = undefined;
    var fw: Writer = .fixed(&out);
    var buf: [2]u8 = undefined;
    var ew: EncodingWriter(Encoder) = .init(&fw, .init(.iso_2022_jp, .{}), &buf);
    for ("a\u{3042}") |byte| try ew.interface.writeByte(byte);
    try ew.interface.flush();
    // The kana is out; the return to ASCII waits for what comes next.
    try testing.expectEqualStrings("a\x1B$B$\"", fw.buffered());
    try ew.interface.writeByte('b');
    try ew.end();
    try testing.expectEqualStrings("a\x1B$B$\"\x1B(Bb", fw.buffered());
    try testing.expectError(error.WriteFailed, ew.interface.writeAll("c"));
}

test "EncodingWriter: a character cut off at the end, and fatal mode" {
    var out: [64]u8 = undefined;
    var fw: Writer = .fixed(&out);
    var ew: EncodingWriter(Encoder) = .init(&fw, .init(.windows_1252, .{}), &.{});
    try ew.interface.writeAll("\u{20AC}\xE2\x82");
    try ew.end();
    try testing.expectEqualStrings("\x80&#65533;", fw.buffered());

    fw = .fixed(&out);
    var buf: [16]u8 = undefined;
    var f: EncodingWriter(Encoder) = .init(&fw, .init(.windows_1252, .{ .mode = .fatal }), &buf);
    try f.interface.writeAll("ab\u{0100}c");
    try testing.expectError(error.WriteFailed, f.interface.flush());
    try testing.expectEqualStrings("ab", fw.buffered());
    try testing.expectEqual(EncodingWriter(Encoder).Unmappable{ .code_point = 0x100, .end = 4 }, f.unmappable.?);
}
