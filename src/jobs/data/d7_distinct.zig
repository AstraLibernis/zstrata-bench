// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! D7: remove duplicate keys.
//!
//! Input: `n` scattered 32-bit keys drawn from a fixed number of different values
//! (data.fillKeys, seed 8).
//! Output: each different key once.
//! Answer (for comparing variants): how many different keys there are, plus (key % 1009 + 1)
//! added up over them, so a missing or repeated key changes the answer.
//! Two jobs share this file: D7 has 1,000 different keys (nearly everything is a repeat), D7u has
//! one different key per two rows (about four rows in ten are first appearances).
//! Outside check: verify/data_jobs.py (NumPy).

const std = @import("std");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const radix = @import("../../kit/radix.zig");
const Table = @import("../../kit/table.zig").Table;
const Env = harness.Env;

const seed = 8;

/// The threaded variant splits the rows into this many equal parts. Each part finds its own
/// different keys; the parts are merged in order.
const parts = 16;

const Input = struct {
    keys: []u32,
    set: std.AutoHashMapUnmanaged(u32, void) = .empty,
    table: Table,
    work: []u32,
    scratch: []u32,
    part: []Table,
    gpa: std.mem.Allocator,
};

fn of(p: *anyopaque) *Input {
    return @ptrCast(@alignCast(p));
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    for (in.part) |*t| t.deinit(gpa);
    gpa.free(in.part);
    gpa.free(in.scratch);
    gpa.free(in.work);
    in.table.deinit(gpa);
    in.set.deinit(gpa);
    gpa.free(in.keys);
    gpa.destroy(in);
}

fn weight(key: u32) f64 {
    return @floatFromInt(key % 1009 + 1);
}

fn answerOfTable(t: *const Table) f64 {
    var a: f64 = @floatFromInt(t.count);
    for (t.keys[0..t.count]) |k| a += weight(k);
    return a;
}

/// The reference: std's hash set.
fn stdSet(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    in.set.clearRetainingCapacity();
    for (in.keys) |k| try in.set.put(in.gpa, k, {});
    var a: f64 = @floatFromInt(in.set.count());
    var it = in.set.keyIterator();
    while (it.next()) |k| a += weight(k.*);
    return a;
}

/// A hand-written table; its list of keys is the answer, in order of first appearance.
fn table(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    in.table.clear();
    for (in.keys) |k| _ = in.table.getOrPut(k);
    return answerOfTable(&in.table);
}

/// Radix sort a copy, then keep each key that differs from the one before it.
fn sortThenScan(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    @memcpy(in.work, in.keys);
    radix.sort(u32, 8, 0, 32, in.work, in.scratch);
    var a: f64 = 0;
    var kept: usize = 0;
    for (in.work, 0..) |k, i| {
        if (i != 0 and k == in.work[i - 1]) continue;
        in.work[kept] = k;
        kept += 1;
        a += weight(k);
    }
    return a + @as(f64, @floatFromInt(kept));
}

/// Pool task over parts [begin, end).
fn distinctParts(ctx: *anyopaque, worker: usize, begin: usize, end: usize) void {
    _ = worker;
    const in = of(ctx);
    const n = in.keys.len;
    for (begin..end) |b| {
        const t = &in.part[b];
        t.clear();
        for (in.keys[b * n / parts .. (b + 1) * n / parts]) |k| _ = t.getOrPut(k);
    }
}

fn Threads(comptime count: u32) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            const in = of(p);
            const pool = try env.pool(count);
            pool.parallelFor(parts, in, distinctParts, 1);
            in.table.clear();
            for (in.part) |*t| {
                for (t.keys[0..t.count]) |k| _ = in.table.getOrPut(k);
            }
            return answerOfTable(&in.table);
        }
    };
}

const How = enum { fixed, per_two_rows };

fn Distinct(comptime id: []const u8, comptime title: []const u8, comptime how: How, comptime fixed: usize) type {
    return struct {
        fn distinctFor(n: usize) usize {
            return switch (how) {
                .fixed => @max(1, @min(fixed, n)),
                .per_two_rows => @max(1, n / 2),
            };
        }

        fn create(gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque {
            const distinct = distinctFor(n);
            if (distinct > std.math.maxInt(u32)) return error.TooManyKeys;
            const in = try gpa.create(Input);
            errdefer gpa.destroy(in);
            const keys = try gpa.alloc(u32, n);
            errdefer gpa.free(keys);
            var main_table = try Table.init(gpa, distinct);
            errdefer main_table.deinit(gpa);
            const work = try gpa.alloc(u32, n);
            errdefer gpa.free(work);
            const scratch = try gpa.alloc(u32, n);
            errdefer gpa.free(scratch);
            const part = try gpa.alloc(Table, parts);
            errdefer gpa.free(part);
            var made: usize = 0;
            errdefer for (part[0..made]) |*t| t.deinit(gpa);
            // A part cannot hold more different keys than it has rows.
            const part_keys = @min(distinct, n / parts + 1);
            while (made < parts) : (made += 1) part[made] = try Table.init(gpa, part_keys);
            data.fillKeys(keys, seed, @intCast(distinct));
            in.* = .{ .keys = keys, .table = main_table, .work = work, .scratch = scratch, .part = part, .gpa = gpa };
            return in;
        }

        pub const job: harness.Job = .{
            .id = id,
            .group = "data processing",
            .title = title,
            .unit = "rows",
            .bytes_per_item = @sizeOf(u32),
            .sizes = &.{ 10_000, 1_000_000, 20_000_000 },
            .quick_sizes = &.{ 1_000, 100_000 },
            .tolerance = 0,
            .source = @embedFile("d7_distinct.zig") ++ @embedFile("../../kit/radix.zig") ++ @embedFile("../../kit/table.zig"),
            .create = create,
            .destroy = destroy,
            .variants = &.{
                .{ .name = "std", .what = "std.AutoHashMap used as a set", .run = stdSet },
                .{ .name = "table", .what = "hand-written table; its key list is the answer", .run = table },
                .{ .name = "sort", .what = "radix sort a copy, keep each key that differs from the one before", .run = sortThenScan },
                .{ .name = "threads8", .what = "16 parts with a table each, on 8 threads; merged in order", .run = Threads(8).run, .threads = true },
                .{ .name = "threads16", .what = "16 parts with a table each, on 16 threads; merged in order", .run = Threads(16).run, .threads = true },
            },
        };
    };
}

pub const few = Distinct("D7", "remove duplicate keys, 1,000 different keys", .fixed, 1_000).job;
pub const unique = Distinct("D7u", "remove duplicate keys, one different key per two rows", .per_two_rows, 0).job;

const edge_sizes = [_]usize{ 0, 1, 2, 15, 16, 17, 999, 1000, 1001, 50_000 };

test "D7: every variant gives the reference answer" {
    try harness.expectVariantsAgree(&few, &edge_sizes);
    try harness.expectVariantsAgree(&unique, &edge_sizes);
}

test "D7: every variant keeps exactly the keys a slow scan keeps" {
    const gpa = std.testing.allocator;
    var env: Env = .{ .gpa = gpa, .io = std.testing.io, .force_threads = 3 };
    defer env.deinit();
    for ([_]*const harness.Job{ &few, &unique }) |job| {
        const n = 3000;
        const p = try job.create(gpa, n);
        defer job.destroy(gpa, p);
        const in = of(p);
        // Keys in order of first appearance, found the slow way.
        var want: std.ArrayList(u32) = .empty;
        defer want.deinit(gpa);
        for (in.keys, 0..) |k, i| {
            if (std.mem.findScalar(u32, in.keys[0..i], k) == null) try want.append(gpa, k);
        }
        _ = try table(&env, p);
        try std.testing.expectEqualSlices(u32, want.items, in.table.keys[0..in.table.count]);
        // The other variants hold the same keys in another order: compare sorted.
        std.mem.sort(u32, want.items, {}, std.sort.asc(u32));
        _ = try sortThenScan(&env, p);
        try std.testing.expectEqualSlices(u32, want.items, in.work[0..want.items.len]);
        _ = try Threads(3).run(&env, p);
        const merged = try gpa.dupe(u32, in.table.keys[0..in.table.count]);
        defer gpa.free(merged);
        std.mem.sort(u32, merged, {}, std.sort.asc(u32));
        try std.testing.expectEqualSlices(u32, want.items, merged);
        _ = try stdSet(&env, p);
        try std.testing.expectEqual(want.items.len, in.set.count());
        for (want.items) |k| try std.testing.expect(in.set.contains(k));
    }
}
