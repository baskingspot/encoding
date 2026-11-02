//! The flat_runs layout: chinese_rank's flat decode table (a u16 per
//! pointer, with a bit per pointer for code points above U+FFFF), and its
//! rank encode table with runs (runs.zig).

const std = @import("std");
const index = @import("../index.zig");
const MultiByte = @import("../sources.zig").MultiByte;
const chinese_rank = @import("chinese_rank.zig");
const runs = @import("runs.zig");

pub fn emit(w: *std.Io.Writer, gpa: std.mem.Allocator, src: MultiByte, entries: []const index.Entry) !void {
    try chinese_rank.emitDecodeFlat(w, gpa, entries);
    if (src.decode) try w.writeAll("pub const decode = decodeIndex;\n\n");
    if (src.encode) try runs.emitEncode(w, gpa, src, entries);
}
