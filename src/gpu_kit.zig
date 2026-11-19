// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! What every GPU variant shares: one Vulkan device for the whole run, and `Compute`, a compute
//! shader with its buffers on the card and the staging buffers to move data to and from it.
//! Built on zstrata's Vulkan layer and shaped by its speed playbook: data stays on the card
//! between runs, and a run with transfers is one submit (upload, dispatch, download).

const std = @import("std");
pub const gpu = @import("gpu");
const vk = gpu.vk;

pub const Gpu = struct {
    ctx: gpu.Context,
    cmds: gpu.Commands,

    /// Opens the first discrete GPU. Heap-allocated so its address is stable; caller frees
    /// with `deinit`.
    pub fn init(gpa: std.mem.Allocator) !*Gpu {
        const g = try gpa.create(Gpu);
        errdefer gpa.destroy(g);
        g.ctx = try gpu.Context.init(gpa, .{});
        errdefer g.ctx.deinit();
        g.cmds = try gpu.Commands.init(&g.ctx);
        return g;
    }

    pub fn deinit(g: *Gpu, gpa: std.mem.Allocator) void {
        g.cmds.deinit(&g.ctx);
        g.ctx.deinit();
        gpa.destroy(g);
    }
};

/// Workgroup counts for `items` invocations of a shader with `local` invocations per group in
/// x. One dimension holds at most 65,535 groups, so large counts spill into y; the shader finds
/// its item as `gl_GlobalInvocationID.x + gl_GlobalInvocationID.y * span`.
pub const Groups = struct { counts: [3]u32, span: u32 };

pub fn groupsFor(items: usize, local: u32) Groups {
    const max_x: usize = 32768;
    const groups = @max(1, (items + local - 1) / local);
    const x = @min(groups, max_x);
    const y = (groups + x - 1) / x;
    return .{ .counts = .{ @intCast(x), @intCast(y), 1 }, .span = @intCast(x * local) };
}

pub const max_buffers = 8;

pub const Compute = struct {
    g: *Gpu,
    pipe: gpu.ComputePipeline,
    /// On the card: inputs first, then outputs, in binding order.
    device: [max_buffers]gpu.Buffer,
    sizes: [max_buffers]usize,
    n_in: usize,
    n_out: usize,
    /// Host-visible: every input back to back, and every output back to back.
    stage_in: gpu.Buffer,
    stage_out: gpu.Buffer,

    /// Buffers of the given byte sizes (each at least 1). Caller frees with `deinit`.
    pub fn init(g: *Gpu, spirv: []align(4) const u8, input_bytes: []const usize, output_bytes: []const usize, push_size: u32) !Compute {
        const ctx = &g.ctx;
        const total = input_bytes.len + output_bytes.len;
        std.debug.assert(total <= max_buffers and input_bytes.len > 0 and output_bytes.len > 0);
        var c: Compute = .{
            .g = g,
            .pipe = undefined,
            .device = undefined,
            .sizes = undefined,
            .n_in = input_bytes.len,
            .n_out = output_bytes.len,
            .stage_in = undefined,
            .stage_out = undefined,
        };
        const usage: vk.BufferUsageFlags = .{ .storage_buffer = true, .transfer_dst = true, .transfer_src = true };
        var made: usize = 0;
        errdefer for (c.device[0..made]) |*b| b.deinit(ctx);
        var in_total: usize = 0;
        var out_total: usize = 0;
        while (made < total) : (made += 1) {
            const bytes = if (made < c.n_in) input_bytes[made] else output_bytes[made - c.n_in];
            c.sizes[made] = bytes;
            if (made < c.n_in) in_total += bytes else out_total += bytes;
            c.device[made] = try gpu.Buffer.init(ctx, bytes, usage, .{ .device_local = true }, .{});
        }
        const host: vk.MemoryPropertyFlags = .{ .host_visible = true, .host_coherent = true };
        c.stage_in = try gpu.Buffer.init(ctx, in_total, .{ .transfer_src = true }, host, .{});
        errdefer c.stage_in.deinit(ctx);
        c.stage_out = try gpu.Buffer.init(ctx, out_total, .{ .transfer_dst = true }, host, .{ .host_cached = true });
        errdefer c.stage_out.deinit(ctx);
        c.pipe = try gpu.ComputePipeline.init(ctx, spirv, @intCast(total), push_size);
        var handles: [max_buffers]vk.Buffer = undefined;
        for (c.device[0..total], handles[0..total]) |b, *h| h.* = b.handle;
        c.pipe.bindBuffers(ctx, handles[0..total]);
        return c;
    }

    pub fn deinit(c: *Compute) void {
        const ctx = &c.g.ctx;
        c.pipe.deinit(ctx);
        c.stage_out.deinit(ctx);
        c.stage_in.deinit(ctx);
        for (c.device[0 .. c.n_in + c.n_out]) |*b| b.deinit(ctx);
        c.* = undefined;
    }

    fn offsetOf(c: *const Compute, first: usize, index: usize) usize {
        var at: usize = 0;
        for (c.sizes[first .. first + index]) |s| at += s;
        return at;
    }

    /// Where the caller writes input `index` before a run with transfers.
    pub fn input(c: *Compute, index: usize, comptime T: type) []T {
        const at = c.offsetOf(0, index);
        const p: [*]T = @ptrCast(@alignCast(c.stage_in.mapped.? + at));
        return p[0 .. c.sizes[index] / @sizeOf(T)];
    }

    /// Where output `index` is found after a run with transfers, or after `download`.
    pub fn output(c: *const Compute, index: usize, comptime T: type) []const T {
        const at = c.offsetOf(c.n_in, index);
        const p: [*]const T = @ptrCast(@alignCast(c.stage_out.mapped.? + at));
        return p[0 .. c.sizes[c.n_in + index] / @sizeOf(T)];
    }

    fn recordUpload(c: *const Compute, cmd: vk.CommandBuffer) void {
        const ctx = &c.g.ctx;
        var at: usize = 0;
        for (c.device[0..c.n_in], c.sizes[0..c.n_in]) |b, size| {
            ctx.vkd.cmdCopyBuffer(cmd, c.stage_in.handle, b.handle, &.{.{ .src_offset = at, .dst_offset = 0, .size = size }});
            at += size;
        }
        gpu.barrier(ctx, cmd, .{ .copy = true }, .{ .transfer_write = true }, .{ .compute_shader = true }, .{ .shader_storage_read = true });
    }

    fn recordDownload(c: *const Compute, cmd: vk.CommandBuffer) void {
        const ctx = &c.g.ctx;
        gpu.barrier(ctx, cmd, .{ .compute_shader = true }, .{ .shader_storage_write = true }, .{ .copy = true }, .{ .transfer_read = true });
        var at: usize = 0;
        for (c.device[c.n_in .. c.n_in + c.n_out], c.sizes[c.n_in .. c.n_in + c.n_out]) |b, size| {
            ctx.vkd.cmdCopyBuffer(cmd, b.handle, c.stage_out.handle, &.{.{ .src_offset = 0, .dst_offset = at, .size = size }});
            at += size;
        }
        gpu.barrier(ctx, cmd, .{ .copy = true }, .{ .transfer_write = true }, .{ .host = true }, .{ .host_read = true });
    }

    pub const Move = struct { upload: bool = false, download: bool = false };

    /// One submit: optionally copy the staged inputs to the card, dispatch, optionally copy the
    /// outputs back; then wait for it.
    pub fn run(c: *Compute, push: *const anyopaque, groups: [3]u32, move: Move) !void {
        const ctx = &c.g.ctx;
        const cmds = &c.g.cmds;
        try cmds.begin(ctx);
        if (move.upload) c.recordUpload(cmds.cmd);
        c.pipe.dispatch(ctx, cmds.cmd, push, groups);
        if (move.download) c.recordDownload(cmds.cmd);
        try cmds.submitAndWait(ctx);
    }

    /// Copy the staged inputs to the card and wait. For data that then stays there.
    pub fn uploadOnly(c: *Compute) !void {
        const ctx = &c.g.ctx;
        const cmds = &c.g.cmds;
        try cmds.begin(ctx);
        c.recordUpload(cmds.cmd);
        try cmds.submitAndWait(ctx);
    }

    /// Copy the outputs back and wait.
    pub fn download(c: *Compute) !void {
        const ctx = &c.g.ctx;
        const cmds = &c.g.cmds;
        try cmds.begin(ctx);
        c.recordDownload(cmds.cmd);
        try cmds.submitAndWait(ctx);
    }
};

test "groupsFor covers every item and never exceeds one dimension's limit" {
    for ([_]usize{ 0, 1, 63, 64, 65, 1000, 2_097_152, 12_500_000, 200_000_000 }) |items| {
        const g = groupsFor(items, 64);
        try std.testing.expect(g.counts[0] <= 32768 and g.counts[1] <= 65535 and g.counts[2] == 1);
        const invocations = @as(u64, g.counts[0]) * g.counts[1] * 64;
        try std.testing.expect(invocations >= items);
        try std.testing.expectEqual(@as(u32, g.counts[0] * 64), g.span);
        // No whole row of groups is wasted.
        if (g.counts[1] > 1) try std.testing.expect(@as(u64, g.counts[0]) * (g.counts[1] - 1) * 64 < items);
    }
}
