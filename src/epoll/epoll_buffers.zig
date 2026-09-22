//! Provided buffers on epoll (decision 20). io_uring picks a buffer from a group itself; here the
//! loop does. A group is the caller's memory cut into equal buffers, with a stack of the ids that
//! are free. A receive from a group takes an id, receives into that buffer and names it in its
//! event, and the caller gives the id back when it has read the bytes.
//!
//! This is `src/kqueue/kqueue_buffers.zig` with the kqueue names changed. The two are the same
//! because neither kernel has a buffer ring: the emulation is the same work on both, and `Group`
//! itself holds no kernel type. It is a copy and not a shared file because the calls take a
//! `*Loop`, which is each backend's own; `core` would have to be generic over it to hold them.
//!
//! The calls take what the uring backend's take, so a caller's code is the same on all three. The
//! memory that holds io_uring's buffer ring holds the stack of free ids here.
//!
//! `register` records nothing: epoll pins no pages, so there is nothing to save.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const constants = @import("constants.zig");
const epoll = @import("epoll.zig");

const Loop = epoll.Loop;

pub const RegisterError = error{ SystemResources, Unexpected };
/// `Unsupported`: the kernel refused the buffer ring itself. Only io_uring can answer that, and it
/// does so for a kernel that cannot do provided buffer rings at all. This backend never enters the
/// kernel here and so never answers it. The set is the same on all three backends because a caller
/// writes one handler for all of them (decision 1).
pub const ProvideError = error{ Unsupported, SystemResources, Unexpected };

/// The alignment of a group's memory: what io_uring's buffer ring needs, kept on every backend so
/// one declaration in a caller's code serves them all.
pub const group_alignment = constants.buffer_ring_alignment;

/// The bytes of bookkeeping a group of `count` buffers needs: what the uring backend's ring
/// needs, which is more than the two bytes per id this backend uses.
pub fn ring_bytes(count: u16) usize {
    assert(count >= 1);
    assert(std.math.isPowerOfTwo(count));
    return @as(usize, count) * constants.buffer_ring_entry_bytes;
}

/// The bytes a group of `count` buffers of `buffer_bytes` needs: the bookkeeping, then the buffers,
/// so buffer 0 starts `ring_bytes(count)` bytes in.
pub fn group_bytes(count: u16, buffer_bytes: u32) usize {
    assert(buffer_bytes >= 1);
    return ring_bytes(count) + @as(usize, count) * buffer_bytes;
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
/// caller's mistake halts on every backend.
pub fn register(loop: *Loop, buffers: []const []u8) RegisterError!void {
    loop.tables.assert_owner();
    assert(buffers.len >= 1);
    assert(buffers.len <= core.constants.registered_buffers_max);
    assert(!loop.buffers_registered);
    loop.buffers_registered = true;
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
    // alignment is the real requirement here; `group_alignment` is io_uring's, asked for on every
    // backend so that one declaration in a caller's code serves them all (`constants.zig`).
    //
    // `uring_buffers.zig` asserts the full figure because its kernel enforces it, which is where a
    // caller who relied on the declaration finds out (2026-09-22).
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

test "provide hands out buffer 0 first, as io_uring's ring does, and every one exactly once" {
    // `provide` pushes the ids in descending order so the top of the stack is 0. Without that a
    // caller that compares the two backends sees a different buffer named for the same receive.
    const options: Loop.Options = .{ .operations = 4 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    loop.init_tables(&memory, options);
    const count = 4;
    const buffer_bytes = 32;
    var group_memory: [group_bytes(count, buffer_bytes)]u8 align(group_alignment) = undefined;
    try provide(&loop, 0, &group_memory, count, buffer_bytes);

    const group = &loop.groups[0];
    try testing.expectEqual(@as(u16, count), group.free_count);
    for (0..count) |expected| {
        try testing.expectEqual(@as(?u16, @intCast(expected)), group.take());
    }
    try testing.expectEqual(@as(?u16, null), group.take());
    // Given back out of order, the stack hands the last one back first and loses none.
    give_back(&loop, 0, 3);
    give_back(&loop, 0, 1);
    try testing.expectEqual(@as(?u16, 1), group.take());
    try testing.expectEqual(@as(?u16, 3), group.take());
    try testing.expectEqual(@as(?u16, null), group.take());
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
    const both = ring_bytes(count) + count * buffer_bytes;
    try testing.expectEqual(both, group_bytes(count, buffer_bytes));
    // Buffer 0 starts where the bookkeeping ends, so a receive into it cannot overwrite the free
    // stack, and the last buffer ends where the memory does.
    const first = @intFromPtr(&group_memory[ring_bytes(count)]);
    try testing.expectEqual(first, @intFromPtr(loop.provided_buffer(0, 0).ptr));
    const last = @intFromPtr(&group_memory[ring_bytes(count) + (count - 1) * buffer_bytes]);
    try testing.expectEqual(last, @intFromPtr(loop.provided_buffer(0, count - 1).ptr));
}
