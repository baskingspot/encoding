//! Detection's trainer: turns the training text `just detect-corpus`
//! writes under zig-out/detect/train/ into src/detect/tables.zig, the
//! models src/detect.zig scores with (docs/slop/results/detect-20261103.md).
//!
//!     detect-train write               write src/detect/tables.zig
//!     detect-train check               fail if the committed tables differ
//!                                      from what `write` would write
//!     detect-train variant NAME OUT    write the variant NAME to OUT, for
//!                                      the measurements of decision 5
//!
//! Run from the repository root. Each group of gen/detect/groups.tsv is one
//! model, trained on its languages in gen/detect/sources.tsv, each language
//! weighted alike.
//!
//! A single-byte group's model is a Markov chain over character classes:
//! the two ASCII classes, one class for each letter or symbol that is
//! common in the group's languages (upper and lower case together), and one
//! each for the group's rare letters, its rare symbols, and bytes an
//! encoding leaves unmapped. Its table holds the cost, in quarter bits, of
//! each class after each other: -log2 P(class | previous class) plus log2
//! of the class's size, so that the sum over a text is the cost of its
//! characters, whatever the classes. A second, 3 by 3 table holds the cost
//! of a letter's case after the previous character's (none, lower, upper).
//!
//! A Chinese, Japanese, or Korean model is the same chain over the classes
//! of src/detect/classes.zig, plus the cost of each of the most frequent
//! characters within its class, and one cost for every other character of
//! a class.

const std = @import("std");
const Io = std.Io;
const index = @import("index");
const classes = @import("classes");
const Cjk = classes.Cjk;

const train_dir = "zig-out/detect/train";
const out_path = "src/detect/tables.zig";

/// What a variant changes.
const Options = struct {
    /// How a single-byte model prices a character: `pairs` by the group's
    /// chain alone; `unigram` by each language's character frequencies
    /// alone, as a frequency model does, with no context; `hybrid` by the
    /// group's chain with each language's frequencies in place of the
    /// group's.
    model: enum { pairs, unigram, hybrid } = .hybrid,
    /// Merge a group's languages by their mixture, or by the most
    /// favorable language for each pair, as chardetng does.
    merge: enum { mixture, max } = .mixture,
    /// Characters a CJK model lists with their own cost.
    top_k: usize = 512,
    /// A single-byte model's classes, at most.
    max_classes: usize = 48,
    /// The share of a group's characters a letter needs for a class of its
    /// own.
    min_share: f64 = 1e-4,
    /// The most a pair costs, in bits.
    cap_bits: f64 = 40,
    /// What an unmapped byte costs, in bits, on each side.
    error_bits: f64 = 24,
    /// The pseudo-count that smooths each row toward the classes'
    /// overall frequencies.
    alpha: f64 = 20,
    /// The pseudo-count that smooths a language's frequencies toward its
    /// group's.
    beta: f64 = 50,

    /// Price each character given whether it is ASCII, which every
    /// candidate sees alike, rather than the chance that it is.
    conditional: bool = true,
    /// The groups whose languages get models of their own.
    split: []const []const u8 = &.{},

    fn unigram(o: Options) bool {
        return o.model == .unigram;
    }
};

const latin = [_][]const u8{ "western", "icelandic", "central", "turkish", "baltic" };

const variants = [_]struct { name: []const u8, options: Options }{
    .{ .name = "hybrid", .options = .{} },
    .{ .name = "pairs", .options = .{ .model = .pairs } },
    .{ .name = "unigram", .options = .{ .model = .unigram } },
    .{ .name = "max", .options = .{ .model = .pairs, .merge = .max } },
    .{ .name = "hybrid-max", .options = .{ .merge = .max } },
    .{ .name = "joint", .options = .{ .conditional = false } },
    .{ .name = "split-latin", .options = .{ .split = &latin } },
    .{ .name = "split-all", .options = .{ .split = &(latin ++ .{ "cyrillic", "hebrew", "arabic" }) } },
    .{ .name = "k256", .options = .{ .top_k = 256 } },
    .{ .name = "k1024", .options = .{ .top_k = 1024 } },
    .{ .name = "k2048", .options = .{ .top_k = 2048 } },
    .{ .name = "c32", .options = .{ .max_classes = 32 } },
    .{ .name = "c64", .options = .{ .max_classes = 64 } },
    .{ .name = "k1024-c64", .options = .{ .top_k = 1024, .max_classes = 64 } },
};

var io: Io = undefined;

pub fn main(init: std.process.Init) !u8 {
    io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 2) return usage();
    const cwd = Io.Dir.cwd();
    if (std.mem.eql(u8, args[1], "variant")) {
        if (args.len != 4) return usage();
        const v = for (variants) |v| {
            if (std.mem.eql(u8, v.name, args[2])) break v;
        } else return usage();
        try cwd.writeFile(io, .{ .sub_path = args[3], .data = try generate(gpa, v.options) });
        return 0;
    }
    const text = try generate(gpa, .{});
    if (std.mem.eql(u8, args[1], "write")) {
        try cwd.writeFile(io, .{ .sub_path = out_path, .data = text });
        return 0;
    }
    if (!std.mem.eql(u8, args[1], "check")) return usage();
    const old = cwd.readFileAlloc(io, out_path, gpa, .limited(16 << 20)) catch "";
    if (std.mem.eql(u8, old, text)) return 0;
    std.debug.print("detect-train: {s} differs from what `just detect-gen` writes\n", .{out_path});
    return 1;
}

fn usage() u8 {
    std.debug.print("usage: detect-train write | check | variant NAME OUT\n", .{});
    return 2;
}

fn readFile(gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20)) catch |err| {
        std.debug.print("detect-train: read {s}: {t} (run `just detect-corpus` from the repository root)\n", .{
            path, err,
        });
        return err;
    };
}

/// The data rows of a TSV file, each split at tabs.
fn rows(gpa: std.mem.Allocator, path: []const u8) ![]const []const []const u8 {
    var out: std.ArrayList([]const []const u8) = .empty;
    var lines = std.mem.splitScalar(u8, try readFile(gpa, path), '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, line, '\t');
        while (it.next()) |f| try fields.append(gpa, f);
        try out.append(gpa, fields.items);
    }
    return out.items;
}

const Group = struct {
    name: []const u8,
    /// The standard's names.
    encodings: []const []const u8,
    langs: []const []const u8,
    texts: []const []const u8,

    /// The index of a Chinese, Japanese, or Korean group's first encoding,
    /// or null for a single-byte group.
    fn cjkIndex(g: Group) ?[]const u8 {
        const pairs = [_][2][]const u8{
            .{ "Shift_JIS", "jis0208" }, .{ "EUC-KR", "euc-kr" }, .{ "GBK", "gb18030" }, .{ "Big5", "big5" },
        };
        for (pairs) |p| if (std.mem.eql(u8, g.encodings[0], p[0])) return p[1];
        return null;
    }

    fn cjk(g: Group) bool {
        return g.cjkIndex() != null;
    }
};

fn readIndex(gpa: std.mem.Allocator, name: []const u8) ![]const index.Entry {
    // ziglint-ignore: Z011 -- 0.16 has no Allocator.print
    const path = try std.fmt.allocPrint(gpa, "vendor/whatwg-encoding/index-{s}.txt", .{name});
    for (path) |*c| c.* = std.ascii.toLower(c.*);
    return index.parse(gpa, try readFile(gpa, path), .whatwg);
}

fn loadGroups(gpa: std.mem.Allocator, o: Options) ![]const Group {
    const sources = try rows(gpa, "gen/detect/sources.tsv");
    var groups: std.ArrayList(Group) = .empty;
    for (try rows(gpa, "gen/detect/groups.tsv")) |r| {
        var encs: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, r[1], ',');
        while (it.next()) |name| try encs.append(gpa, name);
        var langs: std.ArrayList([]const u8) = .empty;
        var texts: std.ArrayList([]const u8) = .empty;
        for (sources) |s| {
            if (!std.mem.eql(u8, s[2], r[0])) continue;
            try langs.append(gpa, s[0]);
            // ziglint-ignore: Z011 -- 0.16 has no Allocator.print
            try texts.append(gpa, try readFile(gpa, try std.fmt.allocPrint(gpa, "{s}/{s}.txt", .{ train_dir, s[0] })));
        }
        if (langs.items.len == 0) return error.GroupWithoutLanguages;
        const split = for (o.split) |name| {
            if (std.mem.eql(u8, name, r[0])) break true;
        } else false;
        if (!split) {
            try groups.append(gpa, .{
                .name = r[0],
                .encodings = encs.items,
                .langs = langs.items,
                .texts = texts.items,
            });
            continue;
        }
        for (langs.items, 0..) |l, i| try groups.append(gpa, .{
            // ziglint-ignore: Z011 -- 0.16 has no Allocator.print
            .name = try std.fmt.allocPrint(gpa, "{s}-{s}", .{ r[0], l }),
            .encodings = encs.items,
            .langs = langs.items[i..][0..1],
            .texts = texts.items[i..][0..1],
        });
    }
    return groups.items;
}

/// A character with case folded away: its lower-case form, its case
/// (0 none, 1 lower, 2 upper), and whether it is a letter or mark.
const Folded = struct { cp: u21, case: u2, letter: bool };

fn fold(cp: u21) Folded {
    const lower: Folded = .{ .cp = cp, .case = 1, .letter = true };
    const upper = struct {
        fn of(to: u21) Folded {
            return .{ .cp = to, .case = 2, .letter = true };
        }
    }.of;
    return switch (cp) {
        0xC0...0xD6, 0xD8...0xDE => upper(cp + 0x20),
        0xDF...0xF6, 0xF8...0xFF, 0xAA, 0xBA, 0xB5 => lower,
        // Latin Extended-A: pairs, upper case first, but for three runs.
        0x130 => .{ .cp = cp, .case = 2, .letter = true },
        0x131, 0x138, 0x149, 0x17F => lower,
        0x178 => upper(0xFF),
        0x139...0x148, 0x179...0x17E => if (cp & 1 == 1) upper(cp + 1) else lower,
        0x100...0x12F, 0x132...0x137, 0x14A...0x177 => if (cp & 1 == 0) upper(cp + 1) else lower,
        0x192 => lower,
        0x1A0, 0x1AF, 0x218, 0x21A => upper(cp + 1),
        0x1A1, 0x1B0, 0x219, 0x21B => lower,
        // Greek.
        0x386 => upper(0x3AC),
        0x388...0x38A => upper(cp + 0x25),
        0x38C => upper(0x3CC),
        0x38E...0x38F => upper(cp + 0x3F),
        0x391...0x3A1, 0x3A3...0x3AB => upper(cp + 0x20),
        0x390, 0x3AC...0x3CE => lower,
        // Cyrillic.
        0x400...0x40F => upper(cp + 0x50),
        0x410...0x42F => upper(cp + 0x20),
        0x430...0x45F => lower,
        0x490 => upper(0x491),
        0x491 => lower,
        // Scripts without case: Hebrew, Arabic, Thai, and combining marks.
        0x300...0x36F,
        0x5B0...0x5F2,
        0x621...0x652,
        0x670...0x6D3,
        0xE01...0xE3A,
        0xE40...0xE4E,
        => .{ .cp = cp, .case = 0, .letter = true },
        else => .{ .cp = cp, .case = 0, .letter = false },
    };
}

/// The code point each byte from 0x80 of a single-byte encoding decodes
/// to, or null where the encoding leaves it unmapped.
fn highHalf(gpa: std.mem.Allocator, name: []const u8) ![128]?u21 {
    var out: [128]?u21 = @splat(null);
    for (try readIndex(gpa, name)) |e| out[e.pointer] = e.cp;
    return out;
}

/// `p`, a distribution over classes, normalized within the ASCII classes
/// and within the rest, leaving out `skip`.
fn conditional(p: []f64, skip: ?usize) void {
    var low: f64 = 0;
    var high: f64 = 0;
    for (p, 0..) |x, b| {
        if (b < classes.ascii_classes) low += x else if (b != skip) high += x;
    }
    for (p, 0..) |*x, b| {
        if (b < classes.ascii_classes) x.* /= low else if (b != skip) x.* /= high;
    }
}

fn bits(p: f64) f64 {
    return -std.math.log2(p);
}

fn quantize(b: f64, cap: f64) u8 {
    const q = @round(@min(b, cap) * classes.units_per_bit);
    return @intFromFloat(std.math.clamp(q, 0, 255));
}

const SingleByteModel = struct {
    n: usize,
    pairs: []const u8,
    case: [9]u8,
    maps: []const [128]u8,
    members: []const []const u21,
    /// Each language's cost for each class.
    freqs: []const []const i8,
};

fn singleByte(gpa: std.mem.Allocator, g: Group, o: Options) !SingleByteModel {
    // The group's repertoire: every character a byte from 0x80 decodes to
    // in one of its encodings.
    const halves = try gpa.alloc([128]?u21, g.encodings.len);
    var repertoire: std.array_hash_map.Auto(u21, void) = .empty;
    for (g.encodings, halves) |e, *h| {
        h.* = try highHalf(gpa, e);
        for (h.*) |cp| if (cp) |c| try repertoire.put(gpa, c, {});
    }

    // Each folded character's share of the characters of the language it
    // is most common in.
    var share: std.array_hash_map.Auto(u21, f64) = .empty;
    for (g.texts) |text| {
        var counts: std.array_hash_map.Auto(u21, f64) = .empty;
        var total: f64 = 0;
        var it = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (it.nextCodepoint()) |cp| {
            total += 1;
            if (cp < 0x80 or !repertoire.contains(cp)) continue;
            const e = try counts.getOrPutValue(gpa, fold(cp).cp, 0);
            e.value_ptr.* += 1;
        }
        for (counts.keys(), counts.values()) |k, v| {
            const e = try share.getOrPutValue(gpa, k, 0);
            e.value_ptr.* = @max(e.value_ptr.*, v / total);
        }
    }

    // A class for each folded character common enough, most common first,
    // then the rare letters, the rare symbols, and unmapped bytes.
    var folds: std.array_hash_map.Auto(u21, void) = .empty;
    for (repertoire.keys()) |cp| try folds.put(gpa, fold(cp).cp, {});
    const common = try gpa.dupe(u21, folds.keys());
    const Ctx = struct {
        const Self = @This();
        share: *const std.array_hash_map.Auto(u21, f64),
        fn s(c: Self, cp: u21) f64 {
            return c.share.get(cp) orelse 0;
        }
        fn lt(c: Self, a: u21, b: u21) bool {
            if (c.s(a) != c.s(b)) return c.s(a) > c.s(b);
            return a < b;
        }
    };
    const ctx: Ctx = .{ .share = &share };
    std.mem.sort(u21, common, ctx, Ctx.lt);
    var k: usize = 0;
    const first = classes.ascii_classes;
    while (k < common.len and k + first + 4 <= o.max_classes and ctx.s(common[k]) >= o.min_share) k += 1;
    const n = k + first + 3;
    const rare_letter = k + first;
    const rare_other = k + first + 1;
    const err = k + first + 2;
    var class_of: std.AutoHashMapUnmanaged(u21, u8) = .empty;
    for (common[0..k], first..) |cp, c| try class_of.put(gpa, cp, @intCast(c));
    const classOf = struct {
        fn f(
            map: *const std.AutoHashMapUnmanaged(u21, u8),
            rep: *const std.array_hash_map.Auto(u21, void),
            cp: u21,
            prev: u8,
            rl: usize,
            ro: usize,
        ) u8 {
            if (cp < 0x80) return classes.asciiClass(@intCast(cp), prev);
            // A character outside the group's encodings: written as a
            // numeric character reference, which is ASCII.
            if (!rep.contains(cp)) return classes.asciiClass(' ', prev);
            const fo = fold(cp);
            return map.get(fo.cp) orelse @intCast(if (fo.letter) rl else ro);
        }
    }.f;
    const caseOf = struct {
        fn f(rep: *const std.array_hash_map.Auto(u21, void), cp: u21) u2 {
            if (cp < 0x80 or !rep.contains(cp)) return 0;
            return fold(cp).case;
        }
    }.f;

    // Each class's size, in folded characters, for the cost of one
    // character of it.
    const size = try gpa.alloc(f64, n);
    @memset(size, 0);
    const members = try gpa.alloc(std.ArrayList(u21), n);
    for (members) |*m| m.* = .empty;
    for (folds.keys()) |f| {
        const c = classOf(&class_of, &repertoire, f, 0, rare_letter, rare_other);
        size[c] += 1;
        try members[c].append(gpa, f);
    }
    size[classes.space] = 1;
    size[classes.letter] = 26;
    size[classes.gap] = 1;
    size[err] = 1;
    for (size) |*s| s.* = @max(s.*, 1);

    // Pair and case counts, each language weighted alike.
    const joint = try gpa.alloc(f64, n * n);
    @memset(joint, 0);
    var case_counts = [_]f64{0} ** 9;
    const lang_pairs = try gpa.alloc(f64, n * n);
    const lang_counts = try gpa.alloc([]f64, g.texts.len);
    const lang_totals = try gpa.alloc(f64, g.texts.len);
    for (g.texts, lang_counts, lang_totals) |text, *lc, *lt| {
        @memset(lang_pairs, 0);
        var lang_case = [_]f64{0} ** 9;
        var total: f64 = 0;
        var prev: u8 = classes.space;
        var prev_case: u2 = 0;
        var it = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (it.nextCodepoint()) |cp| {
            const c = classOf(&class_of, &repertoire, cp, prev, rare_letter, rare_other);
            const cs = caseOf(&repertoire, cp);
            lang_pairs[@as(usize, prev) * n + c] += 1;
            if (cs != 0) lang_case[@as(usize, prev_case) * 3 + cs] += 1;
            total += 1;
            prev = c;
            prev_case = cs;
        }
        lc.* = try gpa.alloc(f64, n);
        @memset(lc.*, 0);
        for (0..n) |a| for (0..n) |b| {
            lc.*[b] += lang_pairs[a * n + b];
        };
        lt.* = total;
        const w = 1e6 / total;
        for (joint, lang_pairs) |*j, l| j.* = switch (o.merge) {
            .mixture => j.* + l * w,
            .max => @max(j.*, l * w),
        };
        for (&case_counts, lang_case) |*j, l| j.* += l * w;
    }
    // The weights put each language at a million characters; smoothing and
    // costs work in counts of the average language.
    var mean_total: f64 = 0;
    for (g.texts) |t| mean_total += @floatFromInt(std.unicode.utf8CountCodepoints(t) catch t.len);
    mean_total /= @floatFromInt(g.texts.len);
    for (joint) |*j| j.* *= mean_total / 1e6;
    for (&case_counts) |*j| j.* *= mean_total / 1e6;

    var col = try gpa.alloc(f64, n);
    @memset(col, 0);
    var all: f64 = 0;
    for (0..n) |a| for (0..n) |b| {
        col[b] += joint[a * n + b];
        all += joint[a * n + b];
    };
    const unigram = try gpa.alloc(f64, n);
    for (unigram, col) |*u, c| u.* = (c + 0.5) / (all + 0.5 * @as(f64, @floatFromInt(n)));

    // Each language's cost for each class: its own frequency, or the
    // difference between it and the group's.
    if (o.conditional) conditional(unigram, err);
    const freqs = try gpa.alloc([]const i8, g.texts.len);
    const lp = try gpa.alloc(f64, n);
    for (freqs, lang_counts, lang_totals) |*f, lc, lt| {
        const v = try gpa.alloc(i8, n);
        for (lp, 0..) |*x, b| x.* = (lc[b] + o.beta * unigram[b]) / (lt + o.beta);
        if (o.conditional) conditional(lp, err);
        for (v, 0..) |*x, b| {
            const p = lp[b];
            const q: f64 = switch (o.model) {
                .pairs => 0,
                .hybrid => if (b < first or b == err) 0 else bits(p) - bits(unigram[b]),
                .unigram => if (b < first) 0 else if (b == err) 2 * o.error_bits else bits(p) + std.math.log2(size[b]),
            };
            x.* = @intFromFloat(std.math.clamp(@round(q * classes.units_per_bit), -127, 127));
        }
        f.* = v;
    }

    const pairs = try gpa.alloc(u8, if (o.unigram()) 0 else n * n);
    if (!o.unigram()) {
        const p = try gpa.alloc(f64, n);
        for (0..n) |a| {
            var row: f64 = 0;
            for (0..n) |b| row += joint[a * n + b];
            for (p, 0..) |*x, b| x.* = (joint[a * n + b] + o.alpha * unigram[b]) / (row + o.alpha);
            if (o.conditional) conditional(p, err);
            for (0..n) |b| {
                pairs[a * n + b] = if (classes.free(@intCast(a), @intCast(b)))
                    0
                else if (a == err or b == err)
                    quantize(o.error_bits, 255)
                else
                    quantize(bits(p[b]) + std.math.log2(size[b]), o.cap_bits);
            }
        }
    }
    var case: [9]u8 = @splat(0);
    if (!o.unigram()) for (0..3) |a| for (1..3) |b| {
        const p = (case_counts[a * 3 + b] + 1) / (case_counts[a * 3 + 1] + case_counts[a * 3 + 2] + 2);
        case[a * 3 + b] = quantize(bits(p), o.cap_bits);
    };

    const maps = try gpa.alloc([128]u8, g.encodings.len);
    for (maps, halves) |*m, h| {
        for (m, h) |*v, cp| v.* = if (cp) |c|
            classOf(&class_of, &repertoire, c, 0, rare_letter, rare_other) | @as(u8, caseOf(&repertoire, c)) << 6
        else
            @intCast(err);
    }
    const member_lists = try gpa.alloc([]const u21, n);
    for (member_lists, members) |*l, m| l.* = m.items;
    if (n > 64) return error.TooManyClasses;
    return .{ .n = n, .pairs = pairs, .case = case, .maps = maps, .members = member_lists, .freqs = freqs };
}

const CjkModel = struct {
    pairs: []const u8,
    uncovered: [Cjk.count]u8,
    chars: []const u16,
    costs: []const u8,
};

fn cjkClassOf(cp: u21, prev: Cjk) Cjk {
    return if (cp > 0xFFFF) .han else classes.cjkClass(@intCast(cp), prev);
}

fn cjkModel(gpa: std.mem.Allocator, g: Group, o: Options) !CjkModel {
    const n = Cjk.count;
    // Each class's size: the characters of the group's first encoding's
    // index, and for Shift_JIS its half-width katakana and its private use
    // area, which the standard maps without an index.
    var seen: std.array_hash_map.Auto(u21, void) = .empty;
    for (try readIndex(gpa, g.cjkIndex().?)) |e| try seen.put(gpa, e.cp, {});
    if (std.mem.eql(u8, g.encodings[0], "Shift_JIS")) {
        for (0xFF61..0xFFA0) |cp| try seen.put(gpa, @intCast(cp), {});
        for (0xE000..0xE758) |cp| try seen.put(gpa, @intCast(cp), {});
    }
    var size = [_]f64{0} ** n;
    for (seen.keys()) |cp| size[@intFromEnum(cjkClassOf(cp, .space))] += 1;
    size[classes.letter] = 26;

    var counts = [_]f64{0} ** (n * n);
    var class_total = [_]f64{0} ** n;
    var freq: std.array_hash_map.Auto(u21, f64) = .empty;
    for (g.texts) |text| {
        var prev: Cjk = .space;
        var it = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (it.nextCodepoint()) |cp| {
            const c = cjkClassOf(cp, prev);
            counts[@as(usize, @intFromEnum(prev)) * n + @intFromEnum(c)] += 1;
            class_total[@intFromEnum(c)] += 1;
            if (c.listed() and cp <= 0xFFFF) {
                const e = try freq.getOrPutValue(gpa, cp, 0);
                e.value_ptr.* += 1;
            }
            prev = c;
        }
    }
    var all: f64 = 0;
    for (class_total) |t| all += t;
    var unigram: [n]f64 = undefined;
    for (&unigram, class_total) |*u, t| u.* = (t + 0.5) / (all + 0.5 * @as(f64, n));

    const pairs = try gpa.alloc(u8, if (o.unigram()) n else n * n);
    if (o.unigram()) {
        var u = unigram;
        if (o.conditional) conditional(&u, null);
        for (pairs, 0..) |*p, b| p.* = if (b < classes.ascii_classes) 0 else quantize(bits(u[b]), o.cap_bits);
    } else {
        for (0..n) |a| {
            var row: f64 = 0;
            for (0..n) |b| row += counts[a * n + b];
            var p: [n]f64 = undefined;
            for (&p, 0..) |*x, b| x.* = (counts[a * n + b] + o.alpha * unigram[b]) / (row + o.alpha);
            if (o.conditional) conditional(&p, null);
            for (0..n) |b| {
                const extra: f64 = if (b == classes.letter) std.math.log2(26.0) else 0;
                const free = classes.free(@intCast(a), @intCast(b));
                pairs[a * n + b] = if (free) 0 else quantize(bits(p[b]) + extra, o.cap_bits);
            }
        }
    }

    // The most frequent characters, by code point, with their cost within
    // their class.
    const Entry = struct { cp: u21, count: f64 };
    const entries = try gpa.alloc(Entry, freq.count());
    for (entries, freq.keys(), freq.values()) |*e, k, v| e.* = .{ .cp = k, .count = v };
    std.mem.sort(Entry, entries, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            if (a.count != b.count) return a.count > b.count;
            return a.cp < b.cp;
        }
    }.lt);
    const top = entries[0..@min(o.top_k, entries.len)];
    std.mem.sort(Entry, top, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.cp < b.cp;
        }
    }.lt);
    var covered = [_]f64{0} ** n;
    var covered_distinct = [_]f64{0} ** n;
    const chars = try gpa.alloc(u16, top.len);
    const costs = try gpa.alloc(u8, top.len);
    for (top, chars, costs) |e, *ch, *co| {
        const c = @intFromEnum(cjkClassOf(e.cp, .space));
        covered[c] += e.count;
        covered_distinct[c] += 1;
        ch.* = @intCast(e.cp);
        co.* = quantize(bits(e.count / class_total[c]), o.cap_bits);
    }
    var uncovered: [n]u8 = @splat(0);
    for (classes.ascii_classes..n) |c| {
        const rest = @max(size[c] - covered_distinct[c], 1);
        const mass = (class_total[c] - covered[c] + 0.5) / (class_total[c] + 0.5);
        uncovered[c] = quantize(bits(mass / rest), o.cap_bits);
    }
    return .{ .pairs = pairs, .uncovered = uncovered, .chars = chars, .costs = costs };
}

fn writeBytes(w: *Io.Writer, bytes: anytype) !void {
    for (bytes, 0..) |b, i| {
        try w.print("{d},", .{b});
        try w.writeAll(if (i % 16 == 15) "\n" else " ");
    }
    try w.writeAll("\n");
}

/// `text` as comment lines of at most 100 bytes, broken at spaces, with a
/// line of its own for each line of `text`.
fn writeComment(w: *Io.Writer, text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var len: usize = 0;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        while (words.next()) |word| {
            if (len > 0 and len + 1 + word.len > 100) {
                try w.writeAll("\n");
                len = 0;
            }
            if (len == 0) {
                try w.writeAll("    //");
                len = 6;
            }
            try w.print(" {s}", .{word});
            len += 1 + word.len;
        }
        try w.writeAll("\n");
    }
}

fn generate(gpa: std.mem.Allocator, o: Options) ![]const u8 {
    const groups = try loadGroups(gpa, o);
    var out: Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    try w.print(
        \\//! Generated by `just detect-gen` (gen/detect/train.zig) from the
        \\//! training text of gen/detect/sources.tsv. Do not edit.
        \\
        \\/// Whether each character's cost ignores the one before it.
        \\pub const unigram = {};
        \\
        \\/// A single-byte group's model. `pairs` holds the cost of each class
        \\/// after each other, `classes` by `classes` (none with `unigram`),
        \\/// `case` that of a letter's case after the previous character's, and
        \\/// each language's `freq` what each character of a class adds.
        \\pub const Group = struct {{
        \\    name: []const u8,
        \\    classes: u8,
        \\    pairs: []const u8,
        \\    case: [9]u8,
        \\    langs: []const Lang,
        \\}};
        \\
        \\pub const Lang = struct {{
        \\    tag: []const u8,
        \\    freq: []const i8,
        \\}};
        \\
        \\/// A single-byte encoding: its group and each byte's class from 0x80,
        \\/// with the case in the top two bits.
        \\pub const SingleByte = struct {{
        \\    name: []const u8,
        \\    group: u8,
        \\    map: [128]u8,
        \\}};
        \\
        \\/// A Chinese, Japanese, or Korean model, for its encodings. `pairs` is
        \\/// as a group's, over the classes of classes.zig; `chars`, sorted,
        \\/// are the characters listed with a cost of their own, `costs`, and
        \\/// `uncovered` is the cost of any other character of a class.
        \\pub const Cjk = struct {{
        \\    group: []const u8,
        \\    encodings: []const []const u8,
        \\    pairs: []const u8,
        \\    uncovered: [{d}]u8,
        \\    chars: []const u16,
        \\    costs: []const u8,
        \\}};
        \\
        \\
    , .{ o.unigram(), Cjk.count });

    var sb_out: Io.Writer.Allocating = .init(gpa);
    const s = &sb_out.writer;

    try w.writeAll("pub const groups = [_]Group{\n");
    var group_index: usize = 0;
    for (groups) |g| {
        if (g.cjk()) continue;
        const m = try singleByte(gpa, g, o);
        var note: Io.Writer.Allocating = .init(gpa);
        try note.writer.print("{s}: {s}\nclasses:", .{ g.name, try std.mem.join(gpa, ", ", g.langs) });
        for (m.members[classes.ascii_classes .. m.n - 1], classes.ascii_classes..) |list, c| {
            try note.writer.print(" {d}", .{c});
            if (list.len > 4) {
                try note.writer.print("({d}-rare)", .{list.len});
                continue;
            }
            try note.writer.writeAll("=");
            for (list) |cp| try note.writer.print("{u}", .{cp});
        }
        try writeComment(w, note.written());
        try w.print("    .{{ .name = \"{s}\", .classes = {d}, .case = .{{", .{ g.name, m.n });
        for (m.case) |c| try w.print(" {d},", .{c});
        try w.writeAll(" }, .langs = &.{\n");
        for (g.langs, m.freqs) |l, f| {
            try w.print(".{{ .tag = \"{s}\", .freq = &.{{\n", .{l});
            try writeBytes(w, f);
            try w.writeAll("} },\n");
        }
        try w.writeAll("}, .pairs = &.{\n");
        try writeBytes(w, m.pairs);
        try w.writeAll("} },\n");
        for (g.encodings, m.maps) |e, map| {
            try s.print("    .{{ .name = \"{s}\", .group = {d}, .map = .{{\n", .{ e, group_index });
            try writeBytes(s, &map);
            try s.writeAll("} },\n");
        }
        group_index += 1;
    }
    try w.writeAll("};\n\npub const single_byte = [_]SingleByte{\n");
    try w.writeAll(sb_out.written());
    try w.writeAll("};\n\npub const cjk = [_]Cjk{\n");
    for (groups) |g| {
        if (!g.cjk()) continue;
        const m = try cjkModel(gpa, g, o);
        try w.print("    .{{ .group = \"{s}\", .encodings = &.{{", .{g.name});
        for (g.encodings) |e| try w.print(" \"{s}\",", .{e});
        try w.writeAll(" }, .uncovered = .{");
        for (m.uncovered) |u| try w.print(" {d},", .{u});
        try w.writeAll(" }, .pairs = &.{\n");
        try writeBytes(w, m.pairs);
        try w.writeAll("}, .chars = &.{\n");
        for (m.chars, 0..) |c, i| {
            try w.print("0x{X:0>4},", .{c});
            try w.writeAll(if (i % 12 == 11) "\n" else " ");
        }
        try w.writeAll("\n}, .costs = &.{\n");
        try writeBytes(w, m.costs);
        try w.writeAll("} },\n");
    }
    try w.writeAll(
        \\};
        \\
        \\/// The languages trained, by tag, and their groups.
        \\pub const Language = struct { tag: []const u8, group: []const u8 };
        \\
        \\pub const languages = [_]Language{
        \\
    );
    const Lang = struct { tag: []const u8, group: []const u8 };
    var langs: std.ArrayList(Lang) = .empty;
    for (groups) |g| for (g.langs) |l| try langs.append(gpa, .{ .tag = l, .group = g.name });
    std.mem.sort(Lang, langs.items, {}, struct {
        fn lt(_: void, a: Lang, b: Lang) bool {
            return std.mem.lessThan(u8, a.tag, b.tag);
        }
    }.lt);
    for (langs.items) |l| try w.print("    .{{ .tag = \"{s}\", .group = \"{s}\" }},\n", .{ l.tag, l.group });
    try w.writeAll("};\n");
    return render(gpa, out.written());
}

/// `source` formatted as `zig fmt` formats it.
fn render(gpa: std.mem.Allocator, source: []const u8) ![]const u8 {
    const z = try gpa.dupeZ(u8, source);
    var tree = try std.zig.Ast.parse(gpa, z, .zig);
    if (tree.errors.len != 0) {
        std.debug.print("detect-train: generated code does not parse:\n{s}\n", .{source});
        return error.BadGeneratedCode;
    }
    return tree.renderAlloc(gpa);
}
