//! The package as a WebAssembly module, for the web-platform-tests harness
//! (test/wpt/run.mjs), which builds TextDecoder, TextEncoder, and a
//! browser's URL and form encoding on these exports. Input goes in
//! `in_buf`, output comes out of `out_buf`; decoders and encoders live in
//! fixed pools, and each call leaves what it read and wrote in `last_*`.

const std = @import("std");
const encoding = @import("encoding");
const Encoding = encoding.Encoding;
const Decoder = encoding.Decoder;
const Encoder = encoding.Encoder;

var in_buf: [4 << 20]u8 align(2) = undefined;
var out_buf: [16 << 20]u8 align(2) = undefined;
var decoders: [256]?Decoder = @splat(null);
var encoders: [256]?Encoder = @splat(null);
var last_read: usize = 0;
var last_written: usize = 0;
var last_cp: u32 = 0;

export fn inPtr() [*]u8 {
    return &in_buf;
}

export fn outPtr() [*]u8 {
    return &out_buf;
}

export fn inCap() usize {
    return in_buf.len;
}

export fn outCap() usize {
    return out_buf.len;
}

export fn lastRead() usize {
    return last_read;
}

export fn lastWritten() usize {
    return last_written;
}

export fn lastCp() u32 {
    return last_cp;
}

/// The encoding for the label in `in_buf[0..len]`, -1 for none.
export fn forLabel(len: usize) i32 {
    const e = Encoding.forLabel(in_buf[0..len]) orelse return -1;
    return @intFromEnum(e);
}

/// Writes the encoding's name to `out_buf` and returns its length.
export fn name(e: u32) usize {
    const n = @as(Encoding, @enumFromInt(e)).name();
    @memcpy(out_buf[0..n.len], n);
    return n.len;
}

export fn isImplemented(e: u32) bool {
    return @as(Encoding, @enumFromInt(e)).isImplemented();
}

export fn outputEncoding(e: u32) u32 {
    return @intFromEnum(@as(Encoding, @enumFromInt(e)).outputEncoding());
}

/// A decoder from the pool, -1 when it is full. `bom` is 0 sniff, 1
/// remove, 2 keep.
export fn decoderNew(e: u32, fatal: bool, bom: u32) i32 {
    for (&decoders, 0..) |*slot, i| {
        if (slot.* != null) continue;
        slot.* = .init(@enumFromInt(e), .{
            .mode = if (fatal) .fatal else .replacement,
            .bom = switch (bom) {
                0 => .sniff,
                1 => .remove,
                else => .keep,
            },
        });
        return @intCast(i);
    }
    return -1;
}

export fn decoderFree(h: u32) void {
    decoders[h] = null;
}

/// Decodes `in_buf[0..len]` to UTF-16 in `out_buf`, which is always big
/// enough: 0 when the input is read, 2 at an error in fatal mode.
export fn decode(h: u32, len: usize, last: bool) u32 {
    const d = &(decoders[h].?);
    const out: []u16 = @alignCast(std.mem.bytesAsSlice(u16, &out_buf));
    if (d.maxUtf16Len(len).? > out.len) @panic("decode: input too long for the output buffer");
    const r = d.decodeToUtf16(in_buf[0..len], out, last);
    last_read = r.read;
    last_written = r.written;
    return @intFromEnum(r.status);
}

/// An encoder for `e`'s output encoding from the pool, -1 when it is full.
export fn encoderNew(e: u32, fatal: bool) i32 {
    for (&encoders, 0..) |*slot, i| {
        if (slot.* != null) continue;
        slot.* = .init(@enumFromInt(e), .{ .mode = if (fatal) .fatal else .html });
        return @intCast(i);
    }
    return -1;
}

export fn encoderFree(h: u32) void {
    encoders[h] = null;
}

/// Encodes `len` UTF-16 units from `in_buf` into the first `room` bytes of
/// `out_buf`: 0 when the input is read, 1 when the next character does not
/// fit, 2 at an unmappable character in fatal mode (`lastCp`).
export fn encode(h: u32, len: usize, room: usize, last: bool) u32 {
    const e = &(encoders[h].?);
    const units: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, in_buf[0 .. len * 2]));
    const r = e.encodeFromUtf16(units, out_buf[0..@min(room, out_buf.len)], last);
    last_read = r.read;
    last_written = r.written;
    last_cp = r.unmappable;
    return @intFromEnum(r.status);
}
