// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M2: find the best split in each of many gradient histograms.
//!
//! Input: `n` histograms of 256 bins, each bin a gradient sum (data.fillUnit seed 70, minus 0.5)
//! and a hessian sum (data.fillUnit seed 71, plus 0.01), as 64-bit floats.
//! Output: for each histogram, the bin b (0 to 254) after which to split so that
//!   GL^2 / (HL + 1) + GR^2 / (HR + 1)
//! is largest, where GL and HL are the sums over bins 0..b and GR, HR the rest; the first such
//! bin on a tie.
//! Answer (for comparing variants): every histogram's best value plus its bin number, added up.
//! Outside check: verify/model_jobs.py (NumPy).

const std = @import("std");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const Env = harness.Env;

const bins = 256;
const splits = bins - 1;
const lambda = 1.0;
const lanes = 8;
const Vec = @Vector(lanes, f64);

/// Threaded variants take the histograms in blocks of this many; block totals are added in order.
const block = 64;

/// One block total per cache line: two workers never write the same line.
const Slot = struct { total: f64 align(std.atomic.cache_line) = 0 };

const Input = struct {
    count: usize,
    g: []f64,
    h: []f64,
    slots: []Slot,
};

fn of(p: *anyopaque) *Input {
    return @ptrCast(@alignCast(p));
}

fn create(gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque {
    const in = try gpa.create(Input);
    errdefer gpa.destroy(in);
    const g = try gpa.alloc(f64, n * bins);
    errdefer gpa.free(g);
    const h = try gpa.alloc(f64, n * bins);
    errdefer gpa.free(h);
    const slots = try gpa.alloc(Slot, (n + block - 1) / block);
    errdefer gpa.free(slots);
    const scratch = try gpa.alloc(f32, n * bins);
    defer gpa.free(scratch);
    data.fillUnit(scratch, 70);
    for (g, scratch) |*d, s| d.* = @as(f64, s) - 0.5;
    data.fillUnit(scratch, 71);
    for (h, scratch) |*d, s| d.* = @as(f64, s) + 0.01;
    in.* = .{ .count = n, .g = g, .h = h, .slots = slots };
    return in;
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    gpa.free(in.slots);
    gpa.free(in.h);
    gpa.free(in.g);
    gpa.destroy(in);
}

fn gain(gl: f64, hl: f64, gt: f64, ht: f64) f64 {
    const gr = gt - gl;
    const hr = ht - hl;
    return gl * gl / (hl + lambda) + gr * gr / (hr + lambda);
}

fn totals(g: *const [bins]f64, h: *const [bins]f64) [2]f64 {
    var gt: f64 = 0;
    var ht: f64 = 0;
    for (g, h) |x, y| {
        gt += x;
        ht += y;
    }
    return .{ gt, ht };
}

/// The reference: walk the bins with running sums, keep the best seen so far.
fn scanBranch(g: *const [bins]f64, h: *const [bins]f64) f64 {
    const t = totals(g, h);
    var gl: f64 = 0;
    var hl: f64 = 0;
    var best = -std.math.inf(f64);
    var best_bin: usize = 0;
    for (0..splits) |b| {
        gl += g[b];
        hl += h[b];
        const v = gain(gl, hl, t[0], t[1]);
        if (v > best) {
            best = v;
            best_bin = b;
        }
    }
    return best + @as(f64, @floatFromInt(best_bin));
}

/// The same walk with the "is it better" step written without a branch.
fn scanSelect(g: *const [bins]f64, h: *const [bins]f64) f64 {
    const t = totals(g, h);
    var gl: f64 = 0;
    var hl: f64 = 0;
    var best = -std.math.inf(f64);
    var best_bin: usize = 0;
    for (0..splits) |b| {
        gl += g[b];
        hl += h[b];
        const v = gain(gl, hl, t[0], t[1]);
        const better = v > best;
        best = if (better) v else best;
        best_bin = if (better) b else best_bin;
    }
    return best + @as(f64, @floatFromInt(best_bin));
}

/// Running sums first (they must be done in order), then all the values 8 at a time, then
/// pick the first largest.
fn scanWide(g: *const [bins]f64, h: *const [bins]f64) f64 {
    var gl: [bins]f64 = undefined;
    var hl: [bins]f64 = undefined;
    var sg: f64 = 0;
    var sh: f64 = 0;
    for (g, h, &gl, &hl) |x, y, *pg, *ph| {
        sg += x;
        sh += y;
        pg.* = sg;
        ph.* = sh;
    }
    const gt: Vec = @splat(sg);
    const ht: Vec = @splat(sh);
    const lam: Vec = @splat(lambda);
    var values: [bins]f64 = undefined;
    var b: usize = 0;
    while (b < bins) : (b += lanes) {
        const l: Vec = gl[b..][0..lanes].*;
        const k: Vec = hl[b..][0..lanes].*;
        const r = gt - l;
        values[b..][0..lanes].* = l * l / (k + lam) + r * r / ((ht - k) + lam);
    }
    // Bin 255 is not a split (nothing would be left on the right).
    var best = -std.math.inf(f64);
    var best_bin: usize = 0;
    for (values[0..splits], 0..) |v, i| {
        const better = v > best;
        best = if (better) v else best;
        best_bin = if (better) i else best_bin;
    }
    return best + @as(f64, @floatFromInt(best_bin));
}

const Kernel = fn (*const [bins]f64, *const [bins]f64) f64;

fn scanRange(comptime kernel: Kernel, in: *const Input, lo: usize, hi: usize) f64 {
    var total: f64 = 0;
    for (lo..hi) |i| total += kernel(in.g[i * bins ..][0..bins], in.h[i * bins ..][0..bins]);
    return total;
}

fn Serial(comptime kernel: Kernel) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            _ = env;
            const in = of(p);
            return scanRange(kernel, in, 0, in.count);
        }
    };
}

/// Pool task over block indices [begin, end).
fn scanBlocks(ctx: *anyopaque, worker: usize, begin: usize, end: usize) void {
    _ = worker;
    const in = of(ctx);
    for (begin..end) |b| in.slots[b].total = scanRange(scanWide, in, b * block, @min((b + 1) * block, in.count));
}

fn Threads(comptime count: u32) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            const in = of(p);
            const pool = try env.pool(count);
            pool.parallelFor(in.slots.len, in, scanBlocks, 1);
            var total: f64 = 0;
            for (in.slots) |s| total += s.total;
            return total;
        }
    };
}

pub const job: harness.Job = .{
    .id = "M2",
    .group = "model learning",
    .title = "best split scan over 256-bin gradient histograms",
    .unit = "histograms",
    .bytes_per_item = 2 * bins * @sizeOf(f64),
    .sizes = &.{ 100, 10_000, 100_000 },
    .quick_sizes = &.{ 10, 1_000 },
    // Serial variants are equal bit for bit; the threaded ones add block totals instead of one
    // running total.
    .tolerance = 1e-9,
    .source = @embedFile("m2_split_scan.zig"),
    .create = create,
    .destroy = destroy,
    .variants = &.{
        .{ .name = "branch", .what = "walk the bins with running sums, branch on a new best", .run = Serial(scanBranch).run },
        .{ .name = "select", .what = "the same walk with the new-best step written without a branch", .run = Serial(scanSelect).run },
        .{ .name = "wide8", .what = "running sums first, then all values 8 at a time, then pick", .run = Serial(scanWide).run },
        .{ .name = "threads8", .what = "wide8 over blocks of histograms on 8 threads", .run = Threads(8).run, .threads = true },
        .{ .name = "threads16", .what = "wide8 over blocks of histograms on 16 threads", .run = Threads(16).run, .threads = true },
    },
};

test "M2: every variant gives the reference answer" {
    try harness.expectVariantsAgree(&job, &.{ 0, 1, 2, block - 1, block, block + 1, 3 * block + 5 });
}

test "M2: the three scans agree bit for bit, and a split worked out by hand" {
    var g: [bins]f64 = @splat(0);
    var h: [bins]f64 = @splat(0);
    // All the gradient is in bins 10 (+3) and 200 (-3); hessian 1 in each of those.
    g[10] = 3;
    h[10] = 1;
    g[200] = -3;
    h[200] = 1;
    // Splitting anywhere from bin 10 to bin 199 separates them: 9/2 + 9/2 = 9. First such bin: 10.
    for ([_]*const Kernel{ scanBranch, scanSelect, scanWide }) |k| try std.testing.expectEqual(@as(f64, 9 + 10), k(&g, &h));
    // On generated data the three are identical.
    const gpa = std.testing.allocator;
    const p = try create(gpa, 50);
    defer destroy(gpa, p);
    const in = of(p);
    for (0..in.count) |i| {
        const gi = in.g[i * bins ..][0..bins];
        const hi = in.h[i * bins ..][0..bins];
        const want = scanBranch(gi, hi);
        try std.testing.expectEqual(want, scanSelect(gi, hi));
        try std.testing.expectEqual(want, scanWide(gi, hi));
    }
}
