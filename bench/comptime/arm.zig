//! The compile-time decoder prototype's arms of `just bench-compare`
//! (docs/slop/comptime.md): bench/zig/arm.zig with its timed calls on the
//! prototype's types, so that an interleaved run sets them against
//! `bench-zig`, the runtime `Decoder` and `Encoder`. Built by
//! bench/comptime/build.zig as:
//!
//! - `bench-comptime`: each encoding's row calls a function specialized to
//!   it, `DecoderFor(&.{e})` and `EncoderFor(&.{e})`,
//!   picked before the timed loop, as a program that knows its encoding
//!   at compile time calls it.
//! - `bench-generic`: `DecoderFor(&implemented)` and `EncoderFor(&implemented)` with the encoding
//!   at run time: the runtime types built from the generic.
//! - `bench-inline`: src/inline_init.zig's `Decoder`, an inline `init`
//!   with the encoding known at compile time and a function pointer for
//!   the family; it has no encoder, so its encode rows are skipped.
//!
//! Same protocol, inputs, buffers, and checksums as bench/zig/arm.zig.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;

const testingx = @import("testingx");
const encoding = @import("encoding");
const Encoding = encoding.Encoding;
const kind = @import("options").kind;
const arm = "bench-" ++ @tagName(kind);

const corpus = "bench/corpus-gen";

const Fn = *const fn (Encoding, []align(4) const u8, []align(4) u8) usize;

const Op = struct {
    arg: []const u8,
    row: []const u8,
    /// Output bytes per input byte.
    out: usize,
};

const ops = [_]Op{
    .{ .arg = "decode-utf8", .row = "DecodeUtf8", .out = 3 },
    .{ .arg = "decode-utf16", .row = "DecodeUtf16", .out = 2 },
    .{ .arg = "encode-utf8", .row = "EncodeUtf8", .out = 4 },
    .{ .arg = "encode-utf16", .row = "EncodeUtf16", .out = 4 },
};

/// Each operation's function for each encoding, or null where it has none.
const fns: [ops.len][encoding_count]?Fn = blk: {
    @setEvalBranchQuota(10_000_000);
    var t: [ops.len][encoding_count]?Fn = @splat(@splat(null));
    for (std.enums.values(Encoding)) |e| {
        if (!e.isImplemented()) continue;
        // `bench-generic` has one function per operation for every
        // encoding, as bench-zig does: with one call site, LLVM inlines
        // the decoder into it, and with one per encoding it does not.
        const C = Calls(if (kind == .generic) .utf_8 else e);
        t[0][@intFromEnum(e)] = C.decodeUtf8;
        t[1][@intFromEnum(e)] = C.decodeUtf16;
        if (kind == .inline_init or e.outputEncoding() != e) continue;
        t[2][@intFromEnum(e)] = C.encodeUtf8;
        t[3][@intFromEnum(e)] = C.encodeUtf16;
    }
    break :blk t;
};

const encoding_count = std.enums.values(Encoding).len;

/// The timed calls for `ce`: specialized to it in `bench-comptime` and
/// `bench-inline`, on the run-time encoding in `bench-generic`.
fn Calls(comptime ce: Encoding) type {
    const D = switch (kind) {
        .comptime_set => encoding.DecoderFor(&.{ce}),
        .generic => encoding.DecoderFor(&encoding.implemented),
        .inline_init => encoding.Decoder,
    };
    const E = switch (kind) {
        .comptime_set => encoding.EncoderFor(&.{ce}),
        .generic => encoding.EncoderFor(&encoding.implemented),
        .inline_init => void,
    };
    return struct {
        fn which(e: Encoding) Encoding {
            return if (kind == .generic) e else ce;
        }

        fn decodeUtf8(e: Encoding, src: []align(4) const u8, dst: []align(4) u8) usize {
            var d: D = .init(which(e), .{ .bom = .keep });
            return d.decodeToUtf8(src, dst, true).written;
        }

        fn decodeUtf16(e: Encoding, src: []align(4) const u8, dst: []align(4) u8) usize {
            var d: D = .init(which(e), .{ .bom = .keep });
            return 2 * d.decodeToUtf16(src, mem.bytesAsSlice(u16, dst), true).written;
        }

        fn encodeUtf8(e: Encoding, src: []align(4) const u8, dst: []align(4) u8) usize {
            var enc: E = .init(which(e), .{});
            return enc.encodeFromUtf8(src, dst, true).written;
        }

        fn encodeUtf16(e: Encoding, src: []align(4) const u8, dst: []align(4) u8) usize {
            var enc: E = .init(which(e), .{});
            return enc.encodeFromUtf16(mem.bytesAsSlice(u16, src), dst, true).written;
        }
    };
}

/// This arm's encoding for a name in bench/encodings.tsv, or why not. An
/// encoder for an encoding whose output encoding is another (UTF-16 and
/// replacement encode as UTF-8) is skipped, as in every arm.
fn coder(name: []const u8, op: usize) error{ NotImplemented, NoEncoder, Unknown }!Encoding {
    for (std.enums.values(Encoding)) |e| {
        if (!mem.eql(u8, e.name(), name)) continue;
        if (!e.isImplemented()) return error.NotImplemented;
        if (fns[op][@intFromEnum(e)] == null) return error.NoEncoder;
        return e;
    }
    return error.Unknown;
}

fn why(err: anyerror) []const u8 {
    return switch (err) {
        error.NotImplemented => "not implemented yet",
        error.NoEncoder => "the standard has no encoder for it",
        else => "no such encoding",
    };
}

var in_offset: usize = 0;
var out_offset: usize = 2048;

fn offsetEnv(environ: *const std.process.Environ.Map, name: []const u8, default: usize) !usize {
    const v = environ.get(name) orelse return default;
    const off = try std.fmt.parseInt(usize, v, 10);
    if (off >= 4096 or off % 4 != 0) {
        std.debug.print("" ++ arm ++ ": {s} must be a multiple of 4 under 4096\n", .{name});
        return error.BadOffset;
    }
    return off;
}

/// `len` bytes `off` bytes past a page boundary, in a mapping of their own:
/// zeroed, and resident only once written.
const Placed = struct {
    mapping: []align(page) u8,
    bytes: []align(4) u8,

    const page = 4096;

    fn init(len: usize, off: usize) !Placed {
        const size = (off + len + page) / page * page;
        const ptr = std.heap.page_allocator.rawAlloc(size, .fromByteUnits(page), @returnAddress()) orelse
            return error.OutOfMemory;
        const mapping: []align(page) u8 = @alignCast(ptr[0..size]);
        return .{ .mapping = mapping, .bytes = @alignCast(mapping[off..][0..len]) };
    }

    fn deinit(p: Placed) void {
        std.heap.page_allocator.rawFree(p.mapping, .fromByteUnits(page), @returnAddress());
    }

    /// Writes every page of the mapping but the data's bytes: a masked load
    /// whose masked-off lanes reach a page nothing has touched takes a
    /// microcode assist on every call.
    fn writeRest(p: Placed) void {
        const off = @intFromPtr(p.bytes.ptr) - @intFromPtr(p.mapping.ptr);
        @memset(p.mapping[0..off], 1);
        @memset(p.mapping[off + p.bytes.len ..], 1);
    }

    fn place(bytes: []const u8) !Placed {
        const p: Placed = try .init(bytes.len, in_offset);
        @memcpy(p.bytes, bytes);
        p.writeRest();
        return p;
    }
};

/// One input: its bytes in the encoding, its text in UTF-8, and the same
/// text in UTF-16, each placed alike.
const Input = struct {
    name: []const u8,
    forms: [3]Placed,

    /// The input an operation reads.
    fn of(in: Input, op: usize) Placed {
        return in.forms[
            switch (op) {
                0, 1 => 0,
                2 => 1,
                else => 2,
            }
        ];
    }

    fn deinit(in: Input) void {
        for (in.forms) |p| p.deinit();
    }
};

fn encodings(io: Io, gpa: mem.Allocator) ![]const []const u8 {
    const text = Io.Dir.cwd().readFileAlloc(io, "bench/encodings.tsv", gpa, .unlimited) catch |err| {
        std.debug.print("" ++ arm ++ ": open bench/encodings.tsv: {t} (run from the repository root)\n", .{err});
        return err;
    };
    var list: std.ArrayList([]const u8) = .empty;
    var lines = mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        try list.append(gpa, line[0 .. mem.findScalar(u8, line, '\t') orelse line.len]);
    }
    return list.items;
}

/// Every input of an encoding, smallest first, then by name. The files are
/// read with `scratch` and freed once placed, so that only the placed
/// inputs count in RSS.
fn load(name: []const u8, io: Io, gpa: mem.Allocator) ![]Input {
    const scratch = std.heap.smp_allocator;
    // ziglint-ignore: Z011 -- 0.16 has no Allocator.print
    const path = try std.fmt.allocPrint(gpa, corpus ++ "/{s}", .{name});
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        std.debug.print("" ++ arm ++ ": open {s}: {t} (run `just bench-corpus`)\n", .{ path, err });
        return err;
    };
    defer dir.close(io);
    var list: std.ArrayList(Input) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!mem.endsWith(u8, entry.name, ".bin")) continue;
        const stem = try gpa.dupe(u8, entry.name[0 .. entry.name.len - 4]);
        const bin = try dir.readFileAlloc(io, entry.name, scratch, .unlimited);
        defer scratch.free(bin);
        // ziglint-ignore: Z011 -- 0.16 has no Allocator.print
        const utf8 = try dir.readFileAlloc(io, try std.fmt.allocPrint(gpa, "{s}.utf8", .{stem}), scratch, .unlimited);
        defer scratch.free(utf8);
        const units = try scratch.alloc(u16, utf8.len);
        defer scratch.free(units);
        const n = try std.unicode.utf8ToUtf16Le(units, utf8);
        for (units[0..n]) |*u| u.* = mem.littleToNative(u16, u.*);
        try list.append(gpa, .{ .name = stem, .forms = .{
            try .place(bin),
            try .place(utf8),
            try .place(mem.sliceAsBytes(units[0..n])),
        } });
    }
    mem.sort(Input, list.items, {}, struct {
        fn lessThan(_: void, a: Input, b: Input) bool {
            if (a.forms[0].bytes.len != b.forms[0].bytes.len) return a.forms[0].bytes.len < b.forms[0].bytes.len;
            return mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return list.items;
}

fn output(op: usize, in: Input) !Placed {
    return .init(in.of(op).bytes.len * ops[op].out + 64, out_offset);
}

fn fnv1a(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| h = (h ^ b) *% 0x100000001b3;
    return h;
}

/// The row being timed. `testingx.benchmark` runs its function before it
/// returns, so setting these first stands in for a closure.
var current_fn: Fn = undefined;
var current_enc: Encoding = undefined;
var current_in: []align(4) const u8 = undefined;
var current_out: []align(4) u8 = undefined;

fn row(b: *testingx.B) !void {
    const f = current_fn;
    const e = current_enc;
    const in = current_in;
    const out = current_out;
    while (try b.loop()) {
        // The input escapes every iteration, so no call is hoisted, and
        // the call stays out of line, as a call into a library is.
        mem.doNotOptimizeAway(in.ptr);
        mem.doNotOptimizeAway(@call(.never_inline, f, .{ e, in, out }));
    }
    b.setBytes(@intCast(in.len));
}

/// `serve`: one row per request line, `OP ENCODING INPUT N`, until stdin
/// ends. The requested encoding's inputs stay loaded until another is.
fn serve(io: Io, gpa: mem.Allocator, defaults: testingx.Options, w: *Io.Writer) !void {
    var buf: [4096]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(io, &buf);
    var loaded: []const u8 = "";
    var ins: []Input = &.{};
    while (try stdin.interface.takeDelimiter('\n')) |line| {
        var fields = mem.tokenizeScalar(u8, line, ' ');
        const arg = fields.next() orelse return error.BadRequest;
        const name = fields.next() orelse return error.BadRequest;
        const input = fields.next() orelse return error.BadRequest;
        const n = try std.fmt.parseInt(u64, fields.next() orelse return error.BadRequest, 10);
        const op = for (ops, 0..) |o, i| {
            if (mem.eql(u8, o.arg, arg)) break i;
        } else return error.UnknownOperation;
        const e = coder(name, op) catch |err| {
            std.debug.print("" ++ arm ++ ": {s} {s}: {s}\n", .{ arg, name, why(err) });
            return err;
        };
        if (!mem.eql(u8, loaded, name)) {
            for (ins) |in| in.deinit();
            ins = try load(name, io, gpa);
            loaded = try gpa.dupe(u8, name);
        }
        const in = for (ins) |in| {
            if (mem.eql(u8, in.name, input)) break in;
        } else return error.UnknownInput;
        const out = try output(op, in);
        defer out.deinit();
        @memset(out.mapping, 1);
        current_fn = fns[op][@intFromEnum(e)].?;
        current_enc = e;
        current_in = in.of(op).bytes;
        current_out = out.bytes;
        var options = defaults;
        if (n > 0) {
            _ = current_fn(e, current_in, current_out);
            options.benchtime = .{ .count = n };
        }
        var r = try testingx.benchmark(std.heap.smp_allocator, io, row, options);
        defer r.deinit(std.heap.smp_allocator);
        const ns: f64 = @floatFromInt(r.t_ns);
        try w.print("Benchmark{s}/{s}/{s}\t{d}\t{d:.2} ns/op\t{d:.2} MB/s\n", .{
            ops[op].row, name, input, r.n, ns / @as(f64, @floatFromInt(r.n)), r.mbPerSec(),
        });
        try w.flush();
    }
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 2 or !(mem.eql(u8, args[1], "check") or mem.eql(u8, args[1], "serve"))) {
        std.debug.print("usage: bench-zig check [OP...] | serve\n", .{});
        return 2;
    }
    in_offset = try offsetEnv(init.environ_map, "BENCH_IN_OFFSET", in_offset);
    out_offset = try offsetEnv(init.environ_map, "BENCH_OUT_OFFSET", out_offset);
    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buf);
    const w = &stdout.interface;

    if (mem.eql(u8, args[1], "serve")) {
        var defaults: testingx.Options = .{};
        const ms = if (init.environ_map.get("BENCHTIME_MS")) |v| try std.fmt.parseInt(u64, v, 10) else 100;
        defaults.benchtime = .{ .duration_ns = ms * std.time.ns_per_ms };
        try serve(io, gpa, defaults, w);
        return 0;
    }
    var wanted: [ops.len]bool = @splat(args.len == 2);
    for (args[2..]) |arg| {
        for (ops, 0..) |o, i| {
            if (mem.eql(u8, o.arg, arg)) wanted[i] = true;
        } else {}
        if (!for (ops) |o| {
            if (mem.eql(u8, o.arg, arg)) break true;
        } else false) {
            std.debug.print("" ++ arm ++ ": unknown operation {s}\n", .{arg});
            return 2;
        }
    }
    for (try encodings(io, gpa)) |name| {
        var ins: ?[]Input = null;
        defer if (ins) |list| for (list) |in| in.deinit();
        for (ops, 0..) |o, op| {
            if (!wanted[op]) continue;
            const e = coder(name, op) catch |err| {
                try w.print("# SKIP Benchmark{s}/{s}: {s}\n", .{ o.row, name, why(err) });
                continue;
            };
            if (ins == null) ins = try load(name, io, gpa);
            for (ins.?) |in| {
                const out = try output(op, in);
                defer out.deinit();
                const n = fns[op][@intFromEnum(e)].?(e, in.of(op).bytes, out.bytes);
                try w.print(
                    "{s}/{s}/{s}\tlen={d} fnv={x:0>16}\n",
                    .{ o.row, name, in.name, n, fnv1a(out.bytes[0..n]) },
                );
            }
        }
    }
    try w.flush();
    return 0;
}
