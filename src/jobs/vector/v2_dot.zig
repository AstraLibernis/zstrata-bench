// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! V2: how to write a running total so that it runs as vector code.
//!
//! The loop is `sum += x[i] * y[i]` over 32-bit floats in [-0.5, 0.5) (data.fillUnit seeds 132
//! and 133, minus 0.5). Nothing is stored, so overlap is not the issue here. The issue is that
//! floating-point addition gives different last bits in a different order, so a compiler may
//! not reorder the additions unless it is told that is acceptable.
//! Answer (for comparing variants): the total. Variants add in different orders, so they agree
//! only to about one part in a thousand of the largest term.

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const Env = harness.Env;

/// What `std.simd` suggests for this build's CPU.
const suggested = std.simd.suggestVectorLength(f32) orelse 4;

/// Whether the build's CPU has a fused multiply-add instruction. Without one, `@mulAdd` still
/// gives the right answer but through a library routine per value, so code meant to run on
/// other machines asks first.
const fused_is_an_instruction = builtin.cpu.has(.x86, .fma) or builtin.cpu.arch.isAARCH64();

const Input = struct {
    x: []f32,
    y: []f32,
};

fn of(p: *anyopaque) *Input {
    return @ptrCast(@alignCast(p));
}

fn create(gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque {
    const in = try gpa.create(Input);
    errdefer gpa.destroy(in);
    const x = try gpa.alloc(f32, n);
    errdefer gpa.free(x);
    const y = try gpa.alloc(f32, n);
    data.fillUnit(x, 132);
    data.fillUnit(y, 133);
    for (x) |*v| v.* -= 0.5;
    for (y) |*v| v.* -= 0.5;
    in.* = .{ .x = x, .y = y };
    return in;
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    gpa.free(in.y);
    gpa.free(in.x);
    gpa.destroy(in);
}

/// The reference: the loop as anyone would write it.
fn plain(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    const in = of(p);
    var s: f32 = 0;
    for (in.x, in.y) |a, b| s += a * b;
    return s;
}

/// The same loop with the compiler told it may reorder floating-point arithmetic.
fn reorderAllowed(env: *Env, p: *anyopaque) anyerror!f64 {
    _ = env;
    @setFloatMode(.optimized);
    const in = of(p);
    var s: f32 = 0;
    for (in.x, in.y) |a, b| s += a * b;
    return s;
}

/// `chains` running sums of `lanes` products each, written out.
fn explicit(comptime lanes: comptime_int, comptime chains: comptime_int, comptime fuse: bool, x: []const f32, y: []const f32) f32 {
    const V = @Vector(lanes, f32);
    var acc: [chains]V = @splat(@splat(0));
    const step = lanes * chains;
    var i: usize = 0;
    while (i + step <= x.len) : (i += step) {
        inline for (0..chains) |c| {
            const a: V = x[i + c * lanes ..][0..lanes].*;
            const b: V = y[i + c * lanes ..][0..lanes].*;
            acc[c] = if (fuse) @mulAdd(V, a, b, acc[c]) else acc[c] + a * b;
        }
    }
    var total: V = acc[0];
    inline for (1..chains) |c| total += acc[c];
    var s: f32 = @reduce(.Add, total);
    while (i < x.len) : (i += 1) s += x[i] * y[i];
    return s;
}

fn Explicit(comptime lanes: comptime_int, comptime chains: comptime_int, comptime fuse: bool) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            _ = env;
            const in = of(p);
            return explicit(lanes, chains, fuse, in.x, in.y);
        }
    };
}

pub const job: harness.Job = .{
    .id = "V2",
    .group = "vectorisation",
    .title = "a loop with a running total: dot product",
    .unit = "values",
    .bytes_per_item = 2 * @sizeOf(f32),
    .sizes = &.{ 1_000, 100_000, 1_000_000 },
    .quick_sizes = &.{ 100, 10_000 },
    .tolerance = 1e-3,
    .source = @embedFile("v2_dot.zig"),
    .create = create,
    .destroy = destroy,
    .variants = &.{
        .{ .name = "plain", .what = "the plain loop", .run = plain },
        .{ .name = "reorder", .what = "the plain loop with @setFloatMode(.optimized)", .run = reorderAllowed },
        .{ .name = "lanes16", .what = "one running sum of 16, written out", .run = Explicit(16, 1, false).run },
        .{ .name = "lanes16x4", .what = "four running sums of 16", .run = Explicit(16, 4, false).run },
        .{ .name = "fused16x4", .what = "four running sums of 16, fused multiply-add", .run = Explicit(16, 4, true).run },
        .{ .name = "fused16x8", .what = "eight running sums of 16, fused multiply-add", .run = Explicit(16, 8, true).run },
        .{ .name = "portable", .what = "four running sums as wide as std.simd suggests, fused only if the build's CPU has the instruction", .run = Explicit(suggested, 4, fused_is_an_instruction).run },
    },
};

test "V2: every variant gives the reference answer" {
    try harness.expectVariantsAgree(&job, &.{ 0, 1, 15, 16, 17, 63, 64, 65, 127, 129, 1000, 5000 });
}

test "V2: totals of values where every order gives the same bits" {
    // Small whole numbers: every partial sum is exact, so all variants must agree exactly.
    var x: [203]f32 = undefined;
    var y: [203]f32 = undefined;
    var want: f32 = 0;
    for (&x, &y, 0..) |*a, *b, i| {
        a.* = @floatFromInt(i % 7);
        b.* = @floatFromInt(i % 5);
        want += a.* * b.*;
    }
    inline for (.{ .{ 16, 1, false }, .{ 16, 4, false }, .{ 16, 4, true }, .{ 16, 8, true }, .{ suggested, 4, fused_is_an_instruction }, .{ 4, 1, false } }) |c| {
        try std.testing.expectEqual(want, explicit(c[0], c[1], c[2], &x, &y));
    }
}
