// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! D3: sort a column of keys.
//!
//! Input: `n` scrambled 32-bit keys (data.fillMixed, seed 2).
//! Output: the keys in ascending order.
//! Answer (for comparing variants): the sum of the keys at positions 0, n/3, n/2 and n-1.
//! Every variant first copies the unsorted keys into its work buffer, so each timed run sorts
//! the same data; that copy is part of every variant's time.
//! Outside check: verify/data_jobs.py (NumPy).

const std = @import("std");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const radix = @import("../../kit/radix.zig");
const Env = harness.Env;

const seed = 2;
const top_buckets = 256;

const Input = struct {
    pristine: []u32,
    work: []u32,
    scratch: []u32,
    /// Where each top-byte bucket starts in `work` (threaded variant); one past the last at [256].
    starts: [top_buckets + 1]usize = undefined,
};

fn of(p: *anyopaque) *Input {
    return @ptrCast(@alignCast(p));
}

fn create(gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque {
    const in = try gpa.create(Input);
    errdefer gpa.destroy(in);
    const pristine = try gpa.alloc(u32, n);
    errdefer gpa.free(pristine);
    const work = try gpa.alloc(u32, n);
    errdefer gpa.free(work);
    const scratch = try gpa.alloc(u32, n);
    data.fillMixed(pristine, seed);
    in.* = .{ .pristine = pristine, .work = work, .scratch = scratch };
    return in;
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    gpa.free(in.scratch);
    gpa.free(in.work);
    gpa.free(in.pristine);
    gpa.destroy(in);
}

fn answerOf(sorted: []const u32) f64 {
    const n = sorted.len;
    if (n == 0) return 0;
    return @as(f64, @floatFromInt(sorted[0])) + @as(f64, @floatFromInt(sorted[n / 3])) +
        @as(f64, @floatFromInt(sorted[n / 2])) + @as(f64, @floatFromInt(sorted[n - 1]));
}

/// The reference: std's general-purpose stable sort.
fn stdSort(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    @memcpy(in.work, in.pristine);
    std.mem.sort(u32, in.work, {}, std.sort.asc(u32));
    return answerOf(in.work);
}

/// std's pattern-defeating quicksort (not stable; fine for bare keys).
fn pdq(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    @memcpy(in.work, in.pristine);
    std.sort.pdq(u32, in.work, {}, std.sort.asc(u32));
    return answerOf(in.work);
}

fn Radix(comptime digit_bits: comptime_int) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            _ = env;
            const in = of(p);
            @memcpy(in.work, in.pristine);
            radix.sort(u32, digit_bits, 0, 32, in.work, in.scratch);
            return answerOf(in.work);
        }
    };
}

/// Pool task over top-byte buckets [begin, end): each bucket is already in its final place,
/// and is sorted by its remaining 24 bits inside its own range of `work` and `scratch`.
fn sortBuckets(ctx: *anyopaque, worker: usize, begin: usize, end: usize) void {
    _ = worker;
    const in = of(ctx);
    for (begin..end) |b| {
        const lo = in.starts[b];
        const hi = in.starts[b + 1];
        radix.sort(u32, 8, 0, 24, in.work[lo..hi], in.scratch[lo..hi]);
    }
}

/// One pass on one thread deals the keys into 256 buckets by their top byte; the buckets are
/// then sorted on all threads.
fn Threads(comptime count: u32) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            const in = of(p);
            const pool = try env.pool(count);
            var counts: [top_buckets]usize = @splat(0);
            for (in.pristine) |k| counts[k >> 24] += 1;
            var at: usize = 0;
            for (in.starts[0..top_buckets], counts) |*s, c| {
                s.* = at;
                at += c;
            }
            in.starts[top_buckets] = at;
            var next: [top_buckets]usize = in.starts[0..top_buckets].*;
            for (in.pristine) |k| {
                in.work[next[k >> 24]] = k;
                next[k >> 24] += 1;
            }
            pool.parallelFor(top_buckets, in, sortBuckets, 1);
            return answerOf(in.work);
        }
    };
}

pub const job: harness.Job = .{
    .id = "D3",
    .group = "data processing",
    .title = "sort a column of 32-bit keys",
    .unit = "keys",
    .bytes_per_item = @sizeOf(u32),
    .sizes = &.{ 10_000, 1_000_000, 10_000_000 },
    .quick_sizes = &.{ 1_000, 100_000 },
    .tolerance = 0,
    .source = @embedFile("d3_sort.zig") ++ @embedFile("../../kit/radix.zig"),
    .create = create,
    .destroy = destroy,
    .variants = &.{
        .{ .name = "std", .what = "std.mem.sort (general, stable)", .run = stdSort },
        .{ .name = "pdq", .what = "std.sort.pdq (quicksort family)", .run = pdq },
        .{ .name = "radix8", .what = "radix sort, 8 bits per pass (4 passes)", .run = Radix(8).run },
        .{ .name = "radix11", .what = "radix sort, 11 bits per pass (3 passes)", .run = Radix(11).run },
        .{ .name = "threads8", .what = "256 buckets by top byte, then radix8 per bucket on 8 threads", .run = Threads(8).run, .threads = true },
        .{ .name = "threads16", .what = "256 buckets by top byte, then radix8 per bucket on 16 threads", .run = Threads(16).run, .threads = true },
    },
};

const edge_sizes = [_]usize{ 0, 1, 2, 3, 255, 256, 257, 1000, 70_001 };

test "D3: every variant gives the reference answer" {
    try harness.expectVariantsAgree(&job, &edge_sizes);
}

test "D3: every variant leaves the whole column sorted and unchanged in content" {
    const gpa = std.testing.allocator;
    var env: Env = .{ .gpa = gpa, .io = std.testing.io, .force_threads = 3 };
    defer env.deinit();
    for (edge_sizes) |n| {
        const p = try create(gpa, n);
        defer destroy(gpa, p);
        const in = of(p);
        const want = try gpa.dupe(u32, in.pristine);
        defer gpa.free(want);
        std.mem.sort(u32, want, {}, std.sort.asc(u32));
        for (job.variants) |v| {
            @memset(in.work, 0);
            _ = try v.run(&env, p);
            try std.testing.expectEqualSlices(u32, want, in.work);
        }
    }
}
