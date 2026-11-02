//! The chinese_hash layout: the decode table flat; the encode table a
//! perfect hash of the code points to slots holding their pointers,
//! checked by decoding the pointer (gen/layouts/chinese_parts.zig).

const std = @import("std");
const index = @import("../index.zig");
const parts = @import("chinese_parts.zig");
const MultiByte = @import("../sources.zig").MultiByte;

pub fn emit(w: *std.Io.Writer, gpa: std.mem.Allocator, src: MultiByte, entries: []const index.Entry) !void {
    try parts.emitDecodeFlat(w, gpa, entries);
    try parts.emitDecodePub(w, src);
    if (src.encode) try parts.emitEncodeHash(w, gpa, src, entries);
}
