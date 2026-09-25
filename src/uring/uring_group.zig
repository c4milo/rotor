//! The wake of a loop in a group on io_uring (decision 21, point 3). Outside a group a sender wakes
//! a loop with an `IORING_OP_MSG_RING` to its ring, and no other process can do that without the
//! ring's descriptor. In a group every loop is woken through the eventfd its group's creator made
//! for it (`linux_shared_group.zig`), which every process of the group holds:
//!
//! - a sender writes one to the eventfd with `write(2)`, which has happened when the call returns;
//! - the loop keeps a poll of its eventfd in its ring, so a write ends the loop's wait, and when the
//!   poll completes it reads the count back to zero and queues the poll again.
//!
//! A write or a read of the eventfd queued in a ring was tried first, on 2026-09-25, and lost wakes:
//! a sender that exited right after its enter could leave its write to a kernel worker that its exit
//! cancelled, and the conformance scenario of a post to a loop that sleeps failed. A poll takes no
//! kernel worker.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const constants = @import("constants.zig");
const uring = @import("uring.zig");

const Loop = uring.Loop;
const group = @import("linux_shared").group;

/// Keeps the poll of the loop's eventfd in the ring: queues it again once the last one completed.
/// A ring with no room leaves it for the next flush, and the tick does not block until it is in.
pub fn arm(loop: *Loop) void {
    if (loop.group_wake < 0 or loop.group_wake_armed) return;
    const sqe = loop.ring.get_sqe() orelse return;
    sqe.prep_poll_add(loop.group_wake, linux.POLL.IN);
    sqe.user_data = constants.user_data_group_wake;
    loop.group_wake_armed = true;
}

/// True while the loop is in a group and the poll of its eventfd is not in the ring: a wait now
/// could miss a wake.
pub fn unarmed(loop: *const Loop) bool {
    return loop.group_wake >= 0 and !loop.group_wake_armed;
}

/// The reap saw the poll of the eventfd complete. It is no longer in the ring. When it reported the
/// eventfd readable, the loop empties the count, or the next poll would complete at once.
pub fn completed(loop: *Loop, result: i32) void {
    assert(loop.group_wake >= 0);
    assert(loop.group_wake_armed);
    loop.group_wake_armed = false;
    if (result > 0) group.drain(loop.group_wake);
}
