// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! S1: mean, variance, minimum and maximum of a column.
//!
//! Input: `n` 32-bit floats in [0, 1) (data.fillUnit, seed 11).
//! Output: the mean, the population variance (mean of squares minus the square of the mean,
//! both sums kept in 64-bit), the minimum and the maximum.
//! Answer (for comparing variants): the four added together; 0 for an empty column.
//! Outside check: verify/science_jobs.py (NumPy).

const std = @import("std");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const Env = harness.Env;

const seed = 11;
const lanes = 16;

/// Threaded variants work in blocks of this many values; block results are combined in block
/// order afterwards.
const block = 1 << 16;

const Stats = struct {
    sum: f64 = 0,
    squares: f64 = 0,
    min: f32 = std.math.inf(f32),
    max: f32 = -std.math.inf(f32),

    fn add(a: *Stats, b: Stats) void {
        a.sum += b.sum;
        a.squares += b.squares;
        a.min = @min(a.min, b.min);
        a.max = @max(a.max, b.max);
    }

    fn answer(s: Stats, n: usize) f64 {
        if (n == 0) return 0;
        const count: f64 = @floatFromInt(n);
        const mean = s.sum / count;
        return mean + (s.squares / count - mean * mean) + s.min + s.max;
    }
};

/// One block result per cache line: two workers never write the same line.
const Slot = struct { stats: Stats align(std.atomic.cache_line) = .{} };

const Input = struct {
    xs: []f32,
    slots: []Slot,
};

fn of(p: *anyopaque) *Input {
    return @ptrCast(@alignCast(p));
}

fn create(gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque {
    const in = try gpa.create(Input);
    errdefer gpa.destroy(in);
    const xs = try gpa.alloc(f32, n);
    errdefer gpa.free(xs);
    const slots = try gpa.alloc(Slot, (n + block - 1) / block);
    data.fillUnit(xs, seed);
    in.* = .{ .xs = xs, .slots = slots };
    return in;
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    gpa.free(in.slots);
    gpa.free(in.xs);
    gpa.destroy(in);
}

/// The reference: one loop, one value at a time, all four results together.
fn onePass(xs: []const f32) Stats {
    var s: Stats = .{};
    for (xs) |x| {
        s.sum += x;
        s.squares += @as(f64, x) * x;
        s.min = @min(s.min, x);
        s.max = @max(s.max, x);
    }
    return s;
}

/// Four simple loops, one per result.
fn fourPasses(xs: []const f32) Stats {
    var s: Stats = .{};
    for (xs) |x| s.sum += x;
    for (xs) |x| s.squares += @as(f64, x) * x;
    for (xs) |x| s.min = @min(s.min, x);
    for (xs) |x| s.max = @max(s.max, x);
    return s;
}

/// One loop, 16 values at a time.
fn wide(xs: []const f32) Stats {
    const F = @Vector(lanes, f32);
    const D = @Vector(lanes, f64);
    var sum: D = @splat(0);
    var squares: D = @splat(0);
    var lo: F = @splat(std.math.inf(f32));
    var hi: F = @splat(-std.math.inf(f32));
    var i: usize = 0;
    while (i + lanes <= xs.len) : (i += lanes) {
        const v: F = xs[i..][0..lanes].*;
        const d: D = @floatCast(v);
        sum += d;
        squares += d * d;
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    var s: Stats = .{
        .sum = @reduce(.Add, sum),
        .squares = @reduce(.Add, squares),
        .min = @reduce(.Min, lo),
        .max = @reduce(.Max, hi),
    };
    s.add(onePass(xs[i..]));
    return s;
}

fn Serial(comptime kernel: fn ([]const f32) Stats) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            _ = env;
            const in = of(p);
            return kernel(in.xs).answer(in.xs.len);
        }
    };
}

/// Pool task over block indices [begin, end).
fn statBlocks(ctx: *anyopaque, worker: usize, begin: usize, end: usize) void {
    _ = worker;
    const in = of(ctx);
    for (begin..end) |b| {
        const lo = b * block;
        in.slots[b].stats = wide(in.xs[lo..@min(lo + block, in.xs.len)]);
    }
}

fn Threads(comptime count: u32) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            const in = of(p);
            const pool = try env.pool(count);
            pool.parallelFor(in.slots.len, in, statBlocks, 1);
            var s: Stats = .{};
            for (in.slots) |slot| s.add(slot.stats);
            return s.answer(in.xs.len);
        }
    };
}

pub const job: harness.Job = .{
    .id = "S1",
    .group = "data science",
    .title = "column statistics: mean, variance, min, max",
    .unit = "values",
    .bytes_per_item = @sizeOf(f32),
    .sizes = &.{ 10_000, 1_000_000, 100_000_000 },
    .quick_sizes = &.{ 1_000, 200_000 },
    .tolerance = 1e-9,
    .source = @embedFile("s1_stats.zig"),
    .create = create,
    .destroy = destroy,
    .variants = &.{
        .{ .name = "onepass", .what = "one loop, one value at a time, all four results", .run = Serial(onePass).run },
        .{ .name = "fourpasses", .what = "four simple loops, one per result", .run = Serial(fourPasses).run },
        .{ .name = "lanes16", .what = "one loop, 16 values at a time", .run = Serial(wide).run },
        .{ .name = "threads8", .what = "lanes16 on 8 threads", .run = Threads(8).run, .threads = true },
        .{ .name = "threads16", .what = "lanes16 on 16 threads", .run = Threads(16).run, .threads = true },
    },
};

test "S1: every variant gives the reference answer" {
    try harness.expectVariantsAgree(&job, &.{ 0, 1, 2, 15, 16, 17, 31, 33, 1000, block - 1, block, block + 1, 2 * block + 3 });
}

test "S1: the reference on a column worked out by hand" {
    // 1, 2, 3, 6: mean 3, mean of squares 12.5, variance 3.5, min 1, max 6.
    const s = onePass(&.{ 1, 2, 3, 6 });
    try std.testing.expectEqual(@as(f64, 12), s.sum);
    try std.testing.expectEqual(@as(f64, 50), s.squares);
    try std.testing.expectEqual(@as(f64, 3 + 3.5 + 1 + 6), s.answer(4));
    try std.testing.expectEqual(@as(f64, 0), (Stats{}).answer(0));
    // The wide kernel on values where min and max sit in the vector part and in the tail.
    var xs: [37]f32 = undefined;
    for (&xs, 0..) |*x, i| x.* = @floatFromInt(i + 10);
    xs[5] = -4;
    xs[36] = 900;
    const w = wide(&xs);
    try std.testing.expectEqual(@as(f32, -4), w.min);
    try std.testing.expectEqual(@as(f32, 900), w.max);
    try std.testing.expectEqual(onePass(&xs).sum, w.sum);
}
