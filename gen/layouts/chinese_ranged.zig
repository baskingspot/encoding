//! The chinese_ranged layout: runs of pointers whose code points go up by
//! one each stored as a start, the rest flat, found by bisection; the
//! encode table the same in reverse (gen/layouts/chinese_parts.zig).

const std = @import("std");
const index = @import("../index.zig");
const parts = @import("chinese_parts.zig");
const MultiByte = @import("../sources.zig").MultiByte;

pub fn emit(w: *std.Io.Writer, gpa: std.mem.Allocator, src: MultiByte, entries: []const index.Entry) !void {
    try parts.emitDecodeRanged(w, gpa, entries);
    try parts.emitDecodePub(w, src);
    if (src.encode) try parts.emitEncodeRanged(w, gpa, src, entries);
}
