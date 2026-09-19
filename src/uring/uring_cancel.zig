//! Cancellation (decision 5). `cancel` is a request: it marks the slot, and the target's final
//! event is the answer. What the request costs depends on where the operation is:
//!
//! - Queued, not yet handed to the kernel: `flush` of the submit path finishes it, and the
//!   kernel never sees it.
//! - A timer: it lives in the loop's own heap, so the cancel is synchronous and has no race.
//! - Held by the kernel: the handle waits in `HandleQueue` for a submission entry, and the
//!   kernel's completion for the target says who won.
//!
//! The queue holds handles and not slot links, because the target can finish, and its slot can
//! be claimed again, before the cancel gets its entry. A handle that went stale is skipped.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const submit_module = @import("uring_submit.zig");
const uring = @import("uring.zig");

const Loop = uring.Loop;
const Handle = core.Handle;
const Slot = core.Slot;

/// Handles per slot the queue has room for. Between two flushes the queue can hold one handle
/// left over from the last flush, whose target has since finished, and one new handle for the
/// operation that claimed the same slot, for every slot of the table.
pub const handles_per_slot = 2;

/// A bounded first-in first-out queue of handles over memory the loop's caller handed in. Its
/// capacity is a power of two, so the wrap is a mask.
pub const HandleQueue = struct {
    handles: []Handle,
    head: u32,
    count: u32,

    pub fn init(queue: *HandleQueue, handles: []Handle) void {
        assert(handles.len >= 1);
        assert(std.math.isPowerOfTwo(handles.len));
        queue.* = .{ .handles = handles, .head = 0, .count = 0 };
    }

    /// The capacity a table of `operations` slots needs.
    pub fn capacity_for(operations: u32) u32 {
        assert(operations >= 1);
        assert(operations <= core.constants.operations_max);
        return std.math.ceilPowerOfTwoAssert(u32, operations * handles_per_slot);
    }

    pub fn push(queue: *HandleQueue, handle: Handle) void {
        assert(!handle.is_none());
        assert(queue.count < queue.handles.len);
        const mask: u32 = @intCast(queue.handles.len - 1);
        queue.handles[(queue.head +% queue.count) & mask] = handle;
        queue.count += 1;
    }

    pub fn pop(queue: *HandleQueue) ?Handle {
        if (queue.count == 0) return null;
        const mask: u32 = @intCast(queue.handles.len - 1);
        const handle = queue.handles[queue.head & mask];
        queue.head +%= 1;
        queue.count -= 1;
        assert(!handle.is_none());
        return handle;
    }
};

/// Asks for the operation `handle` names to be cancelled. A handle whose operation has had its
/// final event names nothing, and that is legal: the caller cannot avoid the race between a
/// reap and a cancel (decision 5, rule 2).
pub fn cancel(loop: *Loop, handle: Handle) void {
    const slot = loop.tables.cancellable(handle) orelse return;
    request(loop, handle.index, slot);
}

/// Marks `slot` for cancellation. `core.Tables` ends what it can end itself, a timer or a slot
/// still queued; an operation the kernel holds gets its handle queued for a cancel entry. The
/// loop calls this itself when a deadline passes, with `flags.timed_out` already set.
pub fn request(loop: *Loop, index: u32, slot: *Slot) void {
    if (loop.tables.request_cancel(index, slot) != .backend) return;
    assert(slot.state == .submitted);
    loop.cancels.push(loop.tables.table.handle_of(index));
}

/// Gives every waiting cancel a submission entry, oldest first. A handle gone stale is dropped.
/// A cancel that finds the submission ring full goes back to the end of the queue, so one pass
/// leaves only handles whose operations the kernel still holds.
pub fn flush(loop: *Loop) void {
    const queued = loop.cancels.count;
    var visited: u32 = 0;
    while (visited < queued) : (visited += 1) {
        const handle = loop.cancels.pop().?;
        const slot = loop.tables.table.lookup(handle) orelse continue;
        if (slot.state != .submitted) continue;
        assert(slot.flags.cancel_requested);
        if (loop.ring.get_sqe()) |sqe| {
            submit_module.prepare_cancel(sqe, handle.to_bits());
        } else {
            loop.cancels.push(handle);
        }
    }
    assert(loop.cancels.count <= queued);
}

const testing = std.testing;

test "handles leave the queue in the order they joined it, across the wrap" {
    var storage: [4]Handle = undefined;
    var queue: HandleQueue = undefined;
    queue.init(&storage);
    try testing.expectEqual(@as(?Handle, null), queue.pop());
    for (1..4) |index| queue.push(.{ .index = @intCast(index), .generation = 1 });
    try testing.expectEqual(@as(u32, 1), queue.pop().?.index);
    try testing.expectEqual(@as(u32, 2), queue.pop().?.index);
    for (4..7) |index| queue.push(.{ .index = @intCast(index), .generation = 1 });
    try testing.expectEqual(@as(u32, 4), queue.count);
    for (3..7) |index| try testing.expectEqual(@as(u32, @intCast(index)), queue.pop().?.index);
    try testing.expectEqual(@as(?Handle, null), queue.pop());
}

test "the queue's capacity is a power of two with two handles of room per slot" {
    try testing.expectEqual(@as(u32, 2), HandleQueue.capacity_for(1));
    try testing.expectEqual(@as(u32, 8), HandleQueue.capacity_for(3));
    try testing.expectEqual(@as(u32, 2048), HandleQueue.capacity_for(1024));
}
