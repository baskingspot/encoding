//! The streaming contract on every implemented encoding (test/props.zig):
//! the same output for any split of the input and any output buffer, both
//! outputs well-formed and in agreement, and the max-length functions
//! sufficient. Inputs are random from the test seed; `just fuzz` runs the
//! same checks for as long as it is given.

const std = @import("std");
const encoding = @import("encoding");
const props = @import("props.zig");

const testing = std.testing;

test "decoders: any split, any buffer, both outputs" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const rng = prng.random();
    for (encoding.implemented) |enc| {
        for (0..40) |_| {
            const src = try props.decoderInput(testing.allocator, rng, 300);
            defer testing.allocator.free(src);
            props.checkDecoder(testing.allocator, rng, enc, src, .{ .exhaustive = 24 }) catch |err| {
                std.debug.print("input ({d} bytes): {x}\n", .{ src.len, src });
                return err;
            };
        }
    }
}

test "encoders: any split, any buffer, UTF-8 and UTF-16 agree" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const rng = prng.random();
    for (encoding.implemented) |enc| {
        if (enc.outputEncoding() != enc) continue;
        for (0..40) |_| {
            const t = try props.encoderInput(testing.allocator, rng, 120);
            defer testing.allocator.free(t.utf8);
            defer testing.allocator.free(t.utf16);
            props.checkEncoder(testing.allocator, rng, enc, t.utf8, t.utf16, .{ .exhaustive = 24 }) catch |err| {
                std.debug.print("input: {x}\n", .{t.utf8});
                return err;
            };
        }
    }
}

test "every SIMD block boundary: one high byte at each position" {
    var buf: [200]u8 = undefined;
    const positions = [_][2]usize{ .{ 0, 20 }, .{ 28, 36 }, .{ 60, 68 }, .{ 124, 132 }, .{ 190, 200 } };
    for (encoding.implemented) |enc| {
        for (positions) |range| for (range[0]..range[1]) |at| {
            @memset(&buf, 'a');
            buf[at] = 0xE9;
            for ([_]usize{ 70, 129, 200 }) |len| {
                if (at >= len) continue;
                try props.checkDecoder(
                    testing.allocator,
                    undefined,
                    enc,
                    buf[0..len],
                    .{ .splits = 0, .exhaustive = 0 },
                );
            }
        };
    }
}
