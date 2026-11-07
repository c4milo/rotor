//! Provided buffers on epoll (decision 20): the calls that take this backend's
//! `*Loop`. The group itself, its layout and its errors are `core/buffer_group.zig`'s, shared with
//! the other readiness backend. The calls take what the uring backend's take, so a caller's code is
//! the same on all three.
//!
//! `register` records nothing: epoll pins no pages, so there is nothing to save.
const std = @import("std");
const assert = std.debug.assert;
const assert_class_a = core.assertion_class.assert_class_a;
const core = @import("core");
const epoll = @import("epoll.zig");

const BufferGroup = core.buffer_group.BufferGroup;
const Loop = epoll.Loop;
const datagram_module = @import("epoll_datagram.zig");

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

/// Reserves the lowest group id that no caller holds, and returns it (decision 29). The id is the
/// caller's until the loop's `deinit`. `BufferGroupsFull` when every id is reserved.
pub fn reserve(loop: *Loop) core.buffer_group.ReserveError!BufferGroup {
    loop.tables.assert_owner();
    return loop.buffer_groups.reserve();
}

/// Makes group `group` of this loop out of `memory`: `count` buffers of `buffer_bytes` each,
/// every one free to start with. `memory` holds `group_bytes(count, buffer_bytes)` bytes aligned
/// to `group_alignment`, the bookkeeping first and the buffers after it, and stays the loop's
/// until `deinit`. Halts on a group that no caller reserved (decision 29).
pub fn provide(
    loop: *Loop,
    group: BufferGroup,
    memory: []align(group_alignment) u8,
    count: u16,
    buffer_bytes: u32,
) ProvideError!void {
    loop.tables.assert_owner();
    const group_id = loop.buffer_groups.reserved(group);
    assert(loop.groups[group_id].buffer_bytes == 0);
    loop.groups[group_id] = Group.carve(memory, count, buffer_bytes);
}

/// Takes group `group` back (rotor issue 13): its memory is the caller's again, and the id may
/// be provided again. Halts while an operation in flight names the group, so a multishot receive
/// from it must reach its final event first. A buffer the caller still holds is plain memory after
/// this, and its `give_back` halts. The datagram shape stays fixed (`core.datagram.Shape`).
pub fn release(loop: *Loop, group: BufferGroup) void {
    loop.tables.assert_owner();
    const group_id = @intFromEnum(group);
    assert(group_id < core.constants.buffer_groups_max);
    assert(loop.groups[group_id].buffer_bytes != 0);
    core.buffer_group.assert_unused(&loop.tables.table, group_id);
    loop.groups[group_id] = .none;
}

/// Hands buffer `buffer_id` of group `group` back, after the caller has read the bytes the
/// receive event named. A buffer the events of a split datagram name goes back at the last of their
/// give-backs (decision 15, amendment of 2026-11-05).
pub fn give_back(loop: *Loop, group: BufferGroup, buffer_id: u16) void {
    loop.tables.assert_owner();
    const group_id = @intFromEnum(group);
    assert_class_a(group_id < core.constants.buffer_groups_max);
    const provided = &loop.groups[group_id];
    if (!core.buffer_group.release(provided.holders, buffer_id)) return;
    provided.give_back(buffer_id);
}

/// A buffer group for datagrams (decision 15). The reserve in front of each datagram is chosen
/// here, once, and `provide_buffers` is untouched, so no stream caller gains a precondition. One
/// loop serves one datagram shape: the first call fixes it, and a later call with a different one
/// halts (`core.datagram.Shape`).
///
/// The shape is checked and recorded after `provide` returns, so a call from another thread halts
/// on `provide`'s owner check before it writes anything.
pub fn provide_datagram_buffers(
    loop: *Loop,
    group: BufferGroup,
    memory: []align(group_alignment) u8,
    count: u16,
    buffer_bytes: u32,
    options: core.datagram.GroupOptions,
) ProvideError!void {
    core.datagram.check_buffer_bytes(buffer_bytes, options);
    try provide(loop, group, memory, count, buffer_bytes);
    loop.datagram_shape.fix(options);
}

/// The datagram an event of group `group` names: the only supported reader of that buffer,
/// because a datagram's bytes do not start at its front. The buffer stays the caller's until
/// `give_back_buffer`.
pub fn datagram(loop: *const Loop, group: BufferGroup, event: core.Event) core.Delivery {
    assert(!event.flags.message);
    assert(event.flags.buffer);
    const buffer = provided_buffer(loop, group, event.flags.buffer_id);
    const bytes: u32 = @intCast(event.result);
    const whole = datagram_module.delivery(buffer, bytes, loop.datagram_shape.options);
    const capacity = buffer.len - core.datagram.prefix_bytes(loop.datagram_shape.options);
    return core.datagram_split.view(whole, capacity, event);
}

/// The bytes of the provided buffer a receive event named: `buffer_id` of `group`.
pub fn provided_buffer(loop: *const Loop, group: BufferGroup, buffer_id: u16) []u8 {
    const group_id = @intFromEnum(group);
    assert_class_a(group_id < core.constants.buffer_groups_max);
    return loop.groups[group_id].bytes_of(buffer_id);
}

const testing = std.testing;

test "a group's buffers start after its bookkeeping and its holders, and the size helper counts all" {
    const options: Loop.Options = .{ .operations = 4, .entries = 4 };
    var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    loop.init_tables(&memory, &options);
    const count = 4;
    const buffer_bytes = 16;
    var group_memory: [group_bytes(count, buffer_bytes)]u8 align(group_alignment) = undefined;
    const group = try reserve(&loop);
    try provide(&loop, group, &group_memory, count, buffer_bytes);
    const offset = core.buffer_group.buffers_offset(count);
    try testing.expectEqual(offset + count * buffer_bytes, group_bytes(count, buffer_bytes));
    // Buffer 0 starts where the bookkeeping and the holders end, so a receive into it cannot
    // overwrite the free stack, and the last buffer ends where the memory does.
    const first = @intFromPtr(&group_memory[offset]);
    try testing.expectEqual(first, @intFromPtr(loop.provided_buffer(group, 0).ptr));
    const last = @intFromPtr(&group_memory[offset + (count - 1) * buffer_bytes]);
    try testing.expectEqual(last, @intFromPtr(loop.provided_buffer(group, count - 1).ptr));
}

test "a buffer a split datagram holds goes back to the group at its last event's give-back" {
    const options: Loop.Options = .{ .operations = 4, .entries = 4 };
    var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    loop.init_tables(&memory, &options);
    const count = 4;
    var group_memory: [group_bytes(count, 64)]u8 align(group_alignment) = undefined;
    const reserved = try reserve(&loop);
    try provide(&loop, reserved, &group_memory, count, 64);
    const group = &loop.groups[@intFromEnum(reserved)];
    const taken = group.take().?;
    // Three datagrams of one coalesced datagram name the buffer.
    core.buffer_group.hold(group.holders, taken, 3);
    give_back(&loop, reserved, taken);
    give_back(&loop, reserved, taken);
    try testing.expectEqual(@as(u16, count - 1), group.free_count);
    give_back(&loop, reserved, taken);
    try testing.expectEqual(@as(u16, count), group.free_count);
}

test "a reserved id is the caller's until the loop ends: a release keeps it, and a provide again" {
    const options: Loop.Options = .{ .operations = 4, .entries = 4 };
    var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    loop.init_tables(&memory, &options);
    const count = 4;
    var group_memory: [group_bytes(count, 64)]u8 align(group_alignment) = undefined;
    const first = try reserve(&loop);
    try testing.expectEqual(@as(u16, 0), @intFromEnum(first));
    try provide(&loop, first, &group_memory, count, 64);
    release(&loop, first);
    // The release gave the memory back and kept the id: the next reserve takes the next one.
    const second = try reserve(&loop);
    try testing.expectEqual(@as(u16, 1), @intFromEnum(second));
    try provide(&loop, first, &group_memory, count, 64);
    try testing.expectEqual(@as(u16, count), loop.groups[0].free_count);
    for (2..core.constants.buffer_groups_max) |_| _ = try reserve(&loop);
    try testing.expectError(error.BufferGroupsFull, reserve(&loop));
}
