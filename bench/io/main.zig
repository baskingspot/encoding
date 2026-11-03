//! The conveniences' and stream adapters' cost (docs/slop/results/io-*.md),
//! each row timed back to back against the direct call it wraps, in an
//! order that alternates from row to row and round to round, so both arms'
//! samples of a row see the same machine. Run pinned to one core from the
//! repository root, after `just bench-corpus`:
//!
//!     bench-io percall ROUNDS OUTDIR    convenience against Decoder/Encoder
//!     bench-io adapters ROUNDS OUTDIR   DecodingReader/EncodingWriter against a loop
//!
//! Each writes one benchstat file per arm into OUTDIR (direct.txt and
//! convert.txt; direct.txt, adapter.txt, and adapter64.txt), and checks
//! that every arm of a row writes the same number of bytes before timing.

const std = @import("std");
const mem = std.mem;
const linux = std.os.linux;
const encoding = @import("encoding");
const Encoding = encoding.Encoding;

const Fn = *const fn (Encoding, []const u8, []u8) usize;

const corpus = "bench/corpus-gen";
const sample_ns = 20 * std.time.ns_per_ms;

/// The per-call rows: each operation on these encodings' web pages.
const percall_encodings = [_]Encoding{ .windows_1252, .shift_jis, .gb18030, .euc_kr, .utf_8, .utf_16le };
const percall_sizes = [_][]const u8{ "16", "64", "256", "4096", "65536" };

const Op = enum { decode_utf8, decode_utf16, encode_utf8, encode_utf16 };
const op_names = [_][]const u8{ "DecodeUtf8", "DecodeUtf16", "EncodeUtf8", "EncodeUtf16" };

/// The decoder and encoder calls for `ce`, on a type over `ce` alone
/// (`ct`), or on `Decoder` and `Encoder` with the encoding at run time.
fn Calls(comptime ce: ?Encoding) type {
    const D = if (ce) |e| encoding.DecoderFor(&.{e}) else encoding.Decoder;
    const E = if (ce) |e| encoding.EncoderFor(&.{e}) else encoding.Encoder;
    return struct {
        inline fn which(e: Encoding) Encoding {
            return ce orelse e;
        }

        fn directDecodeUtf8(e: Encoding, src: []const u8, dst: []u8) usize {
            var d: D = .init(which(e), .{ .bom = .keep });
            const r = d.decodeToUtf8(src, dst, true);
            return if (r.status == .input_empty) r.written else 0;
        }
        fn convertDecodeUtf8(e: Encoding, src: []const u8, dst: []u8) usize {
            const r = encoding.decodeToUtf8(D, which(e), src, dst, .{ .bom = .keep }) catch return 0;
            return r.text.len;
        }
        fn directDecodeUtf16(e: Encoding, src: []const u8, dst: []u8) usize {
            var d: D = .init(which(e), .{ .bom = .keep });
            const r = d.decodeToUtf16(src, units(dst), true);
            return if (r.status == .input_empty) 2 * r.written else 0;
        }
        fn convertDecodeUtf16(e: Encoding, src: []const u8, dst: []u8) usize {
            const r = encoding.decodeToUtf16(D, which(e), src, units(dst), .{ .bom = .keep }) catch return 0;
            return 2 * r.text.len;
        }
        fn directEncodeUtf8(e: Encoding, src: []const u8, dst: []u8) usize {
            var c: E = .init(which(e), .{});
            const r = c.encodeFromUtf8(src, dst, true);
            return if (r.status == .input_empty) r.written else 0;
        }
        fn convertEncodeUtf8(e: Encoding, src: []const u8, dst: []u8) usize {
            const r = encoding.encodeFromUtf8(E, which(e), src, dst, .{}) catch return 0;
            return r.bytes.len;
        }
        fn directEncodeUtf16(e: Encoding, src: []const u8, dst: []u8) usize {
            var c: E = .init(which(e), .{});
            const r = c.encodeFromUtf16(constUnits(src), dst, true);
            return if (r.status == .input_empty) r.written else 0;
        }
        fn convertEncodeUtf16(e: Encoding, src: []const u8, dst: []u8) usize {
            const r = encoding.encodeFromUtf16(E, which(e), constUnits(src), dst, .{}) catch return 0;
            return r.bytes.len;
        }

        const direct = [_]Fn{ directDecodeUtf8, directDecodeUtf16, directEncodeUtf8, directEncodeUtf16 };
        const convert = [_]Fn{ convertDecodeUtf8, convertDecodeUtf16, convertEncodeUtf8, convertEncodeUtf16 };
    };
}

fn units(b: []u8) []u16 {
    return @alignCast(mem.bytesAsSlice(u16, b));
}

fn constUnits(b: []const u8) []const u16 {
    return @alignCast(mem.bytesAsSlice(u16, b));
}

/// One encoding's calls: on its own type, and on the run-time one.
fn callsFor(e: Encoding, ct: bool, arm: enum { direct, convert }, op: Op) Fn {
    inline for (percall_encodings) |ce| {
        if (e == ce) {
            const one = switch (arm) {
                .direct => Calls(ce).direct,
                .convert => Calls(ce).convert,
            };
            const runtime = switch (arm) {
                .direct => Calls(null).direct,
                .convert => Calls(null).convert,
            };
            return if (ct) one[@intFromEnum(op)] else runtime[@intFromEnum(op)];
        }
    }
    unreachable;
}

// The adapters' rows: a stream through `DecodingReader` or
// `EncodingWriter` against a loop of direct calls, each with a 4 KiB
// output buffer the bytes are discarded from.

fn loopDecode(e: Encoding, src: []const u8, out: []u8) usize {
    var d: encoding.Decoder = .init(e, .{ .bom = .keep });
    var i: usize = 0;
    var total: usize = 0;
    while (true) {
        const r = d.decodeToUtf8(src[i..], out[0..4096], true);
        i += r.read;
        total += r.written;
        mem.doNotOptimizeAway(out.ptr);
        if (r.status == .input_empty) return total;
    }
}

fn readerDecode(e: Encoding, src: []const u8, out: []u8) usize {
    var input: std.Io.Reader = .fixed(src);
    var dr: encoding.DecodingReader(encoding.Decoder) = .init(&input, .init(e, .{ .bom = .keep }), &.{});
    var sink: std.Io.Writer.Discarding = .init(out[0..4096]);
    return dr.interface.streamRemaining(&sink.writer) catch 0;
}

fn loopEncode(e: Encoding, src: []const u8, out: []u8) usize {
    var c: encoding.Encoder = .init(e, .{});
    var i: usize = 0;
    var total: usize = 0;
    while (true) {
        const r = c.encodeFromUtf8(src[i..], out[0..4096], true);
        i += r.read;
        total += r.written;
        mem.doNotOptimizeAway(out.ptr);
        if (r.status == .input_empty) return total;
    }
}

fn writerEncode(e: Encoding, src: []const u8, out: []u8) usize {
    return writerEncodeIn(e, src, out, src.len);
}

fn writerEncode64(e: Encoding, src: []const u8, out: []u8) usize {
    return writerEncodeIn(e, src, out, 64);
}

/// Writes `src` in pieces of `piece` bytes to an `EncodingWriter` with a
/// 4 KiB buffer.
inline fn writerEncodeIn(e: Encoding, src: []const u8, out: []u8, piece: usize) usize {
    var sink: std.Io.Writer.Discarding = .init(out[0..4096]);
    var buf: [4096]u8 = undefined;
    var ew: encoding.EncodingWriter(encoding.Encoder) = .init(&sink.writer, .init(e, .{}), &buf);
    var i: usize = 0;
    while (i < src.len) : (i += piece) {
        ew.interface.writeAll(src[i..@min(src.len, i + piece)]) catch return 0;
    }
    ew.end() catch return 0;
    return @intCast(sink.fullCount());
}

const adapter_encodings = [_]Encoding{ .windows_1252, .shift_jis, .gb18030, .utf_8 };
const adapter_sizes = [_][]const u8{ "65536", "1048576" };

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Nanoseconds for `n` calls of `f`, each out of line with its input
/// escaping, as a call into a library is.
fn time(f: Fn, e: Encoding, in: []const u8, out: []u8, n: u64) u64 {
    const start = nowNs();
    for (0..n) |_| {
        mem.doNotOptimizeAway(in.ptr);
        mem.doNotOptimizeAway(@call(.never_inline, f, .{ e, in, out }));
    }
    return nowNs() - start;
}

const Row = struct {
    name: []const u8,
    enc: Encoding,
    in: []const u8,
    /// One function per arm; null where the row lacks that arm.
    arms: [3]?Fn,
    iters: u64 = 0,
};

fn load(gpa: mem.Allocator, io: std.Io, e: Encoding, file: []const u8, op: Op) ![]const u8 {
    const path = try std.fmt.allocPrint(gpa, corpus ++ "/{s}/{s}", .{ e.name(), file });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    if (op != .encode_utf16) return bytes;
    const u = try gpa.alignedAlloc(u16, .of(u16), bytes.len);
    const n = try std.unicode.utf8ToUtf16Le(u, bytes);
    for (u[0..n]) |*x| x.* = mem.littleToNative(u16, x.*);
    return mem.sliceAsBytes(u[0..n]);
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 4) {
        std.debug.print("usage: bench-io percall|adapters ROUNDS OUTDIR\n", .{});
        return 2;
    }
    const rounds = try std.fmt.parseInt(u32, args[2], 10);
    const out_dir = args[3];
    var rows: std.ArrayList(Row) = .empty;
    var arm_names: []const []const u8 = undefined;
    if (mem.eql(u8, args[1], "percall")) {
        arm_names = &.{ "direct", "convert" };
        for (std.enums.values(Op)) |op| for (percall_encodings) |e| {
            if (@intFromEnum(op) >= 2 and e.outputEncoding() != e) continue;
            for (percall_sizes) |size| for ([_]bool{ false, true }) |ct| {
                const ext = if (@intFromEnum(op) < 2) "bin" else "utf8";
                const in = try load(gpa, io, e, try std.fmt.allocPrint(gpa, "web-{s}.{s}", .{ size, ext }), op);
                try rows.append(gpa, .{
                    .name = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}/web-{s}", .{
                        op_names[@intFromEnum(op)], if (ct) "one" else "runtime", e.name(), size,
                    }),
                    .enc = e,
                    .in = in,
                    .arms = .{ callsFor(e, ct, .direct, op), callsFor(e, ct, .convert, op), null },
                });
            };
        };
    } else if (mem.eql(u8, args[1], "adapters")) {
        arm_names = &.{ "direct", "adapter", "adapter64" };
        for ([_]Op{ .decode_utf8, .encode_utf8 }) |op| for (adapter_encodings) |e| for (adapter_sizes) |size| {
            const decode = op == .decode_utf8;
            const file = try std.fmt.allocPrint(gpa, "web-{s}.{s}", .{ size, if (decode) "bin" else "utf8" });
            const in = try load(gpa, io, e, file, op);
            try rows.append(gpa, .{
                .name = try std.fmt.allocPrint(
                    gpa,
                    "{s}/{s}/web-{s}",
                    .{ if (decode) "Reader" else "Writer", e.name(), size },
                ),
                .enc = e,
                .in = in,
                .arms = if (decode)
                    .{ loopDecode, readerDecode, null }
                else
                    .{ loopEncode, writerEncode, writerEncode64 },
            });
        };
    } else return 2;

    const out = try gpa.alignedAlloc(u8, .fromByteUnits(64), 4 * (1 << 20) + 64);
    @memset(out, 1);
    // Every arm of a row writes the same, and enough calls fill a sample.
    for (rows.items) |*row| {
        var want: ?usize = null;
        for (row.arms, 0..) |maybe, a| {
            const f = maybe orelse continue;
            const n = f(row.enc, row.in, out);
            if (n == 0 and row.in.len != 0) {
                std.debug.print("{s}: {s} wrote nothing\n", .{ row.name, arm_names[a] });
                return 1;
            }
            if (want != null and want.? != n) {
                std.debug.print("{s}: {s} wrote {d}, not {d}\n", .{ row.name, arm_names[a], n, want.? });
                return 1;
            }
            want = n;
        }
        var n: u64 = 1;
        while (time(row.arms[0].?, row.enc, row.in, out, n) < sample_ns / 4) n *= 2;
        row.iters = n * 4;
    }

    var files: [3]std.ArrayList(u8) = @splat(.empty);
    for (1..rounds + 1) |round| {
        for (rows.items, 0..) |row, j| {
            var order: [3]usize = .{ 0, 1, 2 };
            if ((round + j) % 2 == 1) order = .{ 2, 1, 0 };
            for (order) |a| {
                const f = row.arms[a] orelse continue;
                const ns = time(f, row.enc, row.in, out, row.iters);
                const per: f64 = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(row.iters));
                const gbs: f64 = @as(f64, @floatFromInt(row.in.len)) / per;
                try files[a].print(
                    gpa,
                    "Benchmark{s}\t{d}\t{d:.3} ns/op\t{d:.4} GB/s\n",
                    .{ row.name, row.iters, per, gbs },
                );
            }
        }
        std.debug.print("round {d} of {d}\n", .{ round, rounds });
    }
    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    for (arm_names, 0..) |name, a| {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}.txt", .{ out_dir, name });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = files[a].items });
    }
    return 0;
}
