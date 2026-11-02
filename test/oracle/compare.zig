//! The encoding_rs differential (`just oracle`): every implemented
//! encoding's decoder and encoder, and the label table, against
//! encoding_rs, through the oracle in test/oracle/rs.
//!
//!     oracle-compare ORACLE [--random N] [--seed N] [--encoding NAME]
//!
//! Decoders get N random inputs each (test/props.zig's), every byte at
//! positions on both sides of the 16- and 64-byte SIMD blocks, every
//! two-byte sequence, and every sequence of three and four bytes from an
//! alphabet of the bytes that start, continue, and end multi-byte
//! sequences. Each runs to UTF-8 and to UTF-16, in replacement and fatal
//! mode, with the byte order mark sniffed, removed, and kept, in one call
//! and a byte at a time into four-byte (two-unit) buffers: the output, and
//! in fatal mode the input and output offsets of each error, must equal
//! encoding_rs's. Encoders get N random texts with ill-formed parts, and
//! every scalar value, from UTF-8 and UTF-16, in html and fatal mode.
//! Labels: every label in the standard's table and variants of each.
//!
//! Differences where encoding_rs departs from the standard are listed in
//! `known` with the reason; any other difference is a mismatch, and the
//! program exits 1 after printing the first few of each kind.

const std = @import("std");
const encoding = @import("encoding");
const props = @import("props");
const Encoding = encoding.Encoding;
const Io = std.Io;

var io: Io = undefined;
const gpa = std.heap.smp_allocator;
/// What one batch's comparisons allocate, freed after the batch.
var scratch_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
const scratch = scratch_state.allocator();
var oracle_path: []const u8 = undefined;

const Op = enum(u8) { decode8 = 1, decode16 = 2, encode8 = 3, encode16 = 4, label = 5 };

const Request = struct {
    op: Op,
    flags: u8,
    enc: Encoding,
    input: []const u8,
};

const Response = struct {
    output: []const u8,
    events: []const Event,
};

const Event = struct { in: u64, out: u64, cp: u32 };

/// Runs a batch through the oracle; one response per request, in order.
fn run(requests: []const Request) ![]Response {
    var batch: std.ArrayList(u8) = .empty;
    defer batch.deinit(gpa);
    for (requests) |r| {
        const name = r.enc.name();
        try batch.appendSlice(gpa, &.{ @intFromEnum(r.op), r.flags, @intCast(name.len) });
        try batch.appendSlice(gpa, name);
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(r.input.len), .little);
        try batch.appendSlice(gpa, &len);
        try batch.appendSlice(gpa, r.input);
    }
    var child = try std.process.spawn(io, .{ .argv = &.{oracle_path}, .stdin = .pipe, .stdout = .pipe });
    defer if (child.id != null) child.kill(io);
    try child.stdin.?.writeStreamingAll(io, batch.items);
    child.stdin.?.close(io);
    child.stdin = null;
    var buf: [64 * 1024]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buf);
    const bytes = try reader.interface.allocRemaining(scratch, .unlimited);
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.OracleFailed;
    const out = try scratch.alloc(Response, requests.len);
    var at: usize = 0;
    for (out) |*resp| {
        const len = std.mem.readInt(u32, bytes[at..][0..4], .little);
        resp.output = bytes[at + 4 ..][0..len];
        at += 4 + len;
        const n = std.mem.readInt(u32, bytes[at..][0..4], .little);
        at += 4;
        const events = try scratch.alloc(Event, n);
        for (events) |*e| {
            e.* = .{
                .in = std.mem.readInt(u64, bytes[at..][0..8], .little),
                .out = std.mem.readInt(u64, bytes[at + 8 ..][0..8], .little),
                .cp = std.mem.readInt(u32, bytes[at + 16 ..][0..4], .little),
            };
            at += 20;
        }
        resp.events = events;
    }
    if (at != bytes.len) return error.BadResponse;
    return out;
}

/// What this package does with a request, in the oracle's format.
fn ours(r: Request, cuts: []const usize, room: usize) !Response {
    const fatal = r.flags & 1 != 0;
    switch (r.op) {
        .decode8, .decode16 => {
            const bom: encoding.Decoder.Bom = switch (r.flags >> 1) {
                0 => .sniff,
                1 => .remove,
                else => .keep,
            };
            const options: encoding.Decoder.Options = .{ .mode = if (fatal) .fatal else .replacement, .bom = bom };
            const Marks = []const props.Mark;
            var output: []const u8 = undefined;
            var marks: Marks = undefined;
            if (r.op == .decode8) {
                const d = try props.decode(u8, scratch, r.enc, options, r.input, cuts, room);
                output = d.units;
                marks = d.errors;
            } else {
                const d = try props.decode(u16, scratch, r.enc, options, r.input, cuts, room / 2);
                const le = try scratch.alloc(u8, d.units.len * 2);
                for (d.units, 0..) |u, i| std.mem.writeInt(u16, le[2 * i ..][0..2], u, .little);
                output = le;
                marks = d.errors;
            }
            const events = try scratch.alloc(Event, marks.len);
            for (marks, events) |m, *e| e.* = .{ .in = m.in, .out = m.out, .cp = 0 };
            return .{ .output = output, .events = events };
        },
        .encode8, .encode16 => {
            const mode: encoding.Encoder.Mode = if (fatal) .fatal else .html;
            const e = if (r.op == .encode8) try props.encode(u8, scratch, r.enc, mode, r.input, cuts, room) else blk: {
                const units = try scratch.alloc(u16, r.input.len / 2);
                for (units, 0..) |*u, i| u.* = std.mem.readInt(u16, r.input[2 * i ..][0..2], .little);
                break :blk try props.encode(u16, scratch, r.enc, mode, units, cuts, room);
            };
            const events = try scratch.alloc(Event, e.unmappable.len);
            for (e.unmappable, events) |cp, *ev| ev.* = .{ .in = 0, .out = 0, .cp = cp };
            return .{ .output = e.bytes, .events = events };
        },
        .label => {
            const name = if (Encoding.forLabel(r.input)) |e| e.name() else "";
            return .{ .output = name, .events = &.{} };
        },
    }
}

/// Where encoding_rs departs from the standard, and the standard wins:
/// none found yet. Each entry names the encoding, the op, and why, and
/// `isKnown` matches the requests it covers.
const known: []const struct { enc: ?Encoding, op: Op, why: []const u8 } = &.{};

fn isKnown(r: Request) bool {
    for (known) |k| {
        if ((k.enc == null or k.enc.? == r.enc) and k.op == r.op) return true;
    }
    return false;
}

const Tally = struct {
    compared: u64 = 0,
    mismatches: u64 = 0,
    printed: std.AutoHashMapUnmanaged(u64, u32) = .empty,
};

fn sameEvents(a: []const Event, b: []const Event, op: Op) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| switch (op) {
        .encode8, .encode16 => if (x.cp != y.cp) return false,
        else => if (x.in != y.in or x.out != y.out) return false,
    };
    return true;
}

fn compareBatch(requests: []const Request, tally: *Tally) !void {
    defer _ = scratch_state.reset(.retain_capacity);
    const theirs = try run(requests);
    for (requests, theirs) |r, t| {
        // One call, then a unit at a time into the smallest buffers.
        const min_room: usize = if (r.op == .encode8 or r.op == .encode16) encoding.max_ncr_len else 4;
        const variants = [_]struct { split: bool, room: usize }{
            .{ .split = false, .room = 0 },
            .{ .split = true, .room = min_room },
        };
        for (variants) |v| {
            if (r.op == .label and v.split) continue;
            var cuts: []usize = &.{};
            if (v.split) {
                const units = if (r.op == .encode16) r.input.len / 2 else r.input.len;
                cuts = try scratch.alloc(usize, units);
                for (cuts, 0..) |*c, i| c.* = i;
            }
            const mine = try ours(r, cuts, v.room);
            tally.compared += 1;
            const marks_ok = if (v.split and (r.op == .decode8 or r.op == .decode16))
                sameMarksLoose(mine.events, t.events)
            else
                sameEvents(mine.events, t.events, r.op);
            if (std.mem.eql(u8, mine.output, t.output) and marks_ok) continue;
            if (isKnown(r)) continue;
            tally.mismatches += 1;
            const key = @as(u64, @intFromEnum(r.enc)) << 16 | @as(u64, @intFromEnum(r.op)) << 8 | r.flags;
            const gop = try tally.printed.getOrPut(gpa, key);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
            if (gop.value_ptr.* > 3) continue;
            std.debug.print("MISMATCH {s} {s} flags {d}{s}\n  input  {x}\n  ours   {x} {any}\n  theirs {x} {any}\n", .{
                r.enc.name(), @tagName(r.op), r.flags,     if (v.split) " (a unit at a time)" else "",
                r.input,      mine.output,    mine.events, t.output,
                t.events,
            });
        }
    }
}

/// Split calls report an error up to three bytes later when a byte read
/// again came in an earlier call (test/props.zig's `Mark`).
fn sameMarksLoose(a: []const Event, b: []const Event) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.out != y.out or @max(x.in, y.in) - @min(x.in, y.in) > 3) return false;
    }
    return true;
}

/// The bytes that start, continue, and end sequences in the standard's
/// multi-byte encodings, and some that do none of those.
const alphabet = [_]u8{
    0x00, 0x0E, 0x0F, 0x1B, 0x24, 0x28, 0x30, 0x39, 0x40, 0x41, 0x42, 0x4A, 0x5C, 0x7E, 0x7F, 0x80,
    0x81, 0x8E, 0x8F, 0x90, 0x9F, 0xA0, 0xA1, 0xBF, 0xC0, 0xC2, 0xDF, 0xE0, 0xED, 0xEF, 0xF4, 0xFF,
};

/// Every decoder input for `enc`.
fn decoderInputs(rng: std.Random, random: usize) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (0..random) |_| try list.append(gpa, try props.decoderInput(gpa, rng, 300));
    const positions = [_]usize{ 0, 1, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129 };
    for (positions) |p| {
        for (0..256) |b| {
            const buf = try gpa.alloc(u8, p + 4);
            @memset(buf, 'a');
            buf[p] = @intCast(b);
            try list.append(gpa, buf);
        }
    }
    for (0..65536) |v| {
        const buf = try gpa.alloc(u8, 2);
        std.mem.writeInt(u16, buf[0..2], @intCast(v), .big);
        try list.append(gpa, buf);
    }
    for (alphabet) |a| for (alphabet) |b| for (alphabet) |c| {
        try list.append(gpa, try gpa.dupe(u8, &.{ a, b, c }));
    };
    for (alphabet[8..24]) |a| for (alphabet[8..24]) |b| for (alphabet[8..24]) |c| for (alphabet[8..24]) |d| {
        try list.append(gpa, try gpa.dupe(u8, &.{ a, b, c, d }));
    };
    return list.items;
}

const Texts = struct { utf8: []const u8, utf16: []const u8 };

/// Every encoder input: random texts, and every scalar value in runs of
/// 4096.
fn encoderInputs(rng: std.Random, random: usize) ![]Texts {
    var list: std.ArrayList(Texts) = .empty;
    for (0..random) |_| {
        const t = try props.encoderInput(gpa, rng, 200);
        try list.append(gpa, .{ .utf8 = t.utf8, .utf16 = try le16(t.utf16) });
    }
    var cp: u21 = 0;
    while (cp <= 0x10FFFF) {
        var t8: std.ArrayList(u8) = .empty;
        var t16: std.ArrayList(u16) = .empty;
        const end = cp + 4096;
        while (cp < end and cp <= 0x10FFFF) : (cp += 1) {
            if (cp >= 0xD800 and cp <= 0xDFFF) continue;
            var b: [4]u8 = undefined;
            try t8.appendSlice(gpa, b[0 .. std.unicode.utf8Encode(cp, &b) catch unreachable]);
            var u: [2]u16 = undefined;
            const n = std.unicode.utf8ToUtf16Le(
                &u,
                b[0 .. std.unicode.utf8CodepointSequenceLength(cp) catch unreachable],
            ) catch unreachable;
            for (u[0..n]) |x| try t16.append(gpa, std.mem.littleToNative(u16, x));
        }
        try list.append(gpa, .{ .utf8 = t8.items, .utf16 = try le16(t16.items) });
    }
    return list.items;
}

fn le16(units: []const u16) ![]const u8 {
    const out = try gpa.alloc(u8, units.len * 2);
    for (units, 0..) |u, i| std.mem.writeInt(u16, out[2 * i ..][0..2], u, .little);
    return out;
}

fn labelInputs() ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    const text = try Io.Dir.cwd().readFileAlloc(io, "vendor/whatwg-encoding/encodings.json", gpa, .limited(1 << 20));
    const Json = []const struct {
        heading: []const u8,
        encodings: []const struct { name: []const u8, labels: []const []const u8 },
    };
    const groups = try std.json.parseFromSliceLeaky(Json, gpa, text, .{});
    for (groups) |g| for (g.encodings) |e| {
        try list.append(gpa, e.name);
        for (e.labels) |l| {
            try list.append(gpa, l);
            try list.append(gpa, try std.ascii.allocUpperString(gpa, l));
            try list.append(gpa, try std.mem.concat(gpa, u8, &.{ " \t\n\x0c\r", l, "\r\n " }));
            try list.append(gpa, try std.mem.concat(gpa, u8, &.{ "\x0b", l }));
            try list.append(gpa, try std.mem.concat(gpa, u8, &.{ l, "\xc2\xa0" }));
            try list.append(gpa, l[0 .. l.len - 1]);
            try list.append(gpa, try std.mem.concat(gpa, u8, &.{ l, "x" }));
        }
    };
    for (
        [_][]const u8{ "", " ", "utf-7", "utf-32", "ucs-2", "cp437", "ibm437", "lat\xc4\xb1n1", "\xe2\x84\xaatf-8" },
    ) |l| try list.append(gpa, l);
    return list.items;
}

pub fn main(init: std.process.Init) !u8 {
    io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: oracle-compare ORACLE [--random N] [--seed N] [--encoding NAME]\n", .{});
        return 2;
    }
    oracle_path = args[1];
    var random: usize = 2000;
    var seed: u64 = 1;
    var only: ?Encoding = null;
    var i: usize = 2;
    while (i + 1 < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "--random")) random = try std.fmt.parseInt(usize, args[i + 1], 10);
        if (std.mem.eql(u8, args[i], "--seed")) seed = try std.fmt.parseInt(u64, args[i + 1], 10);
        if (std.mem.eql(u8, args[i], "--encoding")) only = Encoding.forLabel(args[i + 1]) orelse return 2;
    }
    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();
    var tally: Tally = .{};
    var batch: std.ArrayList(Request) = .empty;

    const labels = try labelInputs();
    for (labels) |l| try batch.append(gpa, .{ .op = .label, .flags = 0, .enc = .utf_8, .input = l });
    try compareBatch(batch.items, &tally);
    std.debug.print("labels: {d} compared\n", .{labels.len});

    const dec_inputs = try decoderInputs(rng, random);
    const enc_inputs = try encoderInputs(rng, random);
    for (encoding.implemented) |enc| {
        if (only != null and only.? != enc) continue;
        // An encoding outside the standard, such as IBM437, has no label,
        // and encoding_rs does not have it.
        if (Encoding.forLabel(enc.name()) != enc) {
            std.debug.print("{s}: not in the standard, so not compared\n", .{enc.name()});
            continue;
        }
        const before = tally.compared;
        const mismatches = tally.mismatches;
        batch.clearRetainingCapacity();
        for (dec_inputs, 0..) |input, n| {
            // The byte order mark options on the random inputs, which
            // start with marks; the rest in the default.
            const boms: []const u8 = if (n < random) &.{ 0, 1, 2 } else &.{0};
            for (boms) |bom| for ([_]u8{ 0, 1 }) |fatal| for ([_]Op{ .decode8, .decode16 }) |op| {
                try batch.append(gpa, .{ .op = op, .flags = fatal | bom << 1, .enc = enc, .input = input });
            };
            if (batch.items.len >= 50_000) {
                try compareBatch(batch.items, &tally);
                batch.clearRetainingCapacity();
            }
        }
        if (enc.outputEncoding() == enc) {
            for (enc_inputs) |t| for ([_]u8{ 0, 1 }) |fatal| {
                try batch.append(gpa, .{ .op = .encode8, .flags = fatal, .enc = enc, .input = t.utf8 });
                try batch.append(gpa, .{ .op = .encode16, .flags = fatal, .enc = enc, .input = t.utf16 });
            };
        }
        try compareBatch(batch.items, &tally);
        std.debug.print(
            "{s}: {d} compared, {d} mismatches\n",
            .{ enc.name(), tally.compared - before, tally.mismatches - mismatches },
        );
    }
    std.debug.print(
        "oracle: {d} comparisons with encoding_rs, {d} mismatches\n",
        .{ tally.compared, tally.mismatches },
    );
    return if (tally.mismatches == 0) 0 else 1;
}
