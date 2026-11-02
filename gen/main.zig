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
//!     gen rodata BINARY...   how many bytes of each binary the generated
//!                            tables take: each array of each table is
//!                            searched for by its little-endian image
//!                            (`just bench-rodata`). encoding_rs lays out
//!                            its single-byte tables as this package does,
//!                            so they are found in its binary too; its
//!                            multi-byte tables are not.
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
    try outputs.append(gpa, .{ .path = "src/tables/gb18030_ranges.zig", .text = try gb18030Ranges(gpa, io) });
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
/// index gb18030 ranges, which maps gb18030's four-byte pointers to code
/// points a range at a time: each range's first pointer and code point,
/// the ranges below U+10000 as u16 arrays and the one above as constants.
fn gb18030Ranges(gpa: std.mem.Allocator, io: Io) ![]const u8 {
    const file = "whatwg-encoding/index-gb18030-ranges.txt";
    const entries = try index.parse(gpa, try readVendor(gpa, io, file), .whatwg);
    const bmp = entries[0 .. entries.len - 1];
    const top = entries[entries.len - 1];
    for (bmp, 0..) |e, i| {
        if (e.cp > 0xFFFF or e.pointer > 0xFFFF) return error.BadRangesIndex;
        if (i > 0 and (e.pointer <= bmp[i - 1].pointer or e.cp <= bmp[i - 1].cp)) return error.BadRangesIndex;
    }
    if (top.cp != 0x10000) return error.BadRangesIndex;
    const pointers = try gpa.alloc(u21, bmp.len);
    const cps = try gpa.alloc(u21, bmp.len);
    for (bmp, pointers, cps) |e, *p, *c| {
        p.* = @intCast(e.pointer);
        c.* = e.cp;
    }
    var out: Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    try w.print(
        \\//! Generated by `just gen` (gen/main.zig) from vendor/{s}.
        \\//! Do not edit.
        \\
        \\/// The first pointer of each range below U+10000, ascending.
        \\pub const pointers = [{d}]u16{{
        \\
    , .{ file, bmp.len });
    try layouts.writeHex(w, u21, pointers);
    try w.print("}};\n\n/// The code point of each of `pointers`.\npub const code_points = [{d}]u16{{\n", .{bmp.len});
    try layouts.writeHex(w, u21, cps);
    try w.print(
        \\}};
        \\
        \\/// The one range from U+10000: its first pointer, which is U+10000.
        \\pub const supplementary_pointer = {d};
        \\
    , .{top.pointer});
    return render(gpa, out.written());
}

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

/// One generated array as a little-endian binary holds it.
const Image = struct { file: []const u8, name: []const u8, bytes: []const u8 };

/// Arrays shorter than this match a binary by chance (the katakana table's
/// two-byte page index matches hundreds of times), so `rodata` skips them.
const min_image_len = 8;

/// The byte image of every array literal of integers in `source`, a
/// generated table file: `[N]u16{ ... }` and the like.
fn arrayImages(gpa: std.mem.Allocator, file: []const u8, source: []const u8, list: *std.ArrayList(Image)) !void {
    const tree = try std.zig.Ast.parse(gpa, try gpa.dupeZ(u8, source), .zig);
    for (tree.rootDecls()) |decl| {
        const var_decl = tree.fullVarDecl(decl) orelse continue;
        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const array = tree.fullArrayInit(&buf, init_node) orelse continue;
        const array_type = tree.fullArrayType(array.ast.type_expr.unwrap() orelse continue) orelse continue;
        const elem = tree.getNodeSource(array_type.ast.elem_type);
        const size: usize = for ([_][]const u8{ "u8", "u16", "u32", "u64" }, [_]usize{ 1, 2, 4, 8 }) |t, n| {
            if (std.mem.eql(u8, elem, t)) break n;
        } else continue;
        const bytes = try gpa.alloc(u8, size * array.ast.elements.len);
        for (array.ast.elements, 0..) |e, i| {
            const v = try std.fmt.parseInt(u64, tree.getNodeSource(e), 0);
            for (0..size) |k| bytes[i * size + k] = @truncate(v >> @intCast(8 * k));
        }
        try list.append(gpa, .{ .file = file, .name = tree.tokenSlice(var_decl.ast.mut_token + 1), .bytes = bytes });
    }
}

/// How many bytes of each binary the generated tables take: each array of
/// every table `gen write` writes, single-byte and multi-byte, searched for
/// by its byte image.
fn rodata(gpa: std.mem.Allocator, io: Io, paths: []const []const u8) !u8 {
    var images: std.ArrayList(Image) = .empty;
    try arrayImages(gpa, "single_byte.zig", try singleByte(gpa, io), &images);
    try arrayImages(gpa, "gb18030_ranges.zig", try gb18030Ranges(gpa, io), &images);
    for (sources.multi_byte) |src| {
        // ziglint-ignore: Z011 -- 0.16 has no Allocator.print
        const file = try std.fmt.allocPrint(gpa, "{s}.zig", .{src.name});
        try arrayImages(gpa, file, try multiByte(gpa, io, src, src.layout), &images);
    }
    for (paths) |path| {
        const bin = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        std.debug.print("{s}:\n", .{path});
        var total: usize = 0;
        var i: usize = 0;
        while (i < images.items.len) {
            // One line per table file.
            const file = images.items[i].file;
            var found: usize = 0;
            var arrays: usize = 0;
            var copies: usize = 0;
            var bytes: usize = 0;
            while (i < images.items.len and std.mem.eql(u8, images.items[i].file, file)) : (i += 1) {
                const image = images.items[i];
                if (image.bytes.len < min_image_len) {
                    std.debug.print("  {s} {s}: {d} bytes, too short to find, not counted\n", .{
                        file, image.name, image.bytes.len,
                    });
                    continue;
                }
                arrays += 1;
                var n: usize = 0;
                var at: usize = 0;
                while (std.mem.findPos(u8, bin, at, image.bytes)) |k| : (at = k + 1) n += 1;
                if (n > 0) found += 1;
                copies += n;
                bytes += n * image.bytes.len;
            }
            if (found == 0) continue;
            std.debug.print("  {s:<26} {d:>3} of {d:>3} arrays, {d:>3} copies, {d:>7} bytes\n", .{
                file, found, arrays, copies, bytes,
            });
            total += bytes;
        }
        std.debug.print("  {s:<26} {d:>7} bytes\n", .{ "total", total });
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
