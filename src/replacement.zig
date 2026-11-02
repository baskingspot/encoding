//! The replacement encoding's decoder: one error for a stream with any
//! bytes in it, and nothing else. Labels such as "iso-2022-kr" map to it,
//! so content in encodings the web removed decodes to a single U+FFFD.
//! It has no encoder; its output encoding is UTF-8.

const std = @import("std");
const codec = @import("codec.zig");
const Encoding = codec.Encoding;
const DecodeResult = codec.DecodeResult;

pub const encodings = [_]Encoding{.replacement};

pub const Decoder = struct {
    /// The standard's "replacement error returned".
    error_returned: bool = false,

    pub fn init(e: Encoding) Decoder {
        _ = e;
        return .{};
    }

    pub fn decode(
        d: *Decoder,
        comptime Unit: type,
        src: []const u8,
        dst: []Unit,
        last: bool,
        mode: codec.DecoderMode,
    ) DecodeResult {
        _ = last;
        if (src.len == 0 or d.error_returned) return .{ .status = .input_empty, .read = src.len, .written = 0 };
        if (mode == .fatal) {
            // The error is the first byte; the rest are read, and
            // ignored, by the calls that go on.
            d.error_returned = true;
            return .{ .status = .malformed, .read = 1, .written = 0 };
        }
        const n = codec.tryPut(Unit, dst, 0, codec.replacement_character) orelse
            return .{ .status = .output_full, .read = 0, .written = 0 };
        d.error_returned = true;
        return .{ .status = .input_empty, .read = src.len, .written = n };
    }

    pub fn maxLen(d: *const Decoder, comptime Unit: type, n: usize) ?usize {
        if (d.error_returned or n == 0) return 0;
        return if (Unit == u16) 1 else 3;
    }
};

test "one U+FFFD for the whole stream" {
    var d = Decoder.init(.replacement);
    var out: [8]u8 = undefined;
    try std.testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 0, .written = 0 },
        d.decode(u8, "", &out, false, .replacement),
    );
    try std.testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 3, .written = 3 },
        d.decode(u8, "abc", &out, false, .replacement),
    );
    try std.testing.expectEqual(
        DecodeResult{ .status = .input_empty, .read = 3, .written = 0 },
        d.decode(u8, "def", &out, true, .replacement),
    );
}
