// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! D1: add up a column.
//!
//! Input: `n` 32-bit floats in [0, 1) (data.fillUnit, seed 12345).
//! Output: their sum, accumulated in 64-bit so every variant can be compared.
//! Outside check: verify/d1_sum.py (NumPy) on 1,000,000 values.

const std = @import("std");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const Env = harness.Env;

const seed = 12345;

/// Threaded variants cut the column into blocks of this many values. A worker writes one
/// partial sum per block, and the partial sums are added in block order afterwards, so the
/// answer does not depend on which worker took which block.
const block = 1 << 16;

/// One partial sum per cache line: two workers never write the same line.
const Partial = struct { sum: f64 align(std.atomic.cache_line) = 0 };

const Input = struct {
    xs: []f32,
    partials: []Partial,
};

fn create(gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque {
    const in = try gpa.create(Input);
    errdefer gpa.destroy(in);
    const xs = try gpa.alloc(f32, n);
    errdefer gpa.free(xs);
    const partials = try gpa.alloc(Partial, (n + block - 1) / block);
    data.fillUnit(xs, seed);
    in.* = .{ .xs = xs, .partials = partials };
    return in;
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    gpa.free(in.partials);
    gpa.free(in.xs);
    gpa.destroy(in);
}

fn of(p: *anyopaque) *Input {
    return @ptrCast(@alignCast(p));
}

/// The reference: one value at a time, in order.
fn reference(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    var sum: f64 = 0;
    for (of(p).xs) |x| sum += x;
    return sum;
}

/// The same loop, with the compiler allowed to reorder the additions.
fn reorder(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    @setFloatMode(.optimized);
    var sum: f64 = 0;
    for (of(p).xs) |x| sum += x;
    return sum;
}

/// `lanes` values at a time into `chains` independent running sums.
fn sumSlice(comptime lanes: comptime_int, comptime chains: comptime_int, xs: []const f32) f64 {
    const Wide = @Vector(lanes, f64);
    var acc: [chains]Wide = @splat(@splat(0));
    const step = lanes * chains;
    var i: usize = 0;
    while (i + step <= xs.len) : (i += step) {
        inline for (0..chains) |c| {
            const v: @Vector(lanes, f32) = xs[i + c * lanes ..][0..lanes].*;
            acc[c] += @as(Wide, @floatCast(v));
        }
    }
    var total: Wide = acc[0];
    inline for (1..chains) |c| total += acc[c];
    var sum: f64 = @reduce(.Add, total);
    while (i < xs.len) : (i += 1) sum += xs[i];
    return sum;
}

fn Vectors(comptime lanes: comptime_int, comptime chains: comptime_int) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            _ = env;
            return sumSlice(lanes, chains, of(p).xs);
        }
    };
}

/// Pool task over block indices [begin, end).
fn sumBlocks(ctx: *anyopaque, worker: usize, begin: usize, end: usize) void {
    _ = worker;
    const in = of(ctx);
    for (begin..end) |b| {
        const lo = b * block;
        const hi = @min(lo + block, in.xs.len);
        in.partials[b].sum = sumSlice(16, 4, in.xs[lo..hi]);
    }
}

fn Threads(comptime count: u32) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            const in = of(p);
            const pool = try env.pool(count);
            pool.parallelFor(in.partials.len, in, sumBlocks, 1);
            var sum: f64 = 0;
            for (in.partials) |part| sum += part.sum;
            return sum;
        }
    };
}

pub const job: harness.Job = .{
    .id = "D1",
    .group = "data processing",
    .title = "add up a column",
    .unit = "values",
    .bytes_per_item = @sizeOf(f32),
    .sizes = &.{ 10_000, 1_000_000, 100_000_000 },
    .quick_sizes = &.{ 1_000, 200_000 },
    .tolerance = 1e-9,
    .source = @embedFile("d1_sum.zig"),
    .create = create,
    .destroy = destroy,
    .variants = &.{
        .{ .name = "reference", .what = "one value at a time, in order", .run = reference },
        .{ .name = "reorder", .what = "the same loop, compiler free to reorder the additions", .run = reorder },
        .{ .name = "lanes4", .what = "4 values at a time", .run = Vectors(4, 1).run },
        .{ .name = "lanes8", .what = "8 values at a time", .run = Vectors(8, 1).run },
        .{ .name = "lanes16", .what = "16 values at a time", .run = Vectors(16, 1).run },
        .{ .name = "lanes16x4", .what = "16 at a time into 4 independent running sums", .run = Vectors(16, 4).run },
        .{ .name = "lanes16x8", .what = "16 at a time into 8 independent running sums", .run = Vectors(16, 8).run },
        .{ .name = "threads8", .what = "lanes16x4 on 8 threads", .run = Threads(8).run },
        .{ .name = "threads14", .what = "lanes16x4 on 14 threads", .run = Threads(14).run },
        .{ .name = "threads16", .what = "lanes16x4 on 16 threads", .run = Threads(16).run },
    },
};

test "D1: every variant equals the reference, at the edges of a vector and of a block" {
    try harness.expectVariantsAgree(&job, &.{ 0, 1, 15, 16, 17, 63, 64, 65, 127, 128, 129, block - 1, block, block + 1, 3 * block + 5 });
}

test "D1: the reference is the plain sum" {
    const gpa = std.testing.allocator;
    var env: Env = .{ .gpa = gpa, .io = std.testing.io };
    defer env.deinit();
    const input = try create(gpa, 1000);
    defer destroy(gpa, input);
    var want: f64 = 0;
    var state: u32 = seed;
    for (0..1000) |_| want += @as(f32, @floatFromInt(data.next(&state) >> 8)) / 16777216.0;
    try std.testing.expectEqual(want, try reference(&env, input));
    // 1000 values in [0, 1) average about a half.
    try std.testing.expect(want > 400 and want < 600);
}
