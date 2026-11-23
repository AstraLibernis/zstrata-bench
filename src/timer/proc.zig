// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Starting one command and measuring it.
//!
//! Windows: the command starts suspended, joins a fresh job object, then runs, so every process
//! it starts is counted. The job gives CPU time, page faults, process count, I/O bytes and the
//! tree's peak committed memory; the process itself gives its peak working set.
//! Unix: rusage of the waited child (CPU time, max RSS, page faults).
//! Wall time runs from just before the start to the end of the wait, as in hyperfine.

const std = @import("std");
const builtin = @import("builtin");
const metric = @import("metric.zig");
const cli = @import("cli.zig");

const is_windows = builtin.os.tag == .windows;

pub fn nowNs(io: std.Io) u64 {
    return @intCast(@max(std.Io.Clock.awake.now(io).nanoseconds, 0));
}

pub const Run = struct {
    argv: []const []const u8,
    environ_map: ?*const std.process.Environ.Map,
    input: cli.Input,
    output: cli.Stream,
};

pub const Error = error{ JobObject, SpawnFailed, OutputFile, InputFile } || std.mem.Allocator.Error;

/// Runs the command once and measures it. `failure` gets the OS error name when the start fails.
pub fn measure(io: std.Io, run: Run, failure: *[]const u8) Error!metric.Sample {
    var stdin_file: ?std.Io.File = null;
    defer if (stdin_file) |f| f.close(io);
    var out_file: ?std.Io.File = null;
    defer if (out_file) |f| f.close(io);
    switch (run.input) {
        .null => {},
        .file => |p| stdin_file = std.Io.Dir.cwd().openFile(io, p, .{}) catch |err| {
            failure.* = @errorName(err);
            return error.InputFile;
        },
    }
    switch (run.output) {
        .file => |p| out_file = std.Io.Dir.cwd().createFile(io, p, .{}) catch |err| {
            failure.* = @errorName(err);
            return error.OutputFile;
        },
        else => {},
    }
    const stdin: std.process.SpawnOptions.StdIo = if (stdin_file) |f| .{ .file = f } else .ignore;
    const stdout: std.process.SpawnOptions.StdIo = switch (run.output) {
        .null => .ignore,
        .pipe => .pipe,
        .inherit => .inherit,
        .file => .{ .file = out_file.? },
    };
    const stderr: std.process.SpawnOptions.StdIo = switch (run.output) {
        .null, .pipe => .ignore,
        .inherit => .inherit,
        .file => .{ .file = out_file.? },
    };
    const options: std.process.SpawnOptions = .{
        .argv = run.argv,
        .environ_map = run.environ_map,
        .stdin = stdin,
        .stdout = stdout,
        .stderr = stderr,
        .request_resource_usage_statistics = true,
        .start_suspended = is_windows,
    };
    return if (is_windows) measureWindows(io, options, failure) else measurePosix(io, options, failure);
}

/// Reads and discards a piped stdout until the child closes it.
fn drain(io: std.Io, child: *std.process.Child) void {
    const f = child.stdout orelse return;
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = f.readStreaming(io, &.{&buf}) catch return;
        if (n == 0) return;
    }
}

fn measurePosix(io: std.Io, options: std.process.SpawnOptions, failure: *[]const u8) Error!metric.Sample {
    const t0 = nowNs(io);
    var child = std.process.spawn(io, options) catch |err| {
        failure.* = @errorName(err);
        return error.SpawnFailed;
    };
    drain(io, &child);
    const term = child.wait(io) catch |err| {
        failure.* = @errorName(err);
        return error.SpawnFailed;
    };
    const t1 = nowNs(io);

    var s: metric.Sample = .{};
    s.values.set(.time_wall_clock, seconds(t1 -| t0));
    s.exit_code = switch (term) {
        .exited => |c| c,
        else => null,
    };
    if (comptime builtin.os.tag != .windows and @TypeOf(child.resource_usage_statistics.rusage) != void) {
        if (child.resource_usage_statistics.rusage) |ru| {
            const user = tv(ru.utime);
            const sys = tv(ru.stime);
            s.values.set(.time_user, user);
            s.values.set(.time_system, sys);
            s.values.set(.time_cpu, user + sys);
            s.values.set(.page_faults, @floatFromInt(@max(ru.minflt, 0) + @max(ru.majflt, 0)));
        }
        if (child.resource_usage_statistics.getMaxRss()) |b| s.values.set(.memory_peak_resident, @floatFromInt(b));
    }
    return s;
}

fn tv(t: anytype) f64 {
    return @as(f64, @floatFromInt(t.sec)) + @as(f64, @floatFromInt(t.usec)) * 1e-6;
}

fn seconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) * 1e-9;
}

fn measureWindows(io: std.Io, options: std.process.SpawnOptions, failure: *[]const u8) Error!metric.Sample {
    const job = win.CreateJobObjectW(null, null) orelse {
        failure.* = "CreateJobObjectW failed";
        return error.JobObject;
    };
    defer std.os.windows.CloseHandle(job);

    const t0 = nowNs(io);
    var child = std.process.spawn(io, options) catch |err| {
        failure.* = @errorName(err);
        return error.SpawnFailed;
    };
    // From here the child exists: every exit path must end it and reap it.
    if (!win.AssignProcessToJobObject(job, child.id.?).toBool()) {
        child.kill(io);
        failure.* = "AssignProcessToJobObject failed";
        return error.JobObject;
    }
    if (win.ResumeThread(child.thread_handle) == std.math.maxInt(u32)) {
        child.kill(io);
        failure.* = "ResumeThread failed";
        return error.SpawnFailed;
    }
    drain(io, &child);
    // Wait here, not in child.wait, to read the full 32-bit exit code before std closes the handle.
    _ = win.WaitForSingleObject(child.id.?, win.INFINITE);
    // The clock stops when the process has ended, before the bookkeeping below.
    const t1 = nowNs(io);
    var code: u32 = 0;
    const have_code = win.GetExitCodeProcess(child.id.?, &code).toBool();
    _ = child.wait(io) catch |err| {
        failure.* = @errorName(err);
        return error.SpawnFailed;
    };

    var s: metric.Sample = .{};
    s.values.set(.time_wall_clock, seconds(t1 -| t0));
    s.exit_code = if (have_code) @as(i32, @bitCast(code)) else null;

    var acct: win.BasicAndIoAccounting = undefined;
    if (win.QueryInformationJobObject(job, .basic_and_io_accounting, &acct, @sizeOf(win.BasicAndIoAccounting), null).toBool()) {
        const user = @as(f64, @floatFromInt(acct.basic.total_user_time)) * 1e-7;
        const sys = @as(f64, @floatFromInt(acct.basic.total_kernel_time)) * 1e-7;
        s.values.set(.time_user, user);
        s.values.set(.time_system, sys);
        s.values.set(.time_cpu, user + sys);
        s.values.set(.page_faults, @floatFromInt(acct.basic.total_page_fault_count));
        s.values.set(.processes, @floatFromInt(acct.basic.total_processes));
        s.values.set(.io_read_bytes, @floatFromInt(acct.io.read_transfer_count));
        s.values.set(.io_write_bytes, @floatFromInt(acct.io.write_transfer_count));
    }
    var ext: win.ExtendedLimit = undefined;
    if (win.QueryInformationJobObject(job, .extended_limit, &ext, @sizeOf(win.ExtendedLimit), null).toBool()) {
        s.values.set(.memory_peak_commit, @floatFromInt(ext.peak_job_memory_used));
    }
    if (comptime is_windows) {
        if (child.resource_usage_statistics.rusage) |vm| s.values.set(.memory_peak_resident, @floatFromInt(vm.PeakWorkingSetSize));
    }
    return s;
}

pub const HookError = error{ HookFailed, SpawnFailed } || std.mem.Allocator.Error;

/// Runs a setup/prepare/conclude/cleanup command through `shell_prefix` with output discarded.
/// Returns its wall time in seconds; a non-zero exit is error.HookFailed (`code` holds it).
pub fn hook(io: std.Io, argv: []const []const u8, environ_map: ?*const std.process.Environ.Map, code: *?i64, failure: *[]const u8) HookError!f64 {
    const t0 = nowNs(io);
    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = environ_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        failure.* = @errorName(err);
        return error.SpawnFailed;
    };
    const term = child.wait(io) catch |err| {
        failure.* = @errorName(err);
        return error.SpawnFailed;
    };
    const t1 = nowNs(io);
    switch (term) {
        .exited => |c| if (c != 0) {
            code.* = c;
            return error.HookFailed;
        },
        else => {
            code.* = null;
            return error.HookFailed;
        },
    }
    return seconds(t1 -| t0);
}

/// The Win32 calls std does not wrap. Referenced only on Windows.
const win = struct {
    const w = std.os.windows;

    const INFINITE: u32 = 0xFFFF_FFFF;

    const JobInfoClass = enum(c_int) {
        basic_and_io_accounting = 8,
        extended_limit = 9,
    };

    const BasicAccounting = extern struct {
        total_user_time: i64,
        total_kernel_time: i64,
        this_period_total_user_time: i64,
        this_period_total_kernel_time: i64,
        total_page_fault_count: u32,
        total_processes: u32,
        active_processes: u32,
        total_terminated_processes: u32,
    };

    const IoCounters = extern struct {
        read_operation_count: u64,
        write_operation_count: u64,
        other_operation_count: u64,
        read_transfer_count: u64,
        write_transfer_count: u64,
        other_transfer_count: u64,
    };

    const BasicAndIoAccounting = extern struct {
        basic: BasicAccounting,
        io: IoCounters,
    };

    const BasicLimit = extern struct {
        per_process_user_time_limit: i64,
        per_job_user_time_limit: i64,
        limit_flags: u32,
        minimum_working_set_size: usize,
        maximum_working_set_size: usize,
        active_process_limit: u32,
        affinity: usize,
        priority_class: u32,
        scheduling_class: u32,
    };

    const ExtendedLimit = extern struct {
        basic: BasicLimit,
        io: IoCounters,
        process_memory_limit: usize,
        job_memory_limit: usize,
        peak_process_memory_used: usize,
        peak_job_memory_used: usize,
    };

    comptime {
        // The layouts Windows documents for 64-bit processes.
        if (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64) {
            std.debug.assert(@sizeOf(BasicAndIoAccounting) == 96);
            std.debug.assert(@sizeOf(BasicLimit) == 64);
            std.debug.assert(@sizeOf(ExtendedLimit) == 144);
        }
    }

    extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?w.HANDLE;
    extern "kernel32" fn AssignProcessToJobObject(job: w.HANDLE, process: w.HANDLE) callconv(.winapi) w.BOOL;
    extern "kernel32" fn QueryInformationJobObject(job: ?w.HANDLE, class: JobInfoClass, info: *anyopaque, length: u32, return_length: ?*u32) callconv(.winapi) w.BOOL;
    extern "kernel32" fn ResumeThread(thread: w.HANDLE) callconv(.winapi) u32;
    extern "kernel32" fn WaitForSingleObject(handle: w.HANDLE, milliseconds: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetExitCodeProcess(process: w.HANDLE, code: *u32) callconv(.winapi) w.BOOL;
};
