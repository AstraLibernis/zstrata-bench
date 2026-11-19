// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Synthetic inputs. Every job gets the same values on every run and on every machine, and the
//! generators are simple enough to repeat exactly in Python for the outside checks
//! (verify/common.py holds the same three functions).

/// One step of the 32-bit linear congruential generator all inputs come from.
pub fn next(state: *u32) u32 {
    state.* = state.* *% 1664525 +% 1013904223;
    return state.*;
}

/// Scrambles all 32 bits (the finishing step of MurmurHash3). The raw generator's low bits
/// repeat with short periods; keys built from them would be unrealistically regular.
pub fn mix(value: u32) u32 {
    var x = value;
    x ^= x >> 16;
    x *%= 0x85ebca6b;
    x ^= x >> 13;
    x *%= 0xc2b2ae35;
    x ^= x >> 16;
    return x;
}

/// Fills `xs` with values in [0, 1): the top 24 bits of each generator step, divided by 2^24.
pub fn fillUnit(xs: []f32, seed: u32) void {
    var state = seed;
    for (xs) |*x| x.* = @as(f32, @floatFromInt(next(&state) >> 8)) / 16777216.0;
}

/// Fills `xs` with scrambled 32-bit values.
pub fn fillMixed(xs: []u32, seed: u32) void {
    var state = seed;
    for (xs) |*x| x.* = mix(next(&state));
}

/// Fills `xs` with scrambled bytes (the low 8 bits of each scrambled value).
pub fn fillBytes(xs: []u8, seed: u32) void {
    var state = seed;
    for (xs) |*x| x.* = @truncate(mix(next(&state)));
}

/// Fills `xs` with keys drawn from `distinct` different values (each key is
/// `mix(scrambled % distinct)`; `mix` never maps two numbers to one, so there are exactly that
/// many keys and they have no pattern a hash function could trip over). `distinct` must be at
/// least 1.
pub fn fillKeys(xs: []u32, seed: u32, distinct: u32) void {
    var state = seed;
    for (xs) |*x| x.* = mix(mix(next(&state)) % distinct);
}

const std = @import("std");

test "fillUnit is the documented sequence" {
    var xs: [3]f32 = undefined;
    fillUnit(&xs, 12345);
    // state_1 = 12345 * 1664525 + 1013904223 mod 2^32 = 87628868
    try std.testing.expectEqual(@as(f32, @floatFromInt(87628868 >> 8)) / 16777216.0, xs[0]);
    for (xs) |x| try std.testing.expect(x >= 0 and x < 1);
    try std.testing.expect(xs[0] != xs[1] and xs[1] != xs[2]);
}

test "mix scrambles and never collides" {
    try std.testing.expectEqual(@as(u32, 0), mix(0));
    try std.testing.expectEqual(@as(u32, 0x514e28b7), mix(1)); // MurmurHash3 fmix32(1)
    // Each step of mix can be undone, so 0..n map to n different keys.
    var seen: [1000]u32 = undefined;
    for (&seen, 0..) |*s, i| s.* = mix(@intCast(i));
    std.mem.sort(u32, &seen, {}, std.sort.asc(u32));
    for (seen[0 .. seen.len - 1], seen[1..]) |a, b| try std.testing.expect(a != b);
}

test "fillKeys draws from exactly `distinct` values" {
    var xs: [5000]u32 = undefined;
    fillKeys(&xs, 3, 7);
    std.mem.sort(u32, &xs, {}, std.sort.asc(u32));
    var kinds: usize = 1;
    for (xs[0 .. xs.len - 1], xs[1..]) |a, b| kinds += @intFromBool(a != b);
    try std.testing.expectEqual(@as(usize, 7), kinds);
}
