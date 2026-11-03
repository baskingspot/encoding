//! The conveniences' and stream adapters' measurements
//! (docs/slop/results/io-*.md), a build of their own over the package in
//! this checkout. Run from this directory, or through `just bench-io` and
//! `just bench-io-sizes`:
//!
//!     zig build bench                 bench-io, ReleaseFast, into zig-out/bin
//!     zig build sizes -Doptimize=M    the link-size programs, into zig-out/bin/size-*

const std = @import("std");
const Variant = @import("size.zig").Variant;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bench = b.addExecutable(.{
        .name = "bench-io",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "encoding", .module = package(b, target, .ReleaseFast) }},
        }),
    });
    b.step("bench", "Build bench-io").dependOn(&b.addInstallArtifact(bench, .{}).step);

    const sizes = b.step("sizes", "Build the link-size programs");
    for (std.enums.values(Variant)) |v| {
        const opts = b.addOptions();
        opts.addOption(Variant, "variant", v);
        const mod = b.createModule(.{
            .root_source_file = b.path("size.zig"),
            .target = target,
            .optimize = optimize,
        });
        mod.addOptions("options", opts);
        if (v != .none) mod.addImport("encoding", package(b, target, optimize));
        const exe = b.addExecutable(.{ .name = b.fmt("size-{t}", .{v}), .root_module = mod });
        sizes.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
}

/// The package's module, as a consumer gets it.
fn package(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.dependency("encoding", .{ .target = target, .optimize = optimize }).module("encoding");
}
