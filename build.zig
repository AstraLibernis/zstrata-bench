// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zstrata is used as a library: its thread pool is the one every threaded variant runs on.
    const zstrata = b.dependency("zstrata", .{});
    const pool = b.createModule(.{
        .root_source_file = zstrata.path("src/cpu/pool.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "pool", .module = pool }},
    });
    const exe = b.addExecutable(.{ .name = "zstrata-bench", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    b.step("run", "run | list | check | answer | one (see docs/GUIDE.md)").dependOn(&run.step);

    const tests = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
    b.step("test", "Every variant of every job against its reference").dependOn(&tests.step);
}
