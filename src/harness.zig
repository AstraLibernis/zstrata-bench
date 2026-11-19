// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! What every job shares: the shape of a job and its variants, the timing loop, and results that
//! are saved one measurement at a time and skipped when nothing they depend on has changed.

const std = @import("std");
const builtin = @import("builtin");
pub const Pool = @import("pool").Pool;

pub const max_threads = 64;

/// Per-run state handed to every variant: allocator, clock, and one thread pool per thread
/// count, created on first use and kept for the whole run (threads are reused, never spawned
/// per measurement).
pub const Env = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    pools: [max_threads + 1]?*Pool = @splat(null),
    /// Tests set this to run every threaded variant on one fixed thread count.
    force_threads: u32 = 0,

    /// The pool with `threads` workers (the caller is one of them). Owned by `Env`.
    pub fn pool(env: *Env, threads: u32) !*Pool {
        const t = if (env.force_threads != 0) env.force_threads else threads;
        if (t == 0 or t > max_threads) return error.BadThreadCount;
        if (env.pools[t]) |p| return p;
        const p = try Pool.init(env.gpa, t);
        env.pools[t] = p;
        return p;
    }

    pub fn deinit(env: *Env) void {
        for (&env.pools) |*slot| {
            if (slot.*) |p| p.deinit();
            slot.* = null;
        }
    }
};

/// One way of doing the job. `run` returns the job's answer as one number, so that every
/// variant can be compared with the reference.
pub const Variant = struct {
    name: []const u8,
    /// The one choice this variant changes, in plain words.
    what: []const u8,
    run: *const fn (env: *Env, input: *anyopaque) anyerror!f64,
};

pub const Job = struct {
    id: []const u8,
    group: []const u8,
    title: []const u8,
    /// What a size counts ("values", "rows").
    unit: []const u8,
    bytes_per_item: usize,
    sizes: []const usize,
    quick_sizes: []const usize,
    /// Largest relative difference from the reference answer that still counts as equal.
    tolerance: f64,
    /// The job's own source text: part of the stamp, so editing a job re-measures it.
    source: []const u8,
    /// Builds the input for `n` items. The caller releases it with `destroy`.
    create: *const fn (gpa: std.mem.Allocator, n: usize) anyerror!*anyopaque,
    destroy: *const fn (gpa: std.mem.Allocator, input: *anyopaque) void,
    /// variants[0] is the reference.
    variants: []const Variant,

    pub fn variant(job: *const Job, name: []const u8) ?*const Variant {
        for (job.variants) |*v| if (std.mem.eql(u8, v.name, name)) return v;
        return null;
    }
};

pub fn agrees(got: f64, want: f64, tolerance: f64) bool {
    if (!std.math.isFinite(got) or !std.math.isFinite(want)) return false;
    return @abs(got - want) <= tolerance * @max(1.0, @abs(want));
}

pub fn nowNs(io: std.Io) u64 {
    return @intCast(@max(std.Io.Clock.awake.now(io).nanoseconds, 0));
}

pub const Measurement = struct {
    /// Time of one run of the variant, in nanoseconds (a fraction for very short runs).
    median_ns: f64,
    min_ns: f64,
    /// (third quartile - first quartile) / median over the timed runs; 0 for a single run.
    spread: f64,
    runs: u32,
    answer: f64,
};

pub const Effort = struct {
    min_runs: u32 = 5,
    max_runs: u32 = max_timed_runs,
    /// Keep repeating until this much time has been measured in total.
    budget_ns: u64 = 300 * std.time.ns_per_ms,

    pub const quick: Effort = .{ .min_runs = 1, .max_runs = 1, .budget_ns = 0 };
};

const max_timed_runs = 31;

/// One untimed run that must give `want`, then timed repeats.
pub fn measure(env: *Env, job: *const Job, v: *const Variant, input: *anyopaque, want: f64, effort: Effort) !Measurement {
    const first = try v.run(env, input);
    if (!agrees(first, want, job.tolerance)) return error.WrongAnswer;

    // The clock ticks in steps of about 100 ns here, so a short variant is called `calls` times
    // per timed sample: enough that one sample lasts about `sample_ns`.
    const probe0 = nowNs(env.io);
    std.mem.doNotOptimizeAway(try v.run(env, input));
    const probe = @max(nowNs(env.io) -| probe0, 1);
    const calls: u64 = if (probe >= sample_ns) 1 else @min(max_calls, (sample_ns + probe - 1) / probe);

    var times: [max_timed_runs]f64 = undefined;
    const limit = @min(effort.max_runs, max_timed_runs);
    var n: u32 = 0;
    var total: u64 = 0;
    while (n < limit and (n < effort.min_runs or total < effort.budget_ns)) : (n += 1) {
        const t0 = nowNs(env.io);
        for (0..calls) |_| std.mem.doNotOptimizeAway(try v.run(env, input));
        const elapsed = nowNs(env.io) -| t0;
        times[n] = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(calls));
        total += elapsed;
    }
    std.mem.sort(f64, times[0..n], {}, std.sort.asc(f64));
    const median = times[n / 2];
    return .{
        .median_ns = median,
        .min_ns = times[0],
        .spread = if (n < 4 or median == 0) 0 else (times[(3 * n) / 4] - times[n / 4]) / median,
        .runs = n,
        .answer = first,
    };
}

/// How long one timed sample should last, and the most calls it may take to get there.
const sample_ns = std.time.ns_per_ms;
const max_calls = 1 << 20;

/// A short name for this machine from what the compiler and the OS report: CPU model, logical
/// CPU count, operating system. Results are filed under it. Caller frees.
pub fn machineId(gpa: std.mem.Allocator) ![]u8 {
    const cpus = std.Thread.getCpuCount() catch 1;
    return gpa.print("{s}-{d}t-{s}", .{ builtin.cpu.model.name, cpus, @tagName(builtin.os.tag) });
}

/// Changes whenever a saved result could be out of date: the job's source, this file, the input
/// generators, the Zig
/// version or the machine. 16 hex digits.
pub fn stamp(job: *const Job, machine: []const u8) [16]u8 {
    var h = std.hash.Wyhash.init(0);
    h.update(job.source);
    h.update(@embedFile("harness.zig"));
    h.update(@embedFile("data.zig"));
    h.update(builtin.zig_version_string);
    h.update(machine);
    var value = h.final();
    var out: [16]u8 = undefined;
    var i: usize = out.len;
    while (i > 0) {
        i -= 1;
        out[i] = "0123456789abcdef"[@intCast(value & 15)];
        value >>= 4;
    }
    return out;
}

/// `results/<machine>/<job>/<variant>__<n>.tsv`. Caller frees.
pub fn resultPath(gpa: std.mem.Allocator, machine: []const u8, job: *const Job, v: *const Variant, n: usize) ![]u8 {
    return gpa.print("results/{s}/{s}/{s}__{d}.tsv", .{ machine, job.id, v.name, n });
}

pub const Saved = struct { median_ns: f64, spread: f64, runs: u32 };

/// The saved measurement at `path`, if there is one and it carries `want_stamp`.
pub fn readSaved(gpa: std.mem.Allocator, io: std.Io, path: []const u8, want_stamp: []const u8) ?Saved {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 16)) catch return null;
    defer gpa.free(text);
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    _ = lines.next() orelse return null; // header
    const row = lines.next() orelse return null;
    var fields = std.mem.splitScalar(u8, row, '\t');
    var col: usize = 0;
    var saved: Saved = .{ .median_ns = 0, .spread = 0, .runs = 0 };
    var stamp_ok = false;
    while (fields.next()) |f| : (col += 1) {
        switch (col) {
            3 => saved.median_ns = std.fmt.parseFloat(f64, f) catch return null,
            5 => saved.spread = std.fmt.parseFloat(f64, f) catch return null,
            6 => saved.runs = std.fmt.parseInt(u32, f, 10) catch return null,
            9 => stamp_ok = std.mem.eql(u8, f, want_stamp),
            else => {},
        }
    }
    return if (stamp_ok and saved.runs != 0) saved else null;
}

pub const columns = "job\tvariant\tn\tmedian_ns\tmin_ns\tspread\truns\titems_per_s\tanswer\tstamp\tzig\n";

/// Writes one measurement to its own file (creating the folders), replacing an older one.
pub fn save(gpa: std.mem.Allocator, io: std.Io, path: []const u8, job: *const Job, v: *const Variant, n: usize, m: Measurement, the_stamp: []const u8) !void {
    const rate = if (m.median_ns == 0) 0 else @as(f64, @floatFromInt(n)) * 1e9 / m.median_ns;
    const text = try gpa.print(columns ++ "{s}\t{s}\t{d}\t{d:.3}\t{d:.3}\t{d:.4}\t{d}\t{e:.4}\t{d}\t{s}\t{s}\n", .{
        job.id, v.name, n, m.median_ns, m.min_ns, m.spread, m.runs, rate, m.answer, the_stamp, builtin.zig_version_string,
    });
    defer gpa.free(text);
    if (std.Io.Dir.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

/// Test helper: every variant of `job` gives the reference answer at each size, with threaded
/// variants forced onto 1, 3 and 16 threads in turn.
pub fn expectVariantsAgree(job: *const Job, sizes: []const usize) !void {
    const gpa = std.testing.allocator;
    for ([_]u32{ 1, 3, 16 }) |threads| {
        var env: Env = .{ .gpa = gpa, .io = std.testing.io, .force_threads = threads };
        defer env.deinit();
        for (sizes) |n| {
            const input = try job.create(gpa, n);
            defer job.destroy(gpa, input);
            const want = try job.variants[0].run(&env, input);
            for (job.variants[1..]) |*v| {
                const got = try v.run(&env, input);
                if (!agrees(got, want, job.tolerance)) {
                    std.debug.print("{s} {s} n={d} threads={d}: got {d}, reference {d}\n", .{ job.id, v.name, n, threads, got, want });
                    return error.VariantDisagrees;
                }
            }
        }
    }
}

test "agrees" {
    try std.testing.expect(agrees(100.0, 100.0 + 5e-8, 1e-9));
    try std.testing.expect(!agrees(100.0, 100.0 + 5e-6, 1e-9));
    try std.testing.expect(agrees(0.0, 1e-10, 1e-9)); // absolute near zero
    try std.testing.expect(!agrees(std.math.nan(f64), 1.0, 1e-9));
    try std.testing.expect(!agrees(std.math.inf(f64), std.math.inf(f64), 1e-9));
}
