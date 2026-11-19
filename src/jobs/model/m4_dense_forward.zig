// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M4: forward pass of one dense layer with ReLU.
//!
//! Input: a batch of `n` rows of 256 inputs (data.fillUnit seed 100, minus 0.5), a 256 by 256
//! weight matrix ((data.fillUnit seed 101 - 0.5) / 8, stored output by output) and 256 biases
//! (data.fillUnit seed 102, minus 0.5). All 32-bit floats.
//! Output: for every row and output, max(0, bias + sum over inputs of input * weight).
//! Answer (for comparing variants): every output added together in 64-bit.
//! The weights are held both ways round (output by output, and input by input).
//! Outside check: verify/model_jobs.py (NumPy).

const std = @import("std");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const Env = harness.Env;
const gpu_kit = @import("../../gpu_kit.zig");
const Compute = gpu_kit.Compute;

const width = 256;
const lanes = 16;
const Vec = @Vector(lanes, f32);
const line = std.atomic.cache_line;

const Input = struct {
    batch: usize,
    x: []f32,
    /// w[o * width + i]: the weights of output o are together.
    w: []f32,
    /// wt[i * width + o]: the weights of input i are together.
    wt: []f32,
    bias: [width]f32,
    /// Starts on a cache line and every row is whole lines, so threads that own different rows
    /// never write the same line.
    y: []align(line) f32,
    /// Buffers on the graphics card, made the first time a GPU variant runs.
    card: ?Compute = null,
    /// The GPU result checked in the untimed run; reported again while the result stays on the card.
    card_answer: f64 = 0,
};

fn of(p: *anyopaque) *Input {
    return @ptrCast(@alignCast(p));
}

fn create(gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque {
    const in = try gpa.create(Input);
    errdefer gpa.destroy(in);
    const x = try gpa.alloc(f32, n * width);
    errdefer gpa.free(x);
    const w = try gpa.alloc(f32, width * width);
    errdefer gpa.free(w);
    const wt = try gpa.alloc(f32, width * width);
    errdefer gpa.free(wt);
    const y = try gpa.alignedAlloc(f32, .fromByteUnits(line), n * width);
    in.* = .{ .batch = n, .x = x, .w = w, .wt = wt, .bias = undefined, .y = y };
    data.fillUnit(x, 100);
    for (x) |*v| v.* -= 0.5;
    data.fillUnit(w, 101);
    for (w) |*v| v.* = (v.* - 0.5) * 0.125;
    for (0..width) |o| {
        for (0..width) |i| wt[i * width + o] = w[o * width + i];
    }
    data.fillUnit(&in.bias, 102);
    for (&in.bias) |*v| v.* -= 0.5;
    return in;
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    if (in.card) |*c| c.deinit();
    gpa.free(in.y);
    gpa.free(in.wt);
    gpa.free(in.w);
    gpa.free(in.x);
    gpa.destroy(in);
}

fn answerOf(y: []const f32) f64 {
    var total: f64 = 0;
    for (y) |v| total += v;
    return total;
}

fn dotPlain(a: []const f32, b: []const f32) f32 {
    var s: f32 = 0;
    for (a, b) |p, q| s += p * q;
    return s;
}

/// `chains` running sums of 16 products each; fused multiply-add when `fuse`.
fn dotWide(comptime chains: comptime_int, comptime fuse: bool, a: *const [width]f32, b: *const [width]f32) f32 {
    var acc: [chains]Vec = @splat(@splat(0));
    var i: usize = 0;
    while (i < width) : (i += lanes * chains) {
        inline for (0..chains) |c| {
            const p: Vec = a[i + c * lanes ..][0..lanes].*;
            const q: Vec = b[i + c * lanes ..][0..lanes].*;
            acc[c] = if (fuse) @mulAdd(Vec, p, q, acc[c]) else acc[c] + p * q;
        }
    }
    var total: Vec = acc[0];
    inline for (1..chains) |c| total += acc[c];
    return @reduce(.Add, total);
}

const Dot = enum { plain, wide, wide4 };

/// One output at a time: the dot product of the row with that output's weights.
fn Dots(comptime how: Dot) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            _ = env;
            const in = of(p);
            for (0..in.batch) |r| {
                const x = in.x[r * width ..][0..width];
                const y = in.y[r * width ..][0..width];
                for (y, 0..) |*out, o| {
                    const wo = in.w[o * width ..][0..width];
                    const s = in.bias[o] + switch (how) {
                        .plain => dotPlain(x, wo),
                        .wide => dotWide(1, false, x, wo),
                        .wide4 => dotWide(4, true, x, wo),
                    };
                    out.* = @max(s, 0);
                }
            }
            return answerOf(in.y);
        }
    };
}

/// Rows [lo, hi): start each output row at the biases, then add one input's weights at a time
/// (four inputs per pass), scaled by that input's value; clamp at the end.
fn scaledRows(in: *Input, lo: usize, hi: usize) void {
    for (lo..hi) |r| {
        const x = in.x[r * width ..][0..width];
        const y = in.y[r * width ..][0..width];
        @memcpy(y, &in.bias);
        var i: usize = 0;
        while (i < width) : (i += 4) {
            var o: usize = 0;
            while (o < width) : (o += lanes) {
                var acc: Vec = y[o..][0..lanes].*;
                inline for (0..4) |t| {
                    const wv: Vec = in.wt[(i + t) * width + o ..][0..lanes].*;
                    acc = @mulAdd(Vec, @as(Vec, @splat(x[i + t])), wv, acc);
                }
                y[o..][0..lanes].* = acc;
            }
        }
        const zero: Vec = @splat(0);
        var o: usize = 0;
        while (o < width) : (o += lanes) y[o..][0..lanes].* = @max(@as(Vec, y[o..][0..lanes].*), zero);
    }
}

/// Weights stored input by input: every output of a row grows together.
fn scaled(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    scaledRows(in, 0, in.batch);
    return answerOf(in.y);
}

/// Pool task over rows [begin, end).
fn scaledTask(ctx: *anyopaque, worker: usize, begin: usize, end: usize) void {
    _ = worker;
    scaledRows(of(ctx), begin, end);
}

fn Threads(comptime count: u32) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            const in = of(p);
            const pool = try env.pool(count);
            pool.parallelFor(in.batch, in, scaledTask, 1);
            return answerOf(in.y);
        }
    };
}

pub const job: harness.Job = .{
    .id = "M4",
    .group = "model learning",
    .title = "dense layer forward with ReLU, 256 inputs to 256 outputs",
    .unit = "rows",
    .bytes_per_item = 2 * width * @sizeOf(f32),
    .sizes = &.{ 64, 4_096, 32_768 },
    .quick_sizes = &.{ 8, 256 },
    // Variants add each output's 256 products in different orders, in 32-bit.
    .tolerance = 1e-4,
    .source = @embedFile("m4_dense_forward.zig"),
    .create = create,
    .destroy = destroy,
    .variants = &.{
        .{ .name = "dot", .what = "one output at a time: a plain dot product with its weights", .run = Dots(.plain).run },
        .{ .name = "dot16", .what = "the dot product 16 values at a time", .run = Dots(.wide).run },
        .{ .name = "dot16x4", .what = "the dot product as four fused running sums of 16", .run = Dots(.wide4).run },
        .{ .name = "scaled", .what = "weights stored input by input; all outputs of a row grow together, fused", .run = scaled },
        .{ .name = "threads8", .what = "scaled, rows shared out over 8 threads", .run = Threads(8).run, .threads = true },
        .{ .name = "threads16", .what = "scaled, rows shared out over 16 threads", .run = Threads(16).run, .threads = true },
        .{ .name = "gpu", .what = "graphics card, data already on it, result left on it", .run = onCard, .gpu = true },
        .{ .name = "gpu+transfer", .what = "graphics card, from main memory and back", .run = withTransfer, .gpu = true },
    },
};

test "M4: every variant gives the reference answer" {
    try harness.expectVariantsAgree(&job, &.{ 0, 1, 2, 3, 17, 40 });
}

test "M4: a layer worked out by hand, including the clamp at zero" {
    const gpa = std.testing.allocator;
    var env: Env = .{ .gpa = gpa, .io = std.testing.io };
    defer env.deinit();
    const p = try create(gpa, 2);
    defer destroy(gpa, p);
    const in = of(p);
    // Output o adds up the inputs times (o + 1), plus bias 1. Row 0 is all 1/256, row 1 all -1.
    for (0..width) |o| {
        for (0..width) |i| {
            in.w[o * width + i] = @floatFromInt(o + 1);
            in.wt[i * width + o] = @floatFromInt(o + 1);
        }
    }
    @memset(&in.bias, 1);
    @memset(in.x[0..width], 1.0 / 256.0);
    @memset(in.x[width..], -1);
    // Row 0: output o = 1 + (o + 1); sum over o = 256 + 256 * 257 / 2. Row 1: all negative: 0.
    for (job.variants) |v| {
        if (v.gpu) continue; // checked against the reference in the test above
        try std.testing.expectEqual(@as(f64, 256 + 32896), try v.run(&env, p));
        try std.testing.expectEqual(@as(f32, 2), in.y[0]);
        try std.testing.expectEqual(@as(f32, 257), in.y[255]);
        try std.testing.expectEqual(@as(f32, 0), in.y[width]);
    }
}

// --- GPU -----------------------------------------------------------------------------------------
// One invocation per (row, output): the dot product of the row with that output's weights, read
// four values at a time.

const spirv align(@alignOf(u32)) = @embedFile("m4_dense.spv").*;
const Push = extern struct { rows: u32 };

fn stage(in: *Input, c: *Compute) void {
    @memcpy(c.input(0, f32), in.x);
    @memcpy(c.input(1, f32), in.w);
    @memcpy(c.input(2, f32), &in.bias);
}

/// The card-side state, created on first use with inputs, weights and biases already uploaded.
fn card(env: *Env, in: *Input) !*Compute {
    if (in.batch > 65535) return error.BatchTooLargeForOneDispatch;
    if (in.card == null) {
        const g = try env.gpu();
        const row_bytes = in.batch * width * @sizeOf(f32);
        var c = try Compute.init(g, &spirv, &.{ row_bytes, width * width * @sizeOf(f32), width * @sizeOf(f32) }, &.{row_bytes}, @sizeOf(Push));
        errdefer c.deinit();
        stage(in, &c);
        try c.uploadOnly();
        in.card = c;
    }
    return &in.card.?;
}

fn dispatch(in: *Input, c: *Compute, move: Compute.Move) !void {
    const push: Push = .{ .rows = @intCast(in.batch) };
    try c.run(&push, .{ width / 64, @intCast(in.batch), 1 }, move);
}

/// Everything already on the card, outputs left on the card: the dispatch alone.
fn onCard(env: *Env, p: *anyopaque) anyerror!f64 {
    const in = of(p);
    if (in.batch == 0) return 0;
    const c = try card(env, in);
    try dispatch(in, c, .{});
    if (env.timing) return in.card_answer;
    try c.download();
    in.card_answer = answerOf(c.output(0, f32));
    return in.card_answer;
}

/// From main memory (inputs, weights and biases) to the outputs back in main memory.
fn withTransfer(env: *Env, p: *anyopaque) anyerror!f64 {
    const in = of(p);
    if (in.batch == 0) return 0;
    const c = try card(env, in);
    stage(in, c);
    try dispatch(in, c, .{ .upload = true, .download = true });
    return answerOf(c.output(0, f32));
}
