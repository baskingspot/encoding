//! What detection's models and their trainer (gen/detect/train.zig) agree
//! on: the cost unit, the classes ASCII bytes take in every model, and the
//! classes of the characters a Chinese, Japanese, or Korean decoder writes.

/// Costs are in quarter bits: a cost of `n` is a probability of 2^(-n/4).
pub const units_per_bit = 4;

/// Every model's first three classes, the ASCII ones: ASCII letters, ASCII
/// bytes that are not letters (space, punctuation, digits, controls), and
/// those same bytes after a character outside ASCII, until the next letter
/// (`gap`). A pair of ASCII classes costs nothing in any model, but for a
/// gap followed by a letter: so markup and ASCII text away from the legacy
/// text weigh nothing, while the ASCII words next to it count.
pub const space = 0;
pub const letter = 1;
pub const gap = 2;
/// How many classes are ASCII.
pub const ascii_classes = 3;

/// The class of an ASCII byte or character after one of class `prev`.
pub fn asciiClass(b: u8, prev: u8) u8 {
    if ((b | 0x20) >= 'a' and (b | 0x20) <= 'z') return letter;
    return if (prev >= gap) gap else space;
}

/// Whether a pair of classes is free in every model.
pub fn free(prev: u8, cur: u8) bool {
    return cur < ascii_classes and prev < ascii_classes and !(prev == gap and cur == letter);
}

/// The classes of the characters a Chinese, Japanese, or Korean model
/// scores, after the two ASCII ones.
pub const Cjk = enum(u8) {
    space = space,
    letter = letter,
    gap = gap,
    hiragana,
    katakana,
    han,
    hangul,
    /// Ideographic punctuation and full-width forms.
    punct,
    /// Half-width katakana, which Shift_JIS writes as single bytes.
    halfwidth,
    /// Everything else outside ASCII: Latin, Greek, and Cyrillic letters,
    /// symbols, box drawing, Hangul jamo.
    other,
    /// Private use, which a decoder writes for user-defined characters.
    private,

    pub const count = @typeInfo(Cjk).@"enum".fields.len;

    /// Whether the models list this class's characters one by one rather
    /// than giving each the same cost.
    pub fn listed(c: Cjk) bool {
        return switch (c) {
            .hiragana, .katakana, .han, .hangul, .punct, .other => true,
            else => false,
        };
    }
};

/// The class of a character a decoder wrote, by UTF-16 code unit, after
/// one of class `prev`; a high surrogate stands for its supplementary
/// character, which is always Han (CJK extension B and on) in the encodings
/// detection scores.
pub fn cjkClass(u: u16, prev: Cjk) Cjk {
    if (u < 0x80) return @enumFromInt(asciiClass(@intCast(u), @intFromEnum(prev)));
    return switch (u) {
        0x3041...0x309F => .hiragana,
        0x30A0...0x30FF, 0x31F0...0x31FF => .katakana,
        0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xD800...0xDBFF => .han,
        0xAC00...0xD7A3 => .hangul,
        0x3000...0x303F, 0xFF01...0xFF60, 0xFFE0...0xFFEF => .punct,
        0xFF61...0xFF9F => .halfwidth,
        0xE000...0xF8FF => .private,
        else => .other,
    };
}
