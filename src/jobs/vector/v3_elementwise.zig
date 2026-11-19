// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! V3: a loop that stores, with a square root and a division in it.
//!
//! The loop is `out[i] = w[i] - 0.001 * m[i] / (sqrt(v[i]) + 1e-8)` over 32-bit floats
//! (w is data.fillUnit seed 134 minus 0.5, m is seed 135 minus 0.5, v is seed 136). Square root
//! and division are the slowest common operations, so this is where one-at-a-time code costs
//! the most.
//! Answer (for comparing variants): every 97th output and the last, added up in 64-bit. Every
//! variant does the same operations in the same order and gives identical bits.

const std = @import("std");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const Env = harness.Env;

const rate: f32 = 0.001;
const tiny: f32 = 1e-8;

/// What `std.simd` suggests for this build's CPU.
const suggested = std.simd.suggestVectorLength(f32) orelse 4;

const Input = struct {
    w: []f32,
    m: []f32,
    v: []f32,
    out: []f32,
};

fn of(p: *anyopaque) *Input {
    return @ptrCast(@alignCast(p));
}

fn create(gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque {
    const in = try gpa.create(Input);
    errdefer gpa.destroy(in);
    const w = try gpa.alloc(f32, n);
    errdefer gpa.free(w);
    const m = try gpa.alloc(f32, n);
    errdefer gpa.free(m);
    const v = try gpa.alloc(f32, n);
    errdefer gpa.free(v);
    const out = try gpa.alloc(f32, n);
    data.fillUnit(w, 134);
    for (w) |*x| x.* -= 0.5;
    data.fillUnit(m, 135);
    for (m) |*x| x.* -= 0.5;
    data.fillUnit(v, 136);
    in.* = .{ .w = w, .m = m, .v = v, .out = out };
    return in;
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    gpa.free(in.out);
    gpa.free(in.v);
    gpa.free(in.m);
    gpa.free(in.w);
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
    for (in.out, in.w, in.m, in.v) |*o, w, m, v| o.* = w - rate * m / (@sqrt(v) + tiny);
    return answerOf(in.out);
}

/// The same loop in a function whose parameters promise they do not overlap.
fn promised(noalias out: []f32, noalias w: []const f32, noalias m: []const f32, noalias v: []const f32) void {
    for (out, w, m, v) |*o, wi, mi, vi| o.* = wi - rate * mi / (@sqrt(vi) + tiny);
}

fn noOverlap(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    promised(in.out, in.w, in.m, in.v);
    return answerOf(in.out);
}

/// Vectors written out, `lanes` values at a time.
fn explicit(comptime lanes: comptime_int, out: []f32, w: []const f32, m: []const f32, v: []const f32) void {
    const V = @Vector(lanes, f32);
    const lr: V = @splat(rate);
    const eps: V = @splat(tiny);
    var i: usize = 0;
    while (i + lanes <= out.len) : (i += lanes) {
        const wv: V = w[i..][0..lanes].*;
        const mv: V = m[i..][0..lanes].*;
        const vv: V = v[i..][0..lanes].*;
        out[i..][0..lanes].* = wv - lr * mv / (@sqrt(vv) + eps);
    }
    while (i < out.len) : (i += 1) out[i] = w[i] - rate * m[i] / (@sqrt(v[i]) + tiny);
}

fn Explicit(comptime lanes: comptime_int) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            _ = env;
            const in = of(p);
            explicit(lanes, in.out, in.w, in.m, in.v);
            return answerOf(in.out);
        }
    };
}

pub const job: harness.Job = .{
    .id = "V3",
    .group = "vectorisation",
    .title = "a loop that stores, with a square root and a division",
    .unit = "values",
    .bytes_per_item = 4 * @sizeOf(f32),
    .sizes = &.{ 1_000, 100_000, 10_000_000 },
    .quick_sizes = &.{ 100, 10_000 },
    .tolerance = 0,
    .source = @embedFile("v3_elementwise.zig"),
    .create = create,
    .destroy = destroy,
    .variants = &.{
        .{ .name = "plain", .what = "the plain loop on slices", .run = plain },
        .{ .name = "noalias", .what = "the plain loop in a function whose parameters are marked noalias", .run = noOverlap },
        .{ .name = "lanes8", .what = "vectors written out, 8 at a time", .run = Explicit(8).run },
        .{ .name = "lanes16", .what = "vectors written out, 16 at a time", .run = Explicit(16).run },
        .{ .name = "suggested", .what = "vectors written out, as many at a time as std.simd suggests for the build's CPU", .run = Explicit(suggested).run },
    },
};

const edge_sizes = [_]usize{ 0, 1, 7, 8, 9, 15, 16, 17, 33, 96, 97, 98, 1000 };

test "V3: every variant gives the reference answer" {
    try harness.expectVariantsAgree(&job, &edge_sizes);
}

test "V3: every variant writes exactly the same values" {
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
        for (want, in.w, in.m, in.v) |x, w, m, v| try std.testing.expectEqual(w - rate * m / (@sqrt(v) + tiny), x);
        for (job.variants[1..]) |variant| {
            @memset(in.out, -1);
            _ = try variant.run(&env, p);
            try std.testing.expectEqualSlices(f32, want, in.out);
        }
    }
}
