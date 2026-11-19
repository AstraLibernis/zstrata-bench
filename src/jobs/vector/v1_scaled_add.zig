// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! V1: how to write a loop that stores so that it runs as vector code.
//!
//! The loop is `out[i] = y[i] + a * x[i]` over 32-bit floats (x is data.fillUnit seed 130,
//! y is seed 131, a is 0.75). It has no running total, so nothing about its arithmetic stops a
//! compiler from doing 16 at a time. `out` might overlap `x` or `y`, and marking the parameters
//! `noalias` removes that doubt, but this Zig does not turn the loop into vector code either
//! way (see docs/measurements.md, "Vectorisation").
//! Answer (for comparing variants): every 97th output and the last, added up in 64-bit.

const std = @import("std");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const Env = harness.Env;

const scale: f32 = 0.75;

/// What `std.simd` suggests for this build's CPU: 16 on AVX-512, 8 on AVX2, 4 on plain x86-64.
/// Code written with it stays correct and sensibly wide when built for another machine.
const suggested = std.simd.suggestVectorLength(f32) orelse 4;

const Input = struct {
    x: []f32,
    y: []f32,
    out: []f32,
};

fn of(p: *anyopaque) *Input {
    return @ptrCast(@alignCast(p));
}

fn create(gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque {
    const in = try gpa.create(Input);
    errdefer gpa.destroy(in);
    const x = try gpa.alloc(f32, n);
    errdefer gpa.free(x);
    const y = try gpa.alloc(f32, n);
    errdefer gpa.free(y);
    const out = try gpa.alloc(f32, n);
    data.fillUnit(x, 130);
    data.fillUnit(y, 131);
    in.* = .{ .x = x, .y = y, .out = out };
    return in;
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    gpa.free(in.out);
    gpa.free(in.y);
    gpa.free(in.x);
    gpa.destroy(in);
}

fn answerOf(out: []const f32) f64 {
    if (out.len == 0) return 0;
    var a: f64 = 0;
    var i: usize = 0;
    while (i < out.len) : (i += 97) a += out[i];
    return a + out[out.len - 1];
}

/// The reference: the loop as anyone would write it, on slices.
fn plain(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    for (in.out, in.y, in.x) |*o, y, x| o.* = y + scale * x;
    return answerOf(in.out);
}

/// The same loop in a function whose parameters promise they do not overlap.
fn promised(noalias out: []f32, noalias y: []const f32, noalias x: []const f32) void {
    for (out, y, x) |*o, yi, xi| o.* = yi + scale * xi;
}

fn noOverlap(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    promised(in.out, in.y, in.x);
    return answerOf(in.out);
}

/// The promise again, with the function kept out of line so the promise cannot be lost when
/// the compiler merges it into its caller.
fn noOverlapOutOfLine(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    @call(.never_inline, promised, .{ in.out, in.y, in.x });
    return answerOf(in.out);
}

/// Vectors written out, `lanes` values at a time; `fuse` uses the fused multiply-add.
fn explicit(comptime lanes: comptime_int, comptime fuse: bool, out: []f32, y: []const f32, x: []const f32) void {
    const V = @Vector(lanes, f32);
    const a: V = @splat(scale);
    var i: usize = 0;
    while (i + lanes <= out.len) : (i += lanes) {
        const xv: V = x[i..][0..lanes].*;
        const yv: V = y[i..][0..lanes].*;
        out[i..][0..lanes].* = if (fuse) @mulAdd(V, a, xv, yv) else yv + a * xv;
    }
    while (i < out.len) : (i += 1) out[i] = if (fuse) @mulAdd(f32, scale, x[i], y[i]) else y[i] + scale * x[i];
}

fn Explicit(comptime lanes: comptime_int, comptime fuse: bool) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            _ = env;
            const in = of(p);
            explicit(lanes, fuse, in.out, in.y, in.x);
            return answerOf(in.out);
        }
    };
}

pub const job: harness.Job = .{
    .id = "V1",
    .group = "vectorisation",
    .title = "a loop that stores: out = y + a * x",
    .unit = "values",
    .bytes_per_item = 3 * @sizeOf(f32),
    .sizes = &.{ 1_000, 100_000, 10_000_000 },
    .quick_sizes = &.{ 100, 10_000 },
    // Only the fused variant differs from the reference, in the last bit of some values.
    .tolerance = 1e-6,
    .source = @embedFile("v1_scaled_add.zig"),
    .create = create,
    .destroy = destroy,
    .variants = &.{
        .{ .name = "plain", .what = "the plain loop on slices", .run = plain },
        .{ .name = "noalias", .what = "the plain loop in a function whose parameters are marked noalias", .run = noOverlap },
        .{ .name = "noalias-out", .what = "noalias, with the function kept out of line", .run = noOverlapOutOfLine },
        .{ .name = "lanes8", .what = "vectors written out, 8 at a time", .run = Explicit(8, false).run },
        .{ .name = "lanes16", .what = "vectors written out, 16 at a time", .run = Explicit(16, false).run },
        .{ .name = "suggested", .what = "vectors written out, as many at a time as std.simd suggests for the build's CPU", .run = Explicit(suggested, false).run },
        .{ .name = "fused16", .what = "lanes16 with fused multiply-add", .run = Explicit(16, true).run },
    },
};

const edge_sizes = [_]usize{ 0, 1, 7, 8, 9, 15, 16, 17, 31, 33, 96, 97, 98, 1000 };

test "V1: every variant gives the reference answer" {
    try harness.expectVariantsAgree(&job, &edge_sizes);
}

test "V1: every unfused variant writes exactly the same values, and they are right" {
    const gpa = std.testing.allocator;
    var env: Env = .{ .gpa = gpa, .io = std.testing.io };
    defer env.deinit();
    for (edge_sizes) |n| {
        const p = try create(gpa, n);
        defer destroy(gpa, p);
        const in = of(p);
        _ = try plain(&env, p);
        const want = try gpa.dupe(f32, in.out);
        defer gpa.free(want);
        for (want, in.y, in.x) |w, y, x| try std.testing.expectEqual(y + scale * x, w);
        for (job.variants[1..6]) |v| {
            @memset(in.out, -1);
            _ = try v.run(&env, p);
            try std.testing.expectEqualSlices(f32, want, in.out);
        }
    }
}
