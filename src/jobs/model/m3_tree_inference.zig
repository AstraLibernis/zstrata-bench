// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M3: run rows through an ensemble of decision trees.
//!
//! Input: `n` rows of 8 features (32-bit floats in [0, 1), data.fillUnit seed 90) and 100 full
//! trees of depth 6. A tree is 63 tests in heap order (the children of test i are 2i+1 and 2i+2)
//! followed by 64 leaf values; a row goes right when its feature is greater than the threshold.
//! Tree t, with base = 1000 t and unit(x) = (x >> 8) / 2^24:
//!   feature of test i     data.mix(base + i) & 7
//!   threshold of test i   unit(data.mix(base + i + 500000))
//!   value of leaf j       unit(data.mix(base + j + 900000)) - 0.5
//! Output: for every row, the sum of its 100 leaf values (added in tree order, in 32-bit).
//! Answer (for comparing variants): those row sums added together in 64-bit.
//! Outside check: verify/model_jobs.py (NumPy).

const std = @import("std");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const Env = harness.Env;

const feats = 8;
const trees = 100;
const depth = 6;
const tests = (1 << depth) - 1;
const leaves = 1 << depth;

const Tree = struct {
    thr: [tests]f32,
    leaf: [leaves]f32,
    feat: [tests]u8,
};

/// Row blocks: the rows of one block (8 KiB) stay in a core's cache while every tree visits them.
const block = 256;

/// One block total per cache line: two workers never write the same line.
const Slot = struct { total: f64 align(std.atomic.cache_line) = 0 };

const Input = struct {
    n: usize,
    rows: []f32,
    forest: []Tree,
    slots: []Slot,
};

fn of(p: *anyopaque) *Input {
    return @ptrCast(@alignCast(p));
}

fn unit(x: u32) f32 {
    return @as(f32, @floatFromInt(x >> 8)) / 16777216.0;
}

fn create(gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque {
    const in = try gpa.create(Input);
    errdefer gpa.destroy(in);
    const rows = try gpa.alloc(f32, n * feats);
    errdefer gpa.free(rows);
    const forest = try gpa.alloc(Tree, trees);
    errdefer gpa.free(forest);
    const slots = try gpa.alloc(Slot, (n + block - 1) / block);
    data.fillUnit(rows, 90);
    for (forest, 0..) |*t, ti| {
        const base: u32 = @intCast(ti * 1000);
        for (0..tests) |i| {
            t.feat[i] = @intCast(data.mix(base + @as(u32, @intCast(i))) & 7);
            t.thr[i] = unit(data.mix(base + @as(u32, @intCast(i)) + 500_000));
        }
        for (0..leaves) |j| t.leaf[j] = unit(data.mix(base + @as(u32, @intCast(j)) + 900_000)) - 0.5;
    }
    in.* = .{ .n = n, .rows = rows, .forest = forest, .slots = slots };
    return in;
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    gpa.free(in.slots);
    gpa.free(in.forest);
    gpa.free(in.rows);
    gpa.destroy(in);
}

fn walkBranch(t: *const Tree, x: *const [feats]f32) f32 {
    var i: usize = 0;
    inline for (0..depth) |_| {
        if (x[t.feat[i]] > t.thr[i]) i = 2 * i + 2 else i = 2 * i + 1;
    }
    return t.leaf[i - tests];
}

fn walkArith(t: *const Tree, x: *const [feats]f32) f32 {
    var i: usize = 0;
    inline for (0..depth) |_| i = 2 * i + 1 + @intFromBool(x[t.feat[i]] > t.thr[i]);
    return t.leaf[i - tests];
}

fn row(in: *const Input, r: usize) *const [feats]f32 {
    return in.rows[r * feats ..][0..feats];
}

/// The reference: for each row, each tree in turn, with an `if` at every test.
fn rowsBranch(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    var total: f64 = 0;
    for (0..in.n) |r| {
        var sum: f32 = 0;
        for (in.forest) |*t| sum += walkBranch(t, row(in, r));
        total += sum;
    }
    return total;
}

/// For each row, each tree in turn, the step down written as arithmetic (no `if`).
fn rowsArith(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    var total: f64 = 0;
    for (0..in.n) |r| {
        var sum: f32 = 0;
        for (in.forest) |*t| sum += walkArith(t, row(in, r));
        total += sum;
    }
    return total;
}

/// Rows [lo, hi), at most `block` of them: each tree visits all the rows before the next tree.
/// With `together` > 1 that many rows walk down a tree side by side.
fn blockTotal(comptime together: comptime_int, comptime step: Step, in: *const Input, lo: usize, hi: usize) f64 {
    var sums: [block]f32 = @splat(0);
    const count = hi - lo;
    for (in.forest) |*t| {
        var r: usize = 0;
        if (together > 1) {
            while (r + together <= count) : (r += together) {
                var i: [together]usize = @splat(0);
                inline for (0..depth) |_| {
                    inline for (0..together) |k| {
                        const x = row(in, lo + r + k);
                        i[k] = 2 * i[k] + 1 + @intFromBool(x[t.feat[i[k]]] > t.thr[i[k]]);
                    }
                }
                inline for (0..together) |k| sums[r + k] += t.leaf[i[k] - tests];
            }
        }
        while (r < count) : (r += 1) sums[r] += if (step == .branch) walkBranch(t, row(in, lo + r)) else walkArith(t, row(in, lo + r));
    }
    var total: f64 = 0;
    for (sums[0..count]) |s| total += s;
    return total;
}

const Step = enum { branch, arith };

fn Blocks(comptime together: comptime_int, comptime step: Step) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            _ = env;
            const in = of(p);
            var total: f64 = 0;
            var lo: usize = 0;
            while (lo < in.n) : (lo += block) total += blockTotal(together, step, in, lo, @min(lo + block, in.n));
            return total;
        }
    };
}

/// Pool task over block indices [begin, end).
fn blockTask(ctx: *anyopaque, worker: usize, begin: usize, end: usize) void {
    _ = worker;
    const in = of(ctx);
    for (begin..end) |b| in.slots[b].total = blockTotal(1, .arith, in, b * block, @min((b + 1) * block, in.n));
}

fn Threads(comptime count: u32) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            const in = of(p);
            const pool = try env.pool(count);
            pool.parallelFor(in.slots.len, in, blockTask, 1);
            var total: f64 = 0;
            for (in.slots) |s| total += s.total;
            return total;
        }
    };
}

pub const job: harness.Job = .{
    .id = "M3",
    .group = "model learning",
    .title = "tree ensemble inference: 100 trees of depth 6 over rows of 8 features",
    .unit = "rows",
    .bytes_per_item = feats * @sizeOf(f32),
    .sizes = &.{ 1_000, 100_000, 1_000_000 },
    .quick_sizes = &.{ 100, 10_000 },
    .tolerance = 1e-9,
    .source = @embedFile("m3_tree_inference.zig"),
    .create = create,
    .destroy = destroy,
    .variants = &.{
        .{ .name = "branch", .what = "row by row, tree by tree, an `if` at every test", .run = rowsBranch },
        .{ .name = "arith", .what = "row by row, the step down written as arithmetic", .run = rowsArith },
        .{ .name = "treefirst", .what = "256 rows at a time; each tree visits them all before the next tree; arithmetic steps", .run = Blocks(1, .arith).run },
        .{ .name = "treefirstif", .what = "treefirst with an `if` at every test", .run = Blocks(1, .branch).run },
        .{ .name = "four", .what = "treefirst with four rows walking down a tree side by side", .run = Blocks(4, .arith).run },
        .{ .name = "eight", .what = "treefirst with eight rows walking down a tree side by side", .run = Blocks(8, .arith).run },
        .{ .name = "threads8", .what = "treefirst, blocks of rows on 8 threads", .run = Threads(8).run, .threads = true },
        .{ .name = "threads16", .what = "treefirst, blocks of rows on 16 threads", .run = Threads(16).run, .threads = true },
    },
};

test "M3: every variant gives the reference answer" {
    try harness.expectVariantsAgree(&job, &.{ 0, 1, 3, 4, 5, 7, 8, 9, block - 1, block, block + 1, 3 * block + 5 });
}

test "M3: a walk worked out by hand, both ways of stepping" {
    var t: Tree = undefined;
    // Every test looks at feature 2 with threshold 0.5; leaf j holds j.
    @memset(&t.feat, 2);
    @memset(&t.thr, 0.5);
    for (&t.leaf, 0..) |*l, j| l.* = @floatFromInt(j);
    var x: [feats]f32 = @splat(0);
    // Always left: leaf 0. Always right: leaf 63. Exactly on the threshold is not "greater": left.
    try std.testing.expectEqual(@as(f32, 0), walkBranch(&t, &x));
    try std.testing.expectEqual(@as(f32, 0), walkArith(&t, &x));
    x[2] = 0.75;
    try std.testing.expectEqual(@as(f32, 63), walkBranch(&t, &x));
    try std.testing.expectEqual(@as(f32, 63), walkArith(&t, &x));
    x[2] = 0.5;
    try std.testing.expectEqual(@as(f32, 0), walkArith(&t, &x));
    // Right at the root only: the leftmost leaf of the right half.
    t.thr[0] = 0.25;
    x[2] = 0.3;
    try std.testing.expectEqual(@as(f32, 32), walkBranch(&t, &x));
    try std.testing.expectEqual(@as(f32, 32), walkArith(&t, &x));
}
