// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! D5: join two tables on a key.
//!
//! Input: a small table of `m = n / 10` rows (key: u32, each key once; payload: f32) and a large
//! table of `n` rows (key: u32, value: f32). About half of the large table's keys exist in the
//! small one.
//!   small keys   data.mix(i) for i in 0..m            payloads data.fillUnit, seed 5
//!   large keys   data.fillKeys, seed 6, from 2m keys  values   data.fillUnit, seed 7
//! Output: for every large row whose key is in the small table, value * payload.
//! Answer (for comparing variants): the number of matches plus the sum of those products.
//! Every variant builds whatever index it needs inside its timed run.
//! Outside check: verify/data_jobs.py (NumPy).

const std = @import("std");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const radix = @import("../../kit/radix.zig");
const Table = @import("../../kit/table.zig").Table;
const Env = harness.Env;

/// Threaded variants look rows up in blocks of this many; partial results are added in block
/// order afterwards.
const block = 1 << 16;

/// One partial result per cache line: two workers never write the same line.
const Partial = struct { sum: f64 align(std.atomic.cache_line) = 0, matches: usize = 0 };

const Input = struct {
    small_keys: []u32,
    payloads: []f32,
    large_keys: []u32,
    values: []f32,
    map: std.AutoHashMapUnmanaged(u32, f32) = .empty,
    table: Table,
    // sort-merge variant: key in the high half, the float's bits in the low half
    small_recs: []u64,
    large_recs: []u64,
    scratch: []u64,
    partials: []Partial,
    gpa: std.mem.Allocator,
};

fn of(p: *anyopaque) *Input {
    return @ptrCast(@alignCast(p));
}

fn create(gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque {
    const m = @max(1, n / 10);
    if (2 * m > std.math.maxInt(u32)) return error.TooManyKeys;
    const in = try gpa.create(Input);
    errdefer gpa.destroy(in);
    const small_keys = try gpa.alloc(u32, m);
    errdefer gpa.free(small_keys);
    const payloads = try gpa.alloc(f32, m);
    errdefer gpa.free(payloads);
    const large_keys = try gpa.alloc(u32, n);
    errdefer gpa.free(large_keys);
    const values = try gpa.alloc(f32, n);
    errdefer gpa.free(values);
    var index = try Table.init(gpa, m);
    errdefer index.deinit(gpa);
    const small_recs = try gpa.alloc(u64, m);
    errdefer gpa.free(small_recs);
    const large_recs = try gpa.alloc(u64, n);
    errdefer gpa.free(large_recs);
    const scratch = try gpa.alloc(u64, @max(n, m));
    errdefer gpa.free(scratch);
    const partials = try gpa.alloc(Partial, (n + block - 1) / block);

    for (small_keys, 0..) |*k, i| k.* = data.mix(@intCast(i));
    data.fillUnit(payloads, 5);
    data.fillKeys(large_keys, 6, @intCast(2 * m));
    data.fillUnit(values, 7);
    in.* = .{
        .small_keys = small_keys,
        .payloads = payloads,
        .large_keys = large_keys,
        .values = values,
        .table = index,
        .small_recs = small_recs,
        .large_recs = large_recs,
        .scratch = scratch,
        .partials = partials,
        .gpa = gpa,
    };
    return in;
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    gpa.free(in.partials);
    gpa.free(in.scratch);
    gpa.free(in.large_recs);
    gpa.free(in.small_recs);
    in.table.deinit(gpa);
    in.map.deinit(gpa);
    gpa.free(in.values);
    gpa.free(in.large_keys);
    gpa.free(in.payloads);
    gpa.free(in.small_keys);
    gpa.destroy(in);
}

fn product(value: f32, payload: f32) f64 {
    return @as(f64, value) * @as(f64, payload);
}

/// The reference: std's hash map on the small table, then look every large row up.
fn stdMap(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    in.map.clearRetainingCapacity();
    try in.map.ensureTotalCapacity(in.gpa, @intCast(in.small_keys.len));
    for (in.small_keys, in.payloads) |k, pay| try in.map.put(in.gpa, k, pay);
    var sum: f64 = 0;
    var matches: usize = 0;
    for (in.large_keys, in.values) |k, v| {
        if (in.map.get(k)) |pay| {
            sum += product(v, pay);
            matches += 1;
        }
    }
    return sum + @as(f64, @floatFromInt(matches));
}

fn buildTable(in: *Input) void {
    in.table.clear();
    // Each small key is new, so its group number is its row.
    for (in.small_keys) |k| _ = in.table.getOrPut(k);
}

fn probe(in: *const Input, keys: []const u32, values: []const f32) Partial {
    var out: Partial = .{};
    for (keys, values) |k, v| {
        if (in.table.get(k)) |row| {
            out.sum += product(v, in.payloads[row]);
            out.matches += 1;
        }
    }
    return out;
}

/// A hand-written table on the small side; the payload is fetched by row number.
fn table(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    buildTable(in);
    const r = probe(in, in.large_keys, in.values);
    return r.sum + @as(f64, @floatFromInt(r.matches));
}

fn pack(key: u32, x: f32) u64 {
    return (@as(u64, key) << 32) | @as(u32, @bitCast(x));
}

fn unpack(rec: u64) f32 {
    return @bitCast(@as(u32, @truncate(rec)));
}

/// Sort both sides by key (radix), then walk them together.
fn sortMerge(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    for (in.small_recs, in.small_keys, in.payloads) |*r, k, pay| r.* = pack(k, pay);
    for (in.large_recs, in.large_keys, in.values) |*r, k, v| r.* = pack(k, v);
    radix.sort(u64, 8, 32, 32, in.small_recs, in.scratch[0..in.small_recs.len]);
    radix.sort(u64, 8, 32, 32, in.large_recs, in.scratch[0..in.large_recs.len]);
    var sum: f64 = 0;
    var matches: usize = 0;
    var s: usize = 0;
    for (in.large_recs) |rec| {
        const key = rec >> 32;
        while (s < in.small_recs.len and in.small_recs[s] >> 32 < key) s += 1;
        if (s == in.small_recs.len) break;
        if (in.small_recs[s] >> 32 == key) {
            sum += product(unpack(rec), unpack(in.small_recs[s]));
            matches += 1;
        }
    }
    return sum + @as(f64, @floatFromInt(matches));
}

/// Pool task over block indices [begin, end).
fn probeBlocks(ctx: *anyopaque, worker: usize, begin: usize, end: usize) void {
    _ = worker;
    const in = of(ctx);
    for (begin..end) |b| {
        const lo = b * block;
        const hi = @min(lo + block, in.large_keys.len);
        in.partials[b] = probe(in, in.large_keys[lo..hi], in.values[lo..hi]);
    }
}

/// Build the table on one thread, look the large rows up on many.
fn Threads(comptime count: u32) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            const in = of(p);
            const pool = try env.pool(count);
            buildTable(in);
            pool.parallelFor(in.partials.len, in, probeBlocks, 1);
            var sum: f64 = 0;
            var matches: usize = 0;
            for (in.partials) |part| {
                sum += part.sum;
                matches += part.matches;
            }
            return sum + @as(f64, @floatFromInt(matches));
        }
    };
}

pub const job: harness.Job = .{
    .id = "D5",
    .group = "data processing",
    .title = "join a large table to one a tenth its size",
    .unit = "rows",
    .bytes_per_item = @sizeOf(u32) + @sizeOf(f32),
    .sizes = &.{ 10_000, 1_000_000, 20_000_000 },
    .quick_sizes = &.{ 1_000, 100_000 },
    .tolerance = 1e-9,
    .source = @embedFile("d5_join.zig") ++ @embedFile("../../kit/radix.zig") ++ @embedFile("../../kit/table.zig"),
    .create = create,
    .destroy = destroy,
    .variants = &.{
        .{ .name = "std", .what = "std.AutoHashMap on the small table", .run = stdMap },
        .{ .name = "table", .what = "hand-written table on the small table", .run = table },
        .{ .name = "sortmerge", .what = "radix sort both sides by key, then walk them together", .run = sortMerge },
        .{ .name = "threads8", .what = "table built on one thread, looked up on 8", .run = Threads(8).run, .threads = true },
        .{ .name = "threads16", .what = "table built on one thread, looked up on 16", .run = Threads(16).run, .threads = true },
    },
};

const edge_sizes = [_]usize{ 0, 1, 9, 10, 11, 20, 1000, block - 1, block, block + 1, 2 * block + 9 };

test "D5: every variant gives the reference answer" {
    try harness.expectVariantsAgree(&job, &edge_sizes);
}

test "D5: the reference matches a join worked out the slow way, and about half the rows match" {
    const gpa = std.testing.allocator;
    var env: Env = .{ .gpa = gpa, .io = std.testing.io };
    defer env.deinit();
    const n = 4000;
    const p = try create(gpa, n);
    defer destroy(gpa, p);
    const in = of(p);
    var sum: f64 = 0;
    var matches: usize = 0;
    for (in.large_keys, in.values) |k, v| {
        if (std.mem.findScalar(u32, in.small_keys, k)) |row| {
            sum += product(v, in.payloads[row]);
            matches += 1;
        }
    }
    try std.testing.expect(harness.agrees(try stdMap(&env, p), sum + @as(f64, @floatFromInt(matches)), 1e-9));
    try std.testing.expect(matches > n * 4 / 10 and matches < n * 6 / 10);
}
