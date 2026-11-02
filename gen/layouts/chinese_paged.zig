//! The chinese_paged layout, two-level both ways: the decode table pages
//! of 32 pointers, a byte each from a base code point where they fit and
//! identical pages shared; the encode table as chinese_rank's
//! (gen/layouts/chinese_parts.zig).

const std = @import("std");
const index = @import("../index.zig");
const parts = @import("chinese_parts.zig");
const MultiByte = @import("../sources.zig").MultiByte;

pub fn emit(w: *std.Io.Writer, gpa: std.mem.Allocator, src: MultiByte, entries: []const index.Entry) !void {
    try parts.emitDecodePaged(w, gpa, entries);
    try parts.emitDecodePub(w, src);
    if (src.encode) try parts.emitEncodeRank(w, gpa, src, entries);
}
