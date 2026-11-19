// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Synthetic inputs. Every job gets the same values on every run and on every machine, and the
//! generator is simple enough to repeat exactly in Python for the outside checks.

/// One step of the 32-bit linear congruential generator all inputs come from.
pub fn next(state: *u32) u32 {
    state.* = state.* *% 1664525 +% 1013904223;
    return state.*;
}

/// Fills `xs` with values in [0, 1): the top 24 bits of each generator step, divided by 2^24.
pub fn fillUnit(xs: []f32, seed: u32) void {
    var state = seed;
    for (xs) |*x| x.* = @as(f32, @floatFromInt(next(&state) >> 8)) / 16777216.0;
}

test "fillUnit is the documented sequence" {
    const std = @import("std");
    var xs: [3]f32 = undefined;
    fillUnit(&xs, 12345);
    // state_1 = 12345 * 1664525 + 1013904223 mod 2^32 = 87628868
    try std.testing.expectEqual(@as(f32, @floatFromInt(87628868 >> 8)) / 16777216.0, xs[0]);
    for (xs) |x| try std.testing.expect(x >= 0 and x < 1);
    try std.testing.expect(xs[0] != xs[1] and xs[1] != xs[2]);
}
