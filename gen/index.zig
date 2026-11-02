//! Reads the two table formats the generator takes: the Encoding
//! Standard's index files (`index-*.txt`: a pointer, a tab, and a code
//! point in hex on each line) and Unicode's vendor mapping files
//! (`0x80<TAB>0x00C7<TAB>#...`, for the IBM code pages, which the standard
//! does not cover).

const std = @import("std");

pub const Entry = struct {
    pointer: u32,
    cp: u21,
};

pub const Format = enum {
    /// The standard's `index-*.txt`.
    whatwg,
    /// Unicode's `MAPPINGS/VENDORS/*.TXT`: byte, code point, comment.
    /// Bytes without a code point are skipped.
    unicode,
};

/// The entries of an index file, in file order. Comments and blank lines
/// are skipped.
pub fn parse(gpa: std.mem.Allocator, text: []const u8, format: Format) ![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const p = fields.next() orelse return error.BadIndexLine;
        const c = fields.next() orelse continue;
        if (c[0] == '#') continue;
        const pointer = switch (format) {
            .whatwg => try std.fmt.parseInt(u32, p, 10),
            .unicode => try std.fmt.parseInt(u32, p, 0),
        };
        const cp = try std.fmt.parseInt(u21, c, 0);
        try list.append(gpa, .{ .pointer = pointer, .cp = cp });
    }
    return list.toOwnedSlice(gpa);
}

test parse {
    const text = "# comment\n\n  0\t0x2500\t\u{2500} (BOX DRAWINGS LIGHT HORIZONTAL)\n127\t0x00A0\t (NO-BREAK SPACE)\n";
    const entries = try parse(std.testing.allocator, text, .whatwg);
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqualSlices(
        Entry,
        &.{ .{ .pointer = 0, .cp = 0x2500 }, .{ .pointer = 127, .cp = 0xA0 } },
        entries,
    );
    const vendor = try parse(std.testing.allocator, "0x80\t0x00c7\t#LATIN\n0x81\t\t#UNDEFINED\n", .unicode);
    defer std.testing.allocator.free(vendor);
    try std.testing.expectEqualSlices(Entry, &.{.{ .pointer = 0x80, .cp = 0xC7 }}, vendor);
}
