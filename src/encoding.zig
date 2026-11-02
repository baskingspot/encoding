//! `Encoding`: one value per encoding, the standard's label table, each
//! encoding's name, BOM sniffing, and output encodings.

const std = @import("std");
const labels = @import("tables/labels.zig");
const codecs = @import("codecs.zig");

/// An encoding: every encoding in the WHATWG Encoding Standard, in the
/// standard's order, then the IBM code pages outside it.
pub const Encoding = enum(u8) {
    utf_8,
    ibm866,
    iso_8859_2,
    iso_8859_3,
    iso_8859_4,
    iso_8859_5,
    iso_8859_6,
    iso_8859_7,
    iso_8859_8,
    iso_8859_8_i,
    iso_8859_10,
    iso_8859_13,
    iso_8859_14,
    iso_8859_15,
    iso_8859_16,
    koi8_r,
    koi8_u,
    macintosh,
    windows_874,
    windows_1250,
    windows_1251,
    windows_1252,
    windows_1253,
    windows_1254,
    windows_1255,
    windows_1256,
    windows_1257,
    windows_1258,
    x_mac_cyrillic,
    gbk,
    gb18030,
    big5,
    euc_jp,
    iso_2022_jp,
    shift_jis,
    euc_kr,
    replacement,
    utf_16be,
    utf_16le,
    x_user_defined,
    /// IBM code page 437, outside the standard: no label maps to it.
    ibm437,
    /// IBM code page 850, outside the standard: no label maps to it.
    ibm850,

    /// The encoding the standard's "get an encoding" gives `label`: leading
    /// and trailing ASCII whitespace removed, matched ASCII
    /// case-insensitively against the label table. Null when no label
    /// matches.
    pub fn forLabel(label: []const u8) ?Encoding {
        const trimmed = std.mem.trim(u8, label, "\t\n\x0c\r ");
        if (trimmed.len == 0 or trimmed.len > labels.max_label_len) return null;
        var buf: [labels.max_label_len]u8 = undefined;
        const key = std.ascii.lowerString(&buf, trimmed);
        var lo: usize = 0;
        var hi: usize = labels.labels.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, labels.labels[mid].label, key)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return labels.labels[mid].encoding,
            }
        }
        return null;
    }

    /// The encoding's name as the standard writes it, such as `"UTF-8"`,
    /// `"Shift_JIS"`, or `"windows-1252"`; `"IBM437"` and `"IBM850"` for
    /// the code pages outside it.
    pub fn name(e: Encoding) []const u8 {
        return name_table[@intFromEnum(e)];
    }

    /// The standard's "get an output encoding": UTF-8 for replacement,
    /// UTF-16BE, and UTF-16LE, which have no encoder; otherwise `e`.
    pub fn outputEncoding(e: Encoding) Encoding {
        return switch (e) {
            .replacement, .utf_16be, .utf_16le => .utf_8,
            else => e,
        };
    }

    /// Whether this version of the package implements `e`'s decoder and
    /// encoder. Every encoding will be; until then `Decoder.init` and
    /// `Encoder.init` panic on one that is not.
    pub fn isImplemented(e: Encoding) bool {
        return codecs.family_of[@intFromEnum(e)] != null;
    }

    /// A byte order mark and the encoding it names.
    pub const Bom = struct {
        encoding: Encoding,
        /// The mark's length in bytes: 3 for UTF-8, 2 for UTF-16.
        len: u2,
    };

    /// The standard's "BOM sniff": the encoding the byte order mark at the
    /// start of `bytes` names, or null. `bytes` needs at least three bytes
    /// to see a UTF-8 mark.
    pub fn forBom(bytes: []const u8) ?Bom {
        if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) return .{ .encoding = .utf_8, .len = 3 };
        if (std.mem.startsWith(u8, bytes, "\xFE\xFF")) return .{ .encoding = .utf_16be, .len = 2 };
        if (std.mem.startsWith(u8, bytes, "\xFF\xFE")) return .{ .encoding = .utf_16le, .len = 2 };
        return null;
    }
};

const name_table = blk: {
    const n = @typeInfo(Encoding).@"enum".fields.len;
    var t: [n][]const u8 = @splat("");
    for (labels.names) |entry| t[@intFromEnum(entry.encoding)] = entry.name;
    t[@intFromEnum(Encoding.ibm437)] = "IBM437";
    t[@intFromEnum(Encoding.ibm850)] = "IBM850";
    for (t, 0..) |s, i| {
        if (s.len == 0) @compileError("no name for " ++ @tagName(@as(Encoding, @enumFromInt(i))));
    }
    break :blk t;
};

const testing = std.testing;

test "forLabel trims ASCII whitespace and ignores ASCII case" {
    try testing.expectEqual(Encoding.windows_1252, Encoding.forLabel("latin1").?);
    try testing.expectEqual(Encoding.windows_1252, Encoding.forLabel(" \t\n\x0c\rLATIN1\r\n").?);
    try testing.expectEqual(Encoding.shift_jis, Encoding.forLabel("sjis").?);
    try testing.expectEqual(Encoding.utf_16le, Encoding.forLabel("utf-16").?);
    try testing.expectEqual(Encoding.replacement, Encoding.forLabel("iso-2022-kr").?);
    try testing.expectEqual(Encoding.utf_8, Encoding.forLabel("unicode-1-1-utf-8").?);
    // Not whitespace to the standard, and no Unicode case folding.
    try testing.expectEqual(@as(?Encoding, null), Encoding.forLabel("\x0blatin1"));
    try testing.expectEqual(@as(?Encoding, null), Encoding.forLabel("latin1\xc2\xa0"));
    try testing.expectEqual(@as(?Encoding, null), Encoding.forLabel("lat\xc4\xb1n1"));
    try testing.expectEqual(@as(?Encoding, null), Encoding.forLabel(""));
    try testing.expectEqual(@as(?Encoding, null), Encoding.forLabel("utf-7"));
    try testing.expectEqual(@as(?Encoding, null), Encoding.forLabel("ibm437"));
    try testing.expectEqual(@as(?Encoding, null), Encoding.forLabel("x" ** 64));
}

test "every label maps back to its encoding, and names are labels" {
    for (labels.labels) |l| try testing.expectEqual(l.encoding, Encoding.forLabel(l.label).?);
    for (labels.names) |n| try testing.expectEqual(n.encoding, Encoding.forLabel(n.name).?);
    try testing.expectEqualStrings("windows-1252", Encoding.windows_1252.name());
    try testing.expectEqualStrings("ISO-8859-8-I", Encoding.iso_8859_8_i.name());
    try testing.expectEqualStrings("IBM437", Encoding.ibm437.name());
}

test "forBom" {
    try testing.expectEqual(Encoding.Bom{ .encoding = .utf_8, .len = 3 }, Encoding.forBom("\xEF\xBB\xBFx").?);
    try testing.expectEqual(Encoding.Bom{ .encoding = .utf_16be, .len = 2 }, Encoding.forBom("\xFE\xFF").?);
    try testing.expectEqual(Encoding.Bom{ .encoding = .utf_16le, .len = 2 }, Encoding.forBom("\xFF\xFE\x00").?);
    try testing.expectEqual(@as(?Encoding.Bom, null), Encoding.forBom("\xEF\xBB"));
    try testing.expectEqual(@as(?Encoding.Bom, null), Encoding.forBom(""));
}

test "outputEncoding" {
    try testing.expectEqual(Encoding.utf_8, Encoding.utf_16be.outputEncoding());
    try testing.expectEqual(Encoding.utf_8, Encoding.replacement.outputEncoding());
    try testing.expectEqual(Encoding.gbk, Encoding.gbk.outputEncoding());
}
