// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Turns saved measurements into answers: for each job and size, the variant to use on one
//! thread and the variant to use with all threads. `look` prints them; `map` writes them all to
//! `map/<machine>.tsv`.

const std = @import("std");
const harness = @import("harness.zig");
const Job = harness.Job;
const Variant = harness.Variant;

pub const Entry = struct {
    variant: *const Variant,
    median_ns: f64,
    spread: f64,
};

/// A variant counts as tied with the fastest when it is within this fraction of it, or within
/// the two spreads added together, whichever is larger.
pub const tie_margin = 0.05;

fn tied(e: Entry, fastest: Entry) bool {
    const margin = @max(tie_margin, e.spread + fastest.spread);
    return e.median_ns <= fastest.median_ns * (1 + margin);
}

/// The entry to recommend: among those tied with the fastest, the one listed first in the job
/// (variants are listed plainest first, so a tie goes to the simpler code). Null when empty.
pub fn choose(entries: []const Entry) ?usize {
    if (entries.len == 0) return null;
    var fastest: usize = 0;
    for (entries, 0..) |e, i| {
        if (e.median_ns < entries[fastest].median_ns) fastest = i;
    }
    for (entries, 0..) |e, i| {
        if (tied(e, entries[fastest])) return i;
    }
    return fastest;
}

/// The fastest entry other than `skip`. Null when there is no other.
pub fn runnerUp(entries: []const Entry, skip: usize) ?usize {
    var best: ?usize = null;
    for (entries, 0..) |e, i| {
        if (i == skip) continue;
        if (best == null or e.median_ns < entries[best.?].median_ns) best = i;
    }
    return best;
}

pub const max_variants = 16;

pub const Answer = struct {
    n: usize,
    reference: ?Entry = null,
    /// Variants that use one thread, in job order, and the pick among them.
    one: [max_variants]Entry = undefined,
    one_len: usize = 0,
    /// Every CPU variant, in job order.
    all: [max_variants]Entry = undefined,
    all_len: usize = 0,
    /// Variants that run on the graphics card, in job order. They are reported one by one,
    /// because "data already on the card" and "with transfers" answer different questions.
    card: [max_variants]Entry = undefined,
    card_len: usize = 0,

    pub fn oneThread(a: *const Answer) []const Entry {
        return a.one[0..a.one_len];
    }

    pub fn onCard(a: *const Answer) []const Entry {
        return a.card[0..a.card_len];
    }

    pub fn everything(a: *const Answer) []const Entry {
        return a.all[0..a.all_len];
    }
};

/// Reads the current saved measurements of `job` at size `n`. Variants that are not measured,
/// or whose saved result is stale, are left out.
pub fn load(gpa: std.mem.Allocator, io: std.Io, machine: []const u8, job: *const Job, n: usize) !Answer {
    const the_stamp = harness.stamp(job, machine);
    var a: Answer = .{ .n = n };
    for (job.variants, 0..) |*v, i| {
        if (a.all_len == max_variants) break;
        const path = try harness.resultPath(gpa, machine, job, v, n);
        defer gpa.free(path);
        const saved = harness.readSaved(gpa, io, path, &the_stamp) orelse continue;
        const e: Entry = .{ .variant = v, .median_ns = saved.median_ns, .spread = saved.spread };
        if (i == 0) a.reference = e;
        if (v.gpu) {
            a.card[a.card_len] = e;
            a.card_len += 1;
            continue;
        }
        a.all[a.all_len] = e;
        a.all_len += 1;
        if (!v.threads) {
            a.one[a.one_len] = e;
            a.one_len += 1;
        }
    }
    return a;
}

pub fn rate(n: usize, median_ns: f64) f64 {
    return if (median_ns <= 0) 0 else @as(f64, @floatFromInt(n)) * 1e9 / median_ns;
}

/// "2.53 billion", "763 million", "41.2 thousand", "870".
fn writeRate(out: *std.Io.Writer, per_second: f64) !void {
    const Scale = struct { at: f64, word: []const u8 };
    for ([_]Scale{ .{ .at = 1e9, .word = " billion" }, .{ .at = 1e6, .word = " million" }, .{ .at = 1e3, .word = " thousand" } }) |s| {
        if (per_second >= s.at) {
            const x = per_second / s.at;
            if (x >= 100) try out.print("{d:.0}{s}", .{ x, s.word }) else if (x >= 10) try out.print("{d:.1}{s}", .{ x, s.word }) else try out.print("{d:.2}{s}", .{ x, s.word });
            return;
        }
    }
    try out.print("{d:.0}", .{per_second});
}

/// 20000000 -> "20,000,000".
fn writeCount(out: *std.Io.Writer, n: usize) !void {
    var buf: [32]u8 = undefined;
    var i: usize = buf.len;
    var left = n;
    var digits: usize = 0;
    while (true) {
        if (digits != 0 and digits % 3 == 0) {
            i -= 1;
            buf[i] = ',';
        }
        i -= 1;
        buf[i] = @intCast('0' + left % 10);
        left /= 10;
        digits += 1;
        if (left == 0) break;
    }
    try out.writeAll(buf[i..]);
}

fn writeLine(out: *std.Io.Writer, job: *const Job, a: *const Answer, label: []const u8, entries: []const Entry, pick: usize) !void {
    const e = entries[pick];
    try out.print("    {s:<12} {s:<11} ", .{ label, e.variant.name });
    try writeRate(out, rate(a.n, e.median_ns));
    try out.print(" {s}/s", .{job.unit});
    if (a.reference) |ref| {
        if (ref.variant != e.variant) try out.print(", {d:.1}x the plain way ({s})", .{ ref.median_ns / e.median_ns, ref.variant.name });
    }
    try out.print("\n{s:<17}{s}\n", .{ "", e.variant.what });
    if (runnerUp(entries, pick)) |r| {
        try out.print("{s:<17}next: {s}, ", .{ "", entries[r].variant.name });
        try writeRate(out, rate(a.n, entries[r].median_ns));
        try out.writeAll("/s\n");
    }
}

/// Prints the answer for one job at one size.
pub fn writeAnswer(out: *std.Io.Writer, job: *const Job, a: *const Answer) !void {
    try out.writeAll("  at ");
    try writeCount(out, a.n);
    try out.print(" {s}\n", .{job.unit});
    const one = a.oneThread();
    const all = a.everything();
    const pick_one = choose(one) orelse {
        try out.writeAll("    not measured yet: run this job first\n");
        return;
    };
    try writeLine(out, job, a, "one thread:", one, pick_one);
    const pick_all = choose(all).?; // `one` is not empty, so neither is `all`
    if (all[pick_all].variant == one[pick_one].variant) {
        if (all.len > one.len) try out.writeAll("    all threads: no gain over one thread at this size\n");
    } else {
        try writeLine(out, job, a, "all threads:", all, pick_all);
    }
    // Each GPU variant, with how it compares to the best CPU answer above.
    const best_cpu = all[pick_all].median_ns;
    for (a.onCard()) |e| {
        try out.print("    {s:<12} {s:<11} ", .{ "graphics:", e.variant.name });
        try writeRate(out, rate(a.n, e.median_ns));
        try out.print(" {s}/s, {d:.1}x the best CPU answer\n{s:<17}{s}\n", .{ job.unit, best_cpu / e.median_ns, "", e.variant.what });
    }
}

/// True when every word appears (ignoring case) in the job's id, title or group. No words
/// matches everything.
pub fn matches(job: *const Job, words: []const []const u8) bool {
    for (words) |w| {
        if (std.ascii.eqlIgnoreCase(job.id, w)) continue;
        if (std.ascii.findIgnoreCase(job.title, w) != null) continue;
        if (std.ascii.findIgnoreCase(job.group, w) != null) continue;
        return false;
    }
    return true;
}

/// The measured size closest to `want`, compared as ratios (1e6 is as far from 1e7 as from 1e5).
pub fn nearestSize(sizes: []const usize, want: usize) usize {
    var best = sizes[0];
    var best_distance = std.math.inf(f64);
    for (sizes) |s| {
        const ratio = (@as(f64, @floatFromInt(s)) + 1) / (@as(f64, @floatFromInt(want)) + 1);
        const distance = @abs(@log(ratio));
        if (distance < best_distance) {
            best_distance = distance;
            best = s;
        }
    }
    return best;
}

/// `look`: the answers for every job matching `words`, at every measured size or only the one
/// nearest `rows`. Returns how many jobs matched.
pub fn look(gpa: std.mem.Allocator, io: std.Io, machine: []const u8, jobs: []const *const Job, words: []const []const u8, rows: ?usize, out: *std.Io.Writer) !usize {
    var found: usize = 0;
    for (jobs) |job| {
        if (!matches(job, words)) continue;
        found += 1;
        try out.print("{s}  {s}\n", .{ job.id, job.title });
        if (rows) |want| {
            const a = try load(gpa, io, machine, job, nearestSize(job.sizes, want));
            try writeAnswer(out, job, &a);
        } else {
            for (job.sizes) |n| {
                const a = try load(gpa, io, machine, job, n);
                try writeAnswer(out, job, &a);
            }
        }
        try out.writeAll("\n");
    }
    return found;
}

pub const map_columns = "job\ttitle\tn\tunit\tthreads\tvariant\titems_per_s\tx_reference\tnext\tnext_items_per_s\twhat\n";

fn writeMapRow(out: *std.Io.Writer, job: *const Job, a: *const Answer, threads: []const u8, entries: []const Entry, pick: usize) !void {
    const e = entries[pick];
    const x = if (a.reference) |ref| ref.median_ns / e.median_ns else 0;
    try out.print("{s}\t{s}\t{d}\t{s}\t{s}\t{s}\t{e:.4}\t{d:.2}\t", .{ job.id, job.title, a.n, job.unit, threads, e.variant.name, rate(a.n, e.median_ns), x });
    if (runnerUp(entries, pick)) |r| {
        try out.print("{s}\t{e:.4}\t", .{ entries[r].variant.name, rate(a.n, entries[r].median_ns) });
    } else {
        try out.writeAll("\t\t");
    }
    try out.print("{s}\n", .{e.variant.what});
}

/// `map`: every answer as one table. Returns the number of rows written.
pub fn writeMap(gpa: std.mem.Allocator, io: std.Io, machine: []const u8, jobs: []const *const Job, out: *std.Io.Writer) !usize {
    var rows: usize = 0;
    try out.writeAll(map_columns);
    for (jobs) |job| {
        for (job.sizes) |n| {
            const a = try load(gpa, io, machine, job, n);
            const one = a.oneThread();
            const all = a.everything();
            const pick_one = choose(one) orelse continue;
            try writeMapRow(out, job, &a, "one", one, pick_one);
            rows += 1;
            const pick_all = choose(all).?; // `one` is not empty, so neither is `all`
            for (a.onCard(), 0..) |_, k| {
                try writeMapRow(out, job, &a, "gpu", a.onCard(), k);
                rows += 1;
            }
            if (all[pick_all].variant != one[pick_one].variant) {
                try writeMapRow(out, job, &a, "all", all, pick_all);
                rows += 1;
            }
        }
    }
    return rows;
}

const t = std.testing;

fn fake(name: []const u8, threads: bool) Variant {
    const none = struct {
        fn run(env: *harness.Env, input: *anyopaque) anyerror!f64 {
            _ = env;
            _ = input;
            return 0;
        }
    }.run;
    return .{ .name = name, .what = "", .run = none, .threads = threads };
}

test "choose: the fastest wins when it is clearly ahead" {
    const v = [_]Variant{ fake("plain", false), fake("fancy", false) };
    const entries = [_]Entry{
        .{ .variant = &v[0], .median_ns = 100, .spread = 0.01 },
        .{ .variant = &v[1], .median_ns = 50, .spread = 0.01 },
    };
    try t.expectEqual(@as(?usize, 1), choose(&entries));
    try t.expectEqual(@as(?usize, 0), runnerUp(&entries, 1));
}

test "choose: a tie goes to the variant listed first" {
    const v = [_]Variant{ fake("plain", false), fake("fancy", false), fake("fancier", false) };
    // 4% slower than the fastest: inside the 5% margin.
    var entries = [_]Entry{
        .{ .variant = &v[0], .median_ns = 104, .spread = 0 },
        .{ .variant = &v[1], .median_ns = 101, .spread = 0 },
        .{ .variant = &v[2], .median_ns = 100, .spread = 0 },
    };
    try t.expectEqual(@as(?usize, 0), choose(&entries));
    // 6% slower: outside the margin, so the next tied one (1% slower) is picked.
    entries[0].median_ns = 106;
    try t.expectEqual(@as(?usize, 1), choose(&entries));
    // A noisy measurement widens the margin: 6% is inside 4% + 3% of spread.
    entries[0].spread = 0.04;
    entries[2].spread = 0.03;
    try t.expectEqual(@as(?usize, 0), choose(&entries));
}

test "choose and runnerUp on empty and single lists" {
    const v = [_]Variant{fake("only", false)};
    const one = [_]Entry{.{ .variant = &v[0], .median_ns = 5, .spread = 0 }};
    try t.expectEqual(@as(?usize, null), choose(&.{}));
    try t.expectEqual(@as(?usize, 0), choose(&one));
    try t.expectEqual(@as(?usize, null), runnerUp(&one, 0));
}

test "matches: every word must be found; id matches exactly" {
    const job: Job = .{
        .id = "D4m",
        .group = "data processing",
        .title = "group by key and total, 100,000 groups",
        .unit = "rows",
        .bytes_per_item = 8,
        .sizes = &.{},
        .quick_sizes = &.{},
        .tolerance = 0,
        .source = "",
        .create = undefined,
        .destroy = undefined,
        .variants = &.{},
    };
    try t.expect(matches(&job, &.{}));
    try t.expect(matches(&job, &.{"d4m"}));
    try t.expect(matches(&job, &.{ "GROUP", "total" }));
    try t.expect(matches(&job, &.{ "data", "group" }));
    try t.expect(!matches(&job, &.{ "group", "sort" }));
    try t.expect(!matches(&job, &.{"d4"})); // an id must match whole, and "d4" is not in the title
}

test "nearestSize compares by ratio" {
    const sizes = [_]usize{ 10_000, 1_000_000, 100_000_000 };
    try t.expectEqual(@as(usize, 10_000), nearestSize(&sizes, 0));
    try t.expectEqual(@as(usize, 10_000), nearestSize(&sizes, 50_000));
    try t.expectEqual(@as(usize, 1_000_000), nearestSize(&sizes, 200_000));
    try t.expectEqual(@as(usize, 1_000_000), nearestSize(&sizes, 5_000_000));
    try t.expectEqual(@as(usize, 100_000_000), nearestSize(&sizes, 20_000_000));
    try t.expectEqual(@as(usize, 100_000_000), nearestSize(&sizes, std.math.maxInt(usize)));
}

test "writeRate and writeCount" {
    var buf: [64]u8 = undefined;
    const cases = [_]struct { x: f64, want: []const u8 }{
        .{ .x = 2.528e9, .want = "2.53 billion" },
        .{ .x = 7.63e8, .want = "763 million" },
        .{ .x = 4.12e4, .want = "41.2 thousand" },
        .{ .x = 870, .want = "870" },
    };
    for (cases) |c| {
        var w: std.Io.Writer = .fixed(&buf);
        try writeRate(&w, c.x);
        try t.expectEqualStrings(c.want, w.buffered());
    }
    for ([_]struct { n: usize, want: []const u8 }{ .{ .n = 0, .want = "0" }, .{ .n = 999, .want = "999" }, .{ .n = 1000, .want = "1,000" }, .{ .n = 20_000_000, .want = "20,000,000" } }) |c| {
        var w: std.Io.Writer = .fixed(&buf);
        try writeCount(&w, c.n);
        try t.expectEqualStrings(c.want, w.buffered());
    }
}
