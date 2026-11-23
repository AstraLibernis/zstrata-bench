// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Starting one command and measuring it.
//!
//! Windows: the command starts suspended, joins a fresh job object, then runs, so every process
//! it starts is counted. The job gives CPU time, page faults, process count, I/O bytes and the
//! tree's peak committed memory; the process itself gives its peak working set.
//! Unix: rusage of the waited child (CPU time, max RSS, page faults).
//! Wall time runs from just before the start to the end of the wait, as in hyperfine.
//!
//! A command for cmd.exe is started with its command line exactly as written (`Run.raw_line`):
//! cmd.exe does not read the C runtime's quoting that std applies to each argument, so
//! `bash -c "a > b"` would reach it mangled. Everything else goes through std.process.spawn.

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
    /// Windows only: the whole command line, passed to CreateProcessW unchanged. Overrides argv.
    raw_line: ?[]const u8 = null,
    environ_map: ?*const std.process.Environ.Map,
    input: cli.Input,
    output: cli.Stream,
};

pub const Error = error{ JobObject, SpawnFailed, OutputFile, InputFile, InvalidCommandLine } || std.mem.Allocator.Error;

/// Runs the command once and measures it. `failure` gets the OS error when the start fails.
/// `scratch` holds the converted command line and environment for a raw start; the caller
/// owns and frees it (an arena reset per run, or the run's own arena).
pub fn measure(io: std.Io, scratch: std.mem.Allocator, run: Run, failure: *[]const u8) Error!metric.Sample {
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
    if (is_windows) {
        if (run.raw_line) |line| return measureWindowsRaw(io, scratch, line, run, stdin_file, out_file, failure);
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
    var s: metric.Sample = .{};
    finishWindows(job, child.id.?, t1 -| t0, &s);
    _ = child.wait(io) catch |err| {
        failure.* = @errorName(err);
        return error.SpawnFailed;
    };
    return s;
}

/// Fills `s` from the ended process and its job. The process handle must still be open.
fn finishWindows(job: std.os.windows.HANDLE, process: std.os.windows.HANDLE, wall_ns: u64, s: *metric.Sample) void {
    s.values.set(.time_wall_clock, seconds(wall_ns));
    var code: u32 = 0;
    s.exit_code = if (win.GetExitCodeProcess(process, &code).toBool()) @as(i32, @bitCast(code)) else null;

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
    var pmc: win.ProcessMemoryCounters = undefined;
    pmc.cb = @sizeOf(win.ProcessMemoryCounters);
    if (win.K32GetProcessMemoryInfo(process, &pmc, @sizeOf(win.ProcessMemoryCounters)).toBool()) {
        s.values.set(.memory_peak_resident, @floatFromInt(pmc.peak_working_set_size));
    }
}

/// A handle the child may inherit: a duplicate of `h`, closed by the caller after the start.
fn inheritable(h: std.os.windows.HANDLE) ?std.os.windows.HANDLE {
    var dup: std.os.windows.HANDLE = undefined;
    const self = win.GetCurrentProcess();
    if (!win.DuplicateHandle(self, h, self, &dup, 0, .TRUE, win.DUPLICATE_SAME_ACCESS).toBool()) return null;
    return dup;
}

/// Holds the last start-failure message with its Windows error code. One timer runs one command
/// at a time, so one buffer is enough.
var error_text: [160]u8 = undefined;

fn lastError(failure: *[]const u8, what: []const u8) void {
    failure.* = std.mem.print(&error_text, "{s} (Windows error {d})", .{ what, win.GetLastError() }) catch what;
}

/// CreateProcessW with `line` as written. Standard handles: NUL, the given files, a pipe whose
/// read end is drained here, or this process's own.
fn measureWindowsRaw(io: std.Io, scratch: std.mem.Allocator, line: []const u8, run: Run, stdin_file: ?std.Io.File, out_file: ?std.Io.File, failure: *[]const u8) Error!metric.Sample {
    const w = std.os.windows;
    const line_w = std.unicode.wtf8ToWtf16LeAllocZ(scratch, line) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.InvalidCommandLine,
    };
    defer scratch.free(line_w);
    var env_block: ?std.process.Environ.WindowsBlock = null;
    defer if (env_block) |b| b.deinit(scratch);
    if (run.environ_map) |m| env_block = m.createWindowsBlock(scratch, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.InvalidCommandLine,
    };

    var sa: w.SECURITY_ATTRIBUTES = .{ .nLength = @sizeOf(w.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = .TRUE };
    // Handles given to the child; all closed right after the start so a pipe sees its end.
    var given: [4]w.HANDLE = undefined;
    var n_given: usize = 0;
    var closed = false;
    defer if (!closed) for (given[0..n_given]) |h| w.CloseHandle(h);

    const nul = win.CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("NUL"), win.GENERIC_READ | win.GENERIC_WRITE, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, &sa, win.OPEN_EXISTING, 0, null);
    if (nul == w.INVALID_HANDLE_VALUE) {
        lastError(failure, "cannot open NUL");
        return error.SpawnFailed;
    }
    given[n_given] = nul;
    n_given += 1;

    var stdin_h = nul;
    if (stdin_file) |f| {
        stdin_h = inheritable(f.handle) orelse {
            lastError(failure, "DuplicateHandle failed");
            return error.SpawnFailed;
        };
        given[n_given] = stdin_h;
        n_given += 1;
    }
    var pipe_read: ?w.HANDLE = null;
    defer if (pipe_read) |h| w.CloseHandle(h);
    var stdout_h = nul;
    var stderr_h = nul;
    switch (run.output) {
        .null => {},
        .file => {
            stdout_h = inheritable(out_file.?.handle) orelse {
                lastError(failure, "DuplicateHandle failed");
                return error.SpawnFailed;
            };
            given[n_given] = stdout_h;
            n_given += 1;
            stderr_h = stdout_h;
        },
        .pipe => {
            var r: w.HANDLE = undefined;
            var wr: w.HANDLE = undefined;
            if (!win.CreatePipe(&r, &wr, &sa, 0).toBool()) {
                lastError(failure, "CreatePipe failed");
                return error.SpawnFailed;
            }
            pipe_read = r;
            given[n_given] = wr;
            n_given += 1;
            stdout_h = wr;
            // Only the write end goes to the child.
            _ = win.SetHandleInformation(r, win.HANDLE_FLAG_INHERIT, 0);
        },
        .inherit => {
            if (win.GetStdHandle(win.STD_OUTPUT_HANDLE)) |h| if (h != w.INVALID_HANDLE_VALUE) if (inheritable(h)) |d| {
                stdout_h = d;
                given[n_given] = d;
                n_given += 1;
            };
            if (win.GetStdHandle(win.STD_ERROR_HANDLE)) |h| if (h != w.INVALID_HANDLE_VALUE) if (inheritable(h)) |d| {
                stderr_h = d;
                given[n_given] = d;
                n_given += 1;
            };
        },
    }

    var si = std.mem.zeroes(w.STARTUPINFOW);
    si.cb = @sizeOf(w.STARTUPINFOW);
    si.dwFlags = w.STARTF_USESTDHANDLES;
    si.hStdInput = stdin_h;
    si.hStdOutput = stdout_h;
    si.hStdError = stderr_h;
    var pi: w.PROCESS.INFORMATION = undefined;

    const job = win.CreateJobObjectW(null, null) orelse {
        failure.* = "CreateJobObjectW failed";
        return error.JobObject;
    };
    defer w.CloseHandle(job);

    const t0 = nowNs(io);
    const started = w.kernel32.CreateProcessW(
        null,
        line_w.ptr,
        null,
        null,
        .TRUE,
        .{ .create_suspended = true, .create_unicode_environment = true },
        if (env_block) |b| b.slice.ptr else null,
        null,
        &si,
        &pi,
    ).toBool();
    for (given[0..n_given]) |h| w.CloseHandle(h);
    closed = true;
    if (!started) {
        lastError(failure, "CreateProcessW failed (the shell was not found or the command line is invalid)");
        return error.SpawnFailed;
    }
    defer w.CloseHandle(pi.hProcess);
    defer w.CloseHandle(pi.hThread);
    if (!win.AssignProcessToJobObject(job, pi.hProcess).toBool() or win.ResumeThread(pi.hThread) == std.math.maxInt(u32)) {
        _ = win.TerminateProcess(pi.hProcess, 1);
        _ = win.WaitForSingleObject(pi.hProcess, win.INFINITE);
        failure.* = "AssignProcessToJobObject or ResumeThread failed";
        return error.JobObject;
    }
    if (pipe_read) |r| {
        var buf: [16 * 1024]u8 = undefined;
        var got: u32 = 0;
        while (win.ReadFile(r, &buf, buf.len, &got, null).toBool() and got > 0) {}
    }
    _ = win.WaitForSingleObject(pi.hProcess, win.INFINITE);
    const t1 = nowNs(io);
    var s: metric.Sample = .{};
    finishWindows(job, pi.hProcess, t1 -| t0, &s);
    return s;
}

/// The Win32 calls std does not wrap. Referenced only on Windows.
const win = struct {
    const w = std.os.windows;

    const INFINITE: u32 = 0xFFFF_FFFF;
    const GENERIC_READ: u32 = 0x8000_0000;
    const GENERIC_WRITE: u32 = 0x4000_0000;
    const FILE_SHARE_READ: u32 = 1;
    const FILE_SHARE_WRITE: u32 = 2;
    const OPEN_EXISTING: u32 = 3;
    const HANDLE_FLAG_INHERIT: u32 = 1;
    const DUPLICATE_SAME_ACCESS: u32 = 2;
    const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
    const STD_ERROR_HANDLE: u32 = @bitCast(@as(i32, -12));

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

    const ProcessMemoryCounters = extern struct {
        cb: u32,
        page_fault_count: u32,
        peak_working_set_size: usize,
        working_set_size: usize,
        quota_peak_paged_pool_usage: usize,
        quota_paged_pool_usage: usize,
        quota_peak_non_paged_pool_usage: usize,
        quota_non_paged_pool_usage: usize,
        pagefile_usage: usize,
        peak_pagefile_usage: usize,
    };

    comptime {
        // The layouts Windows documents for 64-bit processes.
        if (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64) {
            std.debug.assert(@sizeOf(BasicAndIoAccounting) == 96);
            std.debug.assert(@sizeOf(BasicLimit) == 64);
            std.debug.assert(@sizeOf(ExtendedLimit) == 144);
            std.debug.assert(@sizeOf(ProcessMemoryCounters) == 72);
        }
    }

    extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?w.HANDLE;
    extern "kernel32" fn AssignProcessToJobObject(job: w.HANDLE, process: w.HANDLE) callconv(.winapi) w.BOOL;
    extern "kernel32" fn QueryInformationJobObject(job: ?w.HANDLE, class: JobInfoClass, info: *anyopaque, length: u32, return_length: ?*u32) callconv(.winapi) w.BOOL;
    extern "kernel32" fn ResumeThread(thread: w.HANDLE) callconv(.winapi) u32;
    extern "kernel32" fn WaitForSingleObject(handle: w.HANDLE, milliseconds: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetExitCodeProcess(process: w.HANDLE, code: *u32) callconv(.winapi) w.BOOL;
    extern "kernel32" fn TerminateProcess(process: w.HANDLE, code: u32) callconv(.winapi) w.BOOL;
    extern "kernel32" fn K32GetProcessMemoryInfo(process: w.HANDLE, counters: *ProcessMemoryCounters, size: u32) callconv(.winapi) w.BOOL;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*w.SECURITY_ATTRIBUTES, disposition: u32, flags: u32, template: ?w.HANDLE) callconv(.winapi) w.HANDLE;
    extern "kernel32" fn CreatePipe(read: *w.HANDLE, write: *w.HANDLE, security: ?*w.SECURITY_ATTRIBUTES, size: u32) callconv(.winapi) w.BOOL;
    extern "kernel32" fn SetHandleInformation(handle: w.HANDLE, mask: u32, flags: u32) callconv(.winapi) w.BOOL;
    extern "kernel32" fn ReadFile(handle: w.HANDLE, buffer: [*]u8, len: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) w.BOOL;
    extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?w.HANDLE;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) w.HANDLE;
    extern "kernel32" fn DuplicateHandle(source_process: w.HANDLE, source: w.HANDLE, target_process: w.HANDLE, target: *w.HANDLE, access: u32, inherit: w.BOOL, options: u32) callconv(.winapi) w.BOOL;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
};
