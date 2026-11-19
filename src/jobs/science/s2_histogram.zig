// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! S2: histogram of a column.
//!
//! Input: `n` 32-bit floats in [0, 1) (data.fillUnit, seed 12).
//! Output: how many values fall in each of 256 equal-width bins (bin = floor(value * 256)).
//! Answer (for comparing variants): every count weighted by (bin + 1), added up.
//! Outside check: verify/science_jobs.py (NumPy).

const std = @import("std");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const Env = harness.Env;

const seed = 12;
const bins = 256;
const lanes = 16;
const Counts = [bins]u32;

/// The threaded variant splits the column into this many equal parts, each with its own counts.
const parts = 16;

/// One part's counts start on their own cache line and fill whole lines, so two workers never
/// write the same line.
const Part = struct { counts: Counts align(std.atomic.cache_line) = @splat(0) };

const Input = struct {
    xs: []f32,
    counts: Counts = @splat(0),
    part: []Part,
};

fn of(p: *anyopaque) *Input {
    return @ptrCast(@alignCast(p));
}

fn create(gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque {
    if (n > std.math.maxInt(u32)) return error.TooManyValues;
    const in = try gpa.create(Input);
    errdefer gpa.destroy(in);
    const xs = try gpa.alloc(f32, n);
    errdefer gpa.free(xs);
    const part = try gpa.alloc(Part, parts);
    data.fillUnit(xs, seed);
    in.* = .{ .xs = xs, .part = part };
    return in;
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    gpa.free(in.part);
    gpa.free(in.xs);
    gpa.destroy(in);
}

fn binOf(x: f32) usize {
    return @trunc(x * bins);
}

fn answerOf(counts: *const Counts) f64 {
    var a: f64 = 0;
    for (counts, 1..) |c, weight| a += @as(f64, @floatFromInt(c)) * @as(f64, @floatFromInt(weight));
    return a;
}

/// The reference: one table, one value at a time.
fn oneTable(xs: []const f32, counts: *Counts) void {
    @memset(counts, 0);
    for (xs) |x| counts[binOf(x)] += 1;
}

/// Four tables fed in turn, added together at the end. Two neighbouring values that fall in
/// the same bin then update different memory, so the second need not wait for the first.
fn fourTables(xs: []const f32, counts: *Counts) void {
    var t: [4]Counts = @splat(@splat(0));
    var i: usize = 0;
    while (i + 4 <= xs.len) : (i += 4) {
        inline for (0..4) |k| t[k][binOf(xs[i + k])] += 1;
    }
    while (i < xs.len) : (i += 1) t[0][binOf(xs[i])] += 1;
    for (counts, t[0], t[1], t[2], t[3]) |*c, a, b, d, e| c.* = a + b + d + e;
}

/// Work out 16 bin numbers at once, then count them into four tables.
fn wideBins(xs: []const f32, counts: *Counts) void {
    var t: [4]Counts = @splat(@splat(0));
    const scale: @Vector(lanes, f32) = @splat(bins);
    var i: usize = 0;
    while (i + lanes <= xs.len) : (i += lanes) {
        const v: @Vector(lanes, f32) = xs[i..][0..lanes].*;
        const b: [lanes]u32 = @as(@Vector(lanes, u32), @trunc(v * scale));
        inline for (0..lanes) |k| t[k % 4][b[k]] += 1;
    }
    while (i < xs.len) : (i += 1) t[0][binOf(xs[i])] += 1;
    for (counts, t[0], t[1], t[2], t[3]) |*c, a, b, d, e| c.* = a + b + d + e;
}

fn Serial(comptime kernel: fn ([]const f32, *Counts) void) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            _ = env;
            const in = of(p);
            kernel(in.xs, &in.counts);
            return answerOf(&in.counts);
        }
    };
}

/// Pool task over parts [begin, end).
fn countParts(ctx: *anyopaque, worker: usize, begin: usize, end: usize) void {
    _ = worker;
    const in = of(ctx);
    const n = in.xs.len;
    for (begin..end) |b| fourTables(in.xs[b * n / parts .. (b + 1) * n / parts], &in.part[b].counts);
}

fn Threads(comptime count: u32) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            const in = of(p);
            const pool = try env.pool(count);
            pool.parallelFor(parts, in, countParts, 1);
            @memset(&in.counts, 0);
            for (in.part) |*pt| {
                for (&in.counts, pt.counts) |*c, x| c.* += x;
            }
            return answerOf(&in.counts);
        }
    };
}

pub const job: harness.Job = .{
    .id = "S2",
    .group = "data science",
    .title = "histogram of a column, 256 bins",
    .unit = "values",
    .bytes_per_item = @sizeOf(f32),
    .sizes = &.{ 10_000, 1_000_000, 100_000_000 },
    .quick_sizes = &.{ 1_000, 200_000 },
    .tolerance = 0,
    .source = @embedFile("s2_histogram.zig"),
    .create = create,
    .destroy = destroy,
    .variants = &.{
        .{ .name = "onetable", .what = "one table, one value at a time", .run = Serial(oneTable).run },
        .{ .name = "fourtables", .what = "four tables fed in turn, added at the end", .run = Serial(fourTables).run },
        .{ .name = "bins16", .what = "16 bin numbers worked out at once, counted into four tables", .run = Serial(wideBins).run },
        .{ .name = "threads8", .what = "16 parts with their own tables, on 8 threads", .run = Threads(8).run, .threads = true },
        .{ .name = "threads16", .what = "16 parts with their own tables, on 16 threads", .run = Threads(16).run, .threads = true },
    },
};

const edge_sizes = [_]usize{ 0, 1, 3, 4, 5, 15, 16, 17, 33, 1000, 70_003 };

test "S2: every variant gives the reference answer" {
    try harness.expectVariantsAgree(&job, &edge_sizes);
}

test "S2: every kernel produces the same 256 counts, and they add up to n" {
    const gpa = std.testing.allocator;
    for (edge_sizes) |n| {
        const xs = try gpa.alloc(f32, n);
        defer gpa.free(xs);
        data.fillUnit(xs, seed);
        var want: Counts = undefined;
        oneTable(xs, &want);
        var total: usize = 0;
        for (want) |c| total += c;
        try std.testing.expectEqual(n, total);
        var got: Counts = undefined;
        fourTables(xs, &got);
        try std.testing.expectEqualSlices(u32, &want, &got);
        wideBins(xs, &got);
        try std.testing.expectEqualSlices(u32, &want, &got);
    }
}

test "S2: bin edges" {
    try std.testing.expectEqual(@as(usize, 0), binOf(0.0));
    try std.testing.expectEqual(@as(usize, 0), binOf(0.0039));
    try std.testing.expectEqual(@as(usize, 1), binOf(1.0 / 256.0));
    try std.testing.expectEqual(@as(usize, 128), binOf(0.5));
    // The largest value the generator can produce stays in the last bin.
    try std.testing.expectEqual(@as(usize, 255), binOf(16777215.0 / 16777216.0));
}
