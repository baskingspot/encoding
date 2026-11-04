//! The benchmark harness's Zig programs (bench/README.md), a build of its
//! own so the package's build and fetch graph never see them. The package's
//! arm is ReleaseFast for the host CPU unless `-Darm-optimize` and
//! `-Dcpu` say otherwise. The Rust, C, and Go arms are built by the
//! justfile with their own toolchains.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "arm-optimize",
        "The package's arm's optimize mode (default ReleaseFast)",
    ) orelse .ReleaseFast;
    const dispatch = b.option(bool, "dispatch", "Forwarded to the package's -Ddispatch (default: utf's)");
    const encoding_dep = b.dependency("encoding", .{ .target = target, .optimize = optimize, .dispatch = dispatch });
    const encoding = encoding_dep.module("encoding");
    const testingx = b.dependency("testingx", .{ .target = target }).module("testingx");
    const exe = b.addExecutable(.{
        .name = "bench-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/arm.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "encoding", .module = encoding },
                .{ .name = "testingx", .module = testingx },
            },
        }),
    });
    b.installArtifact(exe);
}
