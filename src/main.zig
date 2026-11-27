// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! zstrata-bench: which way of writing a job uses this machine best, measured.
//! Commands are described in docs/GUIDE.md and in `usage` below.

const std = @import("std");
const harness = @import("harness.zig");
const jobs = @import("jobs.zig");
const map = @import("map.zig");
const timer = @import("timer/timer.zig");
const aligned = @import("aligned.zig");
const Job = harness.Job;
const Env = harness.Env;

const usage =
    \\usage: zstrata-bench <command>
    \\
    \\  run <job|group> [--quick] [--force] [--only v1,v2] [--size N]
    \\        measure a job (D1) or a whole group (D). Each measurement is saved as it finishes
    \\        and skipped next time unless its code, the Zig version or the machine changed.
    \\        --quick   tiny sizes, one timed run, nothing saved: checks the path in seconds
    \\        --force   measure again even if a current result is saved
    \\  look [words...] [--rows N]
    \\        the measured answer: which variant to use on one thread and with all threads,
    \\        for every job whose id, title or group contains all the words. --rows picks
    \\        the measured size nearest N. Example: look group total --rows 1e7
    \\  map               write every answer to map/<machine>.tsv
    \\  list              jobs, variants and what each variant changes
    \\  check             which measurements are saved, stale or missing
    \\  answer <job> <n>  the reference answer for n items (for the outside checks in verify/)
    \\  one <job> <variant> <n>
    \\                    build the input and run one variant once (for timing from outside)
    \\  time [options] <command>...
    \\                    time whole programs from outside, hyperfine-style, with process-tree
    \\                    memory on Windows (`time --help`, docs/TIMER.md)
    \\
;

const Options = struct {
    quick: bool = false,
    force: bool = false,
    only: ?[]const u8 = null,
    size: ?usize = null,
};

pub fn main(init: std.process.Init) !void {
    // Every block on a cache-line boundary (aligned.zig): glibc's malloc does not do that.
    // ZSB_PLAIN_ALLOC=1 turns it off, to measure what that costs.
    var aligning: aligned.Aligning = .{ .child = init.gpa };
    const gpa = if (init.environ_map.get("ZSB_PLAIN_ALLOC") != null) init.gpa else aligning.allocator();
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout.interface;

    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "time")) {
        var ebuf: [1024]u8 = undefined;
        var stderr = std.Io.File.stderr().writerStreaming(init.io, &ebuf);
        const tcode = timer.main(gpa, init.io, init.environ_map, argv[2..], out, &stderr.interface, @import("build_options").version) catch |err| blk: {
            try out.flush();
            try stderr.interface.print("error: {s}\n", .{@errorName(err)});
            break :blk 1;
        };
        try out.flush();
        try stderr.interface.flush();
        if (tcode != 0) std.process.exit(tcode);
        return;
    }

    const code = command(gpa, init.io, argv, out) catch |err| blk: {
        try out.flush();
        std.debug.print("error: {s}\n", .{@errorName(err)});
        break :blk 1;
    };
    try out.flush();
    if (code != 0) std.process.exit(code);
}

fn command(gpa: std.mem.Allocator, io: std.Io, argv: []const [:0]const u8, out: *std.Io.Writer) !u8 {
    if (argv.len < 2) {
        try out.writeAll(usage);
        return 2;
    }
    const cmd = argv[1];
    var env: Env = .{ .gpa = gpa, .io = io };
    defer env.deinit();
    const machine = try harness.machineId(gpa);
    defer gpa.free(machine);

    if (std.mem.eql(u8, cmd, "list")) {
        for (jobs.all) |job| {
            try out.print("{s}  {s} ({s}; sizes in {s})\n", .{ job.id, job.title, job.group, job.unit });
            for (job.variants) |v| try out.print("    {s:<12} {s}\n", .{ v.name, v.what });
        }
        return 0;
    }
    if (std.mem.eql(u8, cmd, "check")) return check(gpa, io, machine, out);
    if (std.mem.eql(u8, cmd, "map")) {
        const path = try gpa.print("map/{s}.tsv", .{machine});
        defer gpa.free(path);
        var text: std.Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        const rows = try map.writeMap(gpa, io, machine, &jobs.all, &text.writer);
        try std.Io.Dir.cwd().createDirPath(io, "map");
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text.written() });
        try out.print("wrote {s} ({d} answers)\n", .{ path, rows });
        return 0;
    }
    if (std.mem.eql(u8, cmd, "look")) {
        var words: [16][]const u8 = undefined;
        var n_words: usize = 0;
        var rows: ?usize = null;
        var i: usize = 2;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--rows") and i + 1 < argv.len) {
                i += 1;
                rows = try parseSize(argv[i]);
            } else if (n_words < words.len) {
                words[n_words] = argv[i];
                n_words += 1;
            }
        }
        try out.print("machine: {s}\n\n", .{machine});
        const found = try map.look(gpa, io, machine, &jobs.all, words[0..n_words], rows, out);
        if (found == 0) {
            try out.writeAll("no job matches those words (see `list`)\n");
            return 1;
        }
        return 0;
    }
    if (std.mem.eql(u8, cmd, "answer") and argv.len == 4) {
        const job = find(argv[2]) orelse return unknownJob(argv[2]);
        const n = try parseSize(argv[3]);
        const input = try job.create(gpa, n);
        defer job.destroy(gpa, input);
        try out.print("{d}\n", .{try job.variants[0].run(&env, input)});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "one") and argv.len == 5) {
        const job = find(argv[2]) orelse return unknownJob(argv[2]);
        const v = job.variant(argv[3]) orelse {
            std.debug.print("{s} has no variant '{s}' (see `list`)\n", .{ job.id, argv[3] });
            return 2;
        };
        const n = try parseSize(argv[4]);
        const input = try job.create(gpa, n);
        defer job.destroy(gpa, input);
        try out.print("{d}\n", .{try v.run(&env, input)});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "run") and argv.len >= 3) {
        var opts: Options = .{};
        var i: usize = 3;
        while (i < argv.len) : (i += 1) {
            const a = argv[i];
            if (std.mem.eql(u8, a, "--quick")) {
                opts.quick = true;
            } else if (std.mem.eql(u8, a, "--force")) {
                opts.force = true;
            } else if (std.mem.eql(u8, a, "--only") and i + 1 < argv.len) {
                i += 1;
                opts.only = argv[i];
            } else if (std.mem.eql(u8, a, "--size") and i + 1 < argv.len) {
                i += 1;
                opts.size = try parseSize(argv[i]);
            } else {
                std.debug.print("unknown option '{s}'\n\n{s}", .{ a, usage });
                return 2;
            }
        }
        var matched = false;
        var failed = false;
        for (jobs.all) |job| {
            if (!selected(job, argv[2])) continue;
            matched = true;
            if (!try runJob(&env, machine, job, opts, out)) failed = true;
        }
        if (!matched) return unknownJob(argv[2]);
        return if (failed) 1 else 0;
    }
    try out.writeAll(usage);
    return 2;
}

fn unknownJob(name: []const u8) u8 {
    std.debug.print("no job or group '{s}' (see `list`)\n", .{name});
    return 2;
}

fn find(id: []const u8) ?*const Job {
    for (jobs.all) |job| if (std.ascii.eqlIgnoreCase(job.id, id)) return job;
    return null;
}

/// A job is selected by its id ("D1") or by its group letter ("D").
fn selected(job: *const Job, sel: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(job.id, sel)) return true;
    return sel.len == 1 and std.ascii.toUpper(sel[0]) == std.ascii.toUpper(job.id[0]);
}

/// "1000000", "1e6" or "2.5e7".
fn parseSize(text: []const u8) !usize {
    if (std.fmt.parseInt(usize, text, 10)) |n| return n else |_| {}
    const f = try std.fmt.parseFloat(f64, text);
    if (!std.math.isFinite(f) or f < 0 or f > 1e12) return error.BadSize;
    return @trunc(f);
}

fn wanted(only: ?[]const u8, name: []const u8) bool {
    const list = only orelse return true;
    var it = std.mem.tokenizeScalar(u8, list, ',');
    while (it.next()) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn printRow(out: *std.Io.Writer, job: *const Job, name: []const u8, n: usize, median_ns: f64, spread: f64, runs: u32, note: []const u8) !void {
    const ms = median_ns / 1e6;
    const rate = if (median_ns == 0) 0 else @as(f64, @floatFromInt(n)) * 1e9 / median_ns;
    const gb = rate * @as(f64, @floatFromInt(job.bytes_per_item)) / 1e9;
    try out.print("{s:<4} {d:>11} {s:<12} {d:>11.4} ms {e:>10.3} {s}/s {d:>7.2} GB/s  spread {d:>5.1}%  {d:>2} runs  {s}\n", .{
        job.id, n, name, ms, rate, job.unit, gb, spread * 100, runs, note,
    });
    try out.flush();
}

/// Measures every wanted variant of `job` at every size. Returns false if any variant failed;
/// the others are still measured and saved.
fn runJob(env: *Env, machine: []const u8, job: *const Job, opts: Options, out: *std.Io.Writer) !bool {
    const gpa = env.gpa;
    const the_stamp = harness.stamp(job, machine);
    const sizes: []const usize = if (opts.size) |s| &.{s} else if (opts.quick) job.quick_sizes else job.sizes;
    var ok = true;
    for (sizes) |n| {
        // Build the input only if something at this size still needs measuring.
        var input: ?*anyopaque = null;
        defer if (input) |p| job.destroy(gpa, p);
        var want: f64 = 0;
        for (job.variants) |*v| {
            if (!wanted(opts.only, v.name)) continue;
            const path = try harness.resultPath(gpa, machine, job, v, n);
            defer gpa.free(path);
            if (!opts.quick and !opts.force) {
                if (harness.readSaved(gpa, env.io, path, &the_stamp)) |s| {
                    try printRow(out, job, v.name, n, s.median_ns, s.spread, s.runs, "saved");
                    continue;
                }
            }
            if (input == null) {
                input = try job.create(gpa, n);
                want = try job.variants[0].run(env, input.?);
            }
            const m = harness.measure(env, job, v, input.?, want, if (opts.quick) .quick else .{}) catch |err| {
                try out.print("{s:<4} {d:>11} {s:<12} FAILED: {s}\n", .{ job.id, n, v.name, @errorName(err) });
                try out.flush();
                ok = false;
                continue;
            };
            if (!opts.quick) try harness.save(gpa, env.io, path, job, v, n, m, &the_stamp);
            try printRow(out, job, v.name, n, m.median_ns, m.spread, m.runs, if (opts.quick) "quick, not saved" else "");
        }
    }
    return ok;
}

fn check(gpa: std.mem.Allocator, io: std.Io, machine: []const u8, out: *std.Io.Writer) !u8 {
    var missing: usize = 0;
    try out.print("machine: {s}\n", .{machine});
    for (jobs.all) |job| {
        const the_stamp = harness.stamp(job, machine);
        var saved: usize = 0;
        var total: usize = 0;
        for (job.sizes) |n| {
            for (job.variants) |*v| {
                total += 1;
                const path = try harness.resultPath(gpa, machine, job, v, n);
                defer gpa.free(path);
                if (harness.readSaved(gpa, io, path, &the_stamp) != null) saved += 1;
            }
        }
        missing += total - saved;
        try out.print("{s}  {d} of {d} measurements current\n", .{ job.id, saved, total });
    }
    return if (missing == 0) 0 else 1;
}

test {
    _ = @import("harness.zig");
    _ = @import("data.zig");
    _ = @import("jobs.zig");
    _ = @import("map.zig");
    _ = @import("timer/timer.zig");
    _ = aligned;
}

test "parseSize" {
    try std.testing.expectEqual(@as(usize, 1000000), try parseSize("1e6"));
    try std.testing.expectEqual(@as(usize, 25000000), try parseSize("2.5e7"));
    try std.testing.expectEqual(@as(usize, 42), try parseSize("42"));
    try std.testing.expectError(error.BadSize, parseSize("-1"));
    try std.testing.expectError(error.BadSize, parseSize("1e30"));
}

test "selected and wanted" {
    const job = jobs.all[0];
    try std.testing.expect(selected(job, "d1") and selected(job, "D") and !selected(job, "S") and !selected(job, "D2"));
    try std.testing.expect(wanted(null, "x") and wanted("a,b", "b") and !wanted("a,b", "c"));
}
