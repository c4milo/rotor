//! Provided buffers on kqueue (decision 12, point 4). io_uring picks a buffer from a group
//! itself; here the loop does. A group is the caller's memory cut into equal buffers, with a
//! stack of the ids that are free. A receive from a group takes an id, receives into that
//! buffer and names it in its event, and the caller gives the id back when it has read the bytes.
//!
//! The calls take what the uring backend's take, so a caller's code is the same on both. The
//! memory that holds io_uring's buffer ring holds the stack of free ids here.
//!
//! `register` records nothing: kqueue pins no pages, so there is nothing to save.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const constants = @import("constants.zig");
const kqueue = @import("kqueue.zig");

const Loop = kqueue.Loop;

pub const RegisterError = error{ SystemResources, Unexpected };
/// `Unsupported`: the kernel refused the buffer ring itself. io_uring answers EINVAL for that, and
/// for a misaligned ring and a count that is not a power of two; both of those are now assertions,
/// so what is left is a kernel that cannot do provided buffer rings at all. Before this the three
/// arrived as one `Unexpected`, and a consumer spent a day on the alignment one (2026-09-22).
///
/// The kqueue backend never enters the kernel here and so never answers `Unsupported`. The set is
/// the same on both because a caller writes one handler for both (decision 1).
pub const ProvideError = error{ Unsupported, SystemResources, Unexpected };

/// The alignment of the memory a group's bookkeeping sits in.
/// The alignment of a group's memory: what io_uring's buffer ring needs, kept on both backends so
/// one declaration in a caller's code serves both.
pub const group_alignment = constants.buffer_ring_alignment;

/// The bytes of bookkeeping a group of `count` buffers needs: what the uring backend's ring
/// needs, which is more than the two bytes per id this backend uses.
pub fn ring_bytes(count: u16) usize {
    assert(count >= 1);
    assert(std.math.isPowerOfTwo(count));
    return @as(usize, count) * constants.buffer_ring_entry_bytes;
}

/// One provided-buffer group. `buffer_bytes` is 0 until `provide` names the group.
pub const Group = struct {
    buffers: []u8,
    buffer_bytes: u32,
    count: u16,
    /// The ids of the free buffers. `free[0..free_count]` is the stack, its top at the end.
    free: []u16,
    free_count: u16,

    pub const none: Group = .{
        .buffers = &.{},
        .buffer_bytes = 0,
        .count = 0,
        .free = &.{},
        .free_count = 0,
    };

    /// The bytes of buffer `buffer_id`.
    pub fn bytes_of(group: *const Group, buffer_id: u16) []u8 {
        assert(group.buffer_bytes != 0);
        assert(buffer_id < group.count);
        const start = @as(usize, buffer_id) * group.buffer_bytes;
        return group.buffers[start..][0..group.buffer_bytes];
    }

    /// Takes a free buffer's id, or null when every buffer is with the caller.
    pub fn take(group: *Group) ?u16 {
        assert(group.buffer_bytes != 0);
        if (group.free_count == 0) return null;
        group.free_count -= 1;
        return group.free[group.free_count];
    }

    pub fn give_back(group: *Group, buffer_id: u16) void {
        assert(buffer_id < group.count);
        assert(group.free_count < group.count);
        group.free[group.free_count] = buffer_id;
        group.free_count += 1;
    }
};

/// Records nothing: see the file's comment. It asserts what the uring backend asserts, so a
/// caller's mistake halts on both.
pub fn register(loop: *Loop, buffers: []const []u8) RegisterError!void {
    loop.tables.assert_owner();
    assert(buffers.len >= 1);
    assert(buffers.len <= core.constants.registered_buffers_max);
    assert(!loop.buffers_registered);
    loop.buffers_registered = true;
}

/// Makes `buffers`, cut into pieces of `buffer_bytes`, group `group_id` of this loop, with every
/// buffer free. Both memories stay the loop's until `deinit`.
/// The bytes a group of `count` buffers of `buffer_bytes` needs: the bookkeeping, then the
/// buffers, so buffer 0 starts `ring_bytes(count)` bytes in.
pub fn group_bytes(count: u16, buffer_bytes: u32) usize {
    assert(buffer_bytes >= 1);
    return ring_bytes(count) + @as(usize, count) * buffer_bytes;
}

/// Makes group `group_id` of this loop out of `memory`: `count` buffers of `buffer_bytes` each,
/// every one free to start with. `memory` holds `group_bytes(count, buffer_bytes)` bytes aligned
/// to `group_alignment`, the bookkeeping first and the buffers after it, and stays the loop's
/// until `deinit`.
pub fn provide(
    loop: *Loop,
    group_id: u16,
    memory: []align(group_alignment) u8,
    count: u16,
    buffer_bytes: u32,
) ProvideError!void {
    loop.tables.assert_owner();
    assert(group_id < core.constants.buffer_groups_max);
    assert(loop.groups[group_id].buffer_bytes == 0);
    // What this backend needs, and not `group_alignment`. The free list is read as `[*]u16`, so u16
    // alignment is the real requirement here; `group_alignment` is io_uring's, asked for on both so
    // that one declaration in a caller's code serves both (`constants.zig`).
    //
    // Asserting the larger figure here would refuse memory this backend can use. macOS does not
    // always give a static the alignment it declares: a `[N]u8 align(64 KiB)` came back 16 KiB
    // aligned on 2026-09-22, and `conformance_udp.zig` declares exactly that. `uring_buffers.zig`
    // asserts the full figure because its kernel enforces it, which is where a caller who relied on
    // the declaration finds out.
    assert(std.mem.isAligned(@intFromPtr(memory.ptr), @alignOf(u16)));
    assert(count >= 1);
    assert(count <= core.constants.buffers_per_group_max);
    assert(memory.len >= group_bytes(count, buffer_bytes));
    const free: [*]u16 = @ptrCast(memory.ptr);
    const buffers = memory[ring_bytes(count)..][0 .. @as(usize, count) * buffer_bytes];
    const group = &loop.groups[group_id];
    group.* = .{
        .buffers = buffers,
        .buffer_bytes = buffer_bytes,
        .count = count,
        .free = free[0..count],
        .free_count = 0,
    };
    // Pushed in descending order, so the first receive takes buffer 0, as on io_uring.
    for (0..count) |pushed| group.give_back(@intCast(count - 1 - pushed));
    assert(group.free_count == count);
}

/// Hands buffer `buffer_id` of group `group_id` back, after the caller has read the bytes the
/// receive event named.
pub fn give_back(loop: *Loop, group_id: u16, buffer_id: u16) void {
    loop.tables.assert_owner();
    assert(group_id < core.constants.buffer_groups_max);
    loop.groups[group_id].give_back(buffer_id);
}

const testing = std.testing;

test "a group hands out every buffer once, lowest id first, and takes them back" {
    var memory: [64]u8 = undefined;
    var free: [4]u16 = undefined;
    var group: Group = .{
        .buffers = &memory,
        .buffer_bytes = 16,
        .count = 4,
        .free = &free,
        .free_count = 0,
    };
    for (0..4) |pushed| group.give_back(@intCast(3 - pushed));
    for (0..4) |expected| try testing.expectEqual(@as(?u16, @intCast(expected)), group.take());
    try testing.expectEqual(@as(?u16, null), group.take());
    group.give_back(2);
    try testing.expectEqual(@as(?u16, 2), group.take());
    try testing.expectEqual(@intFromPtr(&memory) + 32, @intFromPtr(group.bytes_of(2).ptr));
    try testing.expectEqual(@as(usize, 16), group.bytes_of(3).len);
    try testing.expectEqual(@as(usize, 64), ring_bytes(4));
}

test "a group's buffers start after its bookkeeping, and the size helper counts both" {
    const options: Loop.Options = .{ .operations = 4, .entries = 4 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    loop.init_tables(&memory, options);
    const count = 4;
    const buffer_bytes = 16;
    var group_memory: [group_bytes(count, buffer_bytes)]u8 align(group_alignment) = undefined;
    try provide(&loop, 0, &group_memory, count, buffer_bytes);
    try testing.expectEqual(ring_bytes(count) + count * buffer_bytes, group_bytes(count, buffer_bytes));
    // Buffer 0 starts where the bookkeeping ends, so a receive into it cannot overwrite the free
    // stack, and the last buffer ends where the memory does.
    const first = @intFromPtr(&group_memory[ring_bytes(count)]);
    try testing.expectEqual(first, @intFromPtr(loop.provided_buffer(0, 0).ptr));
    const last = @intFromPtr(&group_memory[ring_bytes(count) + (count - 1) * buffer_bytes]);
    try testing.expectEqual(last, @intFromPtr(loop.provided_buffer(0, count - 1).ptr));
}
