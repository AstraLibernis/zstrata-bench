// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Least-significant-digit radix sorts used as variants by several jobs.

const std = @import("std");

/// Sorts `items` ascending by `key_bits` bits of each item starting at bit `shift`, taking
/// `digit_bits` bits per pass. Stable. `scratch.len` must equal `items.len`. The result is in
/// `items`.
///
/// `T` is u32 (the value is the key) or u64 (a record: any 32 or fewer bits are the key and
/// the rest ride along).
pub fn sort(
    comptime T: type,
    comptime digit_bits: comptime_int,
    comptime shift: comptime_int,
    comptime key_bits: comptime_int,
    items: []T,
    scratch: []T,
) void {
    std.debug.assert(scratch.len == items.len);
    const passes = (key_bits + digit_bits - 1) / digit_bits;
    const buckets = 1 << digit_bits;

    // One read of the data counts every pass's digits.
    var counts: [passes][buckets]usize = @splat(@splat(0));
    for (items) |item| {
        const key = item >> shift;
        inline for (0..passes) |p| counts[p][@intCast((key >> (p * digit_bits)) & (buckets - 1))] += 1;
    }

    var src = items;
    var dst = scratch;
    inline for (0..passes) |p| {
        // Counts become each bucket's first position.
        var at: usize = 0;
        for (&counts[p]) |*c| {
            const n = c.*;
            c.* = at;
            at += n;
        }
        for (src) |item| {
            const digit: usize = @intCast(((item >> shift) >> (p * digit_bits)) & (buckets - 1));
            dst[counts[p][digit]] = item;
            counts[p][digit] += 1;
        }
        std.mem.swap([]T, &src, &dst);
    }
    // After an odd number of passes the sorted data sits in `scratch`.
    if (passes % 2 == 1) @memcpy(items, scratch);
}

fn expectSorts(comptime digit_bits: comptime_int, n: usize, seed: u64) !void {
    const gpa = std.testing.allocator;
    const a = try gpa.alloc(u32, n);
    defer gpa.free(a);
    const b = try gpa.alloc(u32, n);
    defer gpa.free(b);
    const scratch = try gpa.alloc(u32, n);
    defer gpa.free(scratch);
    var prng = std.Random.DefaultPrng.init(seed);
    for (a) |*x| x.* = prng.random().int(u32);
    // Extremes and repeats, where a wrong digit mask or count would show.
    if (n > 4) {
        a[0] = 0;
        a[1] = std.math.maxInt(u32);
        a[2] = a[3];
    }
    @memcpy(b, a);
    std.mem.sort(u32, b, {}, std.sort.asc(u32));
    sort(u32, digit_bits, 0, 32, a, scratch);
    try std.testing.expectEqualSlices(u32, b, a);
}

test "radix: u32 keys, even and odd pass counts, edge sizes" {
    for ([_]usize{ 0, 1, 2, 3, 255, 256, 257, 5000 }) |n| {
        try expectSorts(8, n, n + 1); // 4 passes: ends in `items`
        try expectSorts(11, n, n + 2); // 3 passes: copied back from scratch
    }
}

test "radix: a partial key sorts only by those bits, and is stable" {
    // Sort by the low 24 bits only: the top byte must keep its original order within ties.
    var items = [_]u32{ 0x02_000005, 0x01_000005, 0x03_000001, 0x00_000005 };
    var scratch: [4]u32 = undefined;
    sort(u32, 8, 0, 24, &items, &scratch);
    try std.testing.expectEqualSlices(u32, &.{ 0x03_000001, 0x02_000005, 0x01_000005, 0x00_000005 }, &items);
}

test "radix: 64-bit records by their high half, payload rides along" {
    var recs = [_]u64{ (3 << 32) | 30, (1 << 32) | 10, (2 << 32) | 20, (1 << 32) | 11 };
    var scratch: [4]u64 = undefined;
    sort(u64, 8, 32, 32, &recs, &scratch);
    try std.testing.expectEqualSlices(u64, &.{ (1 << 32) | 10, (1 << 32) | 11, (2 << 32) | 20, (3 << 32) | 30 }, &recs);
}
