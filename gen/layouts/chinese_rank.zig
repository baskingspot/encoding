//! The chinese_rank layout: the decode table flat; the encode table a bit
//! per code point in blocks of 64 and the pointers in code point order,
//! found by counting the bits below (gen/layouts/chinese_parts.zig).

const std = @import("std");
const index = @import("../index.zig");
const parts = @import("chinese_parts.zig");
const MultiByte = @import("../sources.zig").MultiByte;

pub fn emit(w: *std.Io.Writer, gpa: std.mem.Allocator, src: MultiByte, entries: []const index.Entry) !void {
    try parts.emitDecodeFlat(w, gpa, entries);
    try parts.emitDecodePub(w, src);
    if (src.encode) try parts.emitEncodeRank(w, gpa, src, entries);
}
