// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! S6: multiply two square matrices.
//!
//! Input: two side-by-side matrices of 32-bit floats in [0, 1), stored row after row
//! (data.fillUnit, seeds 40 and 41). A size counts multiply-adds: for size n the side is the
//! cube root of n, rounded.
//! Output: their product.
//! Answer (for comparing variants): every element of the product added together in 64-bit.
//! Every variant adds the terms of one element in the same order (k rising). Variants that use
//! the fused multiply-add instruction round once per term instead of twice, so their results
//! differ from the others in the last bits; the rest are equal bit for bit.
//! Outside check: verify/science_jobs.py (NumPy, which uses a tuned library and another order,
//! so it is compared more loosely).

const std = @import("std");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const Env = harness.Env;
const Compute = @import("../../gpu_kit.zig").Compute;

const line = std.atomic.cache_line;

/// The tiled variants take the second matrix this many rows at a time, and finish every row of
/// the result against those rows before moving on.
const tile = 128;

const Input = struct {
    side: usize,
    a: []f32,
    b: []f32,
    /// Starts on a cache line. With a side that is a multiple of 32 every row is whole lines,
    /// so threads that own different rows never write the same line.
    c: []align(line) f32,
    /// Buffers on the graphics card, made the first time a GPU variant runs.
    card: ?Compute = null,
    /// The GPU result checked in the untimed run; reported again while the result stays on the card.
    card_answer: f64 = 0,
};

fn of(p: *anyopaque) *Input {
    return @ptrCast(@alignCast(p));
}

// --- GPU -----------------------------------------------------------------------------------------
// One invocation per element of the result: the dot product of a row of the first matrix with a
// column of the second. The second matrix is stored column by column on the card, and both are
// read four values at a time, so rows are padded with zeros to a multiple of four.

const spirv align(@alignOf(u32)) = @embedFile("s6_matmul.spv").*;
const Push = extern struct { side: u32, quads: u32 };

fn quadsOf(side: usize) usize {
    return (side + 3) / 4;
}

/// Writes both matrices into the staging buffer in the card's layout.
fn stage(in: *Input, c: *Compute) void {
    const n = in.side;
    const padded = quadsOf(n) * 4;
    const a = c.input(0, f32);
    const bt = c.input(1, f32);
    @memset(a, 0);
    @memset(bt, 0);
    for (0..n) |i| @memcpy(a[i * padded ..][0..n], in.a[i * n ..][0..n]);
    for (0..n) |k| {
        for (0..n) |j| bt[j * padded + k] = in.b[k * n + j];
    }
}

/// The card-side state, created on first use with the inputs already uploaded.
fn card(env: *Env, in: *Input) !*Compute {
    if (in.card == null) {
        const g = try env.gpu();
        const row_bytes = in.side * quadsOf(in.side) * 4 * @sizeOf(f32);
        var c = try Compute.init(g, &spirv, &.{ row_bytes, row_bytes }, &.{in.side * in.side * @sizeOf(f32)}, @sizeOf(Push));
        errdefer c.deinit();
        stage(in, &c);
        try c.uploadOnly();
        in.card = c;
    }
    return &in.card.?;
}

fn dispatch(in: *Input, c: *Compute, move: Compute.Move) !void {
    const push: Push = .{ .side = @intCast(in.side), .quads = @intCast(quadsOf(in.side)) };
    const groups: u32 = @intCast((in.side + 7) / 8);
    try c.run(&push, .{ groups, groups, 1 }, move);
}

/// Data already on the card, result left on the card: the dispatch alone.
fn onCard(env: *Env, p: *anyopaque) anyerror!f64 {
    const in = of(p);
    if (in.side == 0) return 0;
    const c = try card(env, in);
    try dispatch(in, c, .{});
    if (env.timing) return in.card_answer;
    try c.download();
    in.card_answer = answerOf(c.output(0, f32));
    return in.card_answer;
}

/// From matrices in main memory to the product back in main memory.
fn withTransfer(env: *Env, p: *anyopaque) anyerror!f64 {
    const in = of(p);
    if (in.side == 0) return 0;
    const c = try card(env, in);
    stage(in, c);
    try dispatch(in, c, .{ .upload = true, .download = true });
    return answerOf(c.output(0, f32));
}

fn sideFor(n: usize) usize {
    const side: usize = @trunc(@round(std.math.cbrt(@as(f64, @floatFromInt(n)))));
    return side;
}

fn create(gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque {
    const side = sideFor(n);
    const in = try gpa.create(Input);
    errdefer gpa.destroy(in);
    const a = try gpa.alloc(f32, side * side);
    errdefer gpa.free(a);
    const b = try gpa.alloc(f32, side * side);
    errdefer gpa.free(b);
    const c = try gpa.alignedAlloc(f32, .fromByteUnits(line), side * side);
    data.fillUnit(a, 40);
    data.fillUnit(b, 41);
    in.* = .{ .side = side, .a = a, .b = b, .c = c };
    return in;
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    if (in.card) |*c| c.deinit();
    gpa.free(in.c);
    gpa.free(in.b);
    gpa.free(in.a);
    gpa.destroy(in);
}

fn answerOf(c: []const f32) f64 {
    var total: f64 = 0;
    for (c) |x| total += x;
    return total;
}

/// The reference: the loops as the maths is written (row, column, sum over k).
fn textbook(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    const n = in.side;
    for (0..n) |i| {
        for (0..n) |j| {
            var sum: f32 = 0;
            for (0..n) |k| sum += in.a[i * n + k] * in.b[k * n + j];
            in.c[i * n + j] = sum;
        }
    }
    return answerOf(in.c);
}

/// How the innermost step (one row of the result plus a multiple of one row of the second
/// matrix) is written.
const Kernel = enum {
    /// A plain loop; whether it becomes vectors is left to the compiler.
    compiler,
    /// 16 values at a time, written out; multiply, then add (same bits as the plain loop).
    wide,
    /// 16 at a time with the fused multiply-add instruction (rounds once instead of twice).
    fused,
    /// Fused, and four rows of the second matrix per pass over the result row.
    fused4,
};

const lanes = 16;
const Vec = @Vector(lanes, f32);

/// out += a * x.
fn addScaled(comptime fuse: bool, out: []f32, a: f32, x: []const f32) void {
    const av: Vec = @splat(a);
    var j: usize = 0;
    while (j + lanes <= out.len) : (j += lanes) {
        const o: Vec = out[j..][0..lanes].*;
        const xv: Vec = x[j..][0..lanes].*;
        out[j..][0..lanes].* = if (fuse) @mulAdd(Vec, av, xv, o) else o + av * xv;
    }
    while (j < out.len) : (j += 1) out[j] = if (fuse) @mulAdd(f32, a, x[j], out[j]) else out[j] + a * x[j];
}

/// out += a[0] * x[0] + ... + a[3] * x[3], adding in that order for every element.
fn addScaled4(out: []f32, a: [4]f32, x: [4][]const f32) void {
    var j: usize = 0;
    while (j + lanes <= out.len) : (j += lanes) {
        var o: Vec = out[j..][0..lanes].*;
        inline for (0..4) |t| o = @mulAdd(Vec, @as(Vec, @splat(a[t])), @as(Vec, x[t][j..][0..lanes].*), o);
        out[j..][0..lanes].* = o;
    }
    while (j < out.len) : (j += 1) {
        inline for (0..4) |t| out[j] = @mulAdd(f32, a[t], x[t][j], out[j]);
    }
}

/// Rows [row_lo, row_hi) of the product against rows [k_lo, k_hi) of the second matrix. The
/// inner step walks one row of each matrix in order.
fn accumulate(comptime kernel: Kernel, in: *Input, row_lo: usize, row_hi: usize, k_lo: usize, k_hi: usize) void {
    const n = in.side;
    for (row_lo..row_hi) |i| {
        const out = in.c[i * n ..][0..n];
        var k = k_lo;
        if (kernel == .fused4) {
            while (k + 4 <= k_hi) : (k += 4) {
                var rows: [4][]const f32 = undefined;
                for (&rows, 0..) |*r, t| r.* = in.b[(k + t) * n ..][0..n];
                addScaled4(out, in.a[i * n + k ..][0..4].*, rows);
            }
        }
        while (k < k_hi) : (k += 1) {
            const aik = in.a[i * n + k];
            const row = in.b[k * n ..][0..n];
            switch (kernel) {
                .compiler => for (out, row) |*o, bkj| {
                    o.* += aik * bkj;
                },
                .wide => addScaled(false, out, aik, row),
                .fused, .fused4 => addScaled(true, out, aik, row),
            }
        }
    }
}

/// The same sums with the two inner loops swapped.
fn reordered(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    @memset(in.c, 0);
    accumulate(.compiler, in, 0, in.side, 0, in.side);
    return answerOf(in.c);
}

fn tiledRows(comptime kernel: Kernel, in: *Input, row_lo: usize, row_hi: usize) void {
    var k: usize = 0;
    while (k < in.side) : (k += tile) accumulate(kernel, in, row_lo, row_hi, k, @min(k + tile, in.side));
}

/// Reordered, and the second matrix taken 128 rows at a time so that piece stays in cache
/// while every row of the result uses it.
fn Tiled(comptime kernel: Kernel) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            _ = env;
            const in = of(p);
            @memset(in.c, 0);
            tiledRows(kernel, in, 0, in.side);
            return answerOf(in.c);
        }
    };
}

/// Pool task over result rows [begin, end).
fn tiledTask(ctx: *anyopaque, worker: usize, begin: usize, end: usize) void {
    _ = worker;
    const in = of(ctx);
    @memset(in.c[begin * in.side .. end * in.side], 0);
    tiledRows(.fused4, in, begin, end);
}

fn Threads(comptime count: u32) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            const in = of(p);
            const pool = try env.pool(count);
            pool.parallelFor(in.side, in, tiledTask, 1);
            return answerOf(in.c);
        }
    };
}

pub const job: harness.Job = .{
    .id = "S6",
    .group = "data science",
    .title = "multiply two square matrices",
    .unit = "multiply-adds",
    .bytes_per_item = 0,
    .sizes = &.{ 128 * 128 * 128, 512 * 512 * 512, 1024 * 1024 * 1024 },
    .quick_sizes = &.{ 32 * 32 * 32, 96 * 96 * 96 },
    // The fused variants round once per multiply-add instead of twice, and the GPU adds each
    // element as four partial sums, so their sums differ
    // from the reference in the last bits.
    .tolerance = 1e-5,
    .source = @embedFile("s6_matmul.zig"),
    .create = create,
    .destroy = destroy,
    .variants = &.{
        .{ .name = "textbook", .what = "the loops as the maths is written: row, column, sum", .run = textbook },
        .{ .name = "reordered", .what = "the two inner loops swapped, so memory is walked in order", .run = reordered },
        .{ .name = "tiled", .what = "reordered, second matrix taken 128 rows at a time", .run = Tiled(.compiler).run },
        .{ .name = "lanes16", .what = "tiled, inner step written as 16-wide vectors", .run = Tiled(.wide).run },
        .{ .name = "fused", .what = "lanes16 with fused multiply-add", .run = Tiled(.fused).run },
        .{ .name = "fused4", .what = "fused, four rows of the second matrix per pass", .run = Tiled(.fused4).run },
        .{ .name = "threads8", .what = "fused4, result rows shared out over 8 threads", .run = Threads(8).run, .threads = true },
        .{ .name = "threads16", .what = "fused4, result rows shared out over 16 threads", .run = Threads(16).run, .threads = true },
        .{ .name = "gpu", .what = "graphics card, matrices already on it, product left on it", .run = onCard, .gpu = true },
        .{ .name = "gpu+transfer", .what = "graphics card, from main memory and back", .run = withTransfer, .gpu = true },
    },
};

// Sizes are multiply-adds: these give sides 0, 1, 2, 3, 17, 127, 128, 129 and 200.
const edge_sizes = [_]usize{ 0, 1, 8, 27, 4913, 2_048_383, 2_097_152, 2_146_689, 8_000_000 };

test "S6: every variant gives the reference answer" {
    try harness.expectVariantsAgree(&job, &edge_sizes);
}

test "S6: sides, and a product worked out by hand" {
    try std.testing.expectEqual(@as(usize, 0), sideFor(0));
    try std.testing.expectEqual(@as(usize, 128), sideFor(128 * 128 * 128));
    try std.testing.expectEqual(@as(usize, 1024), sideFor(1024 * 1024 * 1024));
    const gpa = std.testing.allocator;
    var env: Env = .{ .gpa = gpa, .io = std.testing.io };
    defer env.deinit();
    const p = try create(gpa, 8); // side 2
    defer destroy(gpa, p);
    const in = of(p);
    @memcpy(in.a, &[_]f32{ 1, 2, 3, 4 });
    @memcpy(in.b, &[_]f32{ 5, 6, 7, 8 });
    // [1 2; 3 4] * [5 6; 7 8] = [19 22; 43 50]
    for (job.variants) |v| {
        if (v.gpu) continue; // checked against the reference in the test above
        try std.testing.expectEqual(@as(f64, 134), try v.run(&env, p));
        try std.testing.expectEqualSlices(f32, &.{ 19, 22, 43, 50 }, in.c);
    }
}
