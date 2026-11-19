// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M5: weight gradient of one dense layer and a gradient-descent step.
//!
//! Input: a batch of `n` rows of 256 layer inputs (data.fillUnit seed 110, minus 0.5), the same
//! number of rows of 256 output gradients (data.fillUnit seed 111, minus 0.5), and a 256 by 256
//! weight matrix ((data.fillUnit seed 112 - 0.5) / 8, output by output). All 32-bit floats.
//! Output: weights - 0.01 * gradient, where gradient[o][i] is the sum over the batch of
//! output gradient o times input i.
//! Answer (for comparing variants): every new weight added together in 64-bit.
//! Every variant adds one weight's terms in batch order; the fused ones round once per term
//! instead of twice.
//! Outside check: verify/model_jobs.py (NumPy).

const std = @import("std");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const Env = harness.Env;

const width = 256;
const lanes = 16;
const Vec = @Vector(lanes, f32);
const line = std.atomic.cache_line;
const rate: f32 = 0.01;

/// The tiled variants take the batch this many rows at a time (inputs and output gradients of a
/// tile are 128 KiB) and finish every weight row against the tile before moving on.
const tile = 64;

const Input = struct {
    batch: usize,
    x: []f32,
    dy: []f32,
    w0: []f32,
    /// Both start on a cache line and each weight row is whole lines, so threads that own
    /// different rows never write the same line.
    grad: []align(line) f32,
    w: []align(line) f32,
};

fn of(p: *anyopaque) *Input {
    return @ptrCast(@alignCast(p));
}

fn create(gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque {
    const in = try gpa.create(Input);
    errdefer gpa.destroy(in);
    const x = try gpa.alloc(f32, n * width);
    errdefer gpa.free(x);
    const dy = try gpa.alloc(f32, n * width);
    errdefer gpa.free(dy);
    const w0 = try gpa.alloc(f32, width * width);
    errdefer gpa.free(w0);
    const grad = try gpa.alignedAlloc(f32, .fromByteUnits(line), width * width);
    errdefer gpa.free(grad);
    const w = try gpa.alignedAlloc(f32, .fromByteUnits(line), width * width);
    data.fillUnit(x, 110);
    for (x) |*v| v.* -= 0.5;
    data.fillUnit(dy, 111);
    for (dy) |*v| v.* -= 0.5;
    data.fillUnit(w0, 112);
    for (w0) |*v| v.* = (v.* - 0.5) * 0.125;
    in.* = .{ .batch = n, .x = x, .dy = dy, .w0 = w0, .grad = grad, .w = w };
    return in;
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    gpa.free(in.w);
    gpa.free(in.grad);
    gpa.free(in.w0);
    gpa.free(in.dy);
    gpa.free(in.x);
    gpa.destroy(in);
}

/// New weights for output rows [lo, hi) from the finished gradient, and nothing else.
fn step(in: *Input, lo: usize, hi: usize) void {
    for (in.w[lo * width .. hi * width], in.w0[lo * width .. hi * width], in.grad[lo * width .. hi * width]) |*w, w0, g| w.* = w0 - rate * g;
}

fn answerOf(w: []const f32) f64 {
    var total: f64 = 0;
    for (w) |v| total += v;
    return total;
}

/// out += a * x, 16 at a time, fused.
fn addScaled(out: *[width]f32, a: f32, x: *const [width]f32) void {
    const av: Vec = @splat(a);
    var j: usize = 0;
    while (j < width) : (j += lanes) out[j..][0..lanes].* = @mulAdd(Vec, av, @as(Vec, x[j..][0..lanes].*), @as(Vec, out[j..][0..lanes].*));
}

/// The reference: for each batch row, for each output, add that row's contribution to the
/// output's whole weight row. Plain loops.
fn rowByRow(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    @memset(in.grad, 0);
    for (0..in.batch) |b| {
        const x = in.x[b * width ..][0..width];
        for (0..width) |o| {
            const d = in.dy[b * width + o];
            for (in.grad[o * width ..][0..width], x) |*g, xi| g.* += d * xi;
        }
    }
    step(in, 0, width);
    return answerOf(in.w);
}

/// The same loop order with the inner step written as fused 16-wide vectors.
fn rowByRowWide(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    @memset(in.grad, 0);
    for (0..in.batch) |b| {
        const x = in.x[b * width ..][0..width];
        for (0..width) |o| addScaled(in.grad[o * width ..][0..width], in.dy[b * width + o], x);
    }
    step(in, 0, width);
    return answerOf(in.w);
}

/// Gradient rows [lo, hi) against batch rows [b_lo, b_hi): each weight row meets all those
/// batch rows before the next weight row is touched.
fn weightRows(in: *Input, lo: usize, hi: usize, b_lo: usize, b_hi: usize) void {
    for (lo..hi) |o| {
        const g = in.grad[o * width ..][0..width];
        for (b_lo..b_hi) |b| addScaled(g, in.dy[b * width + o], in.x[b * width ..][0..width]);
    }
}

/// One weight row at a time against the whole batch (fused).
fn weightFirst(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    @memset(in.grad, 0);
    weightRows(in, 0, width, 0, in.batch);
    step(in, 0, width);
    return answerOf(in.w);
}

fn tiledRows(in: *Input, lo: usize, hi: usize) void {
    @memset(in.grad[lo * width .. hi * width], 0);
    var b: usize = 0;
    while (b < in.batch) : (b += tile) weightRows(in, lo, hi, b, @min(b + tile, in.batch));
    step(in, lo, hi);
}

/// The batch 64 rows at a time; every weight row meets a tile while it is still in cache.
fn tiled(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    tiledRows(in, 0, width);
    return answerOf(in.w);
}

/// Pool task over weight rows [begin, end).
fn tiledTask(ctx: *anyopaque, worker: usize, begin: usize, end: usize) void {
    _ = worker;
    tiledRows(of(ctx), begin, end);
}

fn Threads(comptime count: u32) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            const in = of(p);
            const pool = try env.pool(count);
            pool.parallelFor(width, in, tiledTask, 1);
            return answerOf(in.w);
        }
    };
}

pub const job: harness.Job = .{
    .id = "M5",
    .group = "model learning",
    .title = "dense layer weight gradient and update, 256 by 256 weights",
    .unit = "rows",
    .bytes_per_item = 2 * width * @sizeOf(f32),
    .sizes = &.{ 64, 1_024, 16_384 },
    .quick_sizes = &.{ 8, 128 },
    .tolerance = 1e-5,
    .source = @embedFile("m5_dense_update.zig"),
    .create = create,
    .destroy = destroy,
    .variants = &.{
        .{ .name = "rowbyrow", .what = "batch row by batch row, plain loops", .run = rowByRow },
        .{ .name = "rowbyrow16", .what = "the same order, inner step as fused 16-wide vectors", .run = rowByRowWide },
        .{ .name = "weightfirst", .what = "one weight row at a time against the whole batch", .run = weightFirst },
        .{ .name = "tiled", .what = "weightfirst over 64 batch rows at a time", .run = tiled },
        .{ .name = "threads8", .what = "tiled, weight rows shared out over 8 threads", .run = Threads(8).run, .threads = true },
        .{ .name = "threads16", .what = "tiled, weight rows shared out over 16 threads", .run = Threads(16).run, .threads = true },
    },
};

test "M5: every variant gives the reference answer" {
    try harness.expectVariantsAgree(&job, &.{ 0, 1, 2, tile - 1, tile, tile + 1, 2 * tile + 3 });
}

test "M5: a gradient and step worked out by hand" {
    const gpa = std.testing.allocator;
    var env: Env = .{ .gpa = gpa, .io = std.testing.io };
    defer env.deinit();
    const p = try create(gpa, 2);
    defer destroy(gpa, p);
    const in = of(p);
    // Inputs: row 0 all 1, row 1 all 2. Output gradients: row 0 all 10, row 1 all 100.
    // Every gradient entry is 10 * 1 + 100 * 2 = 210; old weights 5; new = 5 - 0.01 * 210 = 2.9.
    @memset(in.x[0..width], 1);
    @memset(in.x[width..], 2);
    @memset(in.dy[0..width], 10);
    @memset(in.dy[width..], 100);
    @memset(in.w0, 5);
    const want: f32 = 5.0 - rate * 210.0;
    for (job.variants) |v| {
        _ = try v.run(&env, p);
        for (in.grad) |g| try std.testing.expectEqual(@as(f32, 210), g);
        for (in.w) |w| try std.testing.expectEqual(want, w);
    }
}
