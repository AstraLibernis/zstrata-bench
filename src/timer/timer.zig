// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! `zstrata-bench time`: times whole programs from outside, with hyperfine 2.0's options and
//! output, plus the process-tree memory hyperfine cannot read on Windows. See docs/TIMER.md.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const metric = @import("metric.zig");
const stats = @import("stats.zig");
const proc = @import("proc.zig");
const report = @import("report.zig");

const Metric = metric.Metric;

pub const help =
    \\usage: zstrata-bench time [options] <command>...
    \\
    \\Times whole programs, hyperfine-style. Each command runs directly (no shell) unless -S or
    \\--shell is given; quote a command that has spaces. Options take the same names as
    \\hyperfine 2.0; docs/TIMER.md lists every one and where this tool differs.
    \\
    \\Runs
    \\  -w, --warmup N           untimed runs first                             (default 0)
    \\  -m, --min-runs N         at least N timed runs                          (default 10)
    \\  -M, --max-runs N         at most N timed runs                           (default none)
    \\  -r, --runs N             exactly N timed runs
    \\                           Without -r: at least --min-runs and at least ~3 s of runs.
    \\What to measure
    \\  --metrics LIST           a preset (default, time, memory, all) or metric[:unit],...
    \\        time_wall_clock time_cpu time_user time_system                 ns us ms s min h
    \\        memory_peak_resident memory_peak_commit io_read_bytes io_write_bytes
    \\                                                       B kB MB GB TB KiB MiB GiB TiB
    \\        page_faults processes                                          count k M B
    \\        The first is the primary metric (tables, comparisons). JSON holds them all.
    \\Starting the command
    \\  -N                       no shell (default)
    \\  -S                       through the platform shell (cmd.exe here, sh elsewhere)
    \\  --shell SHELL            none, default, or a shell command line ("bash --norc")
    \\  --env 'A=1 B="x y"'      environment additions (once, or once per command)
    \\  --input null|FILE        stdin                                          (default null)
    \\  --output null|pipe|inherit|FILE   stdout+stderr (once, or once per command)
    \\  --show-output            same as --output inherit
    \\  -i, --ignore-failure[=all-non-zero|CODES]   keep runs with these exit codes
    \\Hooks (always through a shell; a failure stops everything)
    \\  -s, --setup CMD          once before each command's runs
    \\  -p, --prepare CMD        before every run (once, or once per command)
    \\  -C, --conclude CMD       after every run (once, or once per command)
    \\  -c, --cleanup CMD        once after each command's runs
    \\Parameters ({name} in commands, names, hooks and --env)
    \\  -P, --parameter-scan VAR MIN MAX      numbers, step 1 unless -D
    \\  -D, --parameter-step-size STEP
    \\  -L, --parameter-list VAR a,b,c        repeat for every combination
    \\Output
    \\  -n, --command-name NAME  a label per command, in order
    \\  --style auto|basic|full|nocolor|color|none   none prints nothing
    \\  --export-json FILE       every run, every metric (hyperfine's schema 2)
    \\  --export-csv FILE        summary of the selected metrics
    \\  --export-markdown|--export-asciidoc|--export-orgmode FILE   primary-metric table
    \\  -h, --help   -V, --version
    \\
;

/// Seconds of timed runs to aim for when the run count is automatic (hyperfine's default).
const min_benchmarking_time: f64 = 3.0;
const default_min_runs: u64 = 10;
/// Runs used to measure the shell's own start-up, which is then subtracted.
const shell_calibration_runs = 50;
/// Below this mean wall time, a shell's start-up dominates and the result is flagged.
const fast_shell_warning_s: f64 = 0.005;

const Ctx = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    base_env: *const std.process.Environ.Map,
    opts: *const cli.Options,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    quiet: bool,
    /// Shell start-up measured on this machine, subtracted from every run (shell mode only).
    overhead: metric.Sample = .{},
};

pub fn main(gpa: std.mem.Allocator, io: std.Io, base_env: *const std.process.Environ.Map, argv: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diag: cli.Diag = .{};
    const opts = cli.parse(arena, argv, &diag) catch |e| switch (e) {
        error.Usage => return usage(err, diag.msg),
        else => return e,
    };
    if (opts.help) {
        try out.writeAll(help);
        return 0;
    }
    if (opts.version) {
        try out.print("zstrata-bench time (hyperfine 2.0 options), built with Zig {s}\n", .{builtin.zig_version_string});
        return 0;
    }
    const benches = cli.expand(arena, &opts, &diag) catch |e| switch (e) {
        error.Usage => return usage(err, diag.msg),
        else => return e,
    };

    var ctx: Ctx = .{ .arena = arena, .io = io, .base_env = base_env, .opts = &opts, .out = out, .err = err, .quiet = opts.style == .none };
    const start_time: i64 = @intCast(std.math.clamp(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s), 0, std.math.maxInt(i64)));

    if (opts.shell != .none) ctx.overhead = calibrate(&ctx) catch |e| return failed(&ctx, e);

    const results = try arena.alloc(report.Result, benches.len);
    var units: report.Units = undefined;
    for (benches, 0..) |*b, bi| {
        results[bi] = runBench(&ctx, b) catch |e| return failed(&ctx, e);
        if (bi == 0) units = report.chooseUnits(&opts.metrics, &results[0]);
        if (!ctx.quiet) {
            try report.terminal(out, bi, &results[bi], if (bi == 0) null else &results[0], &opts.metrics, &units);
            try out.flush();
            try warnings(&ctx, &results[bi]);
            try out.writeAll(" \n");
            try out.flush();
        }
    }

    const ex = opts.exports;
    if (ex.json) |p| try writeExport(&ctx, p, .json, results, &units, start_time);
    if (ex.csv) |p| try writeExport(&ctx, p, .csv, results, &units, start_time);
    if (ex.markdown) |p| try writeExport(&ctx, p, .markdown, results, &units, start_time);
    if (ex.asciidoc) |p| try writeExport(&ctx, p, .asciidoc, results, &units, start_time);
    if (ex.orgmode) |p| try writeExport(&ctx, p, .orgmode, results, &units, start_time);
    return 0;
}

fn usage(err: *std.Io.Writer, msg: []const u8) !u8 {
    try err.print("error: {s}\n", .{msg});
    try err.flush();
    return 2;
}

/// Errors that stop the whole invocation; the message was already printed to stderr.
const Stop = error{ Stopped, OutOfMemory };

fn failed(ctx: *Ctx, e: Stop) !u8 {
    switch (e) {
        error.Stopped => {},
        error.OutOfMemory => try ctx.err.writeAll("error: out of memory\n"),
    }
    try ctx.err.flush();
    return 1;
}

fn stop(ctx: *Ctx, comptime fmt: []const u8, args: anytype) Stop {
    // A failing stderr leaves nothing better to report to; the caller still exits 1.
    ctx.err.print("error: " ++ fmt ++ "\n", args) catch {}; // zsnag:ok stderr is the last resort
    ctx.err.flush() catch {}; // zsnag:ok stderr is the last resort
    return error.Stopped;
}

/// The words a shell is started with before the command text.
fn shellPrefix(ctx: *Ctx, shell: cli.Shell) Stop![]const []const u8 {
    return switch (shell) {
        .none, .default => if (builtin.os.tag == .windows) &.{ "cmd.exe", "/C" } else &.{ "sh", "-c" },
        .custom => |words| blk: {
            const exe = std.Io.Dir.path.basename(words[0]);
            const is_cmd = std.ascii.eqlIgnoreCase(exe, "cmd") or std.ascii.eqlIgnoreCase(exe, "cmd.exe");
            const all = try ctx.arena.alloc([]const u8, words.len + 1);
            @memcpy(all[0..words.len], words);
            all[words.len] = if (is_cmd) "/C" else "-c";
            break :blk all;
        },
    };
}

fn withCommand(ctx: *Ctx, prefix: []const []const u8, command: []const u8) Stop![]const []const u8 {
    const all = try ctx.arena.alloc([]const u8, prefix.len + 1);
    @memcpy(all[0..prefix.len], prefix);
    all[prefix.len] = command;
    return all;
}

/// The argv a benchmarked command runs as.
fn commandArgv(ctx: *Ctx, command: []const u8) Stop![]const []const u8 {
    if (ctx.opts.shell == .none) {
        var diag: cli.Diag = .{};
        return cli.splitWords(ctx.arena, command, &diag) catch |e| switch (e) {
            error.Usage => stop(ctx, "{s}", .{diag.msg}),
            error.OutOfMemory => error.OutOfMemory,
        };
    }
    return withCommand(ctx, try shellPrefix(ctx, ctx.opts.shell), command);
}

/// The parent environment plus `assignments` ("A=1 B='x y'"), or null for no change.
fn environment(ctx: *Ctx, assignments: ?[]const u8) Stop!?*const std.process.Environ.Map {
    const text = assignments orelse return null;
    const map = try ctx.arena.create(std.process.Environ.Map);
    // The map uses the arena too, so it is freed with everything else; no deinit needed.
    map.* = try ctx.base_env.clone(ctx.arena);
    if (std.mem.trim(u8, text, " \t").len == 0) return map;
    var diag: cli.Diag = .{};
    const words = cli.splitWords(ctx.arena, text, &diag) catch |e| switch (e) {
        error.Usage => return stop(ctx, "--env: {s}", .{diag.msg}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    for (words) |w| {
        const eq = std.mem.findScalar(u8, w, '=') orelse return stop(ctx, "--env: '{s}' is not NAME=value", .{w});
        if (eq == 0 or std.mem.findScalar(u8, w[0..eq], 0) != null) return stop(ctx, "--env: '{s}' has no usable name", .{w});
        try map.put(w[0..eq], w[eq + 1 ..]);
    }
    return map;
}

fn runHook(ctx: *Ctx, what: []const u8, command: ?[]const u8, env: ?*const std.process.Environ.Map) Stop!f64 {
    const c = command orelse return 0;
    const argv = try withCommand(ctx, try shellPrefix(ctx, ctx.opts.shell), c);
    var code: ?i64 = null;
    var why: []const u8 = "";
    return proc.hook(ctx.io, argv, env, &code, &why) catch |e| switch (e) {
        error.HookFailed => if (code) |k|
            stop(ctx, "the {s} command '{s}' exited with code {d}", .{ what, c, k })
        else
            stop(ctx, "the {s} command '{s}' was killed", .{ what, c }),
        error.SpawnFailed => stop(ctx, "could not start the {s} command '{s}': {s}", .{ what, c, why }),
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn ignored(ctx: *Ctx, code: ?i64) bool {
    const c = code orelse return ctx.opts.ignore == .all;
    if (c == 0) return true;
    return switch (ctx.opts.ignore) {
        .none => false,
        .all => true,
        .codes => |list| std.mem.findScalar(i64, list, c) != null,
    };
}

/// One timed (or warm-up) run with its prepare and conclude. Returns the sample and the time the
/// two hooks took, which counts against the automatic time budget.
fn oneRun(ctx: *Ctx, b: *const cli.Bench, argv: []const []const u8, env: ?*const std.process.Environ.Map) Stop!struct { sample: metric.Sample, hooks_s: f64 } {
    const prep = try runHook(ctx, "prepare", b.prepare, env);
    var why: []const u8 = "";
    var s = proc.measure(ctx.io, .{ .argv = argv, .environ_map = env, .input = ctx.opts.input, .output = b.output }, &why) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InputFile => return stop(ctx, "cannot open --input file: {s}", .{why}),
        error.OutputFile => return stop(ctx, "cannot create --output file: {s}", .{why}),
        else => return stop(ctx, "could not start '{s}': {s}", .{ b.command, why }),
    };
    if (!ignored(ctx, s.exit_code)) {
        if (s.exit_code) |c|
            return stop(ctx, "command '{s}' exited with code {d}. Use -i/--ignore-failure to keep such runs, or --show-output to see what went wrong.", .{ b.command, c })
        else
            return stop(ctx, "command '{s}' was killed by a signal. Use -i to keep such runs.", .{b.command});
    }
    const conc = try runHook(ctx, "conclude", b.conclude, env);
    if (ctx.opts.shell != .none) {
        for ([_]Metric{ .time_wall_clock, .time_cpu, .time_user, .time_system }) |m| {
            s.values.set(m, @max(s.values.get(m) - ctx.overhead.values.get(m), 0));
        }
    }
    return .{ .sample = s, .hooks_s = prep + conc };
}

/// How many timed runs in total, given the first one.
fn runCount(o: *const cli.Options, first_s: f64) u64 {
    if (o.runs) |r| return r;
    const min = o.min_runs orelse default_min_runs;
    const in_budget: u64 = if (first_s <= 0) std.math.maxInt(u32) else @trunc(@min(min_benchmarking_time / first_s, std.math.maxInt(u32)));
    const want = @max(in_budget, min);
    return if (o.max_runs) |m| @min(want, m) else want;
}

fn runBench(ctx: *Ctx, b: *const cli.Bench) Stop!report.Result {
    const env = try environment(ctx, b.env);
    const argv = try commandArgv(ctx, b.command);
    _ = try runHook(ctx, "setup", b.setup, env);
    for (0..ctx.opts.warmup) |_| _ = try oneRun(ctx, b, argv, env);

    var samples: std.ArrayList(metric.Sample) = .empty;
    const first = try oneRun(ctx, b, argv, env);
    try samples.append(ctx.arena, first.sample);
    const total = runCount(ctx.opts, first.sample.values.get(.time_wall_clock) + first.hooks_s);
    while (samples.items.len < total) {
        const r = try oneRun(ctx, b, argv, env);
        try samples.append(ctx.arena, r.sample);
    }
    _ = try runHook(ctx, "cleanup", b.cleanup, env);

    var r: report.Result = .{ .bench = b.*, .samples = samples.items, .summaries = .initFill(null) };
    const xs = try ctx.arena.alloc(f64, samples.items.len);
    const scratch = try ctx.arena.alloc(f64, samples.items.len);
    for (std.enums.values(Metric)) |m| {
        if (!m.available()) continue;
        for (samples.items, xs) |s, *x| x.* = s.values.get(m);
        r.summaries.set(m, stats.summarize(xs, scratch));
    }
    return r;
}

fn warnings(ctx: *Ctx, r: *const report.Result) !void {
    const w = ctx.err;
    var any = false;
    for (r.samples) |s| if (s.exit_code == null or s.exit_code.? != 0) {
        any = true;
        try w.writeAll(" \n  Warning: some runs ended with a non-zero exit code (kept because of --ignore-failure).\n");
        break;
    };
    const primary = ctx.opts.metrics.primary().metric;
    if (r.samples.len >= 3) {
        const xs = try ctx.arena.alloc(f64, r.samples.len);
        const scratch = try ctx.arena.alloc(f64, r.samples.len);
        for (r.samples, xs) |s, *x| x.* = s.values.get(primary);
        if (stats.firstRunScore(xs, scratch) > stats.outlier_threshold) {
            if (!any) try w.writeAll(" \n");
            any = true;
            var buf: [64]u8 = undefined;
            const unit = metric.autoUnit(primary.kind(), xs[0]);
            try w.print("  Warning: the first run was far above the rest ({s} {s} {s}). Caches filling on the first run are the usual cause: use --warmup, or --prepare to clear them before every run.\n", .{ primary.label(), report.formatValue(&buf, xs[0], unit), unit.name });
        }
    }
    if (ctx.opts.shell != .none) {
        if (r.summaries.get(.time_wall_clock)) |s| if (s.mean < fast_shell_warning_s) {
            if (!any) try w.writeAll(" \n");
            try w.writeAll("  Warning: the command took under 5 ms, so the subtracted shell start-up dominates. Use -N to start it without a shell.\n");
        };
    }
    try w.flush();
}

/// Mean start-up cost of the shell running an empty command.
fn calibrate(ctx: *Ctx) Stop!metric.Sample {
    const argv = try withCommand(ctx, try shellPrefix(ctx, ctx.opts.shell), "");
    var sum: metric.Sample = .{};
    for (0..shell_calibration_runs) |_| {
        var why: []const u8 = "";
        const s = proc.measure(ctx.io, .{ .argv = argv, .environ_map = null, .input = .null, .output = .null }, &why) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return stop(ctx, "could not start the shell '{s}': {s}", .{ argv[0], why }),
        };
        for (std.enums.values(Metric)) |m| sum.values.set(m, sum.values.get(m) + s.values.get(m));
    }
    for (std.enums.values(Metric)) |m| sum.values.set(m, sum.values.get(m) / shell_calibration_runs);
    return sum;
}

const ExportKind = enum { json, csv, markdown, asciidoc, orgmode };

fn writeExport(ctx: *Ctx, path: []const u8, kind: ExportKind, results: []const report.Result, units: *const report.Units, start_time: i64) !void {
    var text: std.Io.Writer.Allocating = .init(ctx.arena);
    const w = &text.writer;
    switch (kind) {
        .json => try report.json(w, results, &ctx.opts.metrics, .{ .start_time = start_time }),
        .csv => try report.csv(w, results, &ctx.opts.metrics),
        .markdown => try report.table(w, .markdown, results, &ctx.opts.metrics, units),
        .asciidoc => try report.table(w, .asciidoc, results, &ctx.opts.metrics, units),
        .orgmode => try report.table(w, .orgmode, results, &ctx.opts.metrics, units),
    }
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = text.written() }) catch |e| {
        try ctx.err.print("error: could not write {s}: {s}\n", .{ path, @errorName(e) });
        try ctx.err.flush();
        return e;
    };
}

test {
    _ = @import("cli.zig");
    _ = @import("metric.zig");
    _ = @import("stats.zig");
    _ = @import("report.zig");
}

test "runCount" {
    var o: cli.Options = .{};
    try std.testing.expectEqual(@as(u64, 300), runCount(&o, 0.01));
    try std.testing.expectEqual(@as(u64, 10), runCount(&o, 2.0));
    o.max_runs = 50;
    try std.testing.expectEqual(@as(u64, 50), runCount(&o, 0.01));
    o.max_runs = null;
    o.min_runs = 20;
    try std.testing.expectEqual(@as(u64, 20), runCount(&o, 1.0));
    o.min_runs = null;
    o.runs = 1;
    try std.testing.expectEqual(@as(u64, 1), runCount(&o, 0.01));
}
