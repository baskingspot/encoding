const std = @import("std");
const sources = @import("gen/sources.zig");
const layouts = @import("gen/layouts.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The one exported module. Everything below is a developer step, so a
    // consumer's fetch graph stops at this module and utf.
    const utf = b.dependency("utf", .{ .target = target, .optimize = optimize }).module("utf");
    const mod = b.addModule("encoding", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "utf", .module = utf }},
    });

    if (b.pkg_hash.len != 0) return;

    // Every step below needs testingx, which is lazy so a consumer never
    // fetches it. On the first configure pass it is not fetched yet, and the
    // build runner fetches it and reruns this script.
    const testingx_dep = b.lazyDependency("testingx", .{ .target = target }) orelse return;
    const runner: std.Build.Step.Compile.TestRunner = .{
        .path = testingx_dep.path("src/runner.zig"),
        .mode = .simple,
    };
    const seed = b.fmt("--seed=0x{x}", .{b.graph.random_seed});
    const test_step = b.step(
        "test",
        "Run the unit tests, the table checks against the indexes, and the streaming checks",
    );

    const mod_tests = b.addTest(.{ .root_module = mod, .test_runner = runner });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.addArg(seed);
    test_step.dependOn(&run_mod_tests.step);

    // Tests against the public module that read vendor/ at run time, from
    // the repository root.
    for ([_][]const u8{ "test/tables.zig", "test/stream.zig" }) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "encoding", .module = mod }},
            }),
            .test_runner = runner,
        });
        const run = b.addRunArtifact(t);
        run.setCwd(b.path("."));
        run.addArg(seed);
        test_step.dependOn(&run.step);
    }

    // The table generator (gen/main.zig) runs on the host.
    const host = b.graph.host;
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("gen/main.zig"),
        .target = host,
        .optimize = .ReleaseSafe,
    });
    const gen = b.addExecutable(.{ .name = "gen", .root_module = gen_mod });
    const gen_tests = b.addTest(.{ .root_module = gen_mod, .test_runner = runner });
    test_step.dependOn(&b.addRunArtifact(gen_tests).step);
    for ([_][2][]const u8{
        .{ "gen", "write" },
        .{ "gen-check", "check" },
    }) |s| {
        const run = b.addRunArtifact(gen);
        run.setCwd(b.path("."));
        run.addArg(s[1]);
        run.has_side_effects = true;
        const desc = if (std.mem.eql(u8, s[1], "write"))
            "Write the tables under src/tables/ from vendor/"
        else
            "Fail if a committed table differs from what `zig build gen` writes";
        b.step(s[0], desc).dependOn(&run.step);
    }

    // `zig build rodata -- BINARY...`: the generated tables' bytes in
    // each binary, for `just bench-rodata`.
    const rodata = b.addRunArtifact(gen);
    rodata.setCwd(b.path("."));
    rodata.addArg("rodata");
    if (b.args) |args| rodata.addArgs(args);
    b.step("rodata", "Count the generated tables' bytes in each binary given after --").dependOn(&rodata.step);

    // Every multi-byte index in every layout, generated into the cache and
    // checked against its index in full, both directions.
    const layouts_step = b.step(
        "test-layouts",
        "Generate every multi-byte index in every layout and check each against its index",
    );
    for (sources.layout_checks) |src| {
        for (std.enums.values(layouts.Layout)) |layout| {
            const run_gen = b.addRunArtifact(gen);
            run_gen.setCwd(b.path("."));
            run_gen.addArgs(&.{ "layout", src.name, @tagName(layout) });
            const table = run_gen.addOutputFileArg(b.fmt("{s}.zig", .{src.name}));
            const check_mod = b.createModule(.{
                .root_source_file = b.path("test/layout_check.zig"),
                .target = target,
                .optimize = optimize,
            });
            check_mod.addAnonymousImport("table", .{ .root_source_file = table });
            check_mod.addAnonymousImport("index", .{ .root_source_file = b.path(b.fmt("vendor/{s}", .{src.file})) });
            const opts = b.addOptions();
            opts.addOption(bool, "decode", src.decode);
            opts.addOption(bool, "encode", src.encode);
            check_mod.addOptions("check_options", opts);
            const t = b.addTest(.{
                .name = b.fmt("layout-{s}-{t}", .{ src.name, layout }),
                .root_module = check_mod,
                .test_runner = runner,
            });
            layouts_step.dependOn(&b.addRunArtifact(t).step);
        }
    }

    // The fuzz driver (test/fuzz/main.zig), for `just fuzz`, with the
    // properties the streaming tests check.
    const props = b.createModule(.{
        .root_source_file = b.path("test/props.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "encoding", .module = mod }},
    });
    const fuzz = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fuzz/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "encoding", .module = mod },
                .{ .name = "props", .module = props },
            },
        }),
    });
    b.step("fuzz", "Build the fuzz driver").dependOn(&b.addInstallArtifact(fuzz, .{}).step);

    // The encoding_rs differential (test/oracle/), for `just oracle`; the
    // Rust side is built by cargo.
    const oracle = b.addExecutable(.{
        .name = "oracle-compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/oracle/compare.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "encoding", .module = mod },
                .{ .name = "props", .module = props },
            },
        }),
    });
    b.step("oracle", "Build the encoding_rs differential driver").dependOn(&b.addInstallArtifact(oracle, .{}).step);

    // The package as WebAssembly, for the web-platform-tests harness
    // (test/wpt/), which runs it under Node.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm64, .os_tag = .freestanding });
    const wasm_utf = b.dependency("utf", .{ .target = wasm_target, .optimize = .ReleaseSafe }).module("utf");
    const wasm = b.addExecutable(.{
        .name = "encoding",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/wpt/wasm.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "encoding", .module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = wasm_target,
                .optimize = .ReleaseSafe,
                .imports = &.{.{ .name = "utf", .module = wasm_utf }},
            }) }},
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    b.step("wpt-wasm", "Build zig-out/bin/encoding.wasm for the web-platform-tests harness")
        .dependOn(&b.addInstallArtifact(wasm, .{}).step);
}
