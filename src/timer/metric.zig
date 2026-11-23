// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! What `time` can measure about a run, the units each is shown in, and `--metrics` parsing.

const std = @import("std");
const builtin = @import("builtin");

pub const Kind = enum { time, memory, count };

pub const Metric = enum {
    time_wall_clock,
    time_cpu,
    time_user,
    time_system,
    /// Peak working set (Windows) or max RSS (Unix) of the started process itself.
    memory_peak_resident,
    /// Windows: peak committed memory of the whole process tree (job object).
    memory_peak_commit,
    page_faults,
    /// Windows: processes started in the tree, the command itself included.
    processes,
    io_read_bytes,
    io_write_bytes,

    pub fn kind(m: Metric) Kind {
        return switch (m) {
            .time_wall_clock, .time_cpu, .time_user, .time_system => .time,
            .memory_peak_resident, .memory_peak_commit, .io_read_bytes, .io_write_bytes => .memory,
            .page_faults, .processes => .count,
        };
    }

    pub fn label(m: Metric) []const u8 {
        return switch (m) {
            .time_wall_clock => "Wall Time",
            .time_cpu => "CPU time",
            .time_user => "User time",
            .time_system => "System time",
            .memory_peak_resident => "Peak memory",
            .memory_peak_commit => "Peak commit",
            .page_faults => "Page faults",
            .processes => "Processes",
            .io_read_bytes => "Read",
            .io_write_bytes => "Written",
        };
    }

    /// Whether this OS can report the metric. Windows reads a job object; Unix reads rusage.
    pub fn available(m: Metric) bool {
        return switch (builtin.os.tag) {
            .windows => true,
            .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => switch (m) {
                .time_wall_clock, .time_cpu, .time_user, .time_system, .memory_peak_resident, .page_faults => true,
                else => false,
            },
            else => m == .time_wall_clock,
        };
    }

    pub fn baseUnit(m: Metric) []const u8 {
        return switch (m.kind()) {
            .time => "second",
            .memory => "byte",
            .count => "count",
        };
    }
};

pub const count = std.enums.values(Metric).len;

pub const Unit = struct {
    name: []const u8,
    /// Base units (seconds, bytes, counts) in one of this unit.
    scale: f64,
    /// Digits after the point in the terminal and the markup tables.
    decimals: u8,
};

const time_units = [_]Unit{
    .{ .name = "ns", .scale = 1e-9, .decimals = 0 },
    .{ .name = "us", .scale = 1e-6, .decimals = 1 },
    .{ .name = "ms", .scale = 1e-3, .decimals = 1 },
    .{ .name = "s", .scale = 1, .decimals = 3 },
    .{ .name = "min", .scale = 60, .decimals = 2 },
    .{ .name = "h", .scale = 3600, .decimals = 2 },
};
const memory_units = [_]Unit{
    .{ .name = "B", .scale = 1, .decimals = 0 },
    .{ .name = "kB", .scale = 1e3, .decimals = 1 },
    .{ .name = "MB", .scale = 1e6, .decimals = 1 },
    .{ .name = "GB", .scale = 1e9, .decimals = 2 },
    .{ .name = "TB", .scale = 1e12, .decimals = 2 },
    .{ .name = "KiB", .scale = 1024, .decimals = 1 },
    .{ .name = "MiB", .scale = 1024 * 1024, .decimals = 1 },
    .{ .name = "GiB", .scale = 1024 * 1024 * 1024, .decimals = 2 },
    .{ .name = "TiB", .scale = 1024 * 1024 * 1024 * 1024, .decimals = 2 },
};
const count_units = [_]Unit{
    .{ .name = "count", .scale = 1, .decimals = 0 },
    .{ .name = "k", .scale = 1e3, .decimals = 1 },
    .{ .name = "M", .scale = 1e6, .decimals = 1 },
    .{ .name = "B", .scale = 1e9, .decimals = 2 },
};

fn unitsOf(k: Kind) []const Unit {
    return switch (k) {
        .time => &time_units,
        .memory => &memory_units,
        .count => &count_units,
    };
}

pub fn findUnit(k: Kind, name: []const u8) ?Unit {
    for (unitsOf(k)) |u| if (std.mem.eql(u8, u.name, name)) return u;
    return null;
}

/// The unit a value of this size is easiest to read in. Time uses ms below a second and s above
/// (µs below a millisecond); memory uses binary units; counts switch at 10 thousand.
pub fn autoUnit(k: Kind, value: f64) Unit {
    const v = @abs(value);
    return switch (k) {
        .time => if (v == 0 or v >= 1) time_units[3] else if (v >= 1e-3) time_units[2] else time_units[1],
        .memory => if (v >= 1 << 30) memory_units[7] else if (v >= 1 << 20) memory_units[6] else if (v >= 1 << 10) memory_units[5] else memory_units[0],
        .count => if (v >= 1e10) count_units[3] else if (v >= 1e7) count_units[2] else if (v >= 1e4) count_units[1] else count_units[0],
    };
}

pub const Selection = struct {
    metric: Metric,
    /// null: chosen from the first command's mean.
    unit: ?Unit = null,
};

pub const max_selected = count;

pub const Selected = struct {
    items: [max_selected]Selection = undefined,
    len: usize = 0,

    pub fn slice(s: *const Selected) []const Selection {
        return s.items[0..s.len];
    }

    pub fn primary(s: *const Selected) Selection {
        return s.items[0];
    }

    fn add(s: *Selected, sel: Selection) error{DuplicateMetric}!void {
        for (s.slice()) |have| if (have.metric == sel.metric) return error.DuplicateMetric;
        s.items[s.len] = sel;
        s.len += 1;
    }
};

pub const ParseError = error{ UnknownMetric, UnknownUnit, DuplicateMetric, MetricUnavailable, EmptyMetrics };

/// `--metrics` value: a preset (default, time, memory, all) or `metric[:unit],...`.
/// `failed` receives the word that could not be used.
pub fn parse(text: []const u8, failed: *[]const u8) ParseError!Selected {
    var s: Selected = .{};
    if (std.mem.eql(u8, text, "default")) {
        try s.add(.{ .metric = .time_wall_clock });
        if (Metric.memory_peak_resident.available()) try s.add(.{ .metric = .memory_peak_resident });
        return s;
    }
    if (std.mem.eql(u8, text, "time")) {
        for ([_]Metric{ .time_wall_clock, .time_cpu, .time_user, .time_system }) |m| {
            if (m.available()) try s.add(.{ .metric = m });
        }
        return s;
    }
    if (std.mem.eql(u8, text, "memory")) {
        for ([_]Metric{ .memory_peak_resident, .memory_peak_commit, .page_faults }) |m| {
            if (m.available()) try s.add(.{ .metric = m });
        }
        if (s.len == 0) return error.EmptyMetrics;
        return s;
    }
    if (std.mem.eql(u8, text, "all")) {
        for (std.enums.values(Metric)) |m| {
            if (m.available()) try s.add(.{ .metric = m });
        }
        return s;
    }
    var it = std.mem.tokenizeScalar(u8, text, ',');
    while (it.next()) |word| {
        failed.* = word;
        const colon = std.mem.findScalar(u8, word, ':');
        const name = if (colon) |c| word[0..c] else word;
        const m = std.meta.stringToEnum(Metric, name) orelse return error.UnknownMetric;
        if (!m.available()) return error.MetricUnavailable;
        var sel: Selection = .{ .metric = m };
        if (colon) |c| sel.unit = findUnit(m.kind(), word[c + 1 ..]) orelse return error.UnknownUnit;
        try s.add(sel);
    }
    if (s.len == 0) return error.EmptyMetrics;
    return s;
}

/// One run's numbers, in base units. Metrics this OS cannot report stay 0 and are never shown.
pub const Sample = struct {
    values: std.EnumArray(Metric, f64) = .initFill(0),
    /// null when the process ended without an exit code (killed by a signal).
    exit_code: ?i64 = 0,
};

test "parse presets and lists" {
    var failed: []const u8 = "";
    const d = try parse("default", &failed);
    try std.testing.expectEqual(Metric.time_wall_clock, d.primary().metric);
    const t = try parse("time", &failed);
    try std.testing.expectEqual(@as(usize, 4), t.len);
    const l = try parse("time_cpu:ms,time_wall_clock", &failed);
    try std.testing.expectEqual(Metric.time_cpu, l.primary().metric);
    try std.testing.expectEqualStrings("ms", l.items[0].unit.?.name);
    try std.testing.expect(l.items[1].unit == null);
    try std.testing.expectError(error.UnknownMetric, parse("wall", &failed));
    try std.testing.expectEqualStrings("wall", failed);
    try std.testing.expectError(error.UnknownUnit, parse("time_cpu:MiB", &failed));
    try std.testing.expectError(error.DuplicateMetric, parse("time_cpu,time_cpu:s", &failed));
    try std.testing.expectError(error.EmptyMetrics, parse(",", &failed));
}

test "autoUnit picks a readable unit" {
    try std.testing.expectEqualStrings("ms", autoUnit(.time, 0.0123).name);
    try std.testing.expectEqualStrings("s", autoUnit(.time, 2.5).name);
    try std.testing.expectEqualStrings("s", autoUnit(.time, 0).name);
    try std.testing.expectEqualStrings("us", autoUnit(.time, 5e-5).name);
    try std.testing.expectEqualStrings("MiB", autoUnit(.memory, 50 * 1024 * 1024).name);
    try std.testing.expectEqualStrings("B", autoUnit(.memory, 100).name);
    try std.testing.expectEqualStrings("k", autoUnit(.count, 12345).name);
}
