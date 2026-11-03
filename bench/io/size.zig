//! The link-size programs for the conveniences and stream adapters
//! (docs/slop/results/io-*.md): each reads stdin, converts it with one way
//! of calling the package, and writes stdout, so that `size -A` of each,
//! net of `none`, shows what that way links. Each pair differs only in the
//! call: the streaming type called directly, or the convenience or
//! adapter over the same type.

const std = @import("std");
const variant = @import("options").variant;

// ziglint-ignore: Z028 -- `none` imports no encoding module
const enc = if (variant == .none) struct {} else @import("encoding");

var in_buf: [1 << 16]u8 = undefined;
var out_buf: [4 << 16]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    var stdin_buf: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    const r = &stdin.interface;
    const w = &stdout.interface;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const label = if (args.len > 1) args[1] else "latin1";
    switch (variant) {
        .none => try w.writeAll(try whole(r)),
        .direct_1252 => try w.writeAll(try direct(
            Win1252.init(.windows_1252, .{ .bom = .remove }),
            try whole(r),
        )),
        .convert_1252 => try w.writeAll((try enc.decodeToUtf8(
            Win1252,
            .windows_1252,
            try whole(r),
            &out_buf,
            .{ .bom = .remove },
        )).text),
        .direct_sjis => try w.writeAll(try direct(Sjis.init(.shift_jis, .{ .bom = .remove }), try whole(r))),
        .convert_sjis => try w.writeAll((try enc.decodeToUtf8(
            Sjis,
            .shift_jis,
            try whole(r),
            &out_buf,
            .{ .bom = .remove },
        )).text),
        .direct_enc_sjis => try w.writeAll(try direct(SjisOut.init(.shift_jis, .{}), try whole(r))),
        .convert_enc_sjis => try w.writeAll((try enc.encodeFromUtf8(
            SjisOut,
            .shift_jis,
            try whole(r),
            &out_buf,
            .{},
        )).bytes),
        .direct_label => try w.writeAll(try direct(enc.Decoder.init(try forLabel(label), .{}), try whole(r))),
        .convert_label => try w.writeAll((try enc.decodeToUtf8(
            enc.Decoder,
            try forLabel(label),
            try whole(r),
            &out_buf,
            .{},
        )).text),
        .stream_1252 => try stream(Win1252.init(.windows_1252, .{ .bom = .remove }), r, w),
        .reader_1252 => {
            var dr: enc.DecodingReader(Win1252) = .init(r, .init(.windows_1252, .{ .bom = .remove }), &.{});
            _ = try dr.interface.streamRemaining(w);
        },
        .stream_enc_sjis => try stream(SjisOut.init(.shift_jis, .{}), r, w),
        .writer_enc_sjis => {
            var buf: [4096]u8 = undefined;
            var ew: enc.EncodingWriter(SjisOut) = .init(w, .init(.shift_jis, .{}), &buf);
            _ = try r.streamRemaining(&ew.interface);
            try ew.end();
        },
    }
    try w.flush();
}

pub const Variant = enum {
    none,
    direct_1252,
    convert_1252,
    direct_sjis,
    convert_sjis,
    direct_enc_sjis,
    convert_enc_sjis,
    direct_label,
    convert_label,
    stream_1252,
    reader_1252,
    stream_enc_sjis,
    writer_enc_sjis,
};

// Analyzed only by the variants that name them.
const Win1252 = enc.DecoderFor(&.{.windows_1252});
const Sjis = enc.DecoderFor(&.{.shift_jis});
const SjisOut = enc.EncoderFor(&.{.shift_jis});

fn forLabel(label: []const u8) !enc.Encoding {
    return enc.Encoding.forLabel(label) orelse error.UnknownLabel;
}

fn whole(r: *std.Io.Reader) ![]const u8 {
    return in_buf[0..try r.readSliceShort(&in_buf)];
}

/// One call of `coder`, a decoder or encoder, over all of `src`.
fn direct(coder: anytype, src: []const u8) ![]const u8 {
    var c = coder;
    const res = if (@hasDecl(@TypeOf(c), "decodeToUtf8"))
        c.decodeToUtf8(src, &out_buf, true)
    else
        c.encodeFromUtf8(src, &out_buf, true);
    if (res.status == .output_full) return error.NoSpaceLeft;
    return out_buf[0..res.written];
}

/// Stdin to stdout in chunks with `coder`, as a loop over the streaming
/// calls does.
fn stream(coder: anytype, r: *std.Io.Reader, w: *std.Io.Writer) !void {
    var c = coder;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try r.readSliceShort(&chunk);
        const last = n < chunk.len;
        var i: usize = 0;
        while (true) {
            const res = if (@hasDecl(@TypeOf(c), "decodeToUtf8"))
                c.decodeToUtf8(chunk[i..n], &out_buf, last)
            else
                c.encodeFromUtf8(chunk[i..n], &out_buf, last);
            try w.writeAll(out_buf[0..res.written]);
            i += res.read;
            if (res.status == .input_empty) break;
        }
        if (last) return;
    }
}
