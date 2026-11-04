//! The compile-time decoder prototype's own build (docs/slop/comptime.md),
//! until the package's build.zig takes its files:
//!
//!     zig build test                  src/specialized_test.zig, Debug and ReleaseSafe
//!     zig build sizes -Doptimize=M    the link-size programs, into zig-out/bin/size-*
//!     zig build arms                  bench-comptime and bench-generic, for bench-compare
//!
//! Run from this directory. The package comes from this checkout.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run src/specialized_test.zig in Debug and ReleaseSafe");
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe }) |mode| {
        const t = b.addTest(.{
            .name = b.fmt("specialized-{t}", .{mode}),
            .root_module = prototype(b, "src/specialized_test.zig", target, mode),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // One program per variant, each reading stdin and writing stdout.
    const sizes = b.step("sizes", "Build the link-size programs");
    const strip = b.option(bool, "strip", "Strip the link-size programs (default: the mode's default)");
    const dispatch = b.option(bool, "dispatch", "Forwarded to the package's -Ddispatch (default: utf's)");
    for (std.enums.values(Variant)) |v| {
        const opts = b.addOptions();
        opts.addOption(Variant, "variant", v);
        const mod = b.createModule(.{
            .root_source_file = b.path("size.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        });
        mod.addOptions("options", opts);
        if (v != .none) mod.addImport("encoding", package(b, target, optimize, dispatch));
        const exe = b.addExecutable(.{ .name = b.fmt("size-{t}", .{v}), .root_module = mod });
        sizes.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    // The bench-compare arms: bench/zig/arm.zig's protocol over the
    // prototype's types. ReleaseFast for the host, as bench-zig is.
    const arms = b.step("arms", "Build bench-comptime and bench-generic");
    const testingx = b.dependency("testingx", .{ .target = target }).module("testingx");
    for (std.enums.values(Kind)) |kind| {
        const opts = b.addOptions();
        opts.addOption(Kind, "kind", kind);
        const mod = b.createModule(.{
            .root_source_file = b.path("arm.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "encoding", .module = package(b, target, .ReleaseFast, null) },
                .{ .name = "testingx", .module = testingx },
            },
        });
        mod.addOptions("options", opts);
        const name = switch (kind) {
            .comptime_set => "comptime",
            .generic => "generic",
        };
        const exe = b.addExecutable(.{ .name = b.fmt("bench-{s}", .{name}), .root_module = mod });
        arms.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
}

/// What an arm times (arm.zig).
pub const Kind = enum { comptime_set, generic };

pub const Variant = enum {
    /// Copies stdin to stdout: the baseline.
    none,
    /// Looks up the label in argv[1] and writes the encoding's name: the
    /// label table, which the `_label` variants link besides a codec.
    label,
    /// `Decoder.init(.windows_1252, .{})`, comptime-known, as
    /// link-size-20261102.md measured.
    rt_1252,
    /// `Decoder` for the label in argv[1].
    rt_label,
    /// `Encoder` for the label in argv[1].
    rt_enc_label,
    /// `DecoderFor(&.{.windows_1252})`, `.bom = .remove`.
    ct_1252,
    /// `DecoderFor(&(.{.windows_1252} ++ bom_encodings))`, `.sniff`.
    ct_1252_sniff,
    /// `DecoderFor(&.{.shift_jis})`.
    ct_sjis,
    /// `DecoderFor(&.{.gb18030})`.
    ct_gb18030,
    /// `DecoderFor(&.{.euc_kr})`.
    ct_euc_kr,
    /// `DecoderFor(&.{ .utf_8, .windows_1252 })` for the label in argv[1]:
    /// UTF-8 with a windows-1252 fallback, as a mail or subtitle reader
    /// has.
    ct_utf8_1252,
    /// `DecoderFor(&no_cjk)` for the label in argv[1].
    ct_nocjk_label,
    /// `DecoderFor(&implemented)` for the label in argv[1]: the runtime
    /// type, built from the generic.
    ct_all_label,
    /// `ct_all_label` and `ct_1252` in one program: whether the two share
    /// the single-byte family's code.
    both,
    /// `EncoderFor(&.{.windows_1252})`.
    ct_enc_1252,
    /// `EncoderFor(&.{.shift_jis})`.
    ct_enc_sjis,
};

/// The package's module, as a consumer gets it.
fn package(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dispatch: ?bool,
) *std.Build.Module {
    const dep = b.dependency("encoding", .{ .target = target, .optimize = optimize, .dispatch = dispatch });
    return dep.module("encoding");
}

/// A module rooted at one of the prototype's files under the package's
/// src/, with the package's utf.
fn prototype(
    b: *std.Build,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const dep = b.dependency("encoding", .{ .target = target, .optimize = optimize });
    const utf = dep.builder.dependency("utf", .{ .target = target, .optimize = optimize }).module("utf");
    return b.createModule(.{
        .root_source_file = dep.path(root),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "utf", .module = utf }},
    });
}
