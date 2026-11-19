// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! D2: filter rows by a condition and collect the ones that pass.
//!
//! Input: `n` 32-bit floats in [0, 1) (data.fillUnit, seed 12345) and a threshold.
//! Output: the values below the threshold, in their original order.
//! Answer (for comparing variants): how many passed, plus the first, middle and last of them.
//! Two jobs share this file: D2 keeps about half the rows (the condition is a coin flip), D2s
//! keeps about 1 in 100 (the condition is almost always false).
//! Outside check: verify/data_jobs.py (NumPy).

const std = @import("std");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const Env = harness.Env;

const seed = 12345;
const lanes = 16;

/// Threaded variants filter the column in blocks of this many values. Each block writes its
/// survivors into the part of the output that lines up with its own part of the input, so the
/// output stays in order as a list of per-block runs and no two workers share memory.
const block = 1 << 16;

/// One survivor count per cache line: two workers never write the same line.
const Count = struct { n: usize align(std.atomic.cache_line) = 0 };

const Input = struct {
    xs: []f32,
    out: []f32,
    counts: []Count,
    threshold: f32,
};

fn of(p: *anyopaque) *Input {
    return @ptrCast(@alignCast(p));
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    gpa.free(in.counts);
    gpa.free(in.out);
    gpa.free(in.xs);
    gpa.destroy(in);
}

/// The count plus the first, middle and last survivor.
fn answerOf(out: []const f32) f64 {
    var a: f64 = @floatFromInt(out.len);
    if (out.len == 0) return a;
    a += out[0];
    a += out[out.len / 2];
    a += out[out.len - 1];
    return a;
}

/// The reference: test each value, copy it if it passes.
fn branch(xs: []const f32, t: f32, out: []f32) usize {
    var k: usize = 0;
    for (xs) |x| {
        if (x < t) {
            out[k] = x;
            k += 1;
        }
    }
    return k;
}

/// Always copy, and move the write position only when the value passes: no branch to mispredict.
/// Needs `out.len >= xs.len`.
fn branchFree(xs: []const f32, t: f32, out: []f32) usize {
    var k: usize = 0;
    for (xs) |x| {
        out[k] = x;
        k += @intFromBool(x < t);
    }
    return k;
}

/// Compare 16 values at once into a 16-bit mask, then copy only the values whose bit is set.
fn maskBits(xs: []const f32, t: f32, out: []f32) usize {
    const limit: @Vector(lanes, f32) = @splat(t);
    var k: usize = 0;
    var i: usize = 0;
    while (i + lanes <= xs.len) : (i += lanes) {
        const v: @Vector(lanes, f32) = xs[i..][0..lanes].*;
        var mask: u16 = @bitCast(v < limit);
        while (mask != 0) : (mask &= mask - 1) {
            out[k] = xs[i + @ctz(mask)];
            k += 1;
        }
    }
    while (i < xs.len) : (i += 1) {
        out[k] = xs[i];
        k += @intFromBool(xs[i] < t);
    }
    return k;
}

fn Serial(comptime kernel: fn ([]const f32, f32, []f32) usize) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            _ = env;
            const in = of(p);
            return answerOf(in.out[0..kernel(in.xs, in.threshold, in.out)]);
        }
    };
}

/// Pool task over block indices [begin, end).
fn filterBlocks(ctx: *anyopaque, worker: usize, begin: usize, end: usize) void {
    _ = worker;
    const in = of(ctx);
    for (begin..end) |b| {
        const lo = b * block;
        const hi = @min(lo + block, in.xs.len);
        in.counts[b].n = maskBits(in.xs[lo..hi], in.threshold, in.out[lo..hi]);
    }
}

/// Survivor number `index` (counting from 0 across all blocks, in order).
fn blockItem(in: *const Input, index: usize) f32 {
    var left = index;
    for (in.counts, 0..) |c, b| {
        if (left < c.n) return in.out[b * block + left];
        left -= c.n;
    }
    unreachable; // callers pass index < total
}

fn Threads(comptime count: u32) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            const in = of(p);
            const pool = try env.pool(count);
            pool.parallelFor(in.counts.len, in, filterBlocks, 1);
            var total: usize = 0;
            for (in.counts) |c| total += c.n;
            var a: f64 = @floatFromInt(total);
            if (total == 0) return a;
            a += blockItem(in, 0);
            a += blockItem(in, total / 2);
            a += blockItem(in, total - 1);
            return a;
        }
    };
}

fn Filter(comptime id: []const u8, comptime title: []const u8, comptime threshold: f32) type {
    return struct {
        fn create(gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque {
            const in = try gpa.create(Input);
            errdefer gpa.destroy(in);
            const xs = try gpa.alloc(f32, n);
            errdefer gpa.free(xs);
            const out = try gpa.alloc(f32, n);
            errdefer gpa.free(out);
            const counts = try gpa.alloc(Count, (n + block - 1) / block);
            data.fillUnit(xs, seed);
            in.* = .{ .xs = xs, .out = out, .counts = counts, .threshold = threshold };
            return in;
        }

        pub const job: harness.Job = .{
            .id = id,
            .group = "data processing",
            .title = title,
            .unit = "rows",
            .bytes_per_item = @sizeOf(f32),
            .sizes = &.{ 10_000, 1_000_000, 100_000_000 },
            .quick_sizes = &.{ 1_000, 200_000 },
            .tolerance = 1e-12,
            .source = @embedFile("d2_filter.zig"),
            .create = create,
            .destroy = destroy,
            .variants = &.{
                .{ .name = "branch", .what = "test each value, copy it if it passes", .run = Serial(branch).run },
                .{ .name = "branchfree", .what = "always copy, advance only on a pass", .run = Serial(branchFree).run },
                .{ .name = "mask16", .what = "compare 16 at a time, copy the set bits", .run = Serial(maskBits).run },
                .{ .name = "threads8", .what = "mask16 on 8 threads, output left in per-block runs", .run = Threads(8).run },
                .{ .name = "threads16", .what = "mask16 on 16 threads, output left in per-block runs", .run = Threads(16).run },
            },
        };
    };
}

pub const half = Filter("D2", "filter rows, about half pass", 0.5).job;
pub const sparse = Filter("D2s", "filter rows, about 1 in 100 pass", 0.01).job;

const edge_sizes = [_]usize{ 0, 1, 15, 16, 17, 31, 32, 33, 1000, block - 1, block, block + 1, 2 * block + 7 };

test "D2: every variant gives the reference answer" {
    try harness.expectVariantsAgree(&half, &edge_sizes);
    try harness.expectVariantsAgree(&sparse, &edge_sizes);
}

test "D2: every kernel collects exactly the same rows, in order" {
    const gpa = std.testing.allocator;
    for ([_]f32{ 0.0, 0.01, 0.5, 1.0 }) |t| {
        for (edge_sizes) |n| {
            const xs = try gpa.alloc(f32, n);
            defer gpa.free(xs);
            data.fillUnit(xs, seed);
            const want = try gpa.alloc(f32, n);
            defer gpa.free(want);
            const got = try gpa.alloc(f32, n);
            defer gpa.free(got);
            const k = branch(xs, t, want);
            // The reference itself: everything kept is below t, and the count matches a plain count.
            var plain: usize = 0;
            for (xs) |x| plain += @intFromBool(x < t);
            try std.testing.expectEqual(plain, k);
            for (want[0..k]) |x| try std.testing.expect(x < t);
            try std.testing.expectEqual(k, branchFree(xs, t, got));
            try std.testing.expectEqualSlices(f32, want[0..k], got[0..k]);
            @memset(got, -1);
            try std.testing.expectEqual(k, maskBits(xs, t, got));
            try std.testing.expectEqualSlices(f32, want[0..k], got[0..k]);
        }
    }
}

test "D2: the block runs of the threaded variant join into the reference output" {
    const gpa = std.testing.allocator;
    const n = 3 * block + 123;
    var env: Env = .{ .gpa = gpa, .io = std.testing.io, .force_threads = 3 };
    defer env.deinit();
    const p = try half.create(gpa, n);
    defer half.destroy(gpa, p);
    _ = try Threads(3).run(&env, p);
    const in = of(p);
    const want = try gpa.alloc(f32, n);
    defer gpa.free(want);
    const k = branch(in.xs, in.threshold, want);
    var total: usize = 0;
    for (in.counts) |c| total += c.n;
    try std.testing.expectEqual(k, total);
    for (0..k) |i| try std.testing.expectEqual(want[i], blockItem(in, i));
}
