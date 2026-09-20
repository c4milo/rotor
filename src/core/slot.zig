//! `Slot`, the loop's record of one in-flight operation (decision 1): 64 bytes aligned to 64, one
//! cache line of the x86-64 servers rotor targets, so an operation touches one line from submit
//! to reap (decision 3, source 7). The loop owns a table of them; the caller holds a `Handle`.
//!
//! A slot holds the operation flattened: a backend reads fields at fixed offsets and never the
//! `Operation` union, and resubmits from the slot alone. `fill` is the one place that flattens,
//! with an exhaustive switch, so an operation kind added to `Operation.Kind` fails to compile
//! here first.
//!
//! Field order puts the 8-byte fields first and the 1-byte fields last, so the struct has no
//! padding between fields. The 2 spare bytes are declared, so adding a field is a decision.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const operation_module = @import("operation.zig");

const Operation = operation_module.Operation;

/// `heap_position` of a slot that has no entry in the timer heap.
pub const heap_position_none: u32 = std.math.maxInt(u32);

/// `next` of a slot that ends a list.
pub const next_none: u32 = std.math.maxInt(u32);

const reserved_bytes = 2;

pub const Slot = extern struct {
    /// The caller's value, copied into every event of the operation.
    user_data: u64 align(constants.slot_bytes),
    /// The buffer's address. For `connect`, the address of the `Address`. For `post`, the
    /// message's payload.
    buffer: u64,
    /// The file offset of a `read` or a `write`. For a `timer`, its delay in nanoseconds.
    offset: u64,
    /// The operation's deadline in nanoseconds from its submitting tick, or 0.
    timeout_ns: u64,
    /// The buffer's length. For `shutdown`, the `How`. For `post`, the message's tag.
    len: u32,
    /// The descriptor. For `post`, the target `LoopId`.
    descriptor: i32,
    /// Rises by one each time the slot is released; never 0 (`Handle.next_generation`).
    generation: u32,
    /// The next slot of the list this slot is on, or `next_none`: the free list while `free`, a
    /// backend's pending list otherwise.
    next: u32,
    /// Where the slot's deadline sits in the timer heap, or `heap_position_none`.
    heap_position: u32,
    /// The final event's result while the slot is `finishing`: the loop produced the result
    /// itself (a timer that fired, a cancel that won before the kernel saw the operation), and
    /// `tick` reads it here when it hands the event to the caller.
    result: i32,
    /// The registered buffer that contains the buffer, or the provided-buffer group, as `flags`
    /// says.
    buffer_index: u16,
    code: Operation.Code,
    state: State,
    flags: Flags,
    /// Times a backend resubmitted the operation, at most `constants.transfer_retries_max`.
    retries: u8,
    reserved: [reserved_bytes]u8,

    pub const State = enum(u8) {
        /// On the free list.
        free,
        /// Claimed, and not yet handed to the kernel.
        queued,
        /// The kernel holds the operation.
        submitted,
        /// The final event is queued in the loop and not yet reaped. The slot is released when
        /// `tick` hands that event to the caller (decision 5, rule 1).
        finishing,
    };

    pub const Flags = packed struct(u8) {
        multishot: bool = false,
        /// `cancel` named this operation and its final event has not been produced yet.
        cancel_requested: bool = false,
        /// The cancel in progress is the loop's own, for a deadline that passed: the final event
        /// says `timeout` and not `canceled`.
        timed_out: bool = false,
        /// `buffer_index` names a registered buffer.
        buffer_registered: bool = false,
        /// `buffer_index` names a provided-buffer group.
        buffer_group: bool = false,
        /// `descriptor` is an index into the descriptors the loop registered.
        descriptor_registered: bool = false,
        /// The loop is measuring this operation (decision 9, rule 2). Statistics never steer
        /// what the loop does: nothing reads this but the statistics themselves.
        sampled: bool = false,
        reserved: u1 = 0,
    };

    /// Flattens `operation` into a slot the table has just claimed. Leaves `generation` and
    /// `next` alone: they are the table's.
    pub fn fill(slot: *Slot, operation: *const Operation) void {
        assert(slot.state == .queued);
        assert(slot.generation >= constants.generation_first);
        slot.user_data = operation.user_data;
        slot.timeout_ns = operation.timeout_ns;
        slot.code = operation.code();
        slot.heap_position = heap_position_none;
        slot.flags = .{};
        slot.retries = 0;
        slot.result = 0;
        slot.buffer = 0;
        slot.offset = 0;
        slot.len = 0;
        slot.buffer_index = 0;
        slot.fill_kind(operation);
        slot.flags.descriptor_registered = operation.descriptor_registered;
        assert(slot.code == operation.code());
    }

    fn fill_kind(slot: *Slot, operation: *const Operation) void {
        switch (operation.kind) {
            .accept => |accept| {
                slot.descriptor = accept.listener;
                slot.flags.multishot = accept.multishot;
            },
            .connect => |connect| {
                slot.descriptor = connect.socket;
                slot.buffer = @intFromPtr(connect.address);
            },
            .receive => |receive| slot.fill_receive(receive),
            .send => |send| {
                slot.fill_transfer(send.socket, send.buffer.bytes, send.buffer.registered);
            },
            .shutdown => |shutdown| {
                slot.descriptor = shutdown.socket;
                slot.len = @intFromEnum(shutdown.how);
            },
            .close => |close| slot.descriptor = close.descriptor,
            .read => |read| {
                slot.fill_transfer(read.file, read.buffer.bytes, read.buffer.registered);
                slot.offset = read.offset;
            },
            .write => |write| {
                slot.fill_transfer(write.file, write.buffer.bytes, write.buffer.registered);
                slot.offset = write.offset;
            },
            .fdatasync => |fdatasync| slot.descriptor = fdatasync.file,
            .timer => |timer| {
                slot.descriptor = 0;
                slot.offset = timer.after_ns;
            },
            .nop => slot.descriptor = 0,
            .post => |post| {
                slot.descriptor = post.target;
                slot.buffer = post.message.payload;
                slot.len = post.message.tag;
            },
        }
    }

    fn fill_receive(slot: *Slot, receive: Operation.Receive) void {
        slot.flags.multishot = receive.multishot;
        switch (receive.target) {
            .buffer => |buffer| slot.fill_transfer(receive.socket, buffer.bytes, buffer.registered),
            .group => |group| {
                slot.descriptor = receive.socket;
                slot.buffer_index = group;
                slot.flags.buffer_group = true;
            },
        }
    }

    fn fill_transfer(
        slot: *Slot,
        descriptor: operation_module.Descriptor,
        transfer: []const u8,
        registered: ?u16,
    ) void {
        assert(transfer.len >= 1);
        assert(transfer.len <= constants.transfer_bytes_max);
        slot.descriptor = descriptor;
        slot.buffer = @intFromPtr(transfer.ptr);
        slot.len = @intCast(transfer.len);
        if (registered) |index| {
            assert(index < constants.registered_buffers_max);
            slot.buffer_index = index;
            slot.flags.buffer_registered = true;
        }
    }

    /// The bytes of a transfer, as the backend that performs it sees them.
    pub fn bytes(slot: *const Slot) []u8 {
        assert(slot.len >= 1);
        assert(slot.buffer != 0);
        const pointer: [*]u8 = @ptrFromInt(slot.buffer);
        return pointer[0..slot.len];
    }
};

comptime {
    assert(@sizeOf(Slot) == constants.slot_bytes);
    assert(@alignOf(Slot) == constants.slot_bytes);
    assert(@offsetOf(Slot, "user_data") == 0);
    // No padding between fields: the last field ends where the struct does.
    assert(@offsetOf(Slot, "reserved") + reserved_bytes == constants.slot_bytes);
    assert(@sizeOf(Slot.Flags) == 1);
}

const testing = std.testing;

fn claimed() Slot {
    var slot: Slot = std.mem.zeroes(Slot);
    slot.state = .queued;
    slot.generation = constants.generation_first;
    slot.next = next_none;
    return slot;
}

test "a slot is one 64-byte cache line with no padding" {
    try testing.expectEqual(64, @sizeOf(Slot));
    try testing.expectEqual(64, @alignOf(Slot));
    try testing.expectEqual(62, @offsetOf(Slot, "reserved"));
}

test "fill flattens a read: descriptor, buffer, length, offset, deadline, registration" {
    var buffer: [4096]u8 = undefined;
    var slot = claimed();
    slot.fill(&.{ .user_data = 0xFEED, .timeout_ns = constants.ns_per_ms, .kind = .{ .read = .{
        .file = 9,
        .buffer = .{ .bytes = &buffer, .registered = 3 },
        .offset = 8192,
    } } });
    try testing.expectEqual(Operation.Code.read, slot.code);
    try testing.expectEqual(@as(u64, 0xFEED), slot.user_data);
    try testing.expectEqual(@as(i32, 9), slot.descriptor);
    try testing.expectEqual(@intFromPtr(&buffer), slot.buffer);
    try testing.expectEqual(@as(u32, 4096), slot.len);
    try testing.expectEqual(@as(u64, 8192), slot.offset);
    try testing.expectEqual(constants.ns_per_ms, slot.timeout_ns);
    try testing.expectEqual(@as(u16, 3), slot.buffer_index);
    try testing.expect(slot.flags.buffer_registered and !slot.flags.buffer_group);
    try testing.expectEqual(heap_position_none, slot.heap_position);
    try testing.expectEqual(@as([]u8, &buffer).ptr, slot.bytes().ptr);
    try testing.expectEqual(constants.generation_first, slot.generation);
}

test "fill flattens a multishot receive from a group, a post and a timer" {
    var slot = claimed();
    slot.fill(&.{ .user_data = 1, .kind = .{ .receive = .{
        .socket = 4,
        .target = .{ .group = 2 },
        .multishot = true,
    } } });
    try testing.expect(slot.flags.multishot and slot.flags.buffer_group);
    try testing.expectEqual(@as(u16, 2), slot.buffer_index);
    try testing.expectEqual(@as(u32, 0), slot.len);

    slot = claimed();
    slot.fill(&.{ .user_data = 2, .kind = .{ .post = .{
        .target = 5,
        .message = .{ .payload = 0xABCD, .tag = 77 },
    } } });
    try testing.expectEqual(@as(i32, 5), slot.descriptor);
    try testing.expectEqual(@as(u64, 0xABCD), slot.buffer);
    try testing.expectEqual(@as(u32, 77), slot.len);

    slot = claimed();
    slot.fill(&.{ .user_data = 3, .kind = .{ .timer = .{ .after_ns = constants.ns_per_s } } });
    try testing.expectEqual(constants.ns_per_s, slot.offset);
    try testing.expect(!slot.flags.multishot);
}

test "fill clears what the slot's last operation left behind" {
    var buffer: [16]u8 = undefined;
    var slot = claimed();
    slot.fill(&.{ .user_data = 1, .descriptor_registered = true, .kind = .{ .send = .{
        .socket = 4,
        .buffer = .{ .bytes = &buffer, .registered = 1 },
    } } });
    // The descriptor field holds the index, and the flag says so.
    try testing.expect(slot.flags.descriptor_registered and slot.flags.buffer_registered);
    try testing.expectEqual(@as(i32, 4), slot.descriptor);
    slot.retries = 5;
    slot.flags.cancel_requested = true;
    slot.fill(&.{ .user_data = 2, .kind = .{ .fdatasync = .{ .file = 6 } } });
    try testing.expectEqual(@as(u64, 0), slot.buffer);
    try testing.expectEqual(@as(u32, 0), slot.len);
    try testing.expectEqual(@as(u8, 0), slot.retries);
    try testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(slot.flags)));
}
