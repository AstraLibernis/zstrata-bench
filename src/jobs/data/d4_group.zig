// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! D4: group rows by key and total a value per group.
//!
//! Input: `n` rows of (key: u32, value: f32). Keys are scattered 32-bit numbers drawn from a
//! fixed number of different values (data.fillKeys, seed 3); values are in [0, 1)
//! (data.fillUnit, seed 4).
//! Output: one 64-bit total per different key.
//! Answer (for comparing variants): the number of groups, plus every total weighted by
//! (key % 1009 + 1), so a total credited to the wrong key changes the answer.
//! Three jobs share this file and differ in how many groups there are: D4 has 1,000, D4m has
//! 100,000, D4h has one group per four rows.
//! Outside check: verify/data_jobs.py (NumPy).

const std = @import("std");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const radix = @import("../../kit/radix.zig");
const Table = @import("../../kit/table.zig").Table;
const Env = harness.Env;

const key_seed = 3;
const value_seed = 4;

/// The threaded variant splits the rows into this many equal parts. Each part builds its own
/// table; the parts are merged in order, so the result does not depend on which worker ran what.
const parts = 16;

const Part = struct {
    table: Table,
    totals: []f64,
};

const Input = struct {
    keys: []u32,
    values: []f32,
    groups: usize,
    // std variant
    map: std.AutoHashMapUnmanaged(u32, f64) = .empty,
    // table variant, and the merge target of the threaded variant
    table: Table,
    totals: []f64,
    // sort variant: key in the high half, the value's bits in the low half
    recs: []u64,
    scratch: []u64,
    // threaded variant; empty when the job has too many groups for per-part tables
    part: []Part,
    gpa: std.mem.Allocator,
};

fn of(p: *anyopaque) *Input {
    return @ptrCast(@alignCast(p));
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    for (in.part) |*pt| {
        gpa.free(pt.totals);
        pt.table.deinit(gpa);
    }
    gpa.free(in.part);
    gpa.free(in.scratch);
    gpa.free(in.recs);
    gpa.free(in.totals);
    in.table.deinit(gpa);
    in.map.deinit(gpa);
    gpa.free(in.values);
    gpa.free(in.keys);
    gpa.destroy(in);
}

fn weight(key: u32) f64 {
    return @floatFromInt(key % 1009 + 1);
}

fn answerOfTable(t: *const Table, totals: []const f64) f64 {
    var a: f64 = @floatFromInt(t.count);
    for (t.keys[0..t.count], totals[0..t.count]) |k, total| a += total * weight(k);
    return a;
}

/// The reference: std's hash map from key to total.
fn stdMap(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    in.map.clearRetainingCapacity();
    for (in.keys, in.values) |k, v| {
        const slot = try in.map.getOrPut(in.gpa, k);
        if (slot.found_existing) slot.value_ptr.* += v else slot.value_ptr.* = v;
    }
    var a: f64 = @floatFromInt(in.map.count());
    var it = in.map.iterator();
    while (it.next()) |e| a += e.value_ptr.* * weight(e.key_ptr.*);
    return a;
}

fn accumulate(t: *Table, totals: []f64, keys: []const u32, values: []const f32) void {
    for (keys, values) |k, v| {
        const before = t.count;
        const g = t.getOrPut(k);
        if (g == before) totals[g] = v else totals[g] += v;
    }
}

/// A hand-written table that hands each key a dense group number; totals live in a plain array.
fn table(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    in.table.clear();
    accumulate(&in.table, in.totals, in.keys, in.values);
    return answerOfTable(&in.table, in.totals);
}

/// Sort the rows by key (radix), then total each run of equal keys.
fn sortThenScan(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    for (in.recs, in.keys, in.values) |*r, k, v| r.* = (@as(u64, k) << 32) | @as(u32, @bitCast(v));
    radix.sort(u64, 8, 32, 32, in.recs, in.scratch);
    var a: f64 = 0;
    var i: usize = 0;
    while (i < in.recs.len) {
        const key: u32 = @intCast(in.recs[i] >> 32);
        var total: f64 = 0;
        while (i < in.recs.len and in.recs[i] >> 32 == key) : (i += 1) {
            total += @as(f32, @bitCast(@as(u32, @truncate(in.recs[i]))));
        }
        a += 1 + total * weight(key);
    }
    return a;
}

/// Pool task over parts [begin, end).
fn groupParts(ctx: *anyopaque, worker: usize, begin: usize, end: usize) void {
    _ = worker;
    const in = of(ctx);
    const n = in.keys.len;
    for (begin..end) |b| {
        const lo = b * n / parts;
        const hi = (b + 1) * n / parts;
        const pt = &in.part[b];
        pt.table.clear();
        accumulate(&pt.table, pt.totals, in.keys[lo..hi], in.values[lo..hi]);
    }
}

fn Threads(comptime count: u32) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            const in = of(p);
            const pool = try env.pool(count);
            pool.parallelFor(parts, in, groupParts, 1);
            in.table.clear();
            for (in.part) |*pt| {
                for (pt.table.keys[0..pt.table.count], pt.totals[0..pt.table.count]) |k, total| {
                    const before = in.table.count;
                    const g = in.table.getOrPut(k);
                    if (g == before) in.totals[g] = total else in.totals[g] += total;
                }
            }
            return answerOfTable(&in.table, in.totals);
        }
    };
}

const How = enum { fixed, per_four_rows };

fn Group(comptime id: []const u8, comptime title: []const u8, comptime how: How, comptime fixed: usize, comptime threaded: bool) type {
    return struct {
        fn groupsFor(n: usize) usize {
            return switch (how) {
                .fixed => @max(1, @min(fixed, n)),
                .per_four_rows => @max(1, n / 4),
            };
        }

        fn create(gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque {
            const groups = groupsFor(n);
            if (groups > std.math.maxInt(u32)) return error.TooManyGroups;
            const in = try gpa.create(Input);
            errdefer gpa.destroy(in);
            const keys = try gpa.alloc(u32, n);
            errdefer gpa.free(keys);
            const values = try gpa.alloc(f32, n);
            errdefer gpa.free(values);
            var main_table = try Table.init(gpa, groups);
            errdefer main_table.deinit(gpa);
            const totals = try gpa.alloc(f64, groups);
            errdefer gpa.free(totals);
            const recs = try gpa.alloc(u64, n);
            errdefer gpa.free(recs);
            const scratch = try gpa.alloc(u64, n);
            errdefer gpa.free(scratch);
            const part = try gpa.alloc(Part, if (threaded) parts else 0);
            errdefer gpa.free(part);
            var made: usize = 0;
            errdefer for (part[0..made]) |*pt| {
                gpa.free(pt.totals);
                pt.table.deinit(gpa);
            };
            while (made < part.len) : (made += 1) {
                var t = try Table.init(gpa, groups);
                errdefer t.deinit(gpa);
                part[made] = .{ .table = t, .totals = try gpa.alloc(f64, groups) };
            }
            data.fillKeys(keys, key_seed, @intCast(groups));
            data.fillUnit(values, value_seed);
            in.* = .{
                .keys = keys,
                .values = values,
                .groups = groups,
                .table = main_table,
                .totals = totals,
                .recs = recs,
                .scratch = scratch,
                .part = part,
                .gpa = gpa,
            };
            return in;
        }

        const base = [_]harness.Variant{
            .{ .name = "std", .what = "std.AutoHashMap from key to total", .run = stdMap },
            .{ .name = "table", .what = "hand-written table giving dense group numbers, totals in an array", .run = table },
            .{ .name = "sort", .what = "radix sort the rows by key, then total each run", .run = sortThenScan },
        };
        const with_threads = base ++ [_]harness.Variant{
            .{ .name = "threads8", .what = "16 parts, each with its own table, on 8 threads; merged in order", .run = Threads(8).run, .threads = true },
            .{ .name = "threads16", .what = "16 parts, each with its own table, on 16 threads; merged in order", .run = Threads(16).run, .threads = true },
        };

        pub const job: harness.Job = .{
            .id = id,
            .group = "data processing",
            .title = title,
            .unit = "rows",
            .bytes_per_item = @sizeOf(u32) + @sizeOf(f32),
            .sizes = &.{ 10_000, 1_000_000, 20_000_000 },
            .quick_sizes = &.{ 1_000, 100_000 },
            .tolerance = 1e-9,
            .source = @embedFile("d4_group.zig") ++ @embedFile("../../kit/radix.zig") ++ @embedFile("../../kit/table.zig"),
            .create = create,
            .destroy = destroy,
            .variants = if (threaded) &with_threads else &base,
        };
    };
}

pub const few = Group("D4", "group by key and total, 1,000 groups", .fixed, 1_000, true).job;
pub const many = Group("D4m", "group by key and total, 100,000 groups", .fixed, 100_000, true).job;
/// Per-part tables for this many groups would need gigabytes, so it has no threaded variant.
pub const huge = Group("D4h", "group by key and total, one group per four rows", .per_four_rows, 0, false).job;

const edge_sizes = [_]usize{ 0, 1, 2, 15, 16, 17, 999, 1000, 1001, 50_000 };

test "D4: every variant gives the reference answer" {
    try harness.expectVariantsAgree(&few, &edge_sizes);
    try harness.expectVariantsAgree(&many, &edge_sizes);
    try harness.expectVariantsAgree(&huge, &edge_sizes);
}

test "D4: the reference matches totals worked out the slow way" {
    const gpa = std.testing.allocator;
    var env: Env = .{ .gpa = gpa, .io = std.testing.io };
    defer env.deinit();
    const n = 5000;
    const p = try few.create(gpa, n);
    defer few.destroy(gpa, p);
    const in = of(p);
    // For every row's key, total all rows with that key by scanning; count each key once.
    var want: f64 = 0;
    for (in.keys, 0..) |k, first| {
        if (std.mem.findScalar(u32, in.keys[0..first], k) != null) continue;
        var total: f64 = 0;
        for (in.keys, in.values) |k2, v| {
            if (k2 == k) total += v;
        }
        want += 1 + total * weight(k);
    }
    try std.testing.expect(harness.agrees(try stdMap(&env, p), want, 1e-9));
    // 5,000 draws from 1,000 keys reach nearly all of them, never more.
    try std.testing.expect(in.map.count() > 900 and in.map.count() <= 1000);
}
