//! Charset detection: a guess at the encoding of bytes that came with no
//! label, as a browser makes for a legacy page.
//!
//!     var detector: Detector = .init();
//!     detector.feed(chunk); // as many times as the input takes
//!     const best = detector.guess(.{ .tld = "example.co.jp" });
//!     // best.encoding, best.confidence
//!
//! `Detector` scores every candidate encoding as the bytes arrive and keeps
//! no input, so it uses the same memory, and gives the same answer, however
//! the input is split. `guess` and `guesses` may be called at any point and
//! feeding may go on after them.
//!
//! The candidates are the encodings legacy web content was written in
//! without a label: UTF-8, Shift_JIS, EUC-JP, ISO-2022-JP, EUC-KR, Big5,
//! GBK, windows-874 and windows-1250 through windows-1258, ISO-8859-2, -4,
//! -5, -6, -7, -8 (visual Hebrew), and -13, KOI8-U, and IBM866. KOI8-R,
//! ISO-8859-8-I, and gb18030 come out as KOI8-U, windows-1255, and GBK,
//! which decode them the same but for a few symbols; ISO-8859-1 and
//! ISO-8859-15 come out as windows-1252. UTF-16 is detected by its byte
//! order mark, before detection (`Encoding.forBom`).
//!
//! UTF-8 is the guess when the bytes are valid UTF-8 with a character
//! outside ASCII, unless the hints forbid it, and ISO-2022-JP when they
//! are valid ISO-2022-JP with an escape to a Japanese character set.
//! Otherwise each candidate decodes the bytes and a model of the text its
//! languages are written in prices what comes out: the bits it takes to
//! say each character given the one before. A Chinese, Japanese, or Korean
//! candidate is out at its first malformed sequence. The cheapest candidate
//! is the guess; the confidence of each is its share of the probability
//! the costs give, so it is high when one candidate is far cheaper than
//! the next. A top-level domain or a declared language makes the encodings
//! of its languages cheaper, which decides short or ambiguous input.

const std = @import("std");
const native_endian = @import("builtin").cpu.arch.endian();
const Encoding = @import("encoding.zig").Encoding;
const coder = @import("coder.zig");
const classes = @import("detect/classes.zig");
const Cjk = classes.Cjk;

/// The detector, with the models trained from gen/detect/sources.tsv.
pub const Detector = DetectorWith(default_tables);
const default_tables = @import("detect/tables.zig");

/// A candidate encoding and how likely it is, from 0 to 1.
pub const Guess = struct {
    encoding: Encoding,
    confidence: f32,
};

/// What else is known about the bytes.
pub const Hints = struct {
    /// The top-level domain they came from, such as `"jp"`, or a host
    /// name, whose last label is taken. ASCII case-insensitive. A country
    /// code makes the encodings of its languages likelier; a generic domain
    /// such as `"com"` says nothing.
    tld: ?[]const u8 = null,
    /// A declared language, a BCP 47 tag such as `"ru"`, `"zh-TW"`, or
    /// `"sr-Latn"`, as `<html lang>` or Content-Language gives it. It
    /// makes the encodings of that language likelier.
    language: ?[]const u8 = null,
    /// Whether UTF-8 may be guessed. A browser that does not want pages to
    /// rely on detected UTF-8 turns it off.
    allow_utf8: bool = true,
};

/// The bits a hint takes off the cost of each encoding of its languages.
const hint_bits = 12;

/// What a CJK character cut off at the end of the input so far costs, in
/// bits: about what a common Han or Hangul character costs.
const pending_bits = 12;

/// The cost, in quarter bits, of choosing an encoding before seeing any
/// bytes: windows-1252 is the commonest legacy encoding, then the other
/// Windows code pages and the CJK encodings, then the ISO and DOS ones.
fn prior(e: Encoding) u32 {
    const bits: u32 = switch (e) {
        .windows_1252 => 0,
        .windows_1251, .gbk, .shift_jis, .euc_kr, .big5 => 1,
        .windows_1250, .windows_1253, .windows_1254, .windows_1255, .windows_1256, .windows_1257 => 2,
        .windows_874, .euc_jp, .utf_8 => 2,
        .iso_8859_2, .iso_8859_7, .koi8_u, .windows_1258 => 3,
        else => 4,
    };
    return bits * classes.units_per_bit;
}

/// A detector over the models in `tables`, a file `gen/detect/train.zig`
/// writes. For the scoring harness, which measures other models.
pub fn DetectorWith(comptime tables: type) type {
    @setEvalBranchQuota(100_000);
    const sb = tables.single_byte;
    const groups = tables.groups;

    // The decoders: UTF-8 and ISO-2022-JP, which are guessed by their
    // validity, then the scored CJK encodings with their models.
    const scored_cjk = [_]Encoding{ .shift_jis, .euc_jp, .euc_kr, .big5, .gbk };
    const decoded = [_]Encoding{ .utf_8, .iso_2022_jp } ++ scored_cjk;
    const Dec = coder.DecoderFor(&decoded);
    const cjk_model = blk: {
        var m: [scored_cjk.len]usize = undefined;
        for (scored_cjk, &m) |e, *mi| {
            mi.* = for (tables.cjk, 0..) |model, i| {
                if (for (model.encodings) |name| {
                    if (Encoding.forLabel(name).? == e) break true;
                } else false) break i;
            } else @compileError("no model for " ++ e.name());
        }
        break :blk m;
    };
    const sb_encodings = blk: {
        var es: [sb.len]Encoding = undefined;
        for (sb, &es) |s, *e| e.* = Encoding.forLabel(s.name).?;
        break :blk es;
    };
    // Each single-byte encoding's class and case for every code: a byte
    // from 0x80, or below it the class of an ASCII byte, which is the same
    // in every encoding.
    const maps = blk: {
        var m: [sb.len][256]u8 = undefined;
        for (sb, &m) |s, *map| {
            for (0..128) |b| map[b] = if (b < classes.ascii_classes) b else 0;
            for (0..128) |b| map[128 + b] = s.map[b];
        }
        break :blk m;
    };
    const n_scored = sb.len + scored_cjk.len;
    // Languages price only characters outside ASCII, which is why the
    // detector counts only bytes from 0x80.
    for (groups) |g| for (g.langs) |l| for (l.freq[0..classes.ascii_classes]) |f| {
        if (f != 0) @compileError("a language prices an ASCII class");
    };

    return struct {
        const Self = @This();

        /// The models, for the scoring harness.
        pub const model = tables;

        /// Every distinct encoding a guess can name.
        pub const candidates = blk: {
            @setEvalBranchQuota(100_000);
            var list: []const Encoding = &.{ .utf_8, .iso_2022_jp };
            for (scored_cjk ++ sb_encodings) |e| {
                if (std.mem.findScalar(Encoding, list, e) == null) list = list ++ .{e};
            }
            break :blk list[0..list.len].*;
        };

        /// The cost so far of each single-byte encoding, then each scored
        /// CJK one, in quarter bits: for a single-byte encoding, its
        /// group's pairs, to which each of the group's languages adds the
        /// cost of each class's characters, counted from `bytes`.
        costs: [n_scored]u64 = @splat(0),
        /// How many times each byte from 0x80 was fed.
        bytes: [128]u32 = @splat(0),
        decoders: [decoded.len]Dec,
        /// Whether each decoder has read no malformed sequence.
        alive: [decoded.len]bool = @splat(true),
        /// The class of the last character each scored CJK decoder wrote.
        prev: [scored_cjk.len]Cjk = @splat(.space),
        /// The code of the last byte fed (as in `maps`), for the pair it
        /// starts with the next.
        last: u8 = classes.space,
        /// Characters outside ASCII the UTF-8 and ISO-2022-JP decoders
        /// wrote.
        utf8_chars: u64 = 0,
        iso_2022_jp_chars: u64 = 0,

        pub fn init() Self {
            var d: Self = .{ .decoders = undefined };
            for (&d.decoders, decoded) |*dec, e| dec.* = .init(e, .{ .mode = .fatal, .bom = .keep });
            return d;
        }

        /// Scores the next bytes of the input.
        pub fn feed(d: *Self, chunk: []const u8) void {
            if (chunk.len == 0) return;
            d.feedSingleByte(chunk);
            inline for (0..decoded.len) |i| {
                if (d.alive[i]) d.feedDecoder(i, chunk);
            }
        }

        /// Scores the pairs of bytes that are not free (`classes.free`):
        /// those with a byte outside ASCII, and a gap with the letter
        /// after it.
        fn feedSingleByte(d: *Self, chunk: []const u8) void {
            var prev = d.last;
            var codes: [256]u8 = undefined;
            var i: usize = 0;
            while (i < chunk.len) {
                if (prev < classes.gap and chunk[i] < 0x80) {
                    const j = nextNonAscii(chunk, i);
                    if (j > i) prev = classes.asciiClass(chunk[j - 1], classes.space);
                    i = j;
                    if (i == chunk.len) break;
                }
                const before = prev;
                var n: usize = 0;
                while (i < chunk.len and n < codes.len) : (i += 1) {
                    const b = chunk[i];
                    if (b < 0x80 and prev < classes.gap) break;
                    if (b >= 0x80) d.bytes[b - 0x80] +%= 1;
                    const code = if (b >= 0x80) b else classes.asciiClass(b, prev);
                    codes[n] = code;
                    n += 1;
                    prev = code;
                }
                d.scoreCodes(before, codes[0..n]);
            }
            d.last = prev;
        }

        fn scoreCodes(d: *Self, prev: u8, codes: []const u8) void {
            inline for (0..sb.len) |c| {
                const g = groups[sb[c].group];
                const map = &maps[c];
                // ISO-8859-8 is visual: its text runs backwards.
                const visual = comptime sb_encodings[c] == .iso_8859_8;
                var p = map[prev];
                var cost: u64 = 0;
                for (codes) |code| {
                    const q = map[code];
                    if (!tables.unigram) cost += if (visual) pairCost(g, q, p) else pairCost(g, p, q);
                    p = q;
                }
                d.costs[c] += cost;
            }
        }

        inline fn pairCost(comptime g: tables.Group, p: u8, q: u8) u32 {
            const t: u32 = if (tables.unigram) g.pairs[q & 63] else g.pairs[@as(usize, p & 63) * g.classes + (q & 63)];
            return t + g.case[@as(usize, p >> 6) * 3 + (q >> 6)];
        }

        fn feedDecoder(d: *Self, comptime i: usize, chunk: []const u8) void {
            var buf: [256]u16 = undefined;
            var src = chunk;
            while (src.len > 0) {
                const r = d.decoders[i].decodeToUtf16(src, &buf, false);
                if (r.status == .malformed) {
                    d.alive[i] = false;
                    return;
                }
                const out = buf[0..r.written];
                switch (i) {
                    0 => d.utf8_chars += countNonAscii(out),
                    1 => d.iso_2022_jp_chars += countNonAscii(out),
                    else => d.scoreCjk(i - 2, out),
                }
                src = src[r.read..];
            }
        }

        fn scoreCjk(d: *Self, comptime j: usize, units: []const u16) void {
            const m = tables.cjk[cjk_model[j]];
            var prev = d.prev[j];
            var cost: u64 = 0;
            var k: usize = 0;
            while (k < units.len) : (k += 1) {
                const u = units[k];
                const c = classes.cjkClass(u, prev);
                if (classes.free(@intFromEnum(prev), @intFromEnum(c))) {
                    prev = c;
                    continue;
                }
                const pair = @as(usize, @intFromEnum(prev)) * Cjk.count + @intFromEnum(c);
                cost += m.pairs[if (tables.unigram) @intFromEnum(c) else pair];
                if (@intFromEnum(c) >= classes.ascii_classes) cost += charCost(m, u, c);
                // A high surrogate stands for its pair.
                if (u >= 0xD800 and u < 0xDC00) k += 1;
                prev = c;
            }
            d.prev[j] = prev;
            d.costs[sb.len + j] += cost;
        }

        fn charCost(comptime m: tables.Cjk, u: u16, c: Cjk) u32 {
            if (c.listed()) {
                var lo: usize = 0;
                var hi: usize = m.chars.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (m.chars[mid] < u) lo = mid + 1 else hi = mid;
                }
                if (lo < m.chars.len and m.chars[lo] == u) return m.costs[lo];
            }
            return m.uncovered[@intFromEnum(c)];
        }

        /// The most likely encoding.
        pub fn guess(d: *const Self, hints: Hints) Guess {
            var one: [1]Guess = undefined;
            return d.guesses(hints, &one)[0];
        }

        /// The candidates, most likely first, as many as fit in `out`
        /// (`candidates.len` is all of them), with their confidences, which
        /// add up to 1 over all of them. Encodings that cannot be the
        /// answer, such as a CJK encoding that met a malformed sequence,
        /// are left out. Never empty.
        pub fn guesses(d: *const Self, hints: Hints, out: []Guess) []Guess {
            std.debug.assert(out.len > 0);
            const hinted = Hinted.of(hints);
            const unit: f64 = classes.units_per_bit;
            // Each encoding's cost in bits: the probabilities of its
            // languages, each a share of it, added up; infinity for one
            // that cannot be the answer.
            const inf = std.math.inf(f64);
            var cost: [candidates.len]f64 = @splat(inf);
            const seen_bytes = bitmask(@as(@Vector(128, u32), d.bytes) != @as(@Vector(128, u32), @splat(0)));
            inline for (sb_encodings, 0..) |e, c| {
                const g = groups[sb[c].group];
                const at = comptime indexOf(e);
                const share = comptime std.math.log2(@as(f64, @floatFromInt(languagesOf(e))));
                const pairs = @as(f64, @floatFromInt(d.costs[c])) / unit;
                // How many characters of each class the encoding read, and
                // which classes it read: few, on short input.
                var counts: [64]u32 = @splat(0);
                var fed = seen_bytes;
                while (fed != 0) : (fed &= fed - 1) {
                    const k = @ctz(fed);
                    counts[maps[c][128 + k] & 63] +%= d.bytes[k];
                }
                const seen = bitmask(@as(@Vector(64, u32), counts) != @as(@Vector(64, u32), @splat(0)));
                var lang_cost: [g.langs.len]f64 = undefined;
                var best: f64 = inf;
                for (g.langs, &lang_cost) |l, *lc| {
                    var sum: i64 = 0;
                    var bits = seen & if (l.freq.len < 64) (@as(u64, 1) << @intCast(l.freq.len)) - 1 else ~@as(u64, 0);
                    while (bits != 0) : (bits &= bits - 1) {
                        const k = @ctz(bits);
                        sum += @as(i64, l.freq[k]) * counts[k];
                    }
                    const bonus: f64 = @floatFromInt(hint_bits * hinted.count(l.tag, sb[c].group));
                    lc.* = pairs + @as(f64, @floatFromInt(sum)) / unit + share - bonus;
                    best = @min(best, lc.*);
                }
                // Add up the languages' probabilities, leaving out those
                // too unlikely to change the sum.
                var total: f64 = 0;
                for (lang_cost) |lc| {
                    if (lc - best < 40) total += std.math.exp2(best - lc);
                }
                cost[at] = addProbabilities(cost[at], best - std.math.log2(total));
            }
            inline for (scored_cjk, 0..) |e, j| {
                if (d.alive[2 + j]) {
                    const bonus: f64 = @floatFromInt(hint_bits * hinted.count(null, groups.len + cjk_model[j]));
                    // A character the input so far cuts off is not scored
                    // yet, though the single-byte candidates scored its
                    // bytes: charge it about what a common one costs.
                    var probe = d.decoders[2 + j];
                    var buf: [4]u16 = undefined;
                    const cut_off = probe.decodeToUtf16(&.{}, &buf, true).status == .malformed;
                    const cut: f64 = if (cut_off) pending_bits else 0;
                    cost[comptime indexOf(e)] = @as(f64, @floatFromInt(d.costs[sb.len + j])) / unit - bonus + cut;
                }
            }
            const iso = comptime indexOf(.iso_2022_jp);
            const utf8 = comptime indexOf(.utf_8);
            cost[iso] = 0;
            cost[utf8] = 0;
            for (&cost, candidates) |*c, e| c.* += @as(f64, @floatFromInt(prior(e))) / unit;
            // Valid UTF-8 and ISO-2022-JP with characters outside ASCII
            // win outright; with none, they cost what ASCII costs
            // everywhere else: nothing but the prior.
            var best = inf;
            for (cost) |c| best = @min(best, c);
            const sure = 64;
            if (d.alive[1]) cost[iso] = if (d.iso_2022_jp_chars > 0) best - sure else cost[iso];
            if (!d.alive[0] or !hints.allow_utf8) cost[utf8] = inf else if (d.utf8_chars > 0) cost[utf8] = best - sure;
            if (!d.alive[1]) cost[iso] = inf;

            // Rank, and turn the costs into probabilities.
            var order: [candidates.len]usize = undefined;
            var n: usize = 0;
            for (cost, 0..) |c, i| if (c != inf) {
                order[n] = i;
                n += 1;
            };
            std.mem.sort(usize, order[0..n], &cost, struct {
                fn lt(cs: *const [candidates.len]f64, a: usize, b: usize) bool {
                    if (cs[a] != cs[b]) return cs[a] < cs[b];
                    return a < b;
                }
            }.lt);
            const min = cost[order[0]];
            var p: [candidates.len]f64 = undefined;
            var total: f64 = 0;
            for (p[0..n], order[0..n]) |*pi, i| {
                pi.* = std.math.exp2(min - cost[i]);
                total += pi.*;
            }
            const m = @min(n, out.len);
            for (out[0..m], p[0..m], order[0..m]) |*g, pi, i| g.* = .{
                .encoding = candidates[i],
                .confidence = @floatCast(pi / total),
            };
            return out[0..m];
        }

        /// The cost of either of two events, from their costs, in bits.
        fn addProbabilities(a: f64, b: f64) f64 {
            const lo = @min(a, b);
            if (@max(a, b) == std.math.inf(f64)) return lo;
            return lo - std.math.log2(1 + std.math.exp2(lo - @max(a, b)));
        }

        /// How many languages a single-byte encoding's models cover.
        fn languagesOf(e: Encoding) usize {
            @setEvalBranchQuota(100_000);
            var n: usize = 0;
            for (sb, sb_encodings) |s, se| {
                if (se == e) n += groups[s.group].langs.len;
            }
            return n;
        }

        fn indexOf(e: Encoding) usize {
            @setEvalBranchQuota(100_000);
            return std.mem.findScalar(Encoding, &candidates, e).?;
        }

        /// The languages and groups (single-byte, then CJK models) the
        /// hints point to: a language trained on by its tag, any other by
        /// its group.
        const Hinted = struct {
            tags: [2]?[]const u8 = @splat(null),
            groups: std.StaticBitSet(groups.len + tables.cjk.len) = .initEmpty(),

            fn of(hints: Hints) Hinted {
                var h: Hinted = .{};
                if (hints.tld) |t| {
                    const label = if (std.mem.findScalarLast(u8, t, '.')) |dot| t[dot + 1 ..] else t;
                    for (tld_languages) |pair| {
                        if (std.ascii.eqlIgnoreCase(pair[0], label)) {
                            h.add(0, pair[1]);
                            break;
                        }
                    }
                }
                if (hints.language) |l| h.add(1, languageKey(l));
                return h;
            }

            fn add(h: *Hinted, i: usize, key: []const u8) void {
                const g = groupOf(key) orelse return;
                const trained = for (tables.languages) |l| {
                    if (std.ascii.eqlIgnoreCase(l.tag, key)) break true;
                } else false;
                if (trained and g < groups.len) h.tags[i] = key else h.groups.set(g);
            }

            /// How many hints point to a language of a group.
            fn count(h: Hinted, tag: ?[]const u8, group: usize) i64 {
                var n: i64 = @intFromBool(h.groups.isSet(group));
                if (tag) |t| for (h.tags) |ht| {
                    if (ht) |x| n += @intFromBool(std.ascii.eqlIgnoreCase(x, t));
                };
                return n;
            }
        };

        /// The index of the group a language tag's language is written in.
        fn groupOf(tag: []const u8) ?usize {
            const name = for (tables.languages) |l| {
                if (std.ascii.eqlIgnoreCase(l.tag, tag)) break l.group;
            } else for (language_aliases) |a| {
                if (std.ascii.eqlIgnoreCase(a[0], tag)) break a[1];
            } else return null;
            for (groups, 0..) |g, i| if (std.mem.eql(u8, g.name, name)) return i;
            for (tables.cjk, 0..) |m, i| if (std.mem.eql(u8, m.group, name)) return groups.len + i;
            return null;
        }
    };
}

/// The key a BCP 47 tag's language has in the tables: its primary subtag,
/// but "zh-hans" or "zh-hant" for Chinese and "sr-latn" for Serbian in
/// Latin script.
fn languageKey(tag: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, tag, "-_");
    const primary = it.next() orelse return "";
    var traditional = false;
    var latin = false;
    while (it.next()) |sub| {
        for ([_][]const u8{ "hant", "tw", "hk", "mo" }) |t| {
            traditional = traditional or std.ascii.eqlIgnoreCase(sub, t);
        }
        latin = latin or std.ascii.eqlIgnoreCase(sub, "latn");
    }
    if (std.ascii.eqlIgnoreCase(primary, "zh")) return if (traditional) "zh-hant" else "zh-hans";
    if (std.ascii.eqlIgnoreCase(primary, "sr") and latin) return "sr-latn";
    return primary;
}

/// Languages outside the corpus, and old or other tags of languages in it,
/// with the group they are written in.
const language_aliases = [_][2][]const u8{
    .{ "nb", "western" },      .{ "nn", "western" }, .{ "ms", "western" }, .{ "sw", "western" },
    .{ "tl", "western" },      .{ "fy", "western" }, .{ "rm", "western" }, .{ "la", "western" },
    .{ "co", "western" },      .{ "wa", "western" }, .{ "ht", "western" }, .{ "an", "western" },
    .{ "ast", "western" },     .{ "li", "western" }, .{ "cy", "western" }, .{ "in", "western" },
    .{ "iw", "hebrew" },       .{ "ji", "hebrew" },  .{ "sh", "central" }, .{ "mo", "central" },
    .{ "sr-latn", "central" },
};

/// Country-code top-level domains and the language their legacy pages
/// were most likely written in.
const tld_languages = [_][2][]const u8{
    .{ "ad", "ca" },      .{ "ae", "ar" },      .{ "al", "sq" },      .{ "ar", "es" },
    .{ "at", "de" },      .{ "au", "en" },      .{ "az", "az" },      .{ "ba", "bs" },
    .{ "be", "nl" },      .{ "bg", "bg" },      .{ "bh", "ar" },      .{ "bo", "es" },
    .{ "br", "pt" },      .{ "by", "be" },      .{ "ca", "en" },      .{ "cat", "ca" },
    .{ "ch", "de" },      .{ "cl", "es" },      .{ "cn", "zh-hans" }, .{ "co", "es" },
    .{ "cr", "es" },      .{ "cu", "es" },      .{ "cy", "el" },      .{ "cz", "cs" },
    .{ "de", "de" },      .{ "dk", "da" },      .{ "do", "es" },      .{ "dz", "ar" },
    .{ "ec", "es" },      .{ "ee", "et" },      .{ "eg", "ar" },      .{ "es", "es" },
    .{ "fi", "fi" },      .{ "fo", "fo" },      .{ "fr", "fr" },      .{ "gr", "el" },
    .{ "gt", "es" },      .{ "hk", "zh-hant" }, .{ "hn", "es" },      .{ "hr", "hr" },
    .{ "hu", "hu" },      .{ "id", "id" },      .{ "ie", "en" },      .{ "il", "he" },
    .{ "iq", "ar" },      .{ "ir", "fa" },      .{ "is", "is" },      .{ "it", "it" },
    .{ "jo", "ar" },      .{ "jp", "ja" },      .{ "kg", "ru" },      .{ "kr", "ko" },
    .{ "kw", "ar" },      .{ "kz", "ru" },      .{ "lb", "ar" },      .{ "li", "de" },
    .{ "lt", "lt" },      .{ "lu", "lb" },      .{ "lv", "lv" },      .{ "ly", "ar" },
    .{ "ma", "ar" },      .{ "md", "ro" },      .{ "me", "sr-latn" }, .{ "mk", "mk" },
    .{ "mo", "zh-hant" }, .{ "mx", "es" },      .{ "ni", "es" },      .{ "nl", "nl" },
    .{ "no", "no" },      .{ "nz", "en" },      .{ "om", "ar" },      .{ "pa", "es" },
    .{ "pe", "es" },      .{ "pk", "ur" },      .{ "pl", "pl" },      .{ "pr", "es" },
    .{ "ps", "ar" },      .{ "pt", "pt" },      .{ "py", "es" },      .{ "qa", "ar" },
    .{ "ro", "ro" },      .{ "rs", "sr" },      .{ "ru", "ru" },      .{ "sa", "ar" },
    .{ "sd", "ar" },      .{ "se", "sv" },      .{ "si", "sl" },      .{ "sk", "sk" },
    .{ "su", "ru" },      .{ "sv", "es" },      .{ "sy", "ar" },      .{ "th", "th" },
    .{ "tn", "ar" },      .{ "tr", "tr" },      .{ "tw", "zh-hant" }, .{ "ua", "uk" },
    .{ "uk", "en" },      .{ "us", "en" },      .{ "uy", "es" },      .{ "ve", "es" },
    .{ "vn", "vi" },      .{ "ye", "ar" },
};

/// The index of the first byte outside ASCII at or after `i`, or
/// `s.len`.
fn nextNonAscii(s: []const u8, start: usize) usize {
    const V = @Vector(16, u8);
    var i = start;
    while (i + 16 <= s.len) : (i += 16) {
        const v: V = s[i..][0..16].*;
        const mask = bitmask(v >= @as(V, @splat(0x80)));
        if (mask != 0) return i + @ctz(mask);
    }
    while (i < s.len and s[i] < 0x80) i += 1;
    return i;
}

/// A bit for each lane of `v`, lane 0 the lowest, on either byte order: a
/// vector of bools bitcasts with lane 0 the highest bit on big-endian.
fn bitmask(v: anytype) @Int(.unsigned, @typeInfo(@TypeOf(v)).vector.len) {
    const m: @Int(.unsigned, @typeInfo(@TypeOf(v)).vector.len) = @bitCast(v);
    return if (native_endian == .big) @bitReverse(m) else m;
}

fn countNonAscii(units: []const u16) u64 {
    var n: u64 = 0;
    for (units) |u| n += @intFromBool(u >= 0x80);
    return n;
}

const testing = std.testing;

/// `text` encoded in `e`, into `buf`.
fn encodeForTest(comptime e: Encoding, text: []const u8, buf: []u8) []const u8 {
    var enc: coder.EncoderFor(&.{e}) = .init(e, .{});
    const r = enc.encodeFromUtf8(text, buf, true);
    std.debug.assert(r.status == .input_empty);
    return buf[0..r.written];
}

test "a sentence or two in each family's encodings" {
    const cases = [_]struct { Encoding, []const u8 }{
        .{ .windows_1252, "Le cœur a ses raisons que la raison ne connaît point, déjà à l'été." },
        .{ .windows_1250, "Zażółć gęślą jaźń, ale przede wszystkim śpiewać trzeba głośno." },
        .{ .iso_8859_2, "Zażółć gęślą jaźń, ale przede wszystkim śpiewać trzeba głośno." },
        .{ .windows_1251, "Съешь же ещё этих мягких булок, да выпей чаю." },
        .{ .koi8_u, "Съешь же ещё этих мягких булок, да выпей чаю." },
        .{ .ibm866, "Съешь же ещё этих мягких булок, да выпей чаю." },
        .{ .windows_1253, "Η γρήγορη καφέ αλεπού πηδάει πάνω από το σκυλί." },
        .{ .windows_1255, "דג סקרן שט בים מאוכזב ולפתע מצא חברה נחמדה מאוד." },
        .{ .windows_1256, "نص حكيم له سر قاطع وذو شأن عظيم مكتوب." },
        .{ .windows_1254, "Pijamalı hasta yağız şoföre çabucak güvendi, öyle mi?" },
        .{ .windows_874, "ภาษาไทยเป็นภาษาราชการ" },
        .{ .shift_jis, "いろはにほへと　ちりぬるを、日本語の文章です。" },
        .{ .euc_jp, "いろはにほへと　ちりぬるを、日本語の文章です。" },
        .{ .iso_2022_jp, "いろはにほへと　ちりぬるを、日本語の文章です。" },
        .{ .euc_kr, "다람쥐 헌 쳇바퀴에 타고파. 한국어 문장입니다." },
        .{ .gbk, "我能吞下玻璃而不伤身体，这是简体中文的句子。" },
        .{ .big5, "我能吞下玻璃而不傷身體，這是繁體中文的句子。" },
    };
    inline for (cases) |case| {
        var buf: [256]u8 = undefined;
        const bytes = encodeForTest(case[0], case[1], &buf);
        var d: Detector = .init();
        d.feed(bytes);
        const g = d.guess(.{});
        testing.expectEqual(case[0], g.encoding) catch |err| {
            std.debug.print("{s}: {s} {d}\n", .{ case[0].name(), g.encoding.name(), g.confidence });
            return err;
        };
    }
}

test "ASCII is windows-1252, or what the hints point to" {
    var d: Detector = .init();
    try testing.expectEqual(Encoding.windows_1252, d.guess(.{}).encoding);
    d.feed("Plain ASCII says nothing about its encoding.");
    try testing.expectEqual(Encoding.windows_1252, d.guess(.{}).encoding);
    try testing.expectEqual(Encoding.windows_1252, d.guess(.{ .tld = "com" }).encoding);
    try testing.expectEqual(Encoding.shift_jis, d.guess(.{ .tld = "www.example.CO.JP" }).encoding);
    try testing.expectEqual(Encoding.windows_1251, d.guess(.{ .tld = "ru" }).encoding);
    try testing.expectEqual(Encoding.big5, d.guess(.{ .language = "zh-TW" }).encoding);
    try testing.expectEqual(Encoding.gbk, d.guess(.{ .language = "zh" }).encoding);
    try testing.expectEqual(Encoding.windows_1250, d.guess(.{ .language = "sr-Latn" }).encoding);
}

test "UTF-8 wins when allowed" {
    var d: Detector = .init();
    d.feed("Съешь же ещё этих мягких французских булок");
    try testing.expectEqual(Encoding.utf_8, d.guess(.{}).encoding);
    var out: [Detector.candidates.len]Guess = undefined;
    for (d.guesses(.{ .allow_utf8 = false }, &out)) |g| try testing.expect(g.encoding != .utf_8);
}

test "the same guesses however the input is split" {
    var buf: [512]u8 = undefined;
    const bytes = encodeForTest(.shift_jis, "Mixed text: 日本語の文章、and some English with café.", &buf);
    var whole: Detector = .init();
    whole.feed(bytes);
    var want: [Detector.candidates.len]Guess = undefined;
    const w = whole.guesses(.{}, &want);
    for (1..bytes.len) |cut| {
        var d: Detector = .init();
        d.feed(bytes[0..cut]);
        _ = d.guess(.{});
        d.feed(bytes[cut..]);
        var got: [Detector.candidates.len]Guess = undefined;
        try testing.expectEqualSlices(Guess, w, d.guesses(.{}, &got));
    }
    var d: Detector = .init();
    for (bytes) |b| d.feed(&.{b});
    var got: [Detector.candidates.len]Guess = undefined;
    try testing.expectEqualSlices(Guess, w, d.guesses(.{}, &got));
}
