// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! `time` options (hyperfine 2.0's set, see docs/TIMER.md) and their expansion into one
//! benchmark per command and parameter combination. Everything is allocated in the caller's
//! arena: parsing happens once per process, so nothing here is freed on its own.

const std = @import("std");
const metric = @import("metric.zig");

pub const Shell = union(enum) {
    /// Start the program directly (hyperfine's -N; the default).
    none,
    /// cmd.exe on Windows, sh elsewhere.
    default,
    /// A shell command line such as "bash --norc", split into words.
    custom: []const []const u8,
};

pub const Stream = union(enum) { null, pipe, inherit, file: []const u8 };
pub const Input = union(enum) { null, file: []const u8 };
pub const IgnoreFailure = union(enum) { none, all, codes: []const i64 };
pub const Style = enum { auto, basic, full, nocolor, color, none };

pub const Param = struct { name: []const u8, values: []const []const u8 };
pub const Pair = struct { name: []const u8, value: []const u8 };

pub const Exports = struct {
    json: ?[]const u8 = null,
    csv: ?[]const u8 = null,
    markdown: ?[]const u8 = null,
    asciidoc: ?[]const u8 = null,
    orgmode: ?[]const u8 = null,
};

pub const Options = struct {
    commands: []const []const u8 = &.{},
    names: []const []const u8 = &.{},
    metrics: metric.Selected = .{},
    warmup: u64 = 0,
    min_runs: ?u64 = null,
    max_runs: ?u64 = null,
    runs: ?u64 = null,
    /// Each: zero entries, one for every command, or one per command in order.
    env: []const []const u8 = &.{},
    prepare: []const []const u8 = &.{},
    conclude: []const []const u8 = &.{},
    output: []const Stream = &.{},
    setup: ?[]const u8 = null,
    cleanup: ?[]const u8 = null,
    params: []const Param = &.{},
    shell: Shell = .none,
    ignore: IgnoreFailure = .none,
    style: Style = .auto,
    input: Input = .null,
    exports: Exports = .{},
    help: bool = false,
    version: bool = false,
};

/// One command with one parameter combination, everything substituted.
pub const Bench = struct {
    command: []const u8,
    /// The command, or its --command-name, shown in reports.
    label: []const u8,
    /// The --command-name as given (substituted), for the JSON `name` field.
    name: ?[]const u8,
    params: []const Pair,
    env: ?[]const u8,
    prepare: ?[]const u8,
    conclude: ?[]const u8,
    setup: ?[]const u8,
    cleanup: ?[]const u8,
    output: Stream,
};

/// What went wrong, for the user. Set whenever `parse` or `expand` return error.Usage.
pub const Diag = struct { msg: []const u8 = "" };

pub const Error = error{ Usage, OutOfMemory };

const Valued = enum {
    metrics,
    warmup,
    min_runs,
    max_runs,
    runs,
    env,
    setup,
    prepare,
    conclude,
    cleanup,
    parameter_step_size,
    shell,
    style,
    export_asciidoc,
    export_csv,
    export_json,
    export_markdown,
    export_orgmode,
    output,
    input,
    command_name,
};

const valued = [_]struct { long: []const u8, short: ?u8, opt: Valued }{
    .{ .long = "metrics", .short = null, .opt = .metrics },
    .{ .long = "warmup", .short = 'w', .opt = .warmup },
    .{ .long = "min-runs", .short = 'm', .opt = .min_runs },
    .{ .long = "max-runs", .short = 'M', .opt = .max_runs },
    .{ .long = "runs", .short = 'r', .opt = .runs },
    .{ .long = "env", .short = null, .opt = .env },
    .{ .long = "setup", .short = 's', .opt = .setup },
    .{ .long = "prepare", .short = 'p', .opt = .prepare },
    .{ .long = "conclude", .short = 'C', .opt = .conclude },
    .{ .long = "cleanup", .short = 'c', .opt = .cleanup },
    .{ .long = "parameter-step-size", .short = 'D', .opt = .parameter_step_size },
    .{ .long = "shell", .short = null, .opt = .shell },
    .{ .long = "style", .short = null, .opt = .style },
    .{ .long = "export-asciidoc", .short = null, .opt = .export_asciidoc },
    .{ .long = "export-csv", .short = null, .opt = .export_csv },
    .{ .long = "export-json", .short = null, .opt = .export_json },
    .{ .long = "export-markdown", .short = null, .opt = .export_markdown },
    .{ .long = "export-orgmode", .short = null, .opt = .export_orgmode },
    .{ .long = "output", .short = null, .opt = .output },
    .{ .long = "input", .short = null, .opt = .input },
    .{ .long = "command-name", .short = 'n', .opt = .command_name },
};

/// Matches `a` against a valued option: "--long", "--long=v", "-x", "-xv". Returns the option
/// and its inline value if any.
fn matchValued(a: []const u8) ?struct { opt: Valued, inline_value: ?[]const u8 } {
    if (std.mem.startsWith(u8, a, "--")) {
        const body = a[2..];
        const eq = std.mem.findScalar(u8, body, '=');
        const key = if (eq) |e| body[0..e] else body;
        for (valued) |v| if (std.mem.eql(u8, key, v.long)) {
            return .{ .opt = v.opt, .inline_value = if (eq) |e| body[e + 1 ..] else null };
        };
        return null;
    }
    if (a.len >= 2 and a[0] == '-') {
        for (valued) |v| if (v.short) |s| if (a[1] == s) {
            return .{ .opt = v.opt, .inline_value = if (a.len > 2) a[2..] else null };
        };
    }
    return null;
}

fn fail(arena: std.mem.Allocator, diag: *Diag, comptime fmt: []const u8, args: anytype) Error {
    diag.msg = try arena.print(fmt, args);
    return error.Usage;
}

fn parseCount(arena: std.mem.Allocator, diag: *Diag, what: []const u8, text: []const u8) Error!u64 {
    return std.fmt.parseInt(u64, text, 10) catch fail(arena, diag, "{s} needs a whole number, got '{s}'", .{ what, text });
}

pub fn parse(arena: std.mem.Allocator, argv: []const []const u8, diag: *Diag) Error!Options {
    var o: Options = .{};
    var commands: std.ArrayList([]const u8) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var env: std.ArrayList([]const u8) = .empty;
    var prepare: std.ArrayList([]const u8) = .empty;
    var conclude: std.ArrayList([]const u8) = .empty;
    var output: std.ArrayList(Stream) = .empty;
    var params: std.ArrayList(Param) = .empty;
    var scan: ?[3][]const u8 = null;
    // Parameters combine in the order given (the last changes fastest), -P included.
    var scan_at: usize = 0;
    var step: ?[]const u8 = null;
    var metrics_text: []const u8 = "default";

    var i: usize = 0;
    var only_commands = false;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (only_commands or a.len < 2 or a[0] != '-') {
            try commands.append(arena, a);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_commands = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            o.help = true;
        } else if (std.mem.eql(u8, a, "-V") or std.mem.eql(u8, a, "--version")) {
            o.version = true;
        } else if (std.mem.eql(u8, a, "-N")) {
            o.shell = .none;
        } else if (std.mem.eql(u8, a, "-S")) {
            o.shell = .default;
        } else if (std.mem.eql(u8, a, "--show-output")) {
            try output.append(arena, .inherit);
        } else if (std.mem.eql(u8, a, "-i") or std.mem.eql(u8, a, "--ignore-failure")) {
            o.ignore = .all;
        } else if (std.mem.startsWith(u8, a, "--ignore-failure=") or std.mem.startsWith(u8, a, "-i=")) {
            const v = a[std.mem.findScalar(u8, a, '=').? + 1 ..];
            if (std.mem.eql(u8, v, "all-non-zero")) {
                o.ignore = .all;
            } else {
                var codes: std.ArrayList(i64) = .empty;
                var it = std.mem.tokenizeScalar(u8, v, ',');
                while (it.next()) |c| {
                    try codes.append(arena, std.fmt.parseInt(i64, c, 10) catch
                        return fail(arena, diag, "--ignore-failure takes all-non-zero or exit codes like 1,2; got '{s}'", .{c}));
                }
                if (codes.items.len == 0) return fail(arena, diag, "--ignore-failure= needs a value", .{});
                o.ignore = .{ .codes = codes.items };
            }
        } else if (std.mem.eql(u8, a, "-P") or std.mem.eql(u8, a, "--parameter-scan")) {
            if (i + 3 >= argv.len) return fail(arena, diag, "{s} needs VAR MIN MAX", .{a});
            if (scan != null) return fail(arena, diag, "--parameter-scan can be given once", .{});
            scan = .{ argv[i + 1], argv[i + 2], argv[i + 3] };
            scan_at = params.items.len;
            i += 3;
        } else if (std.mem.eql(u8, a, "-L") or std.mem.eql(u8, a, "--parameter-list")) {
            if (i + 2 >= argv.len) return fail(arena, diag, "{s} needs VAR VALUES", .{a});
            var values: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, argv[i + 2], ',');
            while (it.next()) |v| try values.append(arena, v);
            try params.append(arena, .{ .name = argv[i + 1], .values = values.items });
            i += 2;
        } else if (matchValued(a)) |m| {
            const value = m.inline_value orelse blk: {
                if (i + 1 >= argv.len) return fail(arena, diag, "{s} needs a value", .{a});
                i += 1;
                break :blk argv[i];
            };
            switch (m.opt) {
                .metrics => metrics_text = value,
                .warmup => o.warmup = try parseCount(arena, diag, "--warmup", value),
                .min_runs => o.min_runs = try parseCount(arena, diag, "--min-runs", value),
                .max_runs => o.max_runs = try parseCount(arena, diag, "--max-runs", value),
                .runs => o.runs = try parseCount(arena, diag, "--runs", value),
                .env => try env.append(arena, value),
                .setup => o.setup = value,
                .prepare => try prepare.append(arena, value),
                .conclude => try conclude.append(arena, value),
                .cleanup => o.cleanup = value,
                .parameter_step_size => step = value,
                .shell => o.shell = if (std.mem.eql(u8, value, "none"))
                    .none
                else if (std.mem.eql(u8, value, "default"))
                    .default
                else
                    .{ .custom = try splitWords(arena, value, diag) },
                .style => o.style = std.meta.stringToEnum(Style, value) orelse
                    return fail(arena, diag, "--style takes auto, basic, full, nocolor, color or none; got '{s}'", .{value}),
                .export_asciidoc => o.exports.asciidoc = value,
                .export_csv => o.exports.csv = value,
                .export_json => o.exports.json = value,
                .export_markdown => o.exports.markdown = value,
                .export_orgmode => o.exports.orgmode = value,
                .output => try output.append(arena, if (std.mem.eql(u8, value, "null"))
                    .null
                else if (std.mem.eql(u8, value, "pipe"))
                    .pipe
                else if (std.mem.eql(u8, value, "inherit"))
                    .inherit
                else
                    .{ .file = value }),
                .input => o.input = if (std.mem.eql(u8, value, "null")) .null else .{ .file = value },
                .command_name => try names.append(arena, value),
            }
        } else {
            return fail(arena, diag, "unknown option '{s}' (see `time --help`)", .{a});
        }
    }
    if (o.help or o.version) return o;

    if (commands.items.len == 0) return fail(arena, diag, "no command to time (see `time --help`)", .{});
    const n = commands.items.len;
    if (names.items.len > n) return fail(arena, diag, "{d} --command-name for {d} commands", .{ names.items.len, n });
    inline for (.{ .{ "--env", env.items.len }, .{ "--prepare", prepare.items.len }, .{ "--conclude", conclude.items.len }, .{ "--output", output.items.len } }) |pair| {
        if (pair[1] > 1 and pair[1] != n) return fail(arena, diag, "{s} given {d} times: give it once (for every command) or once per command ({d})", .{ pair[0], pair[1], n });
    }

    if (o.runs) |r| {
        if (o.min_runs != null or o.max_runs != null) return fail(arena, diag, "--runs cannot be combined with --min-runs or --max-runs", .{});
        if (r == 0) return fail(arena, diag, "--runs must be at least 1", .{});
    }
    if (o.min_runs) |m| if (m == 0) return fail(arena, diag, "--min-runs must be at least 1", .{});
    if (o.max_runs) |m| if (m == 0) return fail(arena, diag, "--max-runs must be at least 1", .{});
    if (o.min_runs != null and o.max_runs != null and o.min_runs.? > o.max_runs.?)
        return fail(arena, diag, "--min-runs ({d}) is larger than --max-runs ({d})", .{ o.min_runs.?, o.max_runs.? });

    if (step != null and scan == null) return fail(arena, diag, "--parameter-step-size needs --parameter-scan", .{});
    if (scan) |s| try params.insert(arena, scan_at, .{ .name = s[0], .values = try scanValues(arena, s[1], s[2], step, diag) });
    for (params.items, 0..) |p, pi| {
        if (p.name.len == 0) return fail(arena, diag, "a parameter needs a name", .{});
        for (params.items[0..pi]) |q| if (std.mem.eql(u8, p.name, q.name))
            return fail(arena, diag, "parameter '{s}' is defined twice", .{p.name});
    }

    var failed: []const u8 = "";
    o.metrics = metric.parse(metrics_text, &failed) catch |err| return switch (err) {
        error.UnknownMetric => fail(arena, diag, "unknown metric '{s}' (see `time --help`)", .{failed}),
        error.UnknownUnit => fail(arena, diag, "'{s}': that unit does not fit the metric", .{failed}),
        error.DuplicateMetric => fail(arena, diag, "metric '{s}' is listed twice", .{failed}),
        error.MetricUnavailable => fail(arena, diag, "metric '{s}' is unavailable on this OS", .{failed}),
        error.EmptyMetrics => fail(arena, diag, "--metrics '{s}' selects nothing on this OS", .{metrics_text}),
    };

    if (o.shell == .none) for (commands.items) |c| {
        if (shellSyntax(c)) |ch| return fail(arena, diag,
            \\command '{s}' contains unquoted shell syntax ('{c}').
            \\Run it through a shell with -S (cmd.exe here, sh elsewhere) or --shell=..., or quote the character.
        , .{ c, ch });
        _ = try splitWords(arena, c, diag);
    };

    o.commands = commands.items;
    o.names = names.items;
    o.env = env.items;
    o.prepare = prepare.items;
    o.conclude = conclude.items;
    o.output = output.items;
    o.params = params.items;
    return o;
}

/// Splits a command line into words: whitespace separates, '...' and "..." group (the quotes are
/// removed, nothing inside is special). A backslash is an ordinary character, so Windows paths
/// work unquoted.
pub fn splitWords(arena: std.mem.Allocator, line: []const u8, diag: *Diag) Error![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var quote: ?u8 = null;
    for (line) |ch| {
        if (quote) |q| {
            if (ch == q) quote = null else try word.append(arena, ch);
        } else if (ch == '\'' or ch == '"') {
            quote = ch;
            in_word = true;
        } else if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
            if (in_word) {
                try words.append(arena, try word.toOwnedSlice(arena));
                in_word = false;
            }
        } else {
            try word.append(arena, ch);
            in_word = true;
        }
    }
    if (quote != null) return fail(arena, diag, "unclosed quote in '{s}'", .{line});
    if (in_word) try words.append(arena, try word.toOwnedSlice(arena));
    if (words.items.len == 0) return fail(arena, diag, "empty command", .{});
    return words.items;
}

/// The first shell-only character outside quotes, if any.
fn shellSyntax(line: []const u8) ?u8 {
    var quote: ?u8 = null;
    for (line, 0..) |ch, k| {
        if (quote) |q| {
            if (ch == q) quote = null;
        } else switch (ch) {
            '\'', '"' => quote = ch,
            '|', '&', ';', '<', '>', '`' => return ch,
            '$' => if (k + 1 < line.len and line[k + 1] == '(') return ch,
            else => {},
        }
    }
    return null;
}

/// A decimal number as an integer and a count of digits after the point.
const Decimal = struct { digits: i64, scale: u8 };

fn parseDecimal(text: []const u8) ?Decimal {
    const dot = std.mem.findScalar(u8, text, '.');
    const scale: usize = if (dot) |d| text.len - d - 1 else 0;
    if (scale > 9 or text.len == 0 or text.len > 19) return null;
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    for (text) |ch| if (ch != '.') {
        buf[len] = ch;
        len += 1;
    };
    const digits = std.fmt.parseInt(i64, buf[0..len], 10) catch return null;
    return .{ .digits = digits, .scale = @intCast(scale) };
}

fn rescale(d: Decimal, scale: u8) i64 {
    var v = d.digits;
    var s = d.scale;
    while (s < scale) : (s += 1) v *= 10;
    return v;
}

/// Most values one parameter scan may produce.
const max_scan_values = 100_000;

fn scanValues(arena: std.mem.Allocator, min_text: []const u8, max_text: []const u8, step_text: ?[]const u8, diag: *Diag) Error![]const []const u8 {
    const lo = parseDecimal(min_text) orelse return fail(arena, diag, "--parameter-scan: '{s}' is not a number", .{min_text});
    const hi = parseDecimal(max_text) orelse return fail(arena, diag, "--parameter-scan: '{s}' is not a number", .{max_text});
    const st: Decimal = if (step_text) |t| parseDecimal(t) orelse
        return fail(arena, diag, "--parameter-step-size: '{s}' is not a number", .{t}) else .{ .digits = 1, .scale = 0 };
    if (step_text == null and (lo.scale != 0 or hi.scale != 0))
        return fail(arena, diag, "--parameter-scan with decimals needs --parameter-step-size", .{});
    if (st.digits <= 0) return fail(arena, diag, "--parameter-step-size must be positive", .{});
    const scale = @max(lo.scale, hi.scale, st.scale);
    const a = rescale(lo, scale);
    const b = rescale(hi, scale);
    const d = rescale(st, scale);
    if (b < a) return fail(arena, diag, "--parameter-scan: MIN {s} is above MAX {s}", .{ min_text, max_text });
    if (@divFloor(b - a, d) >= max_scan_values) return fail(arena, diag, "--parameter-scan would make more than {d} values", .{max_scan_values});

    var values: std.ArrayList([]const u8) = .empty;
    var unit: i64 = 1;
    for (0..scale) |_| unit *= 10;
    var v = a;
    while (v <= b) : (v += d) {
        const whole = @divTrunc(v, unit);
        const frac = @abs(@rem(v, unit));
        const sign: []const u8 = if (v < 0 and whole == 0) "-" else "";
        try values.append(arena, if (scale == 0)
            try arena.print("{d}", .{v})
        else
            try arena.print("{s}{d}.{d:0>[3]}", .{ sign, whole, frac, scale }));
    }
    return values.items;
}

/// Most benchmarks one invocation may expand to.
const max_benches = 100_000;

/// One Bench per parameter combination and command, combinations outermost (hyperfine's order).
pub fn expand(arena: std.mem.Allocator, o: *const Options, diag: *Diag) Error![]const Bench {
    var combos: usize = 1;
    for (o.params) |p| {
        if (p.values.len == 0) return fail(arena, diag, "parameter '{s}' has no values", .{p.name});
        combos = std.math.mul(usize, combos, p.values.len) catch max_benches;
    }
    if (combos * o.commands.len >= max_benches) return fail(arena, diag, "the parameters make more than {d} benchmarks", .{max_benches});

    var benches: std.ArrayList(Bench) = .empty;
    const pick = try arena.alloc(usize, o.params.len);
    @memset(pick, 0);
    for (0..combos) |_| {
        const pairs = try arena.alloc(Pair, o.params.len);
        for (o.params, pick, pairs) |p, k, *pair| pair.* = .{ .name = p.name, .value = p.values[k] };
        for (o.commands, 0..) |cmd, ci| {
            const name = if (ci < o.names.len) try substitute(arena, o.names[ci], pairs) else null;
            var label = name orelse try substitute(arena, cmd, pairs);
            if (name != null and pairs.len > 0 and !hasPlaceholder(o.names[ci], pairs)) {
                var l: std.ArrayList(u8) = .empty;
                try l.appendSlice(arena, label);
                try l.appendSlice(arena, " (");
                for (pairs, 0..) |pair, k| {
                    if (k > 0) try l.appendSlice(arena, ", ");
                    try l.appendSlice(arena, pair.name);
                    try l.appendSlice(arena, " = ");
                    try l.appendSlice(arena, pair.value);
                }
                try l.append(arena, ')');
                label = l.items;
            }
            try benches.append(arena, .{
                .command = try substitute(arena, cmd, pairs),
                .label = label,
                .name = name,
                .params = pairs,
                .env = try perCommand(arena, o.env, ci, pairs),
                .prepare = try perCommand(arena, o.prepare, ci, pairs),
                .conclude = try perCommand(arena, o.conclude, ci, pairs),
                .setup = if (o.setup) |s| try substitute(arena, s, pairs) else null,
                .cleanup = if (o.cleanup) |s| try substitute(arena, s, pairs) else null,
                .output = if (o.output.len == 0) .null else o.output[if (o.output.len == 1) 0 else ci],
            });
        }
        // Next combination: the last parameter changes fastest.
        var k = o.params.len;
        while (k > 0) {
            k -= 1;
            pick[k] += 1;
            if (pick[k] < o.params[k].values.len) break;
            pick[k] = 0;
        }
    }
    return benches.items;
}

fn perCommand(arena: std.mem.Allocator, list: []const []const u8, ci: usize, pairs: []const Pair) Error!?[]const u8 {
    if (list.len == 0) return null;
    return try substitute(arena, list[if (list.len == 1) 0 else ci], pairs);
}

fn hasPlaceholder(text: []const u8, pairs: []const Pair) bool {
    var buf: [256]u8 = undefined;
    for (pairs) |p| {
        const key = std.mem.print(&buf, "{{{s}}}", .{p.name}) catch return true;
        if (std.mem.find(u8, text, key) != null) return true;
    }
    return false;
}

/// Replaces every "{name}" with its value.
pub fn substitute(arena: std.mem.Allocator, text: []const u8, pairs: []const Pair) Error![]const u8 {
    if (pairs.len == 0) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < text.len) {
        if (text[i] == '{') {
            for (pairs) |p| {
                const end = i + 1 + p.name.len;
                if (end < text.len and text[end] == '}' and std.mem.eql(u8, text[i + 1 .. end], p.name)) {
                    try out.appendSlice(arena, p.value);
                    i = end + 1;
                    continue :outer;
                }
            }
        }
        try out.append(arena, text[i]);
        i += 1;
    }
    return out.items;
}

test "splitWords" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = .{};
    const w = try splitWords(arena, "  prog  'two words' C:\\x\\y \"a'b\" ''", &diag);
    try std.testing.expectEqual(@as(usize, 5), w.len);
    try std.testing.expectEqualStrings("prog", w[0]);
    try std.testing.expectEqualStrings("two words", w[1]);
    try std.testing.expectEqualStrings("C:\\x\\y", w[2]);
    try std.testing.expectEqualStrings("a'b", w[3]);
    try std.testing.expectEqualStrings("", w[4]);
    try std.testing.expectError(error.Usage, splitWords(arena, "a 'b", &diag));
    try std.testing.expectError(error.Usage, splitWords(arena, "   ", &diag));
}

test "shellSyntax" {
    try std.testing.expectEqual(@as(?u8, '|'), shellSyntax("a | b"));
    try std.testing.expectEqual(@as(?u8, null), shellSyntax("a '|' \"&&\""));
    try std.testing.expectEqual(@as(?u8, '$'), shellSyntax("echo $(x)"));
    try std.testing.expectEqual(@as(?u8, null), shellSyntax("echo $HOME"));
}

test "scan values are exact decimals" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = .{};
    const a = try scanValues(arena, "0.3", "0.7", "0.2", &diag);
    try std.testing.expectEqual(@as(usize, 3), a.len);
    try std.testing.expectEqualStrings("0.3", a[0]);
    try std.testing.expectEqualStrings("0.7", a[2]);
    const b = try scanValues(arena, "1", "8", null, &diag);
    try std.testing.expectEqual(@as(usize, 8), b.len);
    try std.testing.expectEqualStrings("8", b[7]);
    const c = try scanValues(arena, "-0.5", "0.5", "0.25", &diag);
    try std.testing.expectEqual(@as(usize, 5), c.len);
    try std.testing.expectEqualStrings("-0.50", c[0]);
    try std.testing.expectEqualStrings("-0.25", c[1]);
    try std.testing.expectEqualStrings("0.00", c[2]);
    const one = try scanValues(arena, "5", "5", null, &diag);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectError(error.Usage, scanValues(arena, "0.1", "1", null, &diag));
    try std.testing.expectError(error.Usage, scanValues(arena, "3", "1", null, &diag));
    try std.testing.expectError(error.Usage, scanValues(arena, "1", "2", "0", &diag));
    try std.testing.expectError(error.Usage, scanValues(arena, "0", "1e9", null, &diag));
}

test "parse and expand" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = .{};
    const o = try parse(arena, &.{ "-w", "2", "--runs=5", "-L", "t", "1,4", "-n", "job {t}", "prog -j {t}", "other", "--prepare", "echo {t}" }, &diag);
    try std.testing.expectEqual(@as(u64, 2), o.warmup);
    try std.testing.expectEqual(@as(?u64, 5), o.runs);
    const b = try expand(arena, &o, &diag);
    try std.testing.expectEqual(@as(usize, 4), b.len);
    try std.testing.expectEqualStrings("prog -j 1", b[0].command);
    try std.testing.expectEqualStrings("job 1", b[0].label);
    try std.testing.expectEqualStrings("other", b[1].command);
    try std.testing.expectEqualStrings("other", b[1].label);
    try std.testing.expectEqualStrings("prog -j 4", b[2].command);
    try std.testing.expectEqualStrings("echo 4", b[3].prepare.?);

    const named = try parse(arena, &.{ "-n", "fast", "a {x}", "-L", "x", "1,2" }, &diag);
    const nb = try expand(arena, &named, &diag);
    try std.testing.expectEqualStrings("fast (x = 2)", nb[1].label);

    const two = try parse(arena, &.{ "-L", "a", "1,2", "-P", "b", "1", "3", "c {a} {b}" }, &diag);
    const tb = try expand(arena, &two, &diag);
    try std.testing.expectEqual(@as(usize, 6), tb.len);
    try std.testing.expectEqualStrings("c 1 1", tb[0].command);
    try std.testing.expectEqualStrings("c 1 2", tb[1].command);
    try std.testing.expectEqualStrings("c 2 1", tb[3].command);

    try std.testing.expectError(error.Usage, parse(arena, &.{ "-r", "3", "-m", "2", "x" }, &diag));
    try std.testing.expectError(error.Usage, parse(arena, &.{ "-m", "5", "-M", "2", "x" }, &diag));
    try std.testing.expectError(error.Usage, parse(arena, &.{"a | b"}, &diag));
    _ = try parse(arena, &.{ "-S", "a | b" }, &diag);
    try std.testing.expectError(error.Usage, parse(arena, &.{ "--prepare", "p", "--prepare", "q", "a", "b", "c" }, &diag));
    try std.testing.expectError(error.Usage, parse(arena, &.{ "--bogus", "a" }, &diag));
    try std.testing.expectError(error.Usage, parse(arena, &.{}, &diag));
    const ig = try parse(arena, &.{ "--ignore-failure=1,3", "x" }, &diag);
    try std.testing.expectEqual(@as(i64, 3), ig.ignore.codes[1]);
}

test "substitute" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const s = try substitute(arena_state.allocator(), "{a}-{b}-{c}-{", &.{ .{ .name = "a", .value = "1" }, .{ .name = "b", .value = "22" } });
    try std.testing.expectEqualStrings("1-22-{c}-{", s);
}
