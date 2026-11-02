//! What the generator builds, and from which vendored file: the registry
//! `just gen` reads. Adding an encoding adds one line here when it needs a
//! table (docs/slop/adding-an-encoding.md).

const index = @import("index.zig");
const Layout = @import("layouts.zig").Layout;

/// A single-byte encoding's table: the code points of bytes 0x80 to 0xFF.
/// Bytes below 0x80 are ASCII in every one.
pub const SingleByte = struct {
    /// The table's name in src/tables/single_byte.zig, an `Encoding` tag.
    name: []const u8,
    /// Under vendor/.
    file: []const u8,
    format: index.Format = .whatwg,
};

pub const single_byte = [_]SingleByte{
    .{ .name = "ibm866", .file = "whatwg-encoding/index-ibm866.txt" },
    .{ .name = "iso_8859_2", .file = "whatwg-encoding/index-iso-8859-2.txt" },
    .{ .name = "iso_8859_3", .file = "whatwg-encoding/index-iso-8859-3.txt" },
    .{ .name = "iso_8859_4", .file = "whatwg-encoding/index-iso-8859-4.txt" },
    .{ .name = "iso_8859_5", .file = "whatwg-encoding/index-iso-8859-5.txt" },
    .{ .name = "iso_8859_6", .file = "whatwg-encoding/index-iso-8859-6.txt" },
    .{ .name = "iso_8859_7", .file = "whatwg-encoding/index-iso-8859-7.txt" },
    .{ .name = "iso_8859_8", .file = "whatwg-encoding/index-iso-8859-8.txt" },
    .{ .name = "iso_8859_10", .file = "whatwg-encoding/index-iso-8859-10.txt" },
    .{ .name = "iso_8859_13", .file = "whatwg-encoding/index-iso-8859-13.txt" },
    .{ .name = "iso_8859_14", .file = "whatwg-encoding/index-iso-8859-14.txt" },
    .{ .name = "iso_8859_15", .file = "whatwg-encoding/index-iso-8859-15.txt" },
    .{ .name = "iso_8859_16", .file = "whatwg-encoding/index-iso-8859-16.txt" },
    .{ .name = "koi8_r", .file = "whatwg-encoding/index-koi8-r.txt" },
    .{ .name = "koi8_u", .file = "whatwg-encoding/index-koi8-u.txt" },
    .{ .name = "macintosh", .file = "whatwg-encoding/index-macintosh.txt" },
    .{ .name = "windows_874", .file = "whatwg-encoding/index-windows-874.txt" },
    .{ .name = "windows_1250", .file = "whatwg-encoding/index-windows-1250.txt" },
    .{ .name = "windows_1251", .file = "whatwg-encoding/index-windows-1251.txt" },
    .{ .name = "windows_1252", .file = "whatwg-encoding/index-windows-1252.txt" },
    .{ .name = "windows_1253", .file = "whatwg-encoding/index-windows-1253.txt" },
    .{ .name = "windows_1254", .file = "whatwg-encoding/index-windows-1254.txt" },
    .{ .name = "windows_1255", .file = "whatwg-encoding/index-windows-1255.txt" },
    .{ .name = "windows_1256", .file = "whatwg-encoding/index-windows-1256.txt" },
    .{ .name = "windows_1257", .file = "whatwg-encoding/index-windows-1257.txt" },
    .{ .name = "windows_1258", .file = "whatwg-encoding/index-windows-1258.txt" },
    .{ .name = "x_mac_cyrillic", .file = "whatwg-encoding/index-x-mac-cyrillic.txt" },
    // Outside the standard: IBM 437 and 850 from Unicode's vendor mappings.
    .{ .name = "ibm437", .file = "unicode/CP437.TXT", .format = .unicode },
    .{ .name = "ibm850", .file = "unicode/CP850.TXT", .format = .unicode },
};

/// A multi-byte index, generated into src/tables/<name>.zig with a
/// swappable layout (gen/layouts.zig). Every layout gives the file the
/// same functions, so a codec does not change when its table's layout
/// does: `decode(pointer) ?u21` and, unless `encode` is false,
/// `encode(cp) ?u16`, the standard's index pointer.
pub const MultiByte = struct {
    /// The generated file's name under src/tables/.
    name: []const u8,
    /// Under vendor/.
    file: []const u8,
    layout: Layout = .flat,
    /// Whether to generate `decode`. An encoder-only view of an index
    /// another entry decodes, such as Shift_JIS's view of jis0208, sets
    /// this false.
    decode: bool = true,
    /// Whether to generate `encode`.
    encode: bool = true,
    /// Pointer ranges, inclusive, that `encode` never returns: Shift_JIS's
    /// index pointer excludes 8272 to 8835, and Big5's every pointer below
    /// (0xA1 - 0x81) * 157.
    exclude: []const [2]u32 = &.{},
    /// Code points whose `encode` is the last pointer for them, not the
    /// first: Big5's U+2550, U+255E, U+2561, U+256A, U+5341, and U+5345.
    last: []const u21 = &.{},
};

/// The multi-byte tables committed under src/tables/. Wave 1 adds its own,
/// one line each, after measuring the layouts, such as
/// .{ .name = "jis0208", .file = "whatwg-encoding/index-jis0208.txt" },
pub const multi_byte: []const MultiByte = &.{
    .{ .name = "jis0208", .file = "whatwg-encoding/index-jis0208.txt", .layout = .japanese_paged },
    .{ .name = "jis0212", .file = "whatwg-encoding/index-jis0212.txt", .layout = .japanese_paged, .encode = false },
    .{
        .name = "iso_2022_jp_katakana",
        .file = "whatwg-encoding/index-iso-2022-jp-katakana.txt",
        .layout = .japanese_paged,
        .encode = false,
    },
    .{ .name = "gb18030", .file = "whatwg-encoding/index-gb18030.txt", .layout = .chinese_rank },
    .{
        .name = "big5",
        .file = "whatwg-encoding/index-big5.txt",
        .layout = .chinese_rank,
        .exclude = &.{.{ 0, (0xA1 - 0x81) * 157 - 1 }},
        .last = &.{ 0x2550, 0x255E, 0x2561, 0x256A, 0x5341, 0x5345 },
    },
    .{ .name = "euc_kr", .file = "whatwg-encoding/index-euc-kr.txt", .layout = .chinese_rank },
};

/// Every multi-byte index in the standard, for `zig build test-layouts`,
/// which generates each with every layout into the cache and checks it
/// against its index in full. Not committed tables: these exist so a
/// new layout is checked on every index before anyone picks it.
pub const layout_checks = [_]MultiByte{
    .{ .name = "jis0208", .file = "whatwg-encoding/index-jis0208.txt" },
    .{ .name = "jis0208_shift_jis", .file = "whatwg-encoding/index-jis0208.txt", .exclude = &.{.{ 8272, 8835 }} },
    .{ .name = "jis0212", .file = "whatwg-encoding/index-jis0212.txt", .encode = false },
    .{ .name = "iso_2022_jp_katakana", .file = "whatwg-encoding/index-iso-2022-jp-katakana.txt" },
    .{ .name = "gb18030", .file = "whatwg-encoding/index-gb18030.txt" },
    .{
        .name = "big5",
        .file = "whatwg-encoding/index-big5.txt",
        .exclude = &.{.{ 0, (0xA1 - 0x81) * 157 - 1 }},
        .last = &.{ 0x2550, 0x255E, 0x2561, 0x256A, 0x5341, 0x5345 },
    },
    .{ .name = "euc_kr", .file = "whatwg-encoding/index-euc-kr.txt" },
};
