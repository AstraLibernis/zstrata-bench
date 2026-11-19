// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! S4: correlation between the columns of a table.
//!
//! Input: `n` rows of 8 columns of 32-bit floats. Column 0 is data.fillUnit with seed 20;
//! column c (1 to 7) is data.fillUnit with seed 20 + c, plus c/8 times column 0, so the columns
//! are correlated with column 0 by different amounts.
//! Output: the Pearson correlation of every pair of columns, from 64-bit sums of the values and
//! of their products.
//! Answer (for comparing variants): the 28 correlations added together; 0 for fewer than 2 rows.
//! The table is held both ways round (one array per column, and row after row), so variants
//! can differ in layout.
//! Outside check: verify/science_jobs.py (NumPy).

const std = @import("std");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const Env = harness.Env;

const cols = 8;
const lanes = 16;

/// The cache-sized variant works through the rows in pieces of this many (8 columns of it are
/// 128 KiB, inside a core's own cache).
const piece = 4096;

/// Threaded variants work in blocks of this many rows; block results are added in block order.
const block = 1 << 14;

/// Sums of each column and of each product of two columns (only j >= i is filled).
const Sums = struct {
    s: [cols]f64 = @splat(0),
    p: [cols][cols]f64 = @splat(@splat(0)),

    fn add(a: *Sums, b: *const Sums) void {
        for (&a.s, b.s) |*x, y| x.* += y;
        for (0..cols) |i| {
            for (i..cols) |j| a.p[i][j] += b.p[i][j];
        }
    }

    fn answer(sums: *const Sums, n: usize) f64 {
        if (n < 2) return 0;
        const count: f64 = @floatFromInt(n);
        var a: f64 = 0;
        for (0..cols) |i| {
            const vi = sums.p[i][i] - sums.s[i] * sums.s[i] / count;
            for (i + 1..cols) |j| {
                const vj = sums.p[j][j] - sums.s[j] * sums.s[j] / count;
                const cov = sums.p[i][j] - sums.s[i] * sums.s[j] / count;
                a += cov / @sqrt(vi * vj);
            }
        }
        return a;
    }
};

/// One block result per cache line: two workers never write the same line.
const Slot = struct { sums: Sums align(std.atomic.cache_line) = .{} };

const Columns = [cols][]const f32;

const Input = struct {
    col: [cols][]f32,
    rows: []f32,
    slots: []Slot,
    n: usize,

    fn columns(in: *const Input, lo: usize, hi: usize) Columns {
        var c: Columns = undefined;
        for (&c, in.col) |*dst, src| dst.* = src[lo..hi];
        return c;
    }
};

fn of(p: *anyopaque) *Input {
    return @ptrCast(@alignCast(p));
}

fn create(gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque {
    const in = try gpa.create(Input);
    errdefer gpa.destroy(in);
    var col: [cols][]f32 = undefined;
    var made: usize = 0;
    errdefer for (col[0..made]) |c| gpa.free(c);
    while (made < cols) : (made += 1) col[made] = try gpa.alloc(f32, n);
    const rows = try gpa.alloc(f32, n * cols);
    errdefer gpa.free(rows);
    const slots = try gpa.alloc(Slot, (n + block - 1) / block);

    for (col, 0..) |c, k| data.fillUnit(c, 20 + @as(u32, @intCast(k)));
    for (col[1..], 1..) |c, k| {
        const share = @as(f32, @floatFromInt(k)) * 0.125;
        for (c, col[0]) |*x, base| x.* += share * base;
    }
    for (0..n) |r| {
        for (0..cols) |k| rows[r * cols + k] = col[k][r];
    }
    in.* = .{ .col = col, .rows = rows, .slots = slots, .n = n };
    return in;
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    gpa.free(in.slots);
    gpa.free(in.rows);
    for (in.col) |c| gpa.free(c);
    gpa.destroy(in);
}

fn sumPlain(a: []const f32) f64 {
    var s: f64 = 0;
    for (a) |x| s += x;
    return s;
}

fn dotPlain(a: []const f32, b: []const f32) f64 {
    var s: f64 = 0;
    for (a, b) |x, y| s += @as(f64, x) * y;
    return s;
}

fn sumWide(a: []const f32) f64 {
    const D = @Vector(lanes, f64);
    var acc: D = @splat(0);
    var i: usize = 0;
    while (i + lanes <= a.len) : (i += lanes) acc += @as(D, @floatCast(@as(@Vector(lanes, f32), a[i..][0..lanes].*)));
    return @reduce(.Add, acc) + sumPlain(a[i..]);
}

fn dotWide(a: []const f32, b: []const f32) f64 {
    const F = @Vector(lanes, f32);
    const D = @Vector(lanes, f64);
    var acc: D = @splat(0);
    var i: usize = 0;
    while (i + lanes <= a.len) : (i += lanes) {
        const x: D = @floatCast(@as(F, a[i..][0..lanes].*));
        const y: D = @floatCast(@as(F, b[i..][0..lanes].*));
        acc += x * y;
    }
    return @reduce(.Add, acc) + dotPlain(a[i..], b[i..]);
}

/// One pass over the data per column and per pair of columns: 44 passes.
fn pairwise(comptime wide: bool, c: Columns) Sums {
    var sums: Sums = .{};
    for (0..cols) |i| {
        sums.s[i] = if (wide) sumWide(c[i]) else sumPlain(c[i]);
        for (i..cols) |j| sums.p[i][j] = if (wide) dotWide(c[i], c[j]) else dotPlain(c[i], c[j]);
    }
    return sums;
}

fn addRow(sums: *Sums, x: *const [cols]f64) void {
    for (0..cols) |i| {
        sums.s[i] += x[i];
        for (i..cols) |j| sums.p[i][j] += x[i] * x[j];
    }
}

/// One pass over the rows of the row-after-row copy, all 44 sums updated per row.
fn rowWise(rows: []const f32) Sums {
    var sums: Sums = .{};
    var r: usize = 0;
    while (r + cols <= rows.len) : (r += cols) {
        var x: [cols]f64 = undefined;
        for (&x, rows[r..][0..cols]) |*d, v| d.* = v;
        addRow(&sums, &x);
    }
    return sums;
}

/// One pass over the row numbers, reading all eight column arrays at once.
fn onePassColumns(c: Columns) Sums {
    var sums: Sums = .{};
    for (0..c[0].len) |r| {
        var x: [cols]f64 = undefined;
        for (&x, c) |*d, column| d.* = column[r];
        addRow(&sums, &x);
    }
    return sums;
}

fn reference(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    return pairwise(false, in.columns(0, in.n)).answer(in.n);
}

fn pairs16(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    return pairwise(true, in.columns(0, in.n)).answer(in.n);
}

fn rowLayout(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    return rowWise(in.rows).answer(in.n);
}

fn onePass(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    return onePassColumns(in.columns(0, in.n)).answer(in.n);
}

/// The 44 wide passes, but over a cache-sized piece of the rows at a time.
fn pieces(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    var sums: Sums = .{};
    var lo: usize = 0;
    while (lo < in.n) : (lo += piece) {
        const part = pairwise(true, in.columns(lo, @min(lo + piece, in.n)));
        sums.add(&part);
    }
    return sums.answer(in.n);
}

/// Pool task over block indices [begin, end).
fn correlateBlocks(ctx: *anyopaque, worker: usize, begin: usize, end: usize) void {
    _ = worker;
    const in = of(ctx);
    for (begin..end) |b| {
        const lo = b * block;
        in.slots[b].sums = pairwise(true, in.columns(lo, @min(lo + block, in.n)));
    }
}

fn Threads(comptime count: u32) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            const in = of(p);
            const pool = try env.pool(count);
            pool.parallelFor(in.slots.len, in, correlateBlocks, 1);
            var sums: Sums = .{};
            for (in.slots) |*slot| sums.add(&slot.sums);
            return sums.answer(in.n);
        }
    };
}

pub const job: harness.Job = .{
    .id = "S4",
    .group = "data science",
    .title = "correlation between 8 columns",
    .unit = "rows",
    .bytes_per_item = cols * @sizeOf(f32),
    .sizes = &.{ 10_000, 1_000_000, 10_000_000 },
    .quick_sizes = &.{ 1_000, 100_000 },
    .tolerance = 1e-9,
    .source = @embedFile("s4_correlation.zig"),
    .create = create,
    .destroy = destroy,
    .variants = &.{
        .{ .name = "pairs", .what = "one plain pass per column and per pair of columns (44 passes)", .run = reference },
        .{ .name = "pairs16", .what = "the 44 passes, 16 values at a time", .run = pairs16 },
        .{ .name = "rowlayout", .what = "data stored row after row, one pass updating all 44 sums", .run = rowLayout },
        .{ .name = "onepass", .what = "data stored by column, one pass updating all 44 sums", .run = onePass },
        .{ .name = "pieces", .what = "pairs16 over 4,096 rows at a time, so each piece stays in cache", .run = pieces },
        .{ .name = "threads8", .what = "pairs16 over blocks of rows on 8 threads", .run = Threads(8).run, .threads = true },
        .{ .name = "threads16", .what = "pairs16 over blocks of rows on 16 threads", .run = Threads(16).run, .threads = true },
    },
};

test "S4: every variant gives the reference answer" {
    try harness.expectVariantsAgree(&job, &.{ 0, 1, 2, 3, 15, 16, 17, piece - 1, piece, piece + 1, block + 5, 3 * block + 1 });
}

test "S4: correlations of columns built by hand" {
    // Column 0 is a ramp. Column 1 = 2 * column 0 + 1 (correlation +1 with it), column 2 is
    // minus column 0 (correlation -1), the rest are copies of column 0.
    const n = 6;
    var sums: Sums = .{};
    for (0..n) |r| {
        const t: f64 = @floatFromInt(r);
        var x: [cols]f64 = @splat(t);
        x[1] = 2 * t + 1;
        x[2] = -t;
        addRow(&sums, &x);
    }
    // 28 pairs: column 2 against the 7 others gives -1 each; the other 21 pairs give +1.
    try std.testing.expectApproxEqAbs(@as(f64, 21 - 7), sums.answer(n), 1e-12);
    try std.testing.expectEqual(@as(f64, 0), sums.answer(1));
}

test "S4: the generated columns really are correlated with column 0 by different amounts" {
    const gpa = std.testing.allocator;
    const p = try create(gpa, 20_000);
    defer destroy(gpa, p);
    const in = of(p);
    const sums = pairwise(false, in.columns(0, in.n));
    const count: f64 = @floatFromInt(in.n);
    var last: f64 = -1;
    for (1..cols) |j| {
        const v0 = sums.p[0][0] - sums.s[0] * sums.s[0] / count;
        const vj = sums.p[j][j] - sums.s[j] * sums.s[j] / count;
        const r = (sums.p[0][j] - sums.s[0] * sums.s[j] / count) / @sqrt(v0 * vj);
        try std.testing.expect(r > last and r < 1); // rises with the share of column 0
        last = r;
    }
    try std.testing.expect(last > 0.5);
}
