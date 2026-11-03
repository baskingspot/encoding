//! The detection scoring harness (test/detect/README.md), run from the
//! repository root:
//!
//!     detect-score guess SAMPLES         one line per sample: this
//!                                        package's guess at each cut
//!     detect-score bench SAMPLES         the whole articles' bytes per
//!                                        second, then the time per call on
//!                                        the 32-byte windows, each over at
//!                                        least BENCH_MS
//!     detect-score report SAMPLES NAME=GUESSES...
//!                                        accuracy and bytes needed per
//!                                        encoding and size, for each arm's
//!                                        guesses, as Markdown
//!     detect-score tables NAME        the bytes of the model's tables
//!     detect-score explain ENCODING TEXT
//!                                        debugging: TEXT encoded in
//!                                        ENCODING, the guesses, and each
//!                                        candidate's cost before languages
//!
//! A guess is right when it decodes the sample's bytes to the same text as
//! the sample's own encoding (windows-1250 and ISO-8859-2 both decode most
//! Polish alike). uchardet's "UHC" and "MAC-CYRILLIC" count as EUC-KR and
//! x-mac-cyrillic; any other name the label table does not know, such as
//! uchardet's "ASCII", "IBM852", or empty answer, counts as windows-1252, a
//! browser's fallback.

const std = @import("std");
const Io = std.Io;
const encoding = @import("encoding");
const options = @import("score_options");
const Encoding = encoding.Encoding;
const linux = std.os.linux;

const Detector = if (options.variant) encoding.detect.DetectorWith(variant_tables) else encoding.Detector;
// The module exists only with -Ddetect-tables.
const variant_tables = if (options.variant) @import("tables") else void; // ziglint-ignore: Z028

const Sample = struct {
    kind: u8,
    lang: []const u8,
    encoding: []const u8,
    length: usize,
    cuts: []const usize,
    bytes: []const u8,
};

fn readSamples(gpa: std.mem.Allocator, data: []const u8) ![]const Sample {
    var list: std.ArrayList(Sample) = .empty;
    var i: usize = 0;
    while (i < data.len) {
        const nl = std.mem.findScalarPos(u8, data, i, '\n') orelse return error.BadSamples;
        var f = std.mem.tokenizeScalar(u8, data[i..nl], ' ');
        const kind = (f.next() orelse return error.BadSamples)[0];
        const lang = f.next() orelse return error.BadSamples;
        const enc = f.next() orelse return error.BadSamples;
        const length = try std.fmt.parseInt(usize, f.next() orelse return error.BadSamples, 10);
        const n = try std.fmt.parseInt(usize, f.next() orelse return error.BadSamples, 10);
        const cuts = try gpa.alloc(usize, n);
        for (cuts) |*c| c.* = try std.fmt.parseInt(usize, f.next() orelse return error.BadSamples, 10);
        const len = cuts[n - 1];
        try list.append(gpa, .{
            .kind = kind,
            .lang = lang,
            .encoding = enc,
            .length = length,
            .cuts = cuts,
            .bytes = data[nl + 1 ..][0..len],
        });
        i = nl + 1 + len + 1;
    }
    return list.items;
}

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 3) return usage();
    if (std.mem.eql(u8, args[1], "explain") and args.len == 4) {
        // Debugging: TEXT encoded in ENCODING, and what each candidate
        // made of it.
        const e = Encoding.forLabel(args[2]) orelse return usage();
        var enc: encoding.Encoder = .init(e, .{});
        const bytes = try gpa.alloc(u8, enc.maxLenFromUtf8(args[3].len).?);
        const r = enc.encodeFromUtf8(args[3], bytes, true);
        var d: Detector = .init();
        d.feed(bytes[0..r.written]);
        var out: [8]encoding.detect.Guess = undefined;
        for (d.guesses(.{}, &out)) |g| std.debug.print("{s} {d:.3}  ", .{ g.encoding.name(), g.confidence });
        std.debug.print("\n", .{});
        const t = Detector.model;
        inline for (t.single_byte, 0..) |sbe, c| {
            const g = t.groups[sbe.group];
            std.debug.print("  {s} {s} pairs {d:.1}\n", .{ sbe.name, g.name, @as(f64, @floatFromInt(d.costs[c])) / 4 });
        }
        for (d.costs[t.single_byte.len..], 0..) |c, j| {
            std.debug.print("  cjk{d} {d:.1} alive {}\n", .{ j, @as(f64, @floatFromInt(c)) / 4, d.alive[2 + j] });
        }
        return 0;
    }
    if (std.mem.eql(u8, args[1], "tables")) {
        // The bytes of model data the detector carries, by part.
        const t = Detector.model;
        var pairs: usize = 0;
        var freq: usize = 0;
        for (t.groups) |g| {
            pairs += g.pairs.len + g.case.len;
            for (g.langs) |l| freq += l.freq.len;
        }
        var cjk_pairs: usize = 0;
        var cjk_chars: usize = 0;
        for (t.cjk) |m| {
            cjk_pairs += m.pairs.len + m.uncovered.len;
            cjk_chars += m.chars.len * 3;
        }
        // The detector reads each single-byte encoding's class map through
        // the 256-byte one it derives from it.
        const maps = t.single_byte.len * 256;
        std.debug.print("{s}: single-byte pairs {d}, language frequencies {d}, class maps {d}, " ++
            "CJK pairs {d}, CJK characters {d}, total {d} bytes\n", .{
            args[2], pairs, freq, maps, cjk_pairs, cjk_chars, pairs + freq + maps + cjk_pairs + cjk_chars,
        });
        std.debug.print("{s}: a Detector is {d} bytes\n", .{ args[2], @sizeOf(Detector) });
        return 0;
    }
    const data = try Io.Dir.cwd().readFileAlloc(io, args[2], gpa, .limited(1 << 31));
    const samples = try readSamples(gpa, data);
    var buf: [1 << 16]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buf);
    const w = &stdout.interface;
    if (std.mem.eql(u8, args[1], "guess")) {
        for (samples) |s| {
            var d: Detector = .init();
            var at: usize = 0;
            for (s.cuts, 0..) |c, k| {
                d.feed(s.bytes[at..c]);
                at = c;
                if (k > 0) try w.writeByte(' ');
                try w.writeAll(d.guess(.{}).encoding.name());
            }
            try w.writeByte('\n');
        }
    } else if (std.mem.eql(u8, args[1], "bench")) {
        const ms: u64 = if (init.environ_map.get("BENCH_MS")) |v| try std.fmt.parseInt(u64, v, 10) else 2000;
        var total: usize = 0;
        for (samples) |s| if (s.kind == 'd') {
            total += s.bytes.len;
        };
        var rounds: u64 = 0;
        var sink: usize = 0;
        const start = nowNs();
        while (rounds == 0 or nowNs() - start < ms * std.time.ns_per_ms) : (rounds += 1) {
            for (samples) |s| if (s.kind == 'd') {
                var d: Detector = .init();
                d.feed(s.bytes);
                sink ^= @intFromEnum(d.guess(.{}).encoding);
            };
        }
        const secs = @as(f64, @floatFromInt(nowNs() - start)) / 1e9;
        try w.print("zig\t{d} bytes x {d}\t{d:.1} MB/s\t(sink {d})\n", .{
            total, rounds, @as(f64, @floatFromInt(total * rounds)) / secs / 1e6, sink,
        });
        // The cost of a call on short input: a fresh detector per 32-byte
        // window.
        var calls: u64 = 0;
        const start2 = nowNs();
        while (calls == 0 or nowNs() - start2 < ms * std.time.ns_per_ms) {
            for (samples) |s| if (s.kind == 'w' and s.length == 32) {
                var d: Detector = .init();
                d.feed(s.bytes);
                sink ^= @intFromEnum(d.guess(.{}).encoding);
                calls += 1;
            };
        }
        const ns = @as(f64, @floatFromInt(nowNs() - start2)) / @as(f64, @floatFromInt(calls));
        try w.print("zig\t32-byte windows x {d}\t{d:.0} ns per call\t(sink {d})\n", .{ calls, ns, sink });
    } else if (std.mem.eql(u8, args[1], "report")) {
        if (args.len < 4) return usage();
        try report(gpa, io, w, samples, args[3..]);
    } else return usage();
    try w.flush();
    return 0;
}

fn usage() u8 {
    std.debug.print("usage: detect-score guess SAMPLES | bench SAMPLES | report SAMPLES NAME=GUESSES...\n", .{});
    return 2;
}

/// `bytes` decoded by `e`, with replacement, into `out`.
fn decode(gpa: std.mem.Allocator, e: Encoding, bytes: []const u8) ![]const u8 {
    var d: encoding.Decoder = .init(e, .{ .bom = .keep });
    const out = try gpa.alloc(u8, d.maxUtf8Len(bytes.len).?);
    const r = d.decodeToUtf8(bytes, out, true);
    return out[0..r.written];
}

const sizes = [_]usize{ 16, 32, 64, 128, 256, 1024, 4096 };
/// Columns: each window size, then whole articles.
const columns = sizes.len + 1;

const Tally = struct {
    right: [columns]u32 = @splat(0),
    all: [columns]u32 = @splat(0),
    /// The bytes each article needed, or null for one guessed wrong in
    /// full.
    needed: std.ArrayList(?usize) = .empty,
};

fn report(
    gpa: std.mem.Allocator,
    io: Io,
    w: *Io.Writer,
    samples: []const Sample,
    arm_args: []const [:0]const u8,
) !void {
    const Arm = struct { name: []const u8, lines: [][]const u8 };
    const arms = try gpa.alloc(Arm, arm_args.len);
    for (arms, arm_args) |*a, arg| {
        const eq = std.mem.findScalar(u8, arg, '=') orelse return error.BadArm;
        const text = try Io.Dir.cwd().readFileAlloc(io, arg[eq + 1 ..], gpa, .limited(1 << 30));
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| try lines.append(gpa, l);
        if (lines.items.len < samples.len) return error.TooFewGuesses;
        a.* = .{ .name = arg[0..eq], .lines = lines.items };
    }

    // Tallies by encoding and by language and encoding, for each arm.
    var keys: std.ArrayList([]const u8) = .empty;
    var by_key: std.array_hash_map.String([]Tally) = .empty;
    var encs: std.ArrayList([]const u8) = .empty;
    var by_enc: std.array_hash_map.String([]Tally) = .empty;
    for (samples, 0..) |s, i| {
        const key = try std.fmt.allocPrint(gpa, "{s} {s}", .{ s.lang, s.encoding });
        const kt = try by_key.getOrPut(gpa, key);
        if (!kt.found_existing) {
            kt.value_ptr.* = try gpa.alloc(Tally, arms.len);
            for (kt.value_ptr.*) |*t| t.* = .{};
            try keys.append(gpa, key);
        }
        const et = try by_enc.getOrPut(gpa, s.encoding);
        if (!et.found_existing) {
            et.value_ptr.* = try gpa.alloc(Tally, arms.len);
            for (et.value_ptr.*) |*t| t.* = .{};
            try encs.append(gpa, s.encoding);
        }
        const truth = Encoding.forLabel(s.encoding) orelse return error.UnknownEncoding;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        // The text of each cut in the sample's own encoding.
        const want = try a.alloc([]const u8, s.cuts.len);
        for (want, s.cuts) |*t, c| t.* = try decode(a, truth, s.bytes[0..c]);
        for (arms, 0..) |arm, ai| {
            var names = std.mem.tokenizeScalar(u8, arm.lines[i], ' ');
            var needed: ?usize = null;
            var last_right = false;
            for (s.cuts, want) |c, t| {
                const name = names.next() orelse return error.TooFewGuesses;
                const g: Encoding = Encoding.forLabel(name) orelse
                    if (std.mem.eql(u8, name, "UHC"))
                        .euc_kr
                    else if (std.mem.eql(u8, name, "MAC-CYRILLIC"))
                        .x_mac_cyrillic
                    else
                        .windows_1252;
                const right = g == truth or std.mem.eql(u8, t, try decode(a, g, s.bytes[0..c]));
                if (right and !last_right) needed = c;
                if (!right) needed = null;
                last_right = right;
            }
            const col = if (s.kind == 'd')
                sizes.len
            else
                std.mem.findScalar(usize, &sizes, s.length) orelse return error.BadSize;
            for ([_][]Tally{ kt.value_ptr.*, et.value_ptr.* }) |ts| {
                ts[ai].all[col] += 1;
                ts[ai].right[col] += @intFromBool(last_right);
                if (s.kind == 'd') try ts[ai].needed.append(gpa, needed);
            }
        }
    }

    try w.writeAll("Accuracy, the percentage of samples guessed right, by encoding and size in bytes");
    try w.writeAll(" (each cell: ");
    for (arms, 0..) |a, i| try w.print("{s}{s}", .{ if (i > 0) " / " else "", a.name });
    try w.writeAll("). The last row averages the encodings.\n\n| Encoding |");
    for (sizes) |s| try w.print(" {d} |", .{s});
    try w.writeAll(" article |\n|---|");
    for (0..columns) |_| try w.writeAll("---|");
    try w.writeAll("\n");
    var mean: [columns][]f64 = undefined;
    for (&mean) |*m| {
        m.* = try gpa.alloc(f64, arms.len);
        @memset(m.*, 0);
    }
    for (encs.items) |e| {
        const ts = by_enc.get(e).?;
        try w.print("| {s} |", .{e});
        for (0..columns) |col| {
            for (ts, 0..) |t, ai| {
                const pct = 100 * @as(f64, @floatFromInt(t.right[col])) / @as(f64, @floatFromInt(@max(t.all[col], 1)));
                mean[col][ai] += pct / @as(f64, @floatFromInt(encs.items.len));
                try w.print("{s}{d:.0}", .{ if (ai > 0) "/" else " ", pct });
            }
            try w.writeAll(" |");
        }
        try w.writeAll("\n");
    }
    try w.writeAll("| mean |");
    for (mean) |m| {
        for (m, 0..) |v, ai| try w.print("{s}{d:.1}", .{ if (ai > 0) "/" else " ", v });
        try w.writeAll(" |");
    }
    try w.writeAll("\n\n");

    try w.writeAll("Bytes needed: over each encoding's articles, the median and 90th percentile of the " ++
        "shortest prefix from which every longer one is guessed right (of 16, 24, 32, 48, 64, ... bytes, " ++
        "and the whole article); an article guessed wrong in full counts as never, `-`.\n\n" ++
        "| Encoding | articles |");
    for (arms) |a| try w.print(" {s} median | {s} p90 | {s} never |", .{ a.name, a.name, a.name });
    try w.writeAll("\n|---|---|");
    for (arms) |_| try w.writeAll("---|---|---|");
    try w.writeAll("\n");
    for (encs.items) |e| {
        const ts = by_enc.get(e).?;
        try w.print("| {s} | {d} |", .{ e, ts[0].needed.items.len });
        for (ts) |t| {
            const v = try gpa.alloc(usize, t.needed.items.len);
            var never: usize = 0;
            for (t.needed.items, v) |x, *y| {
                y.* = x orelse std.math.maxInt(usize);
                never += @intFromBool(x == null);
            }
            std.mem.sort(usize, v, {}, std.sort.asc(usize));
            for ([_]usize{ 50, 90 }) |q| {
                const at = (v.len * q + 99) / 100 -| 1;
                if (v.len == 0 or v[at] == std.math.maxInt(usize)) {
                    try w.writeAll(" - |");
                } else try w.print(" {d} |", .{v[at]});
            }
            try w.print(" {d} |", .{never});
        }
        try w.writeAll("\n");
    }

    try w.writeAll("\nAccuracy by language and encoding at 32 and 128 bytes and on whole articles.\n\n" ++
        "| Language | Encoding | 32 | 128 | article |\n|---|---|---|---|---|\n");
    for (keys.items) |k| {
        const ts = by_key.get(k).?;
        const sp = std.mem.findScalar(u8, k, ' ').?;
        try w.print("| {s} | {s} |", .{ k[0..sp], k[sp + 1 ..] });
        for ([_]usize{ 1, 3, sizes.len }) |col| {
            for (ts, 0..) |t, ai| {
                const pct = 100 * @as(f64, @floatFromInt(t.right[col])) / @as(f64, @floatFromInt(@max(t.all[col], 1)));
                try w.print("{s}{d:.0}", .{ if (ai > 0) "/" else " ", pct });
            }
            try w.writeAll(" |");
        }
        try w.writeAll("\n");
    }
}
