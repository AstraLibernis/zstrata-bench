// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M6: one Adam optimiser step over a large array of parameters.
//!
//! Input: `n` parameters w (data.fillUnit seed 120, minus 0.5), first moments m
//! ((seed 121 - 0.5) / 10), second moments v (seed 122 / 100) and gradients g (seed 123,
//! minus 0.5). All 32-bit floats.
//! Output, written to separate arrays so every run starts from the same input:
//!   m' = 0.9 m + (1 - 0.9) g
//!   v' = 0.999 v + (1 - 0.999) g g
//!   w' = w - 0.001 m' / (sqrt(v') + 1e-8)
//! Answer (for comparing variants): every 97th element of w', m' and v', and the last of each,
//! added together in 64-bit. (Adding everything would cost as much as the step itself; the
//! tests compare every element.)
//! Outside check: verify/model_jobs.py (NumPy).

const std = @import("std");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const Env = harness.Env;

const lanes = 16;
const Vec = @Vector(lanes, f32);
const line = std.atomic.cache_line;

const beta1: f32 = 0.9;
const beta2: f32 = 0.999;
const rest1: f32 = 1.0 - beta1;
const rest2: f32 = 1.0 - beta2;
const rate: f32 = 0.001;
const tiny: f32 = 1e-8;

/// Threaded variants take the parameters in blocks of this many. The output arrays start on a
/// cache line and a block is whole lines, so two workers never write the same line.
const block = 1 << 16;

const Out = []align(line) f32;

const Input = struct {
    w: []f32,
    m: []f32,
    v: []f32,
    g: []f32,
    w2: Out,
    m2: Out,
    v2: Out,
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
    const g = try gpa.alloc(f32, n);
    errdefer gpa.free(g);
    const w2 = try gpa.alignedAlloc(f32, .fromByteUnits(line), n);
    errdefer gpa.free(w2);
    const m2 = try gpa.alignedAlloc(f32, .fromByteUnits(line), n);
    errdefer gpa.free(m2);
    const v2 = try gpa.alignedAlloc(f32, .fromByteUnits(line), n);
    data.fillUnit(w, 120);
    for (w) |*x| x.* -= 0.5;
    data.fillUnit(m, 121);
    for (m) |*x| x.* = (x.* - 0.5) * 0.1;
    data.fillUnit(v, 122);
    for (v) |*x| x.* *= 0.01;
    data.fillUnit(g, 123);
    for (g) |*x| x.* -= 0.5;
    in.* = .{ .w = w, .m = m, .v = v, .g = g, .w2 = w2, .m2 = m2, .v2 = v2 };
    return in;
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    gpa.free(in.v2);
    gpa.free(in.m2);
    gpa.free(in.w2);
    gpa.free(in.g);
    gpa.free(in.v);
    gpa.free(in.m);
    gpa.free(in.w);
    gpa.destroy(in);
}

fn answerOf(in: *const Input) f64 {
    const n = in.w2.len;
    if (n == 0) return 0;
    var a: f64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 97) a += @as(f64, in.w2[i]) + in.m2[i] + in.v2[i];
    return a + in.w2[n - 1] + in.m2[n - 1] + in.v2[n - 1];
}

/// The reference: one plain loop doing all three updates for each parameter.
fn plainRange(in: *Input, lo: usize, hi: usize) void {
    for (lo..hi) |i| {
        const g = in.g[i];
        const m = beta1 * in.m[i] + rest1 * g;
        const v = beta2 * in.v[i] + rest2 * g * g;
        in.m2[i] = m;
        in.v2[i] = v;
        in.w2[i] = in.w[i] - rate * m / (@sqrt(v) + tiny);
    }
}

/// Three plain loops: all of m', then all of v', then all of w'.
fn splitRange(in: *Input, lo: usize, hi: usize) void {
    for (in.m2[lo..hi], in.m[lo..hi], in.g[lo..hi]) |*out, m, g| out.* = beta1 * m + rest1 * g;
    for (in.v2[lo..hi], in.v[lo..hi], in.g[lo..hi]) |*out, v, g| out.* = beta2 * v + rest2 * g * g;
    for (in.w2[lo..hi], in.w[lo..hi], in.m2[lo..hi], in.v2[lo..hi]) |*out, w, m, v| out.* = w - rate * m / (@sqrt(v) + tiny);
}

/// One loop, 16 parameters at a time, the same operations in the same order.
fn wideRange(in: *Input, lo: usize, hi: usize) void {
    const b1: Vec = @splat(beta1);
    const b2: Vec = @splat(beta2);
    const r1: Vec = @splat(rest1);
    const r2: Vec = @splat(rest2);
    const lr: Vec = @splat(rate);
    const eps: Vec = @splat(tiny);
    var i = lo;
    while (i + lanes <= hi) : (i += lanes) {
        const g: Vec = in.g[i..][0..lanes].*;
        const m = b1 * @as(Vec, in.m[i..][0..lanes].*) + r1 * g;
        const v = b2 * @as(Vec, in.v[i..][0..lanes].*) + r2 * g * g;
        in.m2[i..][0..lanes].* = m;
        in.v2[i..][0..lanes].* = v;
        in.w2[i..][0..lanes].* = @as(Vec, in.w[i..][0..lanes].*) - lr * m / (@sqrt(v) + eps);
    }
    plainRange(in, i, hi);
}

fn Serial(comptime kernel: fn (*Input, usize, usize) void) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            _ = env;
            const in = of(p);
            kernel(in, 0, in.w.len);
            return answerOf(in);
        }
    };
}

/// Pool task over block indices [begin, end).
fn wideBlocks(ctx: *anyopaque, worker: usize, begin: usize, end: usize) void {
    _ = worker;
    const in = of(ctx);
    for (begin..end) |b| wideRange(in, b * block, @min((b + 1) * block, in.w.len));
}

fn Threads(comptime count: u32) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            const in = of(p);
            const pool = try env.pool(count);
            pool.parallelFor((in.w.len + block - 1) / block, in, wideBlocks, 1);
            return answerOf(in);
        }
    };
}

pub const job: harness.Job = .{
    .id = "M6",
    .group = "model learning",
    .title = "one Adam optimiser step over an array of parameters",
    .unit = "parameters",
    .bytes_per_item = 7 * @sizeOf(f32),
    .sizes = &.{ 10_000, 1_000_000, 50_000_000 },
    .quick_sizes = &.{ 1_000, 200_000 },
    .tolerance = 0,
    .source = @embedFile("m6_adam_step.zig"),
    .create = create,
    .destroy = destroy,
    .variants = &.{
        .{ .name = "oneloop", .what = "one plain loop, all three updates per parameter", .run = Serial(plainRange).run },
        .{ .name = "threeloops", .what = "three plain loops, one per output array", .run = Serial(splitRange).run },
        .{ .name = "lanes16", .what = "one loop, 16 parameters at a time", .run = Serial(wideRange).run },
        .{ .name = "threads8", .what = "lanes16 over blocks on 8 threads", .run = Threads(8).run, .threads = true },
        .{ .name = "threads16", .what = "lanes16 over blocks on 16 threads", .run = Threads(16).run, .threads = true },
    },
};

const edge_sizes = [_]usize{ 0, 1, 15, 16, 17, 96, 97, 98, 1000, block - 1, block, block + 1, 2 * block + 5 };

test "M6: every variant gives the reference answer" {
    try harness.expectVariantsAgree(&job, &edge_sizes);
}

test "M6: every variant writes exactly the same three arrays" {
    const gpa = std.testing.allocator;
    var env: Env = .{ .gpa = gpa, .io = std.testing.io, .force_threads = 3 };
    defer env.deinit();
    for (edge_sizes) |n| {
        const p = try create(gpa, n);
        defer destroy(gpa, p);
        const in = of(p);
        plainRange(in, 0, n);
        const w = try gpa.dupe(f32, in.w2);
        defer gpa.free(w);
        const m = try gpa.dupe(f32, in.m2);
        defer gpa.free(m);
        const v = try gpa.dupe(f32, in.v2);
        defer gpa.free(v);
        for (job.variants[1..]) |variant| {
            @memset(in.w2, 0);
            @memset(in.m2, 0);
            @memset(in.v2, 0);
            _ = try variant.run(&env, p);
            try std.testing.expectEqualSlices(f32, w, in.w2);
            try std.testing.expectEqualSlices(f32, m, in.m2);
            try std.testing.expectEqualSlices(f32, v, in.v2);
        }
    }
}

test "M6: one parameter worked out by hand" {
    const gpa = std.testing.allocator;
    const p = try create(gpa, 1);
    defer destroy(gpa, p);
    const in = of(p);
    in.w[0] = 1;
    in.m[0] = 0;
    in.v[0] = 0;
    in.g[0] = 2;
    plainRange(in, 0, 1);
    // m' = 0.1 * 2 = 0.2; v' = 0.001 * 4 = 0.004; w' = 1 - 0.001 * 0.2 / (sqrt(0.004) + 1e-8).
    try std.testing.expectApproxEqRel(@as(f32, 0.2), in.m2[0], 1e-6);
    // 1 - 0.999 in 32-bit is 0.00099998712, not 0.001, so v' is 0.0039999485.
    try std.testing.expectApproxEqRel(@as(f32, 0.004), in.v2[0], 1e-4);
    try std.testing.expectEqual(rest2 * 4.0, in.v2[0]);
    try std.testing.expectApproxEqRel(@as(f32, 1.0 - 0.001 * 0.2 / 0.0632455532), in.w2[0], 1e-6);
}
