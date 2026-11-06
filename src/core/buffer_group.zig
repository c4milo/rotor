//! Provided-buffer groups where the loop picks the buffer: kqueue (decision 12, point 4) and epoll
//! (decision 20). io_uring picks a buffer from a group itself, with the kernel's buffer ring. A
//! group is the caller's memory cut into equal buffers, with a stack of the ids that are free. A
//! receive from a group takes an id, receives into that buffer and names it in its event, and the
//! caller gives the id back when it has read the bytes.
//!
//! Every backend lays a group out the same way, the bookkeeping first and the buffers after it, so
//! a caller sizes one block for any of them: the memory that holds io_uring's buffer ring holds the
//! stack of free ids on the other two. The calls that take a `*Loop` (`register`, `provide` and
//! `give_back`) stay in each backend. What is here takes no loop and names no kernel type.
const std = @import("std");
const assert = std.debug.assert;
const assert_class_a = @import("assertion_class.zig").assert_class_a;
const constants = @import("constants.zig");
const SlotTable = @import("slot_table.zig").SlotTable;

pub const RegisterError = error{ SystemResources, Unexpected };

/// `Unsupported`: the kernel refused the buffer ring itself. io_uring answers EINVAL for that, and
/// for a misaligned ring and a count that is not a power of two; both of those are now assertions,
/// so what is left is a kernel that cannot do provided buffer rings at all. Before this the three
/// arrived as one `Unexpected`, and a consumer spent a day on the alignment one (2026-09-22).
///
/// kqueue and epoll never enter the kernel here and so never answer `Unsupported`. The set is the
/// same on every backend because a caller writes one handler for all of them (decision 1).
pub const ProvideError = error{ Unsupported, SystemResources, Unexpected };

/// The alignment of a group's memory: what io_uring's buffer ring needs, asked for on every backend
/// so one declaration in a caller's code serves them all.
pub const group_alignment = constants.buffer_ring_alignment;

/// The bytes of bookkeeping a group of `count` buffers needs: one io_uring buffer ring entry per
/// buffer, which is more than the two bytes per id kqueue and epoll use.
pub fn ring_bytes(count: u16) usize {
    assert(count >= 1);
    assert(std.math.isPowerOfTwo(count));
    return @as(usize, count) * constants.buffer_ring_entry_bytes;
}

/// The bytes of a group's holders: one byte per buffer, the events of a split datagram that still
/// name it, rounded up so the buffers that follow start on a ring entry (decision 15, amendment of
/// 2026-11-05).
pub fn holder_bytes(count: u16) usize {
    assert(count >= 1);
    return std.mem.alignForward(usize, count, constants.buffer_ring_entry_bytes);
}

/// Where buffer 0 starts: after the bookkeeping and the holders.
pub fn buffers_offset(count: u16) usize {
    return ring_bytes(count) + holder_bytes(count);
}

/// The bytes a group of `count` buffers of `buffer_bytes` needs: the bookkeeping, the holders,
/// then the buffers.
pub fn group_bytes(count: u16, buffer_bytes: u32) usize {
    assert(buffer_bytes >= 1);
    return buffers_offset(count) + @as(usize, count) * buffer_bytes;
}

/// Marks buffer `buffer_id` as named by `segments` events: the datagrams of one coalesced
/// datagram, which the loop hands over one event each. Each event's give-back counts one, and the
/// buffer goes back to its group at the last.
pub fn hold(holders: []u8, buffer_id: u16, segments: u32) void {
    assert(segments > 1);
    assert(segments <= constants.coalesced_segments_max);
    assert_class_a(holders[buffer_id] == 0);
    holders[buffer_id] = @intCast(segments);
}

/// One event's give-back of buffer `buffer_id`: true when the buffer goes back to its group now,
/// which is at once for a buffer no split holds and at the last event for one that a split holds.
pub fn release(holders: []u8, buffer_id: u16) bool {
    const held = holders[buffer_id];
    if (held <= 1) {
        holders[buffer_id] = 0;
        return true;
    }
    holders[buffer_id] = held - 1;
    return false;
}

/// Halts when an operation in flight names group `group_id`: what each backend's `release` checks
/// before the group's memory goes back to the caller (rotor issue 13). A slot names its group until
/// its final event is handed over and the slot is free. Decision 8, class D: it walks the whole
/// table, on a call a caller makes once per group.
pub fn assert_unused(table: *SlotTable, group_id: u16) void {
    assert(group_id < constants.buffer_groups_max);
    var index: u32 = 0;
    while (index < table.capacity()) : (index += 1) {
        const slot = table.at(index);
        if (slot.state == .free) continue;
        assert(!(slot.flags.buffer_group and slot.buffer_index == group_id));
    }
}

/// One provided-buffer group on a backend whose loop picks the buffer. `buffer_bytes` is 0 until
/// the group is provided.
pub const Group = struct {
    buffers: []u8,
    /// One count per buffer of the events of a split datagram that still name it (`hold`).
    holders: []u8,
    buffer_bytes: u32,
    count: u16,
    /// The ids of the free buffers. `free[0..free_count]` is the stack, its top at the end.
    free: []u16,
    free_count: u16,

    pub const none: Group = .{
        .buffers = &.{},
        .holders = &.{},
        .buffer_bytes = 0,
        .count = 0,
        .free = &.{},
        .free_count = 0,
    };

    /// A group of `count` buffers of `buffer_bytes` each, cut out of `memory` as `group_bytes`
    /// lays it out. Every buffer starts free, and the first `take` answers buffer 0, as io_uring's
    /// ring does.
    pub fn carve(memory: []align(group_alignment) u8, count: u16, buffer_bytes: u32) Group {
        // The free stack is read as `[*]u16`, so u16 alignment is what this needs, and not
        // `group_alignment`, which is io_uring's. Asserting the larger figure would refuse memory
        // these backends can use: macOS does not always give a static the alignment it declares. A
        // `[N]u8 align(64 KiB)` came back 16 KiB aligned on 2026-09-22, and `conformance_udp.zig`
        // declares exactly that. `uring_buffers.zig` asserts the full figure because its kernel
        // enforces it, which is where a caller who relied on the declaration finds out.
        assert(std.mem.isAligned(@intFromPtr(memory.ptr), @alignOf(u16)));
        assert(count >= 1);
        assert(count <= constants.buffers_per_group_max);
        assert(memory.len >= group_bytes(count, buffer_bytes));
        const free: [*]u16 = @ptrCast(memory.ptr);
        var group: Group = .{
            .buffers = memory[buffers_offset(count)..][0 .. @as(usize, count) * buffer_bytes],
            .holders = memory[ring_bytes(count)..][0..count],
            .buffer_bytes = buffer_bytes,
            .count = count,
            .free = free[0..count],
            .free_count = 0,
        };
        @memset(group.holders, 0);
        // Pushed in descending order, so the first receive takes buffer 0.
        for (0..count) |pushed| group.give_back(@intCast(count - 1 - pushed));
        assert(group.free_count == count);
        return group;
    }

    /// The bytes of buffer `buffer_id`.
    pub fn bytes_of(group: *const Group, buffer_id: u16) []u8 {
        assert_class_a(group.buffer_bytes != 0);
        assert_class_a(buffer_id < group.count);
        const start = @as(usize, buffer_id) * group.buffer_bytes;
        return group.buffers[start..][0..group.buffer_bytes];
    }

    /// Takes a free buffer's id, or null when every buffer is with the caller.
    pub fn take(group: *Group) ?u16 {
        assert_class_a(group.buffer_bytes != 0);
        if (group.free_count == 0) return null;
        group.free_count -= 1;
        return group.free[group.free_count];
    }

    pub fn give_back(group: *Group, buffer_id: u16) void {
        assert_class_a(buffer_id < group.count);
        assert_class_a(group.free_count < group.count);
        group.free[group.free_count] = buffer_id;
        group.free_count += 1;
    }
};

const testing = std.testing;

test "a group hands out every buffer once, lowest id first, and takes them back" {
    var memory: [64]u8 = undefined;
    var free: [4]u16 = undefined;
    var holders: [4]u8 = @splat(0);
    var group: Group = .{
        .buffers = &memory,
        .holders = &holders,
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

test "carve puts the buffers after the bookkeeping, and hands out buffer 0 first" {
    const count = 4;
    const buffer_bytes = 32;
    var memory: [group_bytes(count, buffer_bytes)]u8 align(group_alignment) = undefined;
    try testing.expectEqual(buffers_offset(count) + count * buffer_bytes, memory.len);
    var group = Group.carve(&memory, count, buffer_bytes);
    try testing.expectEqual(@as(u16, count), group.free_count);
    // Buffer 0 starts where the bookkeeping and the holders end, so a receive into it cannot
    // overwrite the free stack, and the last buffer ends where the memory does.
    const first = group.bytes_of(0);
    try testing.expectEqual(@intFromPtr(&memory[buffers_offset(count)]), @intFromPtr(first.ptr));
    try testing.expectEqual(@intFromPtr(&memory[ring_bytes(count)]), @intFromPtr(group.holders.ptr));
    const last = group.bytes_of(count - 1);
    try testing.expectEqual(@intFromPtr(&memory) + memory.len, @intFromPtr(last.ptr) + last.len);
    for (0..count) |expected| try testing.expectEqual(@as(?u16, @intCast(expected)), group.take());
    try testing.expectEqual(@as(?u16, null), group.take());
}

test "a held buffer goes back at its last event's give-back, and an unheld one at once" {
    var holders: [4]u8 = @splat(0);
    try testing.expect(release(&holders, 1));
    hold(&holders, 2, 3);
    try testing.expect(!release(&holders, 2));
    try testing.expect(!release(&holders, 2));
    try testing.expect(release(&holders, 2));
    try testing.expectEqual(@as(u8, 0), holders[2]);
}

test "the holders sit between the ring and the buffers, and the buffers start on a ring entry" {
    try testing.expectEqual(@as(usize, 16), holder_bytes(4));
    try testing.expectEqual(@as(usize, 64), holder_bytes(64));
    try testing.expectEqual(ring_bytes(4) + 16, buffers_offset(4));
    try testing.expectEqual(buffers_offset(4) + 4 * 512, group_bytes(4, 512));
}
