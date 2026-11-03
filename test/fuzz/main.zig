//! The fuzz driver behind `just fuzz`: every implemented codec, decoders
//! on arbitrary bytes and encoders on arbitrary UTF-8 and UTF-16, checked
//! for the properties in test/props.zig (no crash or safety panic, output
//! well-formed, the same output for any split of the input and any output
//! buffer, UTF-8 and UTF-16 in agreement, max lengths sufficient), and the
//! charset detector on arbitrary bytes and hints (`checkDetector`), and the
//! stream adapters (test/adapters.zig): `DecodingReader` on decoder inputs
//! and `EncodingWriter` on UTF-8, read and written in random pieces, against
//! one call.
//!
//!     fuzz run [--seconds N] [--seed N] [--target decode|encode|detect|reader|writer|all]
//!              [--encoding NAME|all] [--out DIR]
//!     fuzz repro decode NAME FILE
//!     fuzz repro encode NAME FILE.utf8 FILE.utf16
//!     fuzz repro detect NAME FILE
//!     fuzz repro reader NAME FILE
//!     fuzz repro writer NAME FILE.utf8
//!
//! Inputs run in a forked child that copies each one to shared memory
//! before running it, so a crash, a safety panic, a hang, or a failed
//! property is caught with the input that caused it. A finding goes under
//! `zig-out/fuzz/` (or --out): the input, a decoder input minimized by
//! removing bytes, and the child's log. The driver exits 1 if it found
//! anything. Build it in ReleaseSafe, so safety checks fire.

const std = @import("std");
const encoding = @import("encoding");
const props = @import("props");
const adapters = @import("adapters");
const Encoding = encoding.Encoding;
const linux = std.os.linux;

const max_input = 1 << 16;

const Target = enum { decode, encode, detect, reader, writer };

const Options = struct {
    seconds: u64 = 60,
    seed: ?u64 = null,
    targets: []const Target = &.{ .decode, .encode, .detect, .reader, .writer },
    encodings: []const Encoding = &encoding.implemented,
    out: []const u8 = "zig-out/fuzz",
};

var io: std.Io = undefined;
const gpa = std.heap.smp_allocator;

const usage =
    \\usage: fuzz run [--seconds N] [--seed N] [--target decode|encode|detect|reader|writer|all]
    \\                [--encoding NAME|all] [--out DIR]
    \\       fuzz repro decode NAME FILE
    \\       fuzz repro encode NAME FILE.utf8 FILE.utf16
    \\       fuzz repro detect NAME FILE
    \\       fuzz repro reader NAME FILE
    \\       fuzz repro writer NAME FILE.utf8
    \\
;

pub fn main(init: std.process.Init) !u8 {
    io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return fail();
    if (std.mem.eql(u8, args[1], "repro")) return repro(args[2..]);
    if (!std.mem.eql(u8, args[1], "run")) return fail();
    var opts: Options = .{};
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (i + 1 == args.len) return fail();
        const v = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, a, "--seconds")) {
            opts.seconds = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, a, "--seed")) {
            opts.seed = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, a, "--out")) {
            opts.out = v;
        } else if (std.mem.eql(u8, a, "--target")) {
            if (!std.mem.eql(u8, v, "all")) {
                const t = std.meta.stringToEnum(Target, v) orelse return fail();
                opts.targets = try gpa.dupe(Target, &.{t});
            }
        } else if (std.mem.eql(u8, a, "--encoding")) {
            if (!std.mem.eql(u8, v, "all")) {
                // A label, or a name, for the encodings with none (IBM437).
                const e = Encoding.forLabel(v) orelse for (std.enums.values(Encoding)) |n| {
                    if (std.ascii.eqlIgnoreCase(n.name(), v)) break n;
                } else return fail();
                if (!e.isImplemented()) {
                    std.debug.print("fuzz: {s} is not implemented yet\n", .{e.name()});
                    return 2;
                }
                opts.encodings = try gpa.dupe(Encoding, &.{e});
            }
        } else return fail();
    }
    return supervise(opts);
}

fn fail() u8 {
    std.debug.print("{s}", .{usage});
    return 2;
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u32) void {
    const ts: linux.timespec = .{ .sec = 0, .nsec = @as(isize, ms) * 1_000_000 };
    _ = linux.nanosleep(&ts, null);
}

/// What the child tells the parent about the input it is running.
const Shared = extern struct {
    heartbeat: u64,
    /// The iteration the child is on; the next child starts after it.
    done: u64,
    target: u32,
    encoding: u32,
    len8: u32,
    len16: u32,
    data8: [max_input]u8,
    data16: [max_input]u16,
};

fn mapShared() !*Shared {
    const size = std.mem.alignForward(usize, @sizeOf(Shared), std.heap.page_size_min);
    const rc = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .ANONYMOUS = true }, -1, 0);
    if (linux.errno(rc) != .SUCCESS) return error.MmapFailed;
    return @ptrFromInt(rc);
}

/// Files whose bytes seed the decoder inputs: the web-platform-tests'
/// pages in every encoding, and the benchmark corpus when it is there.
fn loadCorpus() ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{
        "vendor/wpt/encoding/legacy-mb-japanese/shift_jis",
        "vendor/wpt/encoding/legacy-mb-japanese/euc-jp",
        "vendor/wpt/encoding/legacy-mb-japanese/iso-2022-jp",
        "vendor/wpt/encoding/legacy-mb-korean/euc-kr",
        "vendor/wpt/encoding/legacy-mb-tchinese/big5",
        "vendor/wpt/encoding/resources",
        "vendor/wpt/encoding",
        "bench/corpus-gen/text",
    }) |path| {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        var n: usize = 0;
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or n >= 24) continue;
            const data = dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20)) catch continue;
            try list.append(gpa, data);
            n += 1;
        }
    }
    return list.items;
}

/// A decoder input: generated (test/props.zig), or a slice of a corpus
/// file, mutated.
fn decoderInput(rng: std.Random, corpus: []const []const u8) ![]u8 {
    if (corpus.len == 0 or rng.uintLessThan(u8, 3) != 0) return props.decoderInput(gpa, rng, 2048);
    const file = corpus[rng.uintLessThan(usize, corpus.len)];
    const start = rng.uintAtMost(usize, file.len);
    const len = @min(file.len - start, rng.uintAtMost(usize, 600));
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(gpa, file[start..][0..len]);
    var k = rng.uintLessThan(u8, 6);
    while (k > 0 and buf.items.len > 0) : (k -= 1) {
        const at = rng.uintLessThan(usize, buf.items.len);
        switch (rng.uintLessThan(u8, 4)) {
            0 => buf.items[at] ^= @as(u8, 1) << rng.int(u3),
            1 => buf.items[at] = rng.int(u8),
            2 => _ = buf.orderedRemove(at),
            else => try buf.insert(gpa, at, rng.int(u8)),
        }
    }
    return buf.toOwnedSlice(gpa);
}

fn runOne(rng: std.Random, target: Target, enc: Encoding, shared: ?*Shared, corpus: []const []const u8) !void {
    switch (target) {
        .decode, .reader => {
            const src = try decoderInput(rng, corpus);
            defer gpa.free(src);
            if (shared) |s| {
                const n = @min(src.len, max_input);
                @memcpy(s.data8[0..n], src[0..n]);
                s.len8 = @intCast(n);
                _ = @atomicRmw(u64, &s.heartbeat, .Add, 1, .seq_cst);
            }
            if (target == .reader) return adapters.checkReader(gpa, rng, enc, src, adapters.decoderOptions(rng));
            try props.checkDecoder(gpa, rng, enc, src, .{});
        },
        .encode, .writer => {
            const t = try props.encoderInput(gpa, rng, 600);
            defer gpa.free(t.utf8);
            defer gpa.free(t.utf16);
            if (shared) |s| {
                const n8 = @min(t.utf8.len, max_input);
                const n16 = @min(t.utf16.len, max_input);
                @memcpy(s.data8[0..n8], t.utf8[0..n8]);
                @memcpy(s.data16[0..n16], t.utf16[0..n16]);
                s.len8 = @intCast(n8);
                s.len16 = @intCast(n16);
                _ = @atomicRmw(u64, &s.heartbeat, .Add, 1, .seq_cst);
            }
            if (target == .writer) return adapters.checkWriter(gpa, rng, enc, t.utf8, adapters.encoderOptions(rng));
            try props.checkEncoder(gpa, rng, enc, t.utf8, t.utf16, .{});
        },
        .detect => {
            const src = try decoderInput(rng, corpus);
            defer gpa.free(src);
            if (shared) |s| {
                const n = @min(src.len, max_input);
                @memcpy(s.data8[0..n], src[0..n]);
                s.len8 = @intCast(n);
                _ = @atomicRmw(u64, &s.heartbeat, .Add, 1, .seq_cst);
            }
            try checkDetector(rng, src);
        },
    }
}

/// The detector's properties on `src`, with random hints: guesses that
/// are never empty, ranked, with confidences from 0 to 1 that add up to
/// 1, no UTF-8 when it is not allowed, and the same guesses for any split
/// of the input, asked for at any point.
fn checkDetector(rng: std.Random, src: []const u8) !void {
    const tlds = [_][]const u8{ "jp", "example.co.jp", "RU", "cn", "tw", "kr", "de", "com", "", ".", "il.", "gr" };
    const langs = [_][]const u8{ "ja", "zh-TW", "zh-Hant-HK", "sr-Latn", "ru", "he", "iw", "x", "-", "_zh", "ko-KR" };
    var junk: [8]u8 = undefined;
    rng.bytes(&junk);
    const pick = struct {
        fn f(r: std.Random, list: []const []const u8, j: []const u8) ?[]const u8 {
            const k = r.uintLessThan(usize, list.len + 2);
            return if (k < list.len) list[k] else if (k == list.len) null else j[0..r.uintAtMost(usize, j.len)];
        }
    }.f;
    const hints: encoding.detect.Hints = .{
        .tld = pick(rng, &tlds, &junk),
        .language = pick(rng, &langs, &junk),
        .allow_utf8 = rng.boolean(),
    };
    const Detector = encoding.Detector;
    const n = Detector.candidates.len;

    var whole: Detector = .init();
    whole.feed(src);
    var want: [n]encoding.detect.Guess = undefined;
    const all = whole.guesses(hints, &want);
    if (all.len == 0) return error.NoGuess;
    var sum: f64 = 0;
    for (all, 0..) |g, i| {
        if (!(g.confidence >= 0 and g.confidence <= 1)) return error.BadConfidence;
        if (i > 0 and g.confidence > all[i - 1].confidence) return error.NotRanked;
        if (g.encoding == .utf_8 and !hints.allow_utf8) return error.Utf8NotAllowed;
        for (all[0..i]) |h| if (h.encoding == g.encoding) return error.DuplicateGuess;
        sum += g.confidence;
    }
    if (@abs(sum - 1) > 1e-3) return error.ConfidencesDoNotAddUp;
    if (whole.guess(hints).encoding != all[0].encoding) return error.GuessDisagrees;

    var split: Detector = .init();
    var at: usize = 0;
    while (at < src.len) {
        const len = @min(src.len - at, rng.uintAtMost(usize, 40));
        split.feed(src[at..][0..len]);
        at += len;
        // Asking along the way changes nothing.
        if (rng.uintLessThan(u8, 4) == 0) _ = split.guess(hints);
    }
    var got: [n]encoding.detect.Guess = undefined;
    const parts = split.guesses(hints, &got);
    if (parts.len != all.len) return error.SplitDisagrees;
    for (parts, all) |a, b| {
        if (a.encoding != b.encoding or a.confidence != b.confidence) return error.SplitDisagrees;
    }
}

/// The child: inputs from the seed, round robin over targets and
/// encodings, until the deadline. Exits 0 when done, 4 at a failed
/// property.
fn childLoop(opts: Options, shared: *Shared, deadline: i64, corpus: []const []const u8) noreturn {
    var iter = shared.done;
    const combos = opts.targets.len * opts.encodings.len;
    while (nowMs() < deadline) : (iter += 1) {
        var prng: std.Random.DefaultPrng = .init(opts.seed.? +% iter *% 0x9e3779b97f4a7c15);
        const combo = iter % combos;
        const target = opts.targets[combo % opts.targets.len];
        const enc = opts.encodings[combo / opts.targets.len];
        shared.done = iter;
        shared.target = @intFromEnum(target);
        shared.encoding = @intFromEnum(enc);
        runOne(prng.random(), target, enc, shared, corpus) catch |err| {
            std.debug.print("{t} {s}: {t}\n", .{ target, enc.name(), err });
            linux.exit_group(4);
        };
    }
    shared.done = iter;
    linux.exit_group(0);
}

const Status = union(enum) { exited: u8, signaled: u32, hung };

fn waitChild(shared: *Shared, pid: linux.pid_t, timeout: i64) Status {
    var last = @atomicLoad(u64, &shared.heartbeat, .seq_cst);
    var since = nowMs();
    while (true) {
        var status: u32 = 0;
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        if (rc == pid) {
            if (linux.W.IFEXITED(status)) return .{ .exited = linux.W.EXITSTATUS(status) };
            return .{ .signaled = @intFromEnum(linux.W.TERMSIG(status)) };
        }
        const beat = @atomicLoad(u64, &shared.heartbeat, .seq_cst);
        if (beat != last) {
            last = beat;
            since = nowMs();
        } else if (nowMs() - since > timeout) {
            _ = linux.kill(pid, .KILL);
            _ = linux.waitpid(pid, &status, 0);
            return .hung;
        }
        sleepMs(5);
    }
}

fn spawn(log_path: [:0]const u8) !?linux.pid_t {
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return error.ForkFailed;
    if (rc != 0) return @intCast(rc);
    const fd = linux.open(log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(fd) == .SUCCESS) _ = linux.dup2(@intCast(fd), 2);
    return null;
}

fn supervise(opts_in: Options) !u8 {
    var opts = opts_in;
    opts.seed = opts.seed orelse @as(u64, @intCast(nowMs())) *% 0x9e3779b97f4a7c15;
    const shared = try mapShared();
    shared.* = .{
        .heartbeat = 0,
        .done = 0,
        .target = 0,
        .encoding = 0,
        .len8 = 0,
        .len16 = 0,
        .data8 = undefined,
        .data16 = undefined,
    };
    const corpus = try loadCorpus();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, opts.out);
    const log_path = try std.fmt.allocPrintSentinel(gpa, "{s}/child.log", .{opts.out}, 0);
    const start = nowMs();
    const deadline = start + @as(i64, @intCast(opts.seconds)) * 1000;
    std.debug.print("fuzz: seed {d}, {d}s, {d} targets x {d} encodings, {d} corpus files\n", .{
        opts.seed.?, opts.seconds, opts.targets.len, opts.encodings.len, corpus.len,
    });
    var findings: u32 = 0;
    while (nowMs() < deadline) {
        const pid = try spawn(log_path) orelse childLoop(opts, shared, deadline, corpus);
        const status = waitChild(shared, pid, 10_000);
        switch (status) {
            .exited => |c| if (c == 0) break,
            else => {},
        }
        findings += 1;
        try record(opts, shared, status, log_path);
        shared.done += 1;
    }
    std.debug.print(
        "fuzz: {d} inputs in {d}s, {d} findings\n",
        .{ shared.done, @divTrunc(nowMs() - start, 1000), findings },
    );
    return if (findings == 0) 0 else 1;
}

fn record(opts: Options, shared: *Shared, status: Status, log_path: [:0]const u8) !void {
    const target: Target = @enumFromInt(shared.target);
    const enc: Encoding = @enumFromInt(shared.encoding);
    const cwd = std.Io.Dir.cwd();
    const dir = try std.fmt.allocPrint(gpa, "{s}/findings", .{opts.out});
    try cwd.createDirPath(io, dir);
    const base = try std.fmt.allocPrint(gpa, "{s}/{t}-{s}-{d}", .{ dir, target, enc.name(), shared.done });
    const log = cwd.readFileAlloc(io, log_path, gpa, .limited(1 << 20)) catch "";
    std.debug.print("FINDING: {t} {s}, iteration {d}, {any}\n{s}\n", .{ target, enc.name(), shared.done, status, log });
    const data8 = try gpa.dupe(u8, shared.data8[0..shared.len8]);
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.log", .{base}), .data = log });
    switch (target) {
        .decode => {
            try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.input", .{base}), .data = data8 });
            const min = try minimize(enc, data8, log_path);
            try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.min", .{base}), .data = min });
            std.debug.print("  input {d} bytes, minimized to {d}: {s}.min\n", .{ data8.len, min.len, base });
        },
        .detect, .reader => {
            try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.input", .{base}), .data = data8 });
            std.debug.print("  input: {s}.input\n", .{base});
        },
        .encode, .writer => {
            try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.utf8", .{base}), .data = data8 });
            const data16 = std.mem.sliceAsBytes(shared.data16[0..shared.len16]);
            try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.utf16", .{base}), .data = data16 });
            std.debug.print("  input: {s}.utf8 and {s}.utf16\n", .{ base, base });
        },
    }
}

/// Whether `input` still fails the decoder check for `enc`, in a child.
fn stillFails(enc: Encoding, input: []const u8, log_path: [:0]const u8) bool {
    const pid = (spawn(log_path) catch return false) orelse {
        var prng: std.Random.DefaultPrng = .init(1);
        props.checkDecoder(gpa, prng.random(), enc, input, .{}) catch linux.exit_group(4);
        linux.exit_group(0);
    };
    var status: u32 = 0;
    _ = linux.waitpid(pid, &status, 0);
    return !(linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) == 0);
}

/// Removes runs of bytes, halving the run length down to one, while the
/// input still fails.
fn minimize(enc: Encoding, input: []const u8, log_path: [:0]const u8) ![]const u8 {
    var best = try gpa.dupe(u8, input);
    const deadline = nowMs() + 60_000;
    var chunk: usize = @max(1, best.len / 2);
    while (chunk >= 1 and nowMs() < deadline) : (chunk /= 2) {
        var at: usize = 0;
        while (at < best.len and nowMs() < deadline) {
            const n = @min(chunk, best.len - at);
            const candidate = try std.mem.concat(gpa, u8, &.{ best[0..at], best[at + n ..] });
            if (stillFails(enc, candidate, log_path)) {
                best = candidate;
            } else at += n;
        }
        if (chunk == 1) break;
    }
    return best;
}

fn repro(args: []const [:0]const u8) !u8 {
    if (args.len < 3) return fail();
    const target = std.meta.stringToEnum(Target, args[0]) orelse return fail();
    const enc = Encoding.forLabel(args[1]) orelse return fail();
    const cwd = std.Io.Dir.cwd();
    var prng: std.Random.DefaultPrng = .init(1);
    switch (target) {
        .decode => {
            const data = try cwd.readFileAlloc(io, args[2], gpa, .limited(max_input));
            props.checkDecoder(gpa, prng.random(), enc, data, .{}) catch return 1;
        },
        .encode => {
            if (args.len < 4) return fail();
            const t8 = try cwd.readFileAlloc(io, args[2], gpa, .limited(max_input));
            const b16 = try cwd.readFileAlloc(io, args[3], gpa, .limited(2 * max_input));
            const t16 = try gpa.alloc(u16, b16.len / 2);
            @memcpy(std.mem.sliceAsBytes(t16), b16[0 .. 2 * t16.len]);
            props.checkEncoder(gpa, prng.random(), enc, t8, t16, .{}) catch return 1;
        },
        .detect => {
            const data = try cwd.readFileAlloc(io, args[2], gpa, .limited(max_input));
            checkDetector(prng.random(), data) catch return 1;
        },
        // The reads, writes, and options are random: try many.
        .reader => {
            const data = try cwd.readFileAlloc(io, args[2], gpa, .limited(max_input));
            for (0..1000) |_| {
                const rng = prng.random();
                adapters.checkReader(gpa, rng, enc, data, adapters.decoderOptions(rng)) catch return 1;
            }
        },
        .writer => {
            const t8 = try cwd.readFileAlloc(io, args[2], gpa, .limited(max_input));
            for (0..1000) |_| {
                const rng = prng.random();
                adapters.checkWriter(gpa, rng, enc, t8, adapters.encoderOptions(rng)) catch return 1;
            }
        },
    }
    std.debug.print("ok\n", .{});
    return 0;
}
