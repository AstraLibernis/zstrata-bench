// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The terminal report and the exports (JSON, CSV, Markdown, AsciiDoc, Org).
//! The JSON follows hyperfine 2.0's layout (schema 2) so the same readers work on both.

const std = @import("std");
const builtin = @import("builtin");
const metric = @import("metric.zig");
const stats = @import("stats.zig");
const cli = @import("cli.zig");

const Metric = metric.Metric;

pub const Result = struct {
    bench: cli.Bench,
    samples: []const metric.Sample,
    /// For every metric this OS reports.
    summaries: std.EnumArray(Metric, ?stats.Summary),
};

/// The unit each selected metric is shown in: the one asked for, else the one that suits the
/// first command's mean, so every command is shown in the same unit.
pub const Units = std.EnumArray(Metric, ?metric.Unit);

pub fn chooseUnits(selected: *const metric.Selected, first: *const Result) Units {
    var u: Units = .initFill(null);
    for (selected.slice()) |sel| {
        const mean = if (first.summaries.get(sel.metric)) |s| s.mean else 0;
        u.set(sel.metric, sel.unit orelse metric.autoUnit(sel.metric.kind(), mean));
    }
    return u;
}

pub const formatValue = num;

/// `v` in `unit` with the unit's usual decimals.
fn num(buf: []u8, v: f64, unit: metric.Unit) []const u8 {
    const x = v / unit.scale;
    return switch (unit.decimals) {
        0 => std.mem.print(buf, "{d:.0}", .{x}),
        1 => std.mem.print(buf, "{d:.1}", .{x}),
        2 => std.mem.print(buf, "{d:.2}", .{x}),
        else => std.mem.print(buf, "{d:.3}", .{x}),
    } catch "?";
}

/// One benchmark as hyperfine 2.0 lays it out: a header, then one row per selected metric with
/// mean ± σ and min … max, plus the change against the first benchmark when there is one.
pub fn terminal(w: *std.Io.Writer, index: usize, r: *const Result, reference: ?*const Result, selected: *const metric.Selected, units: *const Units) !void {
    try w.print("Benchmark {d}: {s} ({d} run{s})\n", .{ index + 1, r.bench.label, r.samples.len, if (r.samples.len == 1) "" else "s" });
    // Written out because the width padding counts bytes and ± σ … are two or three each.
    try w.writeAll("                      mean     ±        σ             min     …       max\n");
    for (selected.slice()) |sel| {
        const s = r.summaries.get(sel.metric) orelse continue;
        var unit = units.get(sel.metric).?;
        // A plain count needs no unit after each number.
        if (std.mem.eql(u8, unit.name, "count")) unit.name = "";
        var b: [4][64]u8 = undefined;
        try w.print("  {s:<14}{s:>10} {s:<3} ± {s:>9} {s:<3}  {s:>10} {s:<3} … {s:>9} {s}", .{
            sel.metric.label(),
            num(&b[0], s.mean, unit),
            unit.name,
            if (s.stddev) |sd| num(&b[1], sd, unit) else "n/a",
            unit.name,
            num(&b[2], s.min, unit),
            unit.name,
            num(&b[3], s.max, unit),
            unit.name,
        });
        if (reference) |ref| {
            const rs = ref.summaries.get(sel.metric).?;
            var cb: [32]u8 = undefined;
            const pad = 3 -| unit.name.len;
            try w.splatByteAll(' ', pad);
            try w.print("  {s:>9}", .{changeText(&cb, s.mean, rs.mean)});
            var fb: [48]u8 = undefined;
            if (factorText(&fb, s.mean, rs.mean, sel.metric.kind())) |f| try w.print("  {s}", .{f});
        }
        try w.writeByte('\n');
    }
}

fn changeText(buf: []u8, mean: f64, reference: f64) []const u8 {
    const c = stats.change(mean, reference) orelse return "N/A";
    if (@abs(c) < 0.05) return "0.0%";
    return std.mem.print(buf, "{s}{d:.1}%", .{ if (c > 0) "+" else "", c }) catch "?";
}

fn factorText(buf: []u8, mean: f64, reference: f64, kind: metric.Kind) ?[]const u8 {
    const f = stats.factor(mean, reference) orelse return null;
    const word: []const u8 = switch (kind) {
        .time => if (f.lower) "faster" else "slower",
        else => if (f.lower) "less" else "more",
    };
    if (std.math.isInf(f.value)) return std.mem.print(buf, "(∞x {s})", .{word}) catch null;
    return std.mem.print(buf, "({d:.1}x {s})", .{ f.value, word }) catch null;
}

pub const Meta = struct {
    /// Seconds since 1970, UTC.
    start_time: i64,
};

fn writeIsoTime(w: *std.Io.Writer, secs: i64) !void {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(secs, 0)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,              md.month.numeric(),      md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

fn jsonNumber(w: *std.Io.Writer, v: f64) !void {
    if (std.math.isFinite(v)) try w.print("{d}", .{v}) else try w.writeAll("null");
}

fn jsonString(w: *std.Io.Writer, s: []const u8) !void {
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}

/// hyperfine 2.0's JSON (schema 2), with every metric this OS reports. Values in base units.
pub fn json(w: *std.Io.Writer, results: []const Result, selected: *const metric.Selected, meta: Meta) !void {
    try w.print("{{\n  \"schema_version\": 2,\n  \"metadata\": {{\n    \"tool\": \"zstrata-bench time\",\n    \"zig_version\": \"{s}\",\n    \"start_time\": \"", .{builtin.zig_version_string});
    try writeIsoTime(w, meta.start_time);
    try w.print("\",\n    \"platform\": {{\n      \"os\": \"{s}\",\n      \"architecture\": \"{s}\"\n    }}\n  }},\n", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    try w.print("  \"primary_metric\": \"{s}\",\n  \"results\": [", .{@tagName(selected.primary().metric)});
    for (results, 0..) |r, ri| {
        try w.writeAll(if (ri == 0) "\n    {\n      \"command\": " else ",\n    {\n      \"command\": ");
        try jsonString(w, r.bench.command);
        if (r.bench.name) |n| {
            try w.writeAll(",\n      \"name\": ");
            try jsonString(w, n);
        }
        try w.writeAll(",\n      \"measurements\": [");
        for (r.samples, 0..) |s, si| {
            try w.writeAll(if (si == 0) "\n        {" else ",\n        {");
            var first = true;
            for (std.enums.values(Metric)) |m| {
                if (!m.available()) continue;
                try w.print("{s}\n          \"{s}\": {{ \"value\": ", .{ if (first) "" else ",", @tagName(m) });
                try jsonNumber(w, s.values.get(m));
                try w.print(", \"unit\": \"{s}\" }}", .{m.baseUnit()});
                first = false;
            }
            if (s.exit_code) |c| try w.print(",\n          \"exit_code\": {d}\n        }}", .{c}) else try w.writeAll(",\n          \"exit_code\": null\n        }");
        }
        try w.writeAll("\n      ],\n      \"parameters\": {");
        for (r.bench.params, 0..) |p, pi| {
            try w.writeAll(if (pi == 0) "\n        " else ",\n        ");
            try jsonString(w, p.name);
            try w.writeAll(": { \"value\": ");
            try jsonString(w, p.value);
            try w.writeAll(" }");
        }
        try w.writeAll(if (r.bench.params.len > 0) "\n      },\n      \"summary\": {" else "},\n      \"summary\": {");
        var first = true;
        for (std.enums.values(Metric)) |m| {
            const s = r.summaries.get(m) orelse continue;
            try w.print("{s}\n        \"{s}\": {{\n          \"unit\": \"{s}\",\n          \"count\": {d},\n          \"mean\": ", .{ if (first) "" else ",", @tagName(m), m.baseUnit(), s.count });
            try jsonNumber(w, s.mean);
            try w.writeAll(",\n          \"stddev\": ");
            if (s.stddev) |sd| try jsonNumber(w, sd) else try w.writeAll("null");
            try w.writeAll(",\n          \"median\": ");
            try jsonNumber(w, s.median);
            try w.writeAll(",\n          \"min\": ");
            try jsonNumber(w, s.min);
            try w.writeAll(",\n          \"max\": ");
            try jsonNumber(w, s.max);
            try w.writeAll("\n        }");
            first = false;
        }
        try w.writeAll("\n      }\n    }");
    }
    try w.writeAll("\n  ]\n}\n");
}

fn csvField(w: *std.Io.Writer, s: []const u8) !void {
    if (std.mem.findAny(u8, s, ",\"\n\r") == null) return w.writeAll(s);
    try w.writeByte('"');
    for (s) |c| {
        if (c == '"') try w.writeByte('"');
        try w.writeByte(c);
    }
    try w.writeByte('"');
}

fn csvNumber(w: *std.Io.Writer, v: f64) !void {
    if (std.math.isFinite(v)) try w.print("{d}", .{v});
}

/// One row per benchmark: the label, then unit, mean, stddev, median, min and max of every
/// selected metric (in its chosen unit, else the base unit), then one column per parameter.
pub fn csv(w: *std.Io.Writer, results: []const Result, selected: *const metric.Selected) !void {
    try w.writeAll("command");
    for (selected.slice()) |sel| {
        inline for (.{ "unit", "mean", "stddev", "median", "min", "max" }) |col| try w.print(",{s}_{s}", .{ @tagName(sel.metric), col });
    }
    if (results.len > 0) for (results[0].bench.params) |p| {
        try w.writeAll(",parameter_");
        try w.writeAll(p.name);
    };
    try w.writeByte('\n');
    for (results) |r| {
        try csvField(w, r.bench.label);
        for (selected.slice()) |sel| {
            const s = r.summaries.get(sel.metric).?;
            const scale = if (sel.unit) |u| u.scale else 1;
            const base: []const u8 = switch (sel.metric.kind()) {
                .time => "s",
                .memory => "B",
                .count => "count",
            };
            try w.print(",{s},", .{if (sel.unit) |u| u.name else base});
            try csvNumber(w, s.mean / scale);
            try w.writeByte(',');
            if (s.stddev) |sd| try csvNumber(w, sd / scale);
            inline for (.{ "median", "min", "max" }) |f| {
                try w.writeByte(',');
                try csvNumber(w, @field(s, f) / scale);
            }
        }
        for (r.bench.params) |p| {
            try w.writeByte(',');
            try csvField(w, p.value);
        }
        try w.writeByte('\n');
    }
}

pub const Markup = enum { markdown, asciidoc, orgmode };

/// A table of the primary metric: command, mean ± σ, min, max, change and factor against the
/// first command.
pub fn table(w: *std.Io.Writer, kind: Markup, results: []const Result, selected: *const metric.Selected, units: *const Units) !void {
    const m = selected.primary().metric;
    const unit = units.get(m).?;
    const cols = 6;
    var head: [cols][96]u8 = undefined;
    const headers = [cols][]const u8{
        "Command",
        std.mem.print(&head[1], "Mean {s} [{s}]", .{ m.label(), unit.name }) catch "Mean",
        std.mem.print(&head[2], "Min [{s}]", .{unit.name}) catch "Min",
        std.mem.print(&head[3], "Max [{s}]", .{unit.name}) catch "Max",
        "Change",
        "Factor",
    };
    switch (kind) {
        .markdown => {
            try w.writeAll("|");
            for (headers) |h| try w.print(" {s} |", .{h});
            try w.writeAll("\n|:---|---:|---:|---:|---:|:---|\n");
        },
        .asciidoc => {
            try w.writeAll("[cols=\"<,>,>,>,>,<\",options=\"header\"]\n|===\n");
            for (headers) |h| try w.print("| {s}\n", .{h});
        },
        .orgmode => {
            try w.writeAll("|");
            for (headers) |h| try w.print(" {s} |", .{h});
            try w.writeAll("\n|--+--+--+--+--+--|\n");
        },
    }
    const ref = if (results.len > 0) results[0].summaries.get(m).? else undefined;
    for (results, 0..) |r, ri| {
        const s = r.summaries.get(m).?;
        var b: [6][96]u8 = undefined;
        const cmd = switch (kind) {
            .markdown => std.mem.print(&b[0], "`{s}`", .{r.bench.label}) catch r.bench.label,
            .asciidoc => std.mem.print(&b[0], "`{s}`", .{r.bench.label}) catch r.bench.label,
            .orgmode => std.mem.print(&b[0], "={s}=", .{r.bench.label}) catch r.bench.label,
        };
        var nb: [2][64]u8 = undefined;
        const mean_sd = std.mem.print(&b[1], "{s} ± {s}", .{ num(&nb[0], s.mean, unit), if (s.stddev) |sd| num(&nb[1], sd, unit) else "n/a" }) catch "?";
        const cells = [cols][]const u8{
            cmd,
            mean_sd,
            num(&b[2], s.min, unit),
            num(&b[3], s.max, unit),
            if (ri == 0) "" else changeText(&b[4], s.mean, ref.mean),
            if (ri == 0) "" else (factorText(&b[5], s.mean, ref.mean, m.kind()) orelse ""),
        };
        switch (kind) {
            .markdown, .orgmode => {
                try w.writeAll("|");
                for (cells) |c| try w.print(" {s} |", .{c});
                try w.writeByte('\n');
            },
            .asciidoc => {
                try w.writeByte('\n');
                for (cells) |c| try w.print("| {s}\n", .{c});
            },
        }
    }
    if (kind == .asciidoc) try w.writeAll("|===\n");
}

test "csv quoting and change text" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try csvField(&w, "a,\"b\"");
    try std.testing.expectEqualStrings("\"a,\"\"b\"\"\"", w.buffered());
    var cb: [32]u8 = undefined;
    try std.testing.expectEqualStrings("-50.0%", changeText(&cb, 5, 10));
    try std.testing.expectEqualStrings("+30.0%", changeText(&cb, 13, 10));
    try std.testing.expectEqualStrings("0.0%", changeText(&cb, 10.0001, 10));
    try std.testing.expectEqualStrings("N/A", changeText(&cb, 1, 0));
    var fb: [48]u8 = undefined;
    try std.testing.expectEqualStrings("(2.0x faster)", factorText(&fb, 5, 10, .time).?);
    try std.testing.expectEqualStrings("(1.5x more)", factorText(&fb, 15, 10, .memory).?);
}

test "iso time" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeIsoTime(&w, 1_795_000_000);
    try std.testing.expectEqualStrings("2026-11-18T11:06:40Z", w.buffered());
}
