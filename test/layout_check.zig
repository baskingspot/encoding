//! Checks a generated multi-byte table (`table`, from gen/layouts.zig in
//! some layout) against the index it came from (`index`), in full: every
//! pointer decodes to its code point and every other pointer to nothing,
//! and every code point encodes to the standard's index pointer. Run by
//! `zig build test-layouts` for each index and layout.

const std = @import("std");
const table = @import("table");
const options = @import("check_options");
const index_text = @embedFile("index");

const Entry = struct { pointer: u32, cp: u21 };

fn entries(gpa: std.mem.Allocator) ![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    var lines = std.mem.splitScalar(u8, index_text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const p = try std.fmt.parseInt(u32, fields.next().?, 10);
        const c = try std.fmt.parseInt(u21, fields.next().?, 0);
        try list.append(gpa, .{ .pointer = p, .cp = c });
    }
    return list.toOwnedSlice(gpa);
}

fn excluded(pointer: u32) bool {
    for (table.exclude) |r| {
        if (pointer >= r[0] and pointer <= r[1]) return true;
    }
    return false;
}

test "decode: every pointer" {
    if (!options.decode) return;
    const gpa = std.testing.allocator;
    const list = try entries(gpa);
    defer gpa.free(list);
    var end: u32 = 0;
    for (list) |e| end = @max(end, e.pointer + 1);
    const want = try gpa.alloc(?u21, end + 1000);
    defer gpa.free(want);
    @memset(want, null);
    for (list) |e| want[e.pointer] = e.cp;
    for (want, 0..) |w, p| try std.testing.expectEqual(w, table.decode(@intCast(p)));
}

test "encode: every code point" {
    if (!options.encode) return;
    const gpa = std.testing.allocator;
    const list = try entries(gpa);
    defer gpa.free(list);
    // The standard's index pointer for each code point: the first pointer
    // outside `exclude`, or the last for those in `last`.
    var want: std.AutoHashMapUnmanaged(u21, u16) = .empty;
    defer want.deinit(gpa);
    for (list) |e| {
        if (excluded(e.pointer)) continue;
        const gop = try want.getOrPut(gpa, e.cp);
        if (!gop.found_existing or std.mem.findScalar(u21, table.last, e.cp) != null) {
            gop.value_ptr.* = @intCast(e.pointer);
        }
    }
    var cp: u21 = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        try std.testing.expectEqual(want.get(cp), table.encode(cp));
    }
}
