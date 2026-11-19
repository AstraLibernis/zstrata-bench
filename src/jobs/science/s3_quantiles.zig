// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! S3: quantiles of a column.
//!
//! Input: `n` 32-bit floats in [0, 1) (data.fillUnit, seed 13).
//! Output: the values at the 1%, 25%, 50%, 75% and 99% positions of the sorted column, where the
//! position for p% is (n - 1) * p / 100 rounded down.
//! Answer (for comparing variants): the five values added together; 0 for an empty column.
//! The values are never negative, so their bit patterns sort in the same order as the numbers;
//! every variant works on the bit patterns.
//! Outside check: verify/science_jobs.py (NumPy).

const std = @import("std");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const radix = @import("../../kit/radix.zig");
const Env = harness.Env;

const seed = 13;
const percents = [_]usize{ 1, 25, 50, 75, 99 };

/// The histogram variants count the top 16 bits of each value.
const top_bins = 1 << 16;
const TopCounts = [top_bins]u32;

/// The threaded variant counts in this many equal parts of the column.
const parts = 16;

/// One part's counts start on their own cache line and fill whole lines, so two workers never
/// write the same line.
const PartCounts = struct { c: TopCounts align(std.atomic.cache_line) };

const Input = struct {
    xs: []u32,
    work: []u32,
    scratch: []u32,
    counts: *TopCounts,
    part: []PartCounts,
    /// Which wanted quantile (1-based) a top-bits bin holds; 0 for the rest.
    wanted: *[top_bins]u8,
};

fn of(p: *anyopaque) *Input {
    return @ptrCast(@alignCast(p));
}

fn create(gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque {
    if (n > std.math.maxInt(u32)) return error.TooManyValues;
    const in = try gpa.create(Input);
    errdefer gpa.destroy(in);
    const floats = try gpa.alloc(f32, n);
    defer gpa.free(floats);
    const xs = try gpa.alloc(u32, n);
    errdefer gpa.free(xs);
    const work = try gpa.alloc(u32, n);
    errdefer gpa.free(work);
    const scratch = try gpa.alloc(u32, n);
    errdefer gpa.free(scratch);
    const counts = try gpa.create(TopCounts);
    errdefer gpa.destroy(counts);
    const part = try gpa.alloc(PartCounts, parts);
    errdefer gpa.free(part);
    const wanted = try gpa.create([top_bins]u8);
    data.fillUnit(floats, seed);
    for (xs, floats) |*x, f| x.* = @bitCast(f);
    in.* = .{ .xs = xs, .work = work, .scratch = scratch, .counts = counts, .part = part, .wanted = wanted };
    return in;
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    gpa.destroy(in.wanted);
    gpa.free(in.part);
    gpa.destroy(in.counts);
    gpa.free(in.scratch);
    gpa.free(in.work);
    gpa.free(in.xs);
    gpa.destroy(in);
}

fn position(n: usize, percent: usize) usize {
    return (n - 1) * percent / 100;
}

fn value(bits: u32) f64 {
    return @as(f32, @bitCast(bits));
}

fn answerOfSorted(sorted: []const u32) f64 {
    if (sorted.len == 0) return 0;
    var a: f64 = 0;
    for (percents) |pc| a += value(sorted[position(sorted.len, pc)]);
    return a;
}

/// The reference: sort a copy with std, read the five positions.
fn sortStd(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    @memcpy(in.work, in.xs);
    std.sort.pdq(u32, in.work, {}, std.sort.asc(u32));
    return answerOfSorted(in.work);
}

/// Radix sort a copy, read the five positions.
fn sortRadix(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    @memcpy(in.work, in.xs);
    radix.sort(u32, 8, 0, 32, in.work, in.scratch);
    return answerOfSorted(in.work);
}

/// Rearranges `a` so that a[k] is the value a full sort would put there, everything before it
/// is no larger and everything after it is no smaller. `k < a.len`.
fn selectNth(a: []u32, k: usize) void {
    var lo: isize = 0;
    var hi: isize = @as(isize, @intCast(a.len)) - 1;
    const target: isize = @intCast(k);
    // Each round narrows [lo, hi] and keeps `target` inside it, so the loop ends.
    while (lo < hi) {
        const l: usize = @intCast(lo);
        const h: usize = @intCast(hi);
        const mid = l + (h - l) / 2;
        // Median of three as the pivot: sorted and nearly sorted inputs stay fast.
        if (a[mid] < a[l]) std.mem.swap(u32, &a[mid], &a[l]);
        if (a[h] < a[l]) std.mem.swap(u32, &a[h], &a[l]);
        if (a[h] < a[mid]) std.mem.swap(u32, &a[h], &a[mid]);
        const pivot = a[mid];
        var i = lo;
        var j = hi;
        while (i <= j) {
            while (a[@intCast(i)] < pivot) i += 1;
            while (a[@intCast(j)] > pivot) j -= 1;
            if (i <= j) {
                std.mem.swap(u32, &a[@intCast(i)], &a[@intCast(j)]);
                i += 1;
                j -= 1;
            }
        }
        // Now a[lo..j] <= pivot <= a[i..hi], and anything strictly between j and i equals it.
        if (target <= j) {
            hi = j;
        } else if (target >= i) {
            lo = i;
        } else return;
    }
}

/// Partition a copy around each wanted position in turn (no full sort). After the first
/// position is in place, the next is searched only to its right.
fn select(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    const n = in.work.len;
    if (n == 0) return 0;
    @memcpy(in.work, in.xs);
    var a: f64 = 0;
    var from: usize = 0;
    for (percents) |pc| {
        const k = position(n, pc);
        selectNth(in.work[from..], k - from);
        a += value(in.work[k]);
        from = k;
    }
    return a;
}

/// Second half of the histogram variants: `counts` holds how many values have each top-16-bit
/// pattern. Find the bins that hold the wanted positions, pull only those bins' values out in
/// one more pass, sort those few, and read the answer. No copy of the column is made.
fn finishFromCounts(in: *Input) f64 {
    const n = in.xs.len;
    if (n == 0) return 0;
    @memset(in.wanted, 0);
    var bin_of: [percents.len]u32 = undefined;
    var rank_in_bin: [percents.len]usize = undefined;
    {
        var q: usize = 0;
        var before: usize = 0;
        for (in.counts, 0..) |c, b| {
            while (q < percents.len and position(n, percents[q]) < before + c) : (q += 1) {
                bin_of[q] = @intCast(b);
                rank_in_bin[q] = position(n, percents[q]) - before;
                in.wanted[b] = 1;
            }
            before += c;
        }
        std.debug.assert(q == percents.len); // the counts add up to n, so every position is found
    }
    // Wanted bins get consecutive stretches of `work`, in bin order.
    var start: [percents.len]usize = undefined;
    var next: [percents.len]usize = undefined;
    var used: usize = 0;
    for (0..percents.len) |q| {
        if (q != 0 and bin_of[q] == bin_of[q - 1]) {
            start[q] = start[q - 1];
        } else {
            start[q] = used;
            in.wanted[bin_of[q]] = @intCast(q + 1);
            used += in.counts[bin_of[q]];
        }
        next[q] = start[q];
    }
    for (in.xs) |x| {
        const w = in.wanted[x >> 16];
        if (w != 0) {
            in.work[next[w - 1]] = x;
            next[w - 1] += 1;
        }
    }
    var a: f64 = 0;
    for (0..percents.len) |q| {
        // The stretch belongs to the first quantile that claimed the bin; sort it once.
        if (q == 0 or bin_of[q] != bin_of[q - 1]) {
            const stretch = in.work[start[q]..][0..in.counts[bin_of[q]]];
            std.sort.pdq(u32, stretch, {}, std.sort.asc(u32));
        }
        a += value(in.work[start[q] + rank_in_bin[q]]);
    }
    return a;
}

fn countTop(xs: []const u32, counts: *TopCounts) void {
    @memset(counts, 0);
    for (xs) |x| counts[x >> 16] += 1;
}

/// Count the top 16 bits of every value, then look only inside the bins that matter.
fn histogram(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    countTop(in.xs, in.counts);
    return finishFromCounts(in);
}

/// Pool task over parts [begin, end).
fn countParts(ctx: *anyopaque, worker: usize, begin: usize, end: usize) void {
    _ = worker;
    const in = of(ctx);
    const n = in.xs.len;
    for (begin..end) |b| countTop(in.xs[b * n / parts .. (b + 1) * n / parts], &in.part[b].c);
}

fn Threads(comptime count: u32) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            const in = of(p);
            const pool = try env.pool(count);
            pool.parallelFor(parts, in, countParts, 1);
            @memset(in.counts, 0);
            for (in.part) |*pt| {
                for (in.counts, &pt.c) |*c, x| c.* += x;
            }
            return finishFromCounts(in);
        }
    };
}

pub const job: harness.Job = .{
    .id = "S3",
    .group = "data science",
    .title = "quantiles of a column (1, 25, 50, 75, 99 percent)",
    .unit = "values",
    .bytes_per_item = @sizeOf(f32),
    .sizes = &.{ 10_000, 1_000_000, 10_000_000 },
    .quick_sizes = &.{ 1_000, 100_000 },
    .tolerance = 0,
    .source = @embedFile("s3_quantiles.zig") ++ @embedFile("../../kit/radix.zig"),
    .create = create,
    .destroy = destroy,
    .variants = &.{
        .{ .name = "sort", .what = "sort a copy with std.sort.pdq, read the positions", .run = sortStd },
        .{ .name = "radix", .what = "radix sort a copy, read the positions", .run = sortRadix },
        .{ .name = "select", .what = "partition a copy around each position, no full sort", .run = select },
        .{ .name = "histogram", .what = "count the top 16 bits, then sort only the bins that hold a position", .run = histogram },
        .{ .name = "threads8", .what = "histogram with the counting pass on 8 threads", .run = Threads(8).run, .threads = true },
        .{ .name = "threads16", .what = "histogram with the counting pass on 16 threads", .run = Threads(16).run, .threads = true },
    },
};

const edge_sizes = [_]usize{ 0, 1, 2, 3, 4, 5, 99, 100, 101, 1000, 65_537 };

test "S3: every variant gives the reference answer" {
    try harness.expectVariantsAgree(&job, &edge_sizes);
}

test "S3: positions, and the reference on a column worked out by hand" {
    try std.testing.expectEqual(@as(usize, 0), position(1, 99));
    try std.testing.expectEqual(@as(usize, 0), position(101, 0));
    try std.testing.expectEqual(@as(usize, 1), position(101, 1));
    try std.testing.expectEqual(@as(usize, 50), position(101, 50));
    try std.testing.expectEqual(@as(usize, 99), position(101, 99));
    // 0.00, 0.01, ..., 1.00 in sorted order: the five quantiles are 0.01, 0.25, 0.5, 0.75, 0.99.
    var bits: [101]u32 = undefined;
    for (&bits, 0..) |*b, i| b.* = @bitCast(@as(f32, @floatFromInt(i)) / 100.0);
    var want: f64 = 0;
    for ([_]usize{ 1, 25, 50, 75, 99 }) |i| want += @as(f32, @floatFromInt(i)) / 100.0;
    try std.testing.expectEqual(want, answerOfSorted(&bits));
}

test "S3: selectNth puts the right value in place, with duplicates and sorted inputs" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(7);
    for ([_]usize{ 1, 2, 3, 10, 257, 1000 }) |n| {
        for ([_]u32{ 3, 1000, std.math.maxInt(u32) }) |range| {
            const a = try gpa.alloc(u32, n);
            defer gpa.free(a);
            const sorted = try gpa.alloc(u32, n);
            defer gpa.free(sorted);
            for (a) |*x| x.* = prng.random().uintAtMost(u32, range);
            @memcpy(sorted, a);
            std.mem.sort(u32, sorted, {}, std.sort.asc(u32));
            for ([_]usize{ 0, n / 3, n / 2, n - 1 }) |k| {
                selectNth(a, k);
                try std.testing.expectEqual(sorted[k], a[k]);
                for (a[0..k]) |x| try std.testing.expect(x <= a[k]);
                for (a[k..]) |x| try std.testing.expect(x >= a[k]);
            }
            // Already sorted input.
            selectNth(sorted, n / 2);
        }
    }
}
