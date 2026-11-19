// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! D6: split delimited text into fields.
//!
//! Input: `n` bytes of comma-separated numbers, eight fields per line. Field k (counting from 0
//! through the whole text) has 1 + data.mix(k) % 8 digits; its digit j is
//! '0' + data.mix(16 k + j + 2^28) % 10; it is followed by a newline when k % 8 is 7 and by a
//! comma otherwise. The text is cut off at exactly `n` bytes.
//! Output: the position of every comma and newline, in order.
//! Answer (for comparing variants): how many there are, plus the first, middle and last position.
//! Outside check: verify/data_jobs.py (NumPy works the positions out from the field lengths
//! without building the text).

const std = @import("std");
const harness = @import("../../harness.zig");
const data = @import("../../data.zig");
const Env = harness.Env;

const lanes = 64;
const Bytes = @Vector(lanes, u8);

/// Threaded variants scan the text in blocks of this many bytes. A block writes the positions
/// it finds into the part of the output that lines up with its own bytes, so the output stays
/// in order as a list of per-block runs and no two workers share memory.
const block = 1 << 16;

/// One count per cache line: two workers never write the same line.
const Count = struct { n: usize align(std.atomic.cache_line) = 0 };

const Input = struct {
    text: []u8,
    pos: []u32,
    counts: []Count,
};

fn of(p: *anyopaque) *Input {
    return @ptrCast(@alignCast(p));
}

fn create(gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque {
    if (n > std.math.maxInt(u32)) return error.TextTooLong;
    const in = try gpa.create(Input);
    errdefer gpa.destroy(in);
    const text = try gpa.alloc(u8, n);
    errdefer gpa.free(text);
    const pos = try gpa.alloc(u32, n);
    errdefer gpa.free(pos);
    const counts = try gpa.alloc(Count, (n + block - 1) / block);
    var at: usize = 0;
    var k: u32 = 0;
    fill: while (true) : (k +%= 1) {
        const digits = 1 + data.mix(k) % 8;
        for (0..digits) |j| {
            if (at == n) break :fill;
            text[at] = @intCast('0' + data.mix(k *% 16 +% @as(u32, @intCast(j)) +% (1 << 28)) % 10);
            at += 1;
        }
        if (at == n) break;
        text[at] = if (k % 8 == 7) '\n' else ',';
        at += 1;
    }
    in.* = .{ .text = text, .pos = pos, .counts = counts };
    return in;
}

fn destroy(gpa: std.mem.Allocator, p: *anyopaque) void {
    const in = of(p);
    gpa.free(in.counts);
    gpa.free(in.pos);
    gpa.free(in.text);
    gpa.destroy(in);
}

fn answerOf(pos: []const u32) f64 {
    var a: f64 = @floatFromInt(pos.len);
    if (pos.len == 0) return a;
    a += @floatFromInt(pos[0]);
    a += @floatFromInt(pos[pos.len / 2]);
    a += @floatFromInt(pos[pos.len - 1]);
    return a;
}

fn isDelimiter(c: u8) bool {
    return c == ',' or c == '\n';
}

// Every kernel scans `text`, which starts at byte `base` of the whole input, writes the
// positions (in the whole input) of its delimiters to `out` and returns how many there were.
// `out.len` is at least `text.len`.

/// The reference: test each byte, record its position if it is a delimiter.
fn branch(text: []const u8, base: usize, out: []u32) usize {
    var k: usize = 0;
    for (text, base..) |c, i| {
        if (isDelimiter(c)) {
            out[k] = @intCast(i);
            k += 1;
        }
    }
    return k;
}

/// Always record, and move on only when the byte was a delimiter.
fn branchFree(text: []const u8, base: usize, out: []u32) usize {
    var k: usize = 0;
    for (text, base..) |c, i| {
        out[k] = @intCast(i);
        k += @intFromBool(isDelimiter(c));
    }
    return k;
}

/// std's search for the next byte that is any of a set.
fn stdFind(text: []const u8, base: usize, out: []u32) usize {
    var k: usize = 0;
    var at: usize = 0;
    while (std.mem.findAnyPos(u8, text, at, ",\n")) |i| {
        out[k] = @intCast(base + i);
        k += 1;
        at = i + 1;
    }
    return k;
}

/// Compare 64 bytes at once into a 64-bit mask, then record the set bits.
fn mask64(text: []const u8, base: usize, out: []u32) usize {
    const comma: Bytes = @splat(',');
    const newline: Bytes = @splat('\n');
    var k: usize = 0;
    var i: usize = 0;
    while (i + lanes <= text.len) : (i += lanes) {
        const v: Bytes = text[i..][0..lanes].*;
        var mask = @as(u64, @bitCast(v == comma)) | @as(u64, @bitCast(v == newline));
        while (mask != 0) : (mask &= mask - 1) {
            out[k] = @intCast(base + i + @ctz(mask));
            k += 1;
        }
    }
    return k + branch(text[i..], base + i, out[k..]);
}

const Kernel = fn ([]const u8, usize, []u32) usize;

fn Serial(comptime kernel: Kernel) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            _ = env;
            const in = of(p);
            return answerOf(in.pos[0..kernel(in.text, 0, in.pos)]);
        }
    };
}

/// Pool task over block indices [begin, end).
fn scanBlocks(ctx: *anyopaque, worker: usize, begin: usize, end: usize) void {
    _ = worker;
    const in = of(ctx);
    for (begin..end) |b| {
        const lo = b * block;
        const hi = @min(lo + block, in.text.len);
        in.counts[b].n = mask64(in.text[lo..hi], lo, in.pos[lo..hi]);
    }
}

/// Delimiter number `index` (counting from 0 across all blocks, in order).
fn blockItem(in: *const Input, index: usize) u32 {
    var left = index;
    for (in.counts, 0..) |c, b| {
        if (left < c.n) return in.pos[b * block + left];
        left -= c.n;
    }
    unreachable; // callers pass index < total
}

fn Threads(comptime count: u32) type {
    return struct {
        fn run(env: *Env, p: *anyopaque) anyerror!f64 {
            const in = of(p);
            const pool = try env.pool(count);
            pool.parallelFor(in.counts.len, in, scanBlocks, 1);
            var total: usize = 0;
            for (in.counts) |c| total += c.n;
            var a: f64 = @floatFromInt(total);
            if (total == 0) return a;
            a += @floatFromInt(blockItem(in, 0));
            a += @floatFromInt(blockItem(in, total / 2));
            a += @floatFromInt(blockItem(in, total - 1));
            return a;
        }
    };
}

pub const job: harness.Job = .{
    .id = "D6",
    .group = "data processing",
    .title = "split delimited text: find every comma and newline",
    .unit = "bytes",
    .bytes_per_item = 1,
    .sizes = &.{ 10_000, 1_000_000, 100_000_000 },
    .quick_sizes = &.{ 1_000, 200_000 },
    .tolerance = 0,
    .source = @embedFile("d6_split.zig"),
    .create = create,
    .destroy = destroy,
    .variants = &.{
        .{ .name = "branch", .what = "test each byte, record its position if it is a delimiter", .run = Serial(branch).run },
        .{ .name = "branchfree", .what = "always record, move on only for a delimiter", .run = Serial(branchFree).run },
        .{ .name = "std", .what = "std.mem.findAnyPos for each next delimiter", .run = Serial(stdFind).run },
        .{ .name = "mask64", .what = "compare 64 bytes at a time, record the set bits", .run = Serial(mask64).run },
        .{ .name = "threads8", .what = "mask64 on 8 threads, positions left in per-block runs", .run = Threads(8).run, .threads = true },
        .{ .name = "threads16", .what = "mask64 on 16 threads, positions left in per-block runs", .run = Threads(16).run, .threads = true },
    },
};

const edge_sizes = [_]usize{ 0, 1, 2, 63, 64, 65, 127, 128, 129, 1000, block - 1, block, block + 1, 2 * block + 7 };

test "D6: every variant gives the reference answer" {
    try harness.expectVariantsAgree(&job, &edge_sizes);
}

test "D6: every kernel finds exactly the same positions, and the text is well formed" {
    const gpa = std.testing.allocator;
    for (edge_sizes) |n| {
        const p = try create(gpa, n);
        defer destroy(gpa, p);
        const in = of(p);
        // Only digits, commas and newlines; never two delimiters in a row; eight fields a line.
        var fields_on_line: usize = 0;
        for (in.text, 0..) |c, i| {
            try std.testing.expect(std.ascii.isDigit(c) or isDelimiter(c));
            if (isDelimiter(c)) {
                try std.testing.expect(i > 0 and !isDelimiter(in.text[i - 1]));
                fields_on_line += 1;
                if (c == '\n') {
                    try std.testing.expectEqual(@as(usize, 8), fields_on_line);
                    fields_on_line = 0;
                }
            }
        }
        const want = try gpa.alloc(u32, n);
        defer gpa.free(want);
        const k = branch(in.text, 0, want);
        var plain: usize = 0;
        for (in.text) |c| plain += @intFromBool(isDelimiter(c));
        try std.testing.expectEqual(plain, k);
        inline for (.{ branchFree, stdFind, mask64 }) |kernel| {
            @memset(in.pos, 0xFFFF_FFFF);
            try std.testing.expectEqual(k, kernel(in.text, 0, in.pos));
            try std.testing.expectEqualSlices(u32, want[0..k], in.pos[0..k]);
        }
        // A kernel given the middle of the text reports positions in the whole text.
        if (n > 200) {
            const from = 100;
            const kk = mask64(in.text[from..], from, in.pos);
            const first = std.mem.findScalar(u32, want[0..k], in.pos[0]).?;
            try std.testing.expectEqualSlices(u32, want[first..k], in.pos[0..kk]);
            try std.testing.expect(in.pos[0] >= from);
        }
    }
}

test "D6: the block runs of the threaded variant join into the reference output" {
    const gpa = std.testing.allocator;
    const n = 3 * block + 123;
    var env: harness.Env = .{ .gpa = gpa, .io = std.testing.io, .force_threads = 3 };
    defer env.deinit();
    const p = try create(gpa, n);
    defer destroy(gpa, p);
    const in = of(p);
    const want = try gpa.alloc(u32, n);
    defer gpa.free(want);
    const k = branch(in.text, 0, want);
    _ = try Threads(3).run(&env, p);
    var total: usize = 0;
    for (in.counts) |c| total += c.n;
    try std.testing.expectEqual(k, total);
    for (0..k) |i| try std.testing.expectEqual(want[i], blockItem(in, i));
}
