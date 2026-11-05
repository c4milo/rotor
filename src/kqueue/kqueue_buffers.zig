//! Provided buffers on kqueue (decision 12, point 4): the calls that take this backend's
//! `*Loop`. The group itself, its layout and its errors are `core/buffer_group.zig`'s, shared with
//! the other readiness backend. The calls take what the uring backend's take, so a caller's code is
//! the same on all three.
//!
//! `register` records nothing: kqueue pins no pages, so there is nothing to save.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const kqueue = @import("kqueue.zig");

const Loop = kqueue.Loop;

pub const RegisterError = core.buffer_group.RegisterError;
pub const ProvideError = core.buffer_group.ProvideError;
pub const group_alignment = core.buffer_group.group_alignment;
pub const ring_bytes = core.buffer_group.ring_bytes;
pub const group_bytes = core.buffer_group.group_bytes;
pub const Group = core.buffer_group.Group;

/// Records nothing: see the file's comment. It asserts what the uring backend asserts, so a
/// caller's mistake halts on every backend.
pub fn register(loop: *Loop, buffers: []const []u8) RegisterError!void {
    loop.tables.assert_owner();
    loop.tables.note_buffers(buffers.len);
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
    loop.groups[group_id] = Group.carve(memory, count, buffer_bytes);
}

/// Hands buffer `buffer_id` of group `group_id` back, after the caller has read the bytes the
/// receive event named. A buffer the events of a split datagram name goes back at the last of their
/// give-backs (decision 15, amendment of 2026-11-05).
pub fn give_back(loop: *Loop, group_id: u16, buffer_id: u16) void {
    loop.tables.assert_owner();
    assert(group_id < core.constants.buffer_groups_max);
    const group = &loop.groups[group_id];
    if (!core.buffer_group.release(group.holders, buffer_id)) return;
    group.give_back(buffer_id);
}

const testing = std.testing;

test "a group's buffers start after its bookkeeping and its holders, and the size helper counts all" {
    const options: Loop.Options = .{ .operations = 4, .entries = 4 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    loop.init_tables(&memory, options);
    const count = 4;
    const buffer_bytes = 16;
    var group_memory: [group_bytes(count, buffer_bytes)]u8 align(group_alignment) = undefined;
    try provide(&loop, 0, &group_memory, count, buffer_bytes);
    const offset = core.buffer_group.buffers_offset(count);
    try testing.expectEqual(offset + count * buffer_bytes, group_bytes(count, buffer_bytes));
    // Buffer 0 starts where the bookkeeping and the holders end, so a receive into it cannot
    // overwrite the free stack, and the last buffer ends where the memory does.
    const first = @intFromPtr(&group_memory[offset]);
    try testing.expectEqual(first, @intFromPtr(loop.provided_buffer(0, 0).ptr));
    const last = @intFromPtr(&group_memory[offset + (count - 1) * buffer_bytes]);
    try testing.expectEqual(last, @intFromPtr(loop.provided_buffer(0, count - 1).ptr));
}

test "a buffer a split datagram holds goes back to the group at its last event's give-back" {
    const options: Loop.Options = .{ .operations = 4, .entries = 4 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    loop.init_tables(&memory, options);
    const count = 4;
    var group_memory: [group_bytes(count, 64)]u8 align(group_alignment) = undefined;
    try provide(&loop, 0, &group_memory, count, 64);
    const group = &loop.groups[0];
    const taken = group.take().?;
    // Three datagrams of one coalesced datagram name the buffer.
    core.buffer_group.hold(group.holders, taken, 3);
    give_back(&loop, 0, taken);
    give_back(&loop, 0, taken);
    try testing.expectEqual(@as(u16, count - 1), group.free_count);
    give_back(&loop, 0, taken);
    try testing.expectEqual(@as(u16, count), group.free_count);
}
