//! `Layout`: how a loop divides the one region of memory its caller hands it (decision 4, Memory
//! per core). `memory_bytes` and `init` run the same sequence of `add` calls, so the size a
//! backend reports is the size it carves, by construction.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

/// The alignment of the region a caller hands a loop: a `Slot`'s, the strictest of any table.
pub const memory_alignment = constants.slot_bytes;

pub const Layout = struct {
    bytes: usize = 0,

    /// Reserves room for `count` values of `T` at `T`'s alignment and returns its offset.
    pub fn add(layout: *Layout, comptime T: type, count: usize) usize {
        comptime assert(@alignOf(T) <= memory_alignment);
        assert(count >= 1);
        const offset = std.mem.alignForward(usize, layout.bytes, @alignOf(T));
        layout.bytes = offset + @sizeOf(T) * count;
        assert(layout.bytes > offset);
        return offset;
    }

    /// Reserves room as `add` does and returns that part of `memory`. The region's base has the
    /// strictest alignment any table needs, so an offset aligned for `T` is an address aligned
    /// for `T`.
    pub fn take(
        layout: *Layout,
        memory: []align(memory_alignment) u8,
        comptime T: type,
        count: usize,
    ) []T {
        const offset = layout.add(T, count);
        assert(layout.bytes <= memory.len);
        const pointer: [*]T = @ptrCast(@alignCast(memory.ptr + offset));
        return pointer[0..count];
    }
};

const testing = std.testing;

test "take hands out aligned, disjoint parts, and add reports the same size" {
    var memory: [256]u8 align(memory_alignment) = undefined;
    var sizing: Layout = .{};
    _ = sizing.add(u8, 3);
    _ = sizing.add(u64, 2);
    _ = sizing.add(u16, 1);
    try testing.expectEqual(@as(usize, 26), sizing.bytes);

    var layout: Layout = .{};
    const bytes = layout.take(&memory, u8, 3);
    const words = layout.take(&memory, u64, 2);
    const half = layout.take(&memory, u16, 1);
    try testing.expectEqual(sizing.bytes, layout.bytes);
    try testing.expectEqual(@intFromPtr(&memory), @intFromPtr(bytes.ptr));
    try testing.expectEqual(@intFromPtr(&memory) + 8, @intFromPtr(words.ptr));
    try testing.expectEqual(@intFromPtr(&memory) + 24, @intFromPtr(half.ptr));
    try testing.expectEqual(@as(usize, 2), words.len);
}
