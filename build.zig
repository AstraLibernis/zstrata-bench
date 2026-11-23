// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");

/// Compute shaders in shaders/<name>.comp; each is importable as "<name>.spv".
const shaders = [_][]const u8{ "s5_distances", "s6_matmul", "m3_trees", "m4_dense", "m6_adam" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zstrata is used as a library: its thread pool is the one every threaded variant runs on,
    // and its Vulkan layer is the one every GPU variant runs on.
    const zstrata = b.dependency("zstrata", .{});
    const pool = b.createModule(.{
        .root_source_file = zstrata.path("src/cpu/pool.zig"),
        .target = target,
        .optimize = optimize,
    });
    const vulkan = b.dependency("vulkan", .{
        .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");
    const gpu = b.createModule(.{
        .root_source_file = zstrata.path("src/gpu.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vulkan", .module = vulkan }},
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // libc so the Vulkan loader can be opened with the system's own loader on Linux.
        .link_libc = true,
        .imports = &.{
            .{ .name = "pool", .module = pool },
            .{ .name = "gpu", .module = gpu },
        },
    });
    for (shaders) |name| {
        mod.addAnonymousImport(b.fmt("{s}.spv", .{name}), .{ .root_source_file = compileShader(b, name) });
    }
    // The version printed by `--version` and written into exports comes from build.zig.zon.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    mod.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{ .name = "zstrata-bench", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    b.step("run", "run | look | map | list | check | answer | one (see docs/GUIDE.md)").dependOn(&run.step);

    // GPU tests open the real card; without one they skip the GPU variants. In Debug the
    // Khronos validation layer is used when it can be found.
    const tests = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
    useLocalLayers(b, tests);
    b.step("test", "Every variant of every job against its reference").dependOn(&tests.step);
}

/// shaders/<name>.comp -> SPIR-V with glslc from `$VKPREFIX/bin` (default: the per-user shaderc
/// at `%USERPROFILE%\.local\shaderc` on Windows, `~/.local/vulkan/usr` elsewhere).
fn compileShader(b: *std.Build, name: []const u8) std.Build.LazyPath {
    const env = &b.graph.environ_map;
    const windows = b.graph.host.result.os.tag == .windows;
    const prefix = env.get("VKPREFIX") orelse if (windows)
        b.fmt("{s}/.local/shaderc", .{env.get("USERPROFILE") orelse @panic("set VKPREFIX to find glslc")})
    else
        b.fmt("{s}/.local/vulkan/usr", .{env.get("HOME") orelse @panic("set VKPREFIX to find glslc")});
    const glslc = b.addSystemCommand(&.{ b.fmt("{s}/bin/{s}", .{ prefix, if (windows) "glslc.exe" else "glslc" }), "--target-env=vulkan1.3", "-O", "-o" });
    const spv = glslc.addOutputFileArg(b.fmt("{s}.spv", .{name}));
    glslc.addFileArg(b.path(b.fmt("shaders/{s}.comp", .{name})));
    return spv;
}

/// Lets the tests find the validation layer in the per-user folder (`$VKLAYERS` overrides).
fn useLocalLayers(b: *std.Build, run: *std.Build.Step.Run) void {
    const env = &b.graph.environ_map;
    if (env.get("VKLAYERS")) |layers| {
        run.setEnvironmentVariable("VK_ADD_LAYER_PATH", layers);
    } else if (b.graph.host.result.os.tag == .windows) {
        if (env.get("USERPROFILE")) |home| run.setEnvironmentVariable("VK_ADD_LAYER_PATH", b.fmt("{s}/.local/vk-layers", .{home}));
    }
}
