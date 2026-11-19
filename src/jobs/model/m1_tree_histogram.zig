// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M1: build the gradient histograms a boosted-tree learner needs for one node.
//!
//! Input: `n` rows with 8 features already cut into 256 bins (one byte each; feature f is
//! data.fillBytes with seed 50 + f), and per row a gradient (data.fillUnit seed 60, minus 0.5)
//! and a hessian (data.fillUnit seed 61), both 32-bit floats.
//! Output: for every feature and bin, the 64-bit sums of the gradients and of the hessians of
//! the rows that fall in it.
//! Answer (for comparing variants): every sum weighted by its feature and bin number:
//! (feature + 1) * (bin + 1) * (gradient sum + hessian sum / 2), added up.
//! The bins are held both ways round (one array per feature, and row after row).
//! Outside check: verify/model_jobs.py (NumPy).

const std = @import("std");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const Env = harness.Env;

const feats = 8;
const bins = 256;

/// A gradient sum and a hessian sum side by side: one cache line holds four bins.
const GH = struct { g: f64 = 0, h: f64 = 0 };
const Table = [bins]GH;
const Hist = [feats]Table;

/// The cache-sized variant takes the rows in pieces of this many (their gradients, hessians and
/// one feature's bins are 36 KiB).
const piece = 4096;

/// The threaded variant splits the rows into this many equal parts, each with its own histogram.
const parts = 16;

/// One part's histogram starts on its own cache line and fills whole lines.
const PartHist = struct { hist: Hist align(std.atomic.cache_line) };

const Input = struct {
    n: usize,
    col: [feats][]u8,
    rows: []u8,
    g: []f32,
    h: []f32,
    hist: *Hist,
    second: *Hist,
    /// The reference keeps gradient sums and hessian sums in two separate tables.
    sum_g: *[feats][bins]f64,
    sum_h: *[feats][bins]f64,
    part: []PartHist,
};

fn of(p: *anyopaque) *Input {
    return @ptrCast(@alignCast(p));
}

fn create(gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque {
    const in = try gpa.create(Input);
    errdefer gpa.destroy(in);
    var col: [feats][]u8 = undefined;
    var made: usize = 0;
    errdefer for (col[0..made]) |c| gpa.free(c);
    while (made < feats) : (made += 1) col[made] = try gpa.alloc(u8, n);
    const rows = try gpa.alloc(u8, n * feats);
    errdefer gpa.free(rows);
    const g = try gpa.alloc(f32, n);
    errdefer gpa.free(g);
    const h = try gpa.alloc(f32, n);
    errdefer gpa.free(h);
    const hist = try gpa.create(Hist);
    errdefer gpa.destroy(hist);
    const second = try gpa.create(Hist);
    errdefer gpa.destroy(second);
    const sum_g = try gpa.create([feats][bins]f64);
    errdefer gpa.destroy(sum_g);
    const sum_h = try gpa.create([feats][bins]f64);
    errdefer gpa.destroy(sum_h);
    const part = try gpa.alloc(PartHist, parts);

    for (col, 0..) |c, f| data.fillBytes(c, 50 + @as(u32, @intCast(f)));
    for (0..n) |r| {
        for (0..feats) |f| rows[r * feats + f] = col[f][r];
    }
    data.fillUnit(g, 60);
    for (g) |*x| x.* -= 0.5;
    data.fillUnit(h, 61);
    in.* = .{ .n = n, .col = col, .rows = rows, .g = g, .h = h, .hist = hist, .second = second, .sum_g = sum_g, .sum_h = sum_h, .part = part };
    return in;
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    gpa.free(in.part);
    gpa.destroy(in.sum_h);
    gpa.destroy(in.sum_g);
    gpa.destroy(in.second);
    gpa.destroy(in.hist);
    gpa.free(in.h);
    gpa.free(in.g);
    gpa.free(in.rows);
    for (in.col) |c| gpa.free(c);
    gpa.destroy(in);
}

fn weight(f: usize, b: usize) f64 {
    return @floatFromInt((f + 1) * (b + 1));
}

fn answerOf(hist: *const Hist) f64 {
    var a: f64 = 0;
    for (hist, 0..) |*table, f| {
        for (table, 0..) |e, b| a += weight(f, b) * (e.g + e.h * 0.5);
    }
    return a;
}

fn clear(hist: *Hist) void {
    for (hist) |*table| @memset(table, .{});
}

/// The reference: one pass per feature; gradient sums and hessian sums in separate tables.
fn separate(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    for (in.sum_g) |*t| @memset(t, 0);
    for (in.sum_h) |*t| @memset(t, 0);
    for (0..feats) |f| {
        for (in.col[f], in.g, in.h) |b, g, h| {
            in.sum_g[f][b] += g;
            in.sum_h[f][b] += h;
        }
    }
    var a: f64 = 0;
    for (0..feats) |f| {
        for (0..bins) |b| a += weight(f, b) * (in.sum_g[f][b] + in.sum_h[f][b] * 0.5);
    }
    return a;
}

/// One feature's rows into one table of side-by-side sums.
fn addColumn(table: *Table, col: []const u8, g: []const f32, h: []const f32) void {
    for (col, g, h) |b, gr, he| {
        table[b].g += gr;
        table[b].h += he;
    }
}

/// One pass per feature; each bin's two sums side by side.
fn sideBySide(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    clear(in.hist);
    for (0..feats) |f| addColumn(&in.hist[f], in.col[f], in.g, in.h);
    return answerOf(in.hist);
}

/// Bins stored row after row: one pass over the rows, all 8 features per row.
fn rowWise(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    clear(in.hist);
    for (0..in.n) |r| {
        const g = in.g[r];
        const h = in.h[r];
        inline for (0..feats) |f| {
            const e = &in.hist[f][in.rows[r * feats + f]];
            e.g += g;
            e.h += h;
        }
    }
    return answerOf(in.hist);
}

/// One pass per feature, but rows go to two tables in turn (added at the end), so two
/// neighbouring rows in the same bin do not wait on each other.
fn twoTables(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    clear(in.hist);
    clear(in.second);
    for (0..feats) |f| {
        const col = in.col[f];
        const a = &in.hist[f];
        const b = &in.second[f];
        var r: usize = 0;
        while (r + 2 <= col.len) : (r += 2) {
            a[col[r]].g += in.g[r];
            a[col[r]].h += in.h[r];
            b[col[r + 1]].g += in.g[r + 1];
            b[col[r + 1]].h += in.h[r + 1];
        }
        if (r < col.len) {
            a[col[r]].g += in.g[r];
            a[col[r]].h += in.h[r];
        }
        for (a, b) |*x, y| {
            x.g += y.g;
            x.h += y.h;
        }
    }
    return answerOf(in.hist);
}

/// Rows [lo, hi): the passes per feature, over 4,096 rows at a time.
fn addPieces(in: *const Input, hist: *Hist, lo: usize, hi: usize) void {
    var at = lo;
    while (at < hi) : (at += piece) {
        const end = @min(at + piece, hi);
        for (0..feats) |f| addColumn(&hist[f], in.col[f][at..end], in.g[at..end], in.h[at..end]);
    }
}

/// One pass per feature over a cache-sized piece of the rows at a time.
fn pieces(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    clear(in.hist);
    addPieces(in, in.hist, 0, in.n);
    return answerOf(in.hist);
}

/// Pool task over parts [begin, end).
fn buildParts(ctx: *anyopaque, worker: usize, begin: usize, end: usize) void {
    _ = worker;
    const in = of(ctx);
    for (begin..end) |b| {
        clear(&in.part[b].hist);
        addPieces(in, &in.part[b].hist, b * in.n / parts, (b + 1) * in.n / parts);
    }
}

fn Threads(comptime count: u32) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            const in = of(p);
            const pool = try env.pool(count);
            pool.parallelFor(parts, in, buildParts, 1);
            clear(in.hist);
            for (in.part) |*pt| {
                for (in.hist, &pt.hist) |*table, *src| {
                    for (table, src) |*x, y| {
                        x.g += y.g;
                        x.h += y.h;
                    }
                }
            }
            return answerOf(in.hist);
        }
    };
}

pub const job: harness.Job = .{
    .id = "M1",
    .group = "model learning",
    .title = "tree histogram build: gradients into 256 bins for 8 features",
    .unit = "rows",
    .bytes_per_item = feats + 2 * @sizeOf(f32),
    .sizes = &.{ 10_000, 1_000_000, 10_000_000 },
    .quick_sizes = &.{ 1_000, 100_000 },
    .tolerance = 1e-9,
    .source = @embedFile("m1_tree_histogram.zig"),
    .create = create,
    .destroy = destroy,
    .variants = &.{
        .{ .name = "separate", .what = "one pass per feature; gradient and hessian sums in separate tables", .run = separate },
        .{ .name = "sidebyside", .what = "one pass per feature; each bin's two sums side by side", .run = sideBySide },
        .{ .name = "rowwise", .what = "bins stored row after row; one pass, 8 features per row", .run = rowWise },
        .{ .name = "twotables", .what = "sidebyside with rows going to two tables in turn", .run = twoTables },
        .{ .name = "pieces", .what = "sidebyside over 4,096 rows at a time", .run = pieces },
        .{ .name = "threads8", .what = "pieces in 16 parts with their own histograms, 8 threads", .run = Threads(8).run, .threads = true },
        .{ .name = "threads16", .what = "pieces in 16 parts with their own histograms, 16 threads", .run = Threads(16).run, .threads = true },
    },
};

test "M1: every variant gives the reference answer" {
    try harness.expectVariantsAgree(&job, &.{ 0, 1, 2, 3, 15, 16, 17, piece - 1, piece, piece + 1, 3 * piece + 7 });
}

test "M1: a histogram worked out by hand" {
    const gpa = std.testing.allocator;
    var env: Env = .{ .gpa = gpa, .io = std.testing.io };
    defer env.deinit();
    const p = try create(gpa, 3);
    defer destroy(gpa, p);
    const in = of(p);
    // Every feature: rows 0 and 2 in bin 4, row 1 in bin 9. Gradients 1, 2, 4; hessians 8, 16, 32.
    for (0..3) |r| {
        const b: u8 = if (r == 1) 9 else 4;
        for (0..feats) |f| {
            in.col[f][r] = b;
            in.rows[r * feats + f] = b;
        }
        in.g[r] = @floatFromInt(@as(u32, 1) << @intCast(r));
        in.h[r] = @floatFromInt(@as(u32, 8) << @intCast(r));
    }
    // Per feature: bin 4 holds g = 5, h = 40; bin 9 holds g = 2, h = 16.
    // Weighted: 5 * (5 + 20) + 10 * (2 + 8) = 225, times (1 + 2 + ... + 8) = 36.
    for (job.variants) |v| try std.testing.expectEqual(@as(f64, 225 * 36), try v.run(&env, p));
    try std.testing.expectEqual(@as(f64, 5), in.hist[3][4].g);
    try std.testing.expectEqual(@as(f64, 16), in.hist[7][9].h);
}
