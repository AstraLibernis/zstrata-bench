// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! S5: distances between all pairs of rows.
//!
//! Input: points in 8 dimensions, 32-bit floats in [0, 1); dimension d is data.fillUnit with
//! seed 30 + d. A size counts pairs: for size n there are floor(sqrt(n)) points.
//! Output: for every point, the squared distance to its nearest other point.
//! Answer (for comparing variants): those nearest distances added together in 64-bit; 0 for
//! fewer than 2 points.
//! The points are held both ways round (one array per dimension, and point after point).
//! Outside check: verify/science_jobs.py (NumPy).

const std = @import("std");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const Env = harness.Env;

const dims = 8;
const lanes = 16;
const Vec = @Vector(lanes, f32);

/// Padding in the per-dimension arrays sits this far away, so it is never the nearest point.
const far: f32 = 1e18;

/// Threaded variants take the points in blocks of this many; block totals are added in block order.
const block = 256;

/// One block total per cache line: two workers never write the same line.
const Slot = struct { total: f64 align(std.atomic.cache_line) = 0 };

const Input = struct {
    points: usize,
    /// One array per dimension, padded with `far` to a whole number of vectors.
    dim: [dims][]f32,
    /// Point after point: dims floats each.
    rows: []f32,
    slots: []Slot,
};

fn of(p: *anyopaque) *Input {
    return @ptrCast(@alignCast(p));
}

fn create(gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque {
    const points: usize = std.math.sqrt(n);
    const padded = std.mem.alignForward(usize, points, lanes);
    const in = try gpa.create(Input);
    errdefer gpa.destroy(in);
    var dim: [dims][]f32 = undefined;
    var made: usize = 0;
    errdefer for (dim[0..made]) |d| gpa.free(d);
    while (made < dims) : (made += 1) dim[made] = try gpa.alloc(f32, padded);
    const rows = try gpa.alloc(f32, points * dims);
    errdefer gpa.free(rows);
    const slots = try gpa.alloc(Slot, (points + block - 1) / block);

    for (dim, 0..) |d, k| {
        data.fillUnit(d[0..points], 30 + @as(u32, @intCast(k)));
        @memset(d[points..], far);
    }
    for (0..points) |i| {
        for (0..dims) |k| rows[i * dims + k] = dim[k][i];
    }
    in.* = .{ .points = points, .dim = dim, .rows = rows, .slots = slots };
    return in;
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    gpa.free(in.slots);
    gpa.free(in.rows);
    for (in.dim) |d| gpa.free(d);
    gpa.destroy(in);
}

/// The reference: three plain loops over point, other point, dimension.
fn plain(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    if (in.points < 2) return 0;
    var total: f64 = 0;
    for (0..in.points) |i| {
        const a = in.rows[i * dims ..][0..dims];
        var best = std.math.inf(f32);
        for (0..in.points) |j| {
            if (j == i) continue;
            const b = in.rows[j * dims ..][0..dims];
            var d2: f32 = 0;
            for (a, b) |x, y| d2 += (x - y) * (x - y);
            best = @min(best, d2);
        }
        total += best;
    }
    return total;
}

/// Each pair's 8 dimensions as one vector.
fn acrossDims(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    if (in.points < 2) return 0;
    const Row = @Vector(dims, f32);
    var total: f64 = 0;
    for (0..in.points) |i| {
        const a: Row = in.rows[i * dims ..][0..dims].*;
        var best = std.math.inf(f32);
        for (0..in.points) |j| {
            if (j == i) continue;
            const diff = @as(Row, in.rows[j * dims ..][0..dims].*) - a;
            best = @min(best, @reduce(.Add, diff * diff));
        }
        total += best;
    }
    return total;
}

/// Nearest squared distance from point `i` to any other, 16 other points at a time.
fn nearest(in: *const Input, i: usize) f32 {
    var here: [dims]Vec = undefined;
    for (&here, in.dim) |*h, d| h.* = @splat(d[i]);
    var best: Vec = @splat(std.math.inf(f32));
    const padded = in.dim[0].len;
    var j: usize = 0;
    while (j < padded) : (j += lanes) {
        var d2: Vec = @splat(0);
        inline for (0..dims) |k| {
            const diff = @as(Vec, in.dim[k][j..][0..lanes].*) - here[k];
            d2 += diff * diff;
        }
        // The point itself is in exactly one group of 16: take it out of the running there.
        if (i >= j and i < j + lanes) {
            var group: [lanes]f32 = d2;
            group[i - j] = std.math.inf(f32);
            d2 = group;
        }
        best = @min(best, d2);
    }
    return @reduce(.Min, best);
}

/// One array per dimension; for each point, 16 other points at a time.
fn acrossPoints(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    if (in.points < 2) return 0;
    var total: f64 = 0;
    for (0..in.points) |i| total += nearest(in, i);
    return total;
}

/// Pool task over block indices [begin, end).
fn nearestBlocks(ctx: *anyopaque, worker: usize, begin: usize, end: usize) void {
    _ = worker;
    const in = of(ctx);
    for (begin..end) |b| {
        var total: f64 = 0;
        for (b * block..@min((b + 1) * block, in.points)) |i| total += nearest(in, i);
        in.slots[b].total = total;
    }
}

fn Threads(comptime count: u32) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            const in = of(p);
            if (in.points < 2) return 0;
            const pool = try env.pool(count);
            pool.parallelFor(in.slots.len, in, nearestBlocks, 1);
            var total: f64 = 0;
            for (in.slots) |s| total += s.total;
            return total;
        }
    };
}

pub const job: harness.Job = .{
    .id = "S5",
    .group = "data science",
    .title = "nearest neighbour distance for every point, 8 dimensions, all pairs",
    .unit = "pairs",
    .bytes_per_item = 0,
    .sizes = &.{ 1_000_000, 16_000_000, 256_000_000 },
    .quick_sizes = &.{ 10_000, 250_000 },
    // Variants add a pair's eight squared differences in different orders, so the 32-bit
    // distances can differ in their last bits.
    .tolerance = 1e-5,
    .source = @embedFile("s5_distances.zig"),
    .create = create,
    .destroy = destroy,
    .variants = &.{
        .{ .name = "plain", .what = "three plain loops: point, other point, dimension", .run = plain },
        .{ .name = "dims8", .what = "each pair's 8 dimensions as one vector", .run = acrossDims },
        .{ .name = "points16", .what = "one array per dimension, 16 other points at a time", .run = acrossPoints },
        .{ .name = "threads8", .what = "points16 on 8 threads", .run = Threads(8).run, .threads = true },
        .{ .name = "threads16", .what = "points16 on 16 threads", .run = Threads(16).run, .threads = true },
    },
};

// Sizes are pairs: these give 0, 1, 2, 3, 15, 16, 17, 33, 256, 257 and 600 points.
const edge_sizes = [_]usize{ 0, 1, 4, 9, 225, 256, 289, 1089, 65_536, 66_049, 360_000 };

test "S5: every variant gives the reference answer" {
    try harness.expectVariantsAgree(&job, &edge_sizes);
}

test "S5: nearest distances of points placed by hand" {
    const gpa = std.testing.allocator;
    var env: Env = .{ .gpa = gpa, .io = std.testing.io };
    defer env.deinit();
    const p = try create(gpa, 16); // 4 points
    defer destroy(gpa, p);
    const in = of(p);
    // On a line along dimension 0 at 0, 1, 3 and 7; every other dimension is 0.
    const xs = [_]f32{ 0, 1, 3, 7 };
    for (0..4) |i| {
        for (0..dims) |k| {
            const v: f32 = if (k == 0) xs[i] else 0;
            in.dim[k][i] = v;
            in.rows[i * dims + k] = v;
        }
    }
    // Nearest squared distances: 1, 1, 4, 16.
    for (job.variants) |v| try std.testing.expectEqual(@as(f64, 22), try v.run(&env, p));
}
