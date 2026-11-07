//! `Layout`: how a loop divides the one region of memory its caller hands it (decision 4, Memory
//! per core). `memory_bytes` and `init` run the same sequence of `add` calls, so the size a
//! backend reports is the size it carves, by construction.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

/// The alignment of the region a caller hands a loop: a `Slot`'s. Only a line that another thread
/// reads, such as the heartbeat, needs more, and `Layout` aligns that line at run time.
pub const memory_alignment = constants.slot_bytes;

/// The strictest alignment `Layout` carves: the heartbeat's line (decision 28).
pub const line_alignment_max = constants.heartbeat_alignment;

pub const Layout = struct {
    bytes: usize = 0,

    /// Reserves room for `count` values of `T` and returns its offset. A type aligned to at most
    /// `memory_alignment` sits at that offset. A type with a stricter alignment, such as the
    /// heartbeat, gets `slack_of(T)` more bytes, and `take` moves it forward to the first address
    /// aligned for it. So the size depends only on the sequence of calls, and not on the address.
    pub fn add(layout: *Layout, comptime T: type, count: usize) usize {
        comptime assert(@alignOf(T) <= line_alignment_max);
        assert(count >= 1);
        const start_alignment = @min(@alignOf(T), memory_alignment);
        const offset = std.mem.alignForward(usize, layout.bytes, start_alignment);
        layout.bytes = offset + slack_of(T) + @sizeOf(T) * count;
        assert(layout.bytes > offset);
        return offset;
    }

    /// Reserves room as `add` does and returns that part of `memory`. The region's base has
    /// `memory_alignment`, so an offset aligned for a type of at most that alignment is an address
    /// aligned for it. A type with a stricter alignment skips at most `slack_of(T)` bytes forward,
    /// as the registry's header and the offload's rings do.
    pub fn take(
        layout: *Layout,
        memory: []align(memory_alignment) u8,
        comptime T: type,
        count: usize,
    ) []T {
        const offset = layout.add(T, count);
        assert(layout.bytes <= memory.len);
        const start = @intFromPtr(memory.ptr) + offset;
        const skipped = std.mem.alignForward(usize, start, @alignOf(T)) - start;
        assert(skipped <= slack_of(T));
        const pointer: [*]T = @ptrCast(@alignCast(memory.ptr + offset + skipped));
        return pointer[0..count];
    }
};

/// The bytes `take` may skip to reach an address aligned for `T`: 0 for a type aligned to at most
/// `memory_alignment`, and the difference of the two alignments otherwise.
pub fn slack_of(comptime T: type) usize {
    if (@alignOf(T) <= memory_alignment) return 0;
    return @alignOf(T) - memory_alignment;
}

comptime {
    assert(std.math.isPowerOfTwo(memory_alignment));
    assert(std.math.isPowerOfTwo(line_alignment_max));
    assert(line_alignment_max >= memory_alignment);
}

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

/// A line aligned to `line_alignment_max`, as the heartbeat is.
const Line = struct {
    word: u64 align(line_alignment_max),
};

test "a line aligned more strictly than the region sits on its own boundary at either base" {
    // One region starts on a 128-byte boundary, and one starts 64 bytes past it. `take` skips
    // forward in the second and skips nothing in the first. Both fit in the size `add` reports.
    var backing: [512]u8 align(line_alignment_max) = undefined;
    var sizing: Layout = .{};
    _ = sizing.add(u64, 3);
    _ = sizing.add(Line, 1);
    _ = sizing.add(u16, 1);
    // The words end at 24, and the line's room starts at the next multiple of 64.
    const line_room = slack_of(Line) + @sizeOf(Line);
    try testing.expectEqual(memory_alignment + line_room + @sizeOf(u16), sizing.bytes);
    for ([_]usize{ 0, memory_alignment }) |shift| {
        const memory: []align(memory_alignment) u8 = @alignCast(backing[shift..][0..sizing.bytes]);
        var layout: Layout = .{};
        const words = layout.take(memory, u64, 3);
        const line = layout.take(memory, Line, 1);
        const half = layout.take(memory, u16, 1);
        try testing.expectEqual(sizing.bytes, layout.bytes);
        try testing.expectEqual(@as(usize, 0), @intFromPtr(line.ptr) % line_alignment_max);
        // The line lies after the words and before the half, in the room `add` reserved for it.
        try testing.expect(@intFromPtr(line.ptr) >= @intFromPtr(words.ptr) + 3 * @sizeOf(u64));
        try testing.expect(@intFromPtr(line.ptr) + @sizeOf(Line) <= @intFromPtr(half.ptr));
        try testing.expect(@intFromPtr(half.ptr) + @sizeOf(u16) <= @intFromPtr(memory.ptr) + memory.len);
    }
}
