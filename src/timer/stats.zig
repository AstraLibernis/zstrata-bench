// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Summary statistics of one metric over the timed runs, the first-run outlier check, and the
//! comparison with the reference command.

const std = @import("std");

pub const Summary = struct {
    count: usize,
    mean: f64,
    /// Sample standard deviation (n - 1); null for a single run.
    stddev: ?f64,
    median: f64,
    min: f64,
    max: f64,
};

/// `scratch` must be as long as `xs`; it is overwritten.
pub fn summarize(xs: []const f64, scratch: []f64) Summary {
    std.debug.assert(xs.len > 0 and scratch.len >= xs.len);
    var sum: f64 = 0;
    for (xs) |x| sum += x;
    const n: f64 = @floatFromInt(xs.len);
    const mean = sum / n;
    var stddev: ?f64 = null;
    if (xs.len > 1) {
        var sq: f64 = 0;
        for (xs) |x| sq += (x - mean) * (x - mean);
        stddev = std.math.sqrt(sq / (n - 1));
    }
    const sorted = scratch[0..xs.len];
    @memcpy(sorted, xs);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
    return .{
        .count = xs.len,
        .mean = mean,
        .stddev = stddev,
        .median = medianSorted(sorted),
        .min = sorted[0],
        .max = sorted[sorted.len - 1],
    };
}

fn medianSorted(sorted: []const f64) f64 {
    const n = sorted.len;
    return if (n % 2 == 1) sorted[n / 2] else (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
}

/// A first run this many median absolute deviations above the median is reported. The same bar
/// hyperfine uses: ten times the normal-consistency constant 1.4826.
pub const outlier_threshold: f64 = 1.4826 * 10.0;

/// (xs[0] - median) / MAD. A MAD of zero counts as the smallest positive f64 step at 1, so any
/// first run above an otherwise constant series scores high. `scratch` as in `summarize`.
pub fn firstRunScore(xs: []const f64, scratch: []f64) f64 {
    std.debug.assert(xs.len > 0 and scratch.len >= xs.len);
    const s = scratch[0..xs.len];
    @memcpy(s, xs);
    std.mem.sort(f64, s, {}, std.sort.asc(f64));
    const median = medianSorted(s);
    for (xs, s) |x, *d| d.* = @abs(x - median);
    std.mem.sort(f64, s, {}, std.sort.asc(f64));
    const mad = medianSorted(s);
    return (xs[0] - median) / (if (mad > 0) mad else std.math.floatEps(f64));
}

/// Percent change of `mean` against the reference mean; null when the reference is 0.
pub fn change(mean: f64, reference: f64) ?f64 {
    if (reference == 0) return null;
    return 100 * (mean / reference - 1);
}

/// "N.Nx faster/slower" (or less/more for non-time metrics) when the means differ by at least
/// 30%, else null. The factor is infinite when one side is 0.
pub const Factor = struct { value: f64, lower: bool };

pub fn factor(mean: f64, reference: f64) ?Factor {
    if (reference <= 0) return null;
    if (mean < 1.3 * reference and mean > 0.7 * reference) return null;
    const lower = mean < reference;
    return .{
        .value = if (lower) (if (mean == 0) std.math.inf(f64) else reference / mean) else mean / reference,
        .lower = lower,
    };
}

test "summarize" {
    var scratch: [5]f64 = undefined;
    const s = summarize(&.{ 3, 1, 2, 5, 4 }, &scratch);
    try std.testing.expectEqual(@as(f64, 3), s.mean);
    try std.testing.expectEqual(@as(f64, 3), s.median);
    try std.testing.expectEqual(@as(f64, 1), s.min);
    try std.testing.expectEqual(@as(f64, 5), s.max);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5811388300841898), s.stddev.?, 1e-15);
    const even = summarize(&.{ 4, 1, 3, 2 }, &scratch);
    try std.testing.expectEqual(@as(f64, 2.5), even.median);
    const one = summarize(&.{7}, &scratch);
    try std.testing.expect(one.stddev == null);
    try std.testing.expectEqual(@as(f64, 7), one.median);
}

test "first-run outlier score" {
    var scratch: [8]f64 = undefined;
    // The cases hyperfine's own tests use for its outlier rule.
    try std.testing.expect(firstRunScore(&.{ 0.5, 0.30, 0.29, 0.31, 0.30 }, &scratch) > outlier_threshold);
    try std.testing.expect(firstRunScore(&.{ 0.2, 0.0, -0.2 }, &scratch) <= outlier_threshold);
    try std.testing.expect(firstRunScore(&.{ 4.0, -0.2, 0.0, 0.2 }, &scratch) > outlier_threshold);
    try std.testing.expect(firstRunScore(&.{50.0}, &scratch) <= outlier_threshold);
    try std.testing.expect(firstRunScore(&.{ 2, 1, 1, 1 }, &scratch) > outlier_threshold);
}

test "change and factor" {
    try std.testing.expectApproxEqAbs(@as(f64, -50), change(5, 10).?, 1e-12);
    try std.testing.expect(change(5, 0) == null);
    try std.testing.expect(factor(11, 10) == null);
    const f = factor(5, 10).?;
    try std.testing.expect(f.lower and f.value == 2);
    const g = factor(13, 10).?;
    try std.testing.expect(!g.lower and @abs(g.value - 1.3) < 1e-12);
    try std.testing.expect(std.math.isInf(factor(0, 10).?.value));
}
