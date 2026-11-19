// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! A small open-addressing hash table from a u32 key to a dense group number (0, 1, 2, ... in
//! order of first appearance). Jobs keep their per-group data in plain arrays indexed by that
//! number. Used as the hand-written alternative to std's hash map.

const std = @import("std");

pub const Table = struct {
    /// Group number + 1 per slot; 0 marks an empty slot. Length is a power of two.
    slots: []u32,
    /// Key of each group, by group number.
    keys: []u32,
    count: u32 = 0,
    shift: u5,

    /// Room for `max_groups` different keys at no more than half full. Caller frees with `deinit`.
    pub fn init(gpa: std.mem.Allocator, max_groups: usize) !Table {
        const want = @max(max_groups, 1) * 2;
        if (want > 1 << 31) return error.TableTooLarge;
        const cap = std.math.ceilPowerOfTwoAssert(usize, @max(want, 2));
        const slots = try gpa.alloc(u32, cap);
        errdefer gpa.free(slots);
        const keys = try gpa.alloc(u32, @max(max_groups, 1));
        @memset(slots, 0);
        return .{ .slots = slots, .keys = keys, .shift = @intCast(32 - std.math.log2_int(usize, cap)) };
    }

    pub fn deinit(t: *Table, gpa: std.mem.Allocator) void {
        gpa.free(t.keys);
        gpa.free(t.slots);
        t.* = undefined;
    }

    /// Forget every key; keep the memory.
    pub fn clear(t: *Table) void {
        @memset(t.slots, 0);
        t.count = 0;
    }

    /// Multiply, fold the high bits down, multiply again, keep the top bits. One multiply alone
    /// is not enough: keys that are themselves multiples of a constant related to the
    /// multiplier pile into a few slots (see docs/measurements.md, D4).
    fn home(t: *const Table, key: u32) usize {
        var x = key *% 0x85EBCA6B;
        x ^= x >> 15;
        x *%= 0xC2B2AE35;
        return x >> t.shift;
    }

    /// The group number of `key`, adding it if new. The caller must not add more than the
    /// `max_groups` the table was made for.
    pub fn getOrPut(t: *Table, key: u32) u32 {
        const mask = t.slots.len - 1;
        var i = t.home(key);
        while (true) : (i = (i + 1) & mask) {
            const s = t.slots[i];
            if (s == 0) {
                std.debug.assert(t.count < t.keys.len);
                t.keys[t.count] = key;
                t.count += 1;
                t.slots[i] = t.count;
                return t.count - 1;
            }
            if (t.keys[s - 1] == key) return s - 1;
        }
    }

    /// The group number of `key`, or null. Safe to call from many threads at once as long as
    /// nobody is adding.
    pub fn get(t: *const Table, key: u32) ?u32 {
        const mask = t.slots.len - 1;
        var i = t.home(key);
        while (true) : (i = (i + 1) & mask) {
            const s = t.slots[i];
            if (s == 0) return null;
            if (t.keys[s - 1] == key) return s - 1;
        }
    }
};

test "table: numbers groups in order of first appearance, finds them again" {
    const gpa = std.testing.allocator;
    var t = try Table.init(gpa, 1000);
    defer t.deinit(gpa);
    try std.testing.expectEqual(@as(?u32, null), t.get(7));
    // Keys chosen to collide on their home slot as well as not.
    for (0..1000) |i| {
        const key: u32 = @intCast(i * 4096 + (i % 3));
        try std.testing.expectEqual(@as(u32, @intCast(i)), t.getOrPut(key));
    }
    for (0..1000) |i| {
        const key: u32 = @intCast(i * 4096 + (i % 3));
        try std.testing.expectEqual(@as(u32, @intCast(i)), t.getOrPut(key));
        try std.testing.expectEqual(@as(?u32, @intCast(i)), t.get(key));
        try std.testing.expectEqual(key, t.keys[i]);
    }
    try std.testing.expectEqual(@as(u32, 1000), t.count);
    try std.testing.expectEqual(@as(?u32, null), t.get(5));
    t.clear();
    try std.testing.expectEqual(@as(u32, 0), t.count);
    try std.testing.expectEqual(@as(?u32, null), t.get(4096));
}

test "table: one key, and key zero" {
    const gpa = std.testing.allocator;
    var t = try Table.init(gpa, 1);
    defer t.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), t.getOrPut(0));
    try std.testing.expectEqual(@as(?u32, 0), t.get(0));
    try std.testing.expectEqual(@as(?u32, null), t.get(1));
}
