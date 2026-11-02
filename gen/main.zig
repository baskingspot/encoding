//! The table generator: reads the vendored Encoding Standard data under
//! vendor/ and writes the Zig tables under src/tables/.
//!
//!     gen write              write every table (`just gen`)
//!     gen check              fail if a committed table differs from a
//!                            fresh one (`just gen-check`)
//!     gen layout NAME LAYOUT OUT
//!                            write the gen/sources.zig `layout_checks`
//!                            entry NAME in LAYOUT to OUT, for
//!                            `zig build test-layouts`
//!     gen rodata BINARY...   how many bytes of each binary the single-byte
//!                            tables take: each table is searched for as
//!                            128 little-endian u16 code points, the
//!                            layout both this package and encoding_rs
//!                            use (`just bench-rodata`)
//!
//! Run from the repository root. Output goes through `zig fmt`'s renderer,
//! so a fresh table is byte for byte what the formatter leaves.

const std = @import("std");
const Io = std.Io;
const index = @import("index.zig");
const layouts = @import("layouts.zig");
const sources = @import("sources.zig");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 2) return usage();
    const cwd = Io.Dir.cwd();
    if (std.mem.eql(u8, args[1], "layout")) {
        if (args.len != 5) return usage();
        const src = for (sources.layout_checks) |s| {
            if (std.mem.eql(u8, s.name, args[2])) break s;
        } else return error.UnknownIndex;
        const layout = std.meta.stringToEnum(layouts.Layout, args[3]) orelse return error.UnknownLayout;
        const text = try multiByte(gpa, io, src, layout);
        try cwd.writeFile(io, .{ .sub_path = args[4], .data = text });
        return 0;
    }
    if (std.mem.eql(u8, args[1], "rodata")) {
        if (args.len < 3) return usage();
        return rodata(gpa, io, args[2..]);
    }
    const write = std.mem.eql(u8, args[1], "write");
    if (!write and !std.mem.eql(u8, args[1], "check")) return usage();

    var outputs: std.ArrayList(struct { path: []const u8, text: []const u8 }) = .empty;
    try outputs.append(gpa, .{ .path = "src/tables/labels.zig", .text = try labelTable(gpa, io) });
    try outputs.append(gpa, .{ .path = "src/tables/single_byte.zig", .text = try singleByte(gpa, io) });
    for (sources.multi_byte) |src| {
        // ziglint-ignore: Z011 -- 0.16 has no Allocator.print
        const path = try std.fmt.allocPrint(gpa, "src/tables/{s}.zig", .{src.name});
        try outputs.append(gpa, .{ .path = path, .text = try multiByte(gpa, io, src, src.layout) });
    }
    var stale: usize = 0;
    for (outputs.items) |out| {
        if (write) {
            try cwd.writeFile(io, .{ .sub_path = out.path, .data = out.text });
            continue;
        }
        const old = cwd.readFileAlloc(io, out.path, gpa, .limited(64 << 20)) catch "";
        if (!std.mem.eql(u8, old, out.text)) {
            std.debug.print("gen: {s} differs from what `just gen` writes\n", .{out.path});
            stale += 1;
        }
    }
    return if (stale == 0) 0 else 1;
}

fn usage() u8 {
    std.debug.print("usage: gen write | gen check | gen layout NAME LAYOUT OUT | gen rodata BINARY...\n", .{});
    return 2;
}

fn readVendor(gpa: std.mem.Allocator, io: Io, file: []const u8) ![]const u8 {
    // ziglint-ignore: Z011 -- 0.16 has no Allocator.print
    const path = try std.fmt.allocPrint(gpa, "vendor/{s}", .{file});
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20)) catch |err| {
        std.debug.print("gen: read {s}: {t} (run from the repository root)\n", .{ path, err });
        return err;
    };
}

/// `source` formatted as `zig fmt` formats it.
fn render(gpa: std.mem.Allocator, source: []const u8) ![]const u8 {
    const z = try gpa.dupeZ(u8, source);
    var tree = try std.zig.Ast.parse(gpa, z, .zig);
    if (tree.errors.len != 0) {
        std.debug.print("gen: generated code does not parse:\n{s}\n", .{source});
        return error.BadGeneratedCode;
    }
    return tree.renderAlloc(gpa);
}

/// An `Encoding` tag from a name in encodings.json: `Shift_JIS` is
/// `shift_jis`, `ISO-8859-8-I` is `iso_8859_8_i`.
fn tagOf(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    const tag = try gpa.alloc(u8, name.len);
    for (name, tag) |c, *t| t.* = if (c == '-') '_' else std.ascii.toLower(c);
    return tag;
}

const Json = []const struct {
    heading: []const u8,
    encodings: []const struct { name: []const u8, labels: []const []const u8 },
};

fn labelTable(gpa: std.mem.Allocator, io: Io) ![]const u8 {
    const text = try readVendor(gpa, io, "whatwg-encoding/encodings.json");
    const groups = try std.json.parseFromSliceLeaky(Json, gpa, text, .{});
    const Label = struct { label: []const u8, tag: []const u8 };
    var list: std.ArrayList(Label) = .empty;
    var out: Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    try w.writeAll(
        \\//! Generated by `just gen` (gen/main.zig) from
        \\//! vendor/whatwg-encoding/encodings.json. Do not edit.
        \\
        \\const Encoding = @import("../encoding.zig").Encoding;
        \\
        \\pub const Name = struct { encoding: Encoding, name: []const u8 };
        \\pub const Label = struct { label: []const u8, encoding: Encoding };
        \\
        \\/// Each encoding's name, in the standard's order.
        \\pub const names = [_]Name{
        \\
    );
    var max_len: usize = 0;
    for (groups) |g| {
        for (g.encodings) |e| {
            const tag = try tagOf(gpa, e.name);
            try w.print("    .{{ .encoding = .{s}, .name = \"{s}\" }},\n", .{ tag, e.name });
            for (e.labels) |l| {
                try list.append(gpa, .{ .label = l, .tag = tag });
                max_len = @max(max_len, l.len);
            }
        }
    }
    std.mem.sort(Label, list.items, {}, struct {
        fn lt(_: void, a: Label, b: Label) bool {
            return std.mem.lessThan(u8, a.label, b.label);
        }
    }.lt);
    try w.writeAll("};\n\n/// Every label, sorted by its bytes.\npub const labels = [_]Label{\n");
    for (list.items, 0..) |l, i| {
        if (i > 0 and std.mem.eql(u8, l.label, list.items[i - 1].label)) return error.DuplicateLabel;
        try w.print("    .{{ .label = \"{s}\", .encoding = .{s} }},\n", .{ l.label, l.tag });
    }
    try w.print("}};\n\npub const max_label_len = {d};\n", .{max_len});
    return render(gpa, out.written());
}

fn singleByte(gpa: std.mem.Allocator, io: Io) ![]const u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    try w.writeAll(
        \\//! Generated by `just gen` (gen/main.zig) from the single-byte indexes
        \\//! under vendor/ (gen/sources.zig). Do not edit.
        \\//!
        \\//! Each table holds the code points of bytes 0x80 to 0xFF; 0 is a byte
        \\//! with none, an error to the decoder.
        \\
        \\
    );
    for (sources.single_byte) |sb| {
        const table = try singleByteTable(gpa, io, sb);
        try w.print("pub const {s} = [128]u16{{\n", .{sb.name});
        try layouts.writeHex(w, u21, &table);
        try w.writeAll("};\n\n");
    }
    return render(gpa, out.written());
}

/// The code points of bytes 0x80 to 0xFF, 0 for none.
fn singleByteTable(gpa: std.mem.Allocator, io: Io, sb: sources.SingleByte) ![128]u21 {
    const entries = try index.parse(gpa, try readVendor(gpa, io, sb.file), sb.format);
    var table: [128]u21 = @splat(0);
    for (entries) |e| {
        const p = if (sb.format == .unicode) blk: {
            // Unicode's vendor files list every byte; bytes below 0x80
            // must be ASCII, as the single-byte decoder assumes.
            if (e.pointer < 0x80) {
                if (e.cp != e.pointer) return error.NotAsciiCompatible;
                continue;
            }
            break :blk e.pointer - 0x80;
        } else e.pointer;
        if (p >= 128 or e.cp > 0xFFFF or e.cp == 0) return error.BadSingleByteEntry;
        table[p] = e.cp;
    }
    return table;
}

fn rodata(gpa: std.mem.Allocator, io: Io, paths: []const []const u8) !u8 {
    var images: [sources.single_byte.len][256]u8 = undefined;
    for (sources.single_byte, &images) |sb, *image| {
        const table = try singleByteTable(gpa, io, sb);
        for (table, 0..) |cp, i| std.mem.writeInt(u16, image[2 * i ..][0..2], @intCast(cp), .little);
    }
    for (paths) |path| {
        const bin = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        var found: usize = 0;
        var copies: usize = 0;
        for (sources.single_byte, &images) |sb, *image| {
            var n: usize = 0;
            var at: usize = 0;
            while (std.mem.findPos(u8, bin, at, image)) |i| : (at = i + 1) n += 1;
            if (n == 0) std.debug.print("gen: {s}: no {s} table\n", .{ path, sb.name });
            if (n > 0) found += 1;
            copies += n;
        }
        std.debug.print("{s}: {d} of {d} single-byte tables, {d} copies, {d} bytes\n", .{
            path, found, images.len, copies, copies * 256,
        });
    }
    return 0;
}

fn multiByte(gpa: std.mem.Allocator, io: Io, src: sources.MultiByte, layout: layouts.Layout) ![]const u8 {
    const entries = try index.parse(gpa, try readVendor(gpa, io, src.file), .whatwg);
    var out: Io.Writer.Allocating = .init(gpa);
    try layouts.emit(layout, &out.writer, gpa, src, entries);
    return render(gpa, out.written());
}

test {
    _ = index;
}
