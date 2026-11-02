//! The link-size programs (docs/slop/results/comptime-20261102.md): each
//! reads stdin, decodes or encodes it with one variant of the API, and
//! writes stdout, so that `size -A` of each shows what that variant links.
//! `none` copies stdin to stdout, the baseline the others are net of.

const std = @import("std");
const variant = @import("options").variant;

// ziglint-ignore: Z028 -- `none` imports no encoding module
const enc = if (variant == .none) struct {} else @import("encoding");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var in_buf: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &in_buf);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const label = if (args.len > 1) args[1] else "latin1";
    const r = &stdin.interface;
    const w = &stdout.interface;
    try switch (variant) {
        .none => copy(r, w),
        .label => named(try forLabel(label), r, w),
        .rt_1252 => run(enc.Decoder.init(.windows_1252, .{}), r, w),
        .rt_label => run(enc.Decoder.init(try forLabel(label), .{}), r, w),
        .rt_enc_label => run(enc.Encoder.init(try forLabel(label), .{}), r, w),
        .ct_1252 => run(enc.DecoderFor(&.{.windows_1252}).init(.windows_1252, .{ .bom = .remove }), r, w),
        .ct_1252_sniff => run(enc.DecoderFor(&sniffing_1252).init(.windows_1252, .{}), r, w),
        .ct_sjis => run(enc.DecoderFor(&.{.shift_jis}).init(.shift_jis, .{ .bom = .remove }), r, w),
        .ct_gb18030 => run(enc.DecoderFor(&.{.gb18030}).init(.gb18030, .{ .bom = .remove }), r, w),
        .ct_euc_kr => run(enc.DecoderFor(&.{.euc_kr}).init(.euc_kr, .{ .bom = .remove }), r, w),
        .ct_utf8_1252 => run(Utf8Or1252.init(try forLabel(label), .{ .bom = .remove }), r, w),
        .ct_nocjk_label => run(enc.DecoderFor(&no_cjk).init(try forLabel(label), .{}), r, w),
        .ct_all_label => run(enc.DecoderFor(&enc.implemented).init(try forLabel(label), .{}), r, w),
        .ct_enc_1252 => run(enc.EncoderFor(&.{.windows_1252}).init(.windows_1252, .{}), r, w),
        .both => both(label, r, w),
        .ct_enc_sjis => run(enc.EncoderFor(&.{.shift_jis}).init(.shift_jis, .{}), r, w),
    };
    try stdout.interface.flush();
}

// Analyzed only by the variant that names it.
const sniffing_1252 = [_]enc.Encoding{.windows_1252} ++ enc.bom_encodings;
const Utf8Or1252 = enc.DecoderFor(&.{ .utf_8, .windows_1252 });

fn forLabel(label: []const u8) !enc.Encoding {
    return enc.Encoding.forLabel(label) orelse error.UnknownLabel;
}

/// `ct_1252` on the label, then `ct_all_label` on stdin.
fn both(label: []const u8, r: *std.Io.Reader, w: *std.Io.Writer) !void {
    var d = enc.DecoderFor(&.{.windows_1252}).init(.windows_1252, .{ .bom = .remove });
    var buf: [64]u8 = undefined;
    const res = d.decodeToUtf8(label[0..@min(label.len, 16)], &buf, true);
    try w.writeAll(buf[0..res.written]);
    try run(enc.DecoderFor(&enc.implemented).init(try forLabel(label), .{}), r, w);
}

fn named(e: enc.Encoding, r: *std.Io.Reader, w: *std.Io.Writer) !void {
    try w.writeAll(e.name());
    try copy(r, w);
}

fn copy(r: *std.Io.Reader, w: *std.Io.Writer) !void {
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try r.readSliceShort(&chunk);
        try w.writeAll(chunk[0..n]);
        if (n < chunk.len) return;
    }
}

/// Converts stdin to stdout in chunks with `coder`, a decoder or encoder.
fn run(coder: anytype, r: *std.Io.Reader, w: *std.Io.Writer) !void {
    var c = coder;
    var chunk: [4096]u8 = undefined;
    var dst: [4 * 4096 + 16]u8 = undefined;
    while (true) {
        const n = try r.readSliceShort(&chunk);
        const last = n < chunk.len;
        var i: usize = 0;
        while (true) {
            const res = if (@hasDecl(@TypeOf(c), "decodeToUtf8"))
                c.decodeToUtf8(chunk[i..n], &dst, last)
            else
                c.encodeFromUtf8(chunk[i..n], &dst, last);
            try w.writeAll(dst[0..res.written]);
            i += res.read;
            if (res.status == .input_empty) break;
        }
        if (last) return;
    }
}

/// Every implemented encoding but the CJK ones, which the package does
/// not export.
const no_cjk = if (variant == .none) .{} else blk: {
    var list: []const enc.Encoding = &.{};
    for (enc.implemented) |e| switch (e) {
        .shift_jis, .euc_jp, .iso_2022_jp, .gbk, .gb18030, .big5, .euc_kr => {},
        else => list = list ++ .{e},
    };
    break :blk list[0..list.len].*;
};
