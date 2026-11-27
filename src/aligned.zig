// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! An allocator that hands every block out on a cache-line boundary, whatever alignment was
//! asked for. With libc linked the general allocator is `malloc`, and glibc returns big blocks
//! 16 bytes into a cache line: 64-byte vector loads from such a block touch two lines each
//! (zstrata, docs/measurements.md, "Linux gaps"). Windows' heap already aligns big blocks, so
//! the same code measured differently on the two systems.

const std = @import("std");
const Alignment = std.mem.Alignment;

pub const line: Alignment = .fromByteUnits(std.atomic.cache_line);

pub const Aligning = struct {
    child: std.mem.Allocator,

    pub fn allocator(self: *Aligning) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *Aligning = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, alignment.max(line), ra);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
        const self: *Aligning = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment.max(line), new_len, ra);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Aligning = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment.max(line), new_len, ra);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        const self: *Aligning = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment.max(line), ra);
    }
};

test "every block starts on a cache line and survives growing" {
    var a: Aligning = .{ .child = std.testing.allocator };
    const gpa = a.allocator();
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    for (0..10_000) |i| try list.append(gpa, @truncate(i));
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(list.items.ptr) % std.atomic.cache_line);
    try std.testing.expectEqual(@as(u8, @truncate(9_999)), list.items[9_999]);
    const one = try gpa.create(u8);
    defer gpa.destroy(one);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(one) % std.atomic.cache_line);
}
