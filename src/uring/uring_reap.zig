//! The reap path: a completion entry in, an event out. `complete` enters no kernel, so a test
//! hands it completion entries it built itself, in any order the kernel may produce, on every
//! host (decision 10).
//!
//! An operation that succeeded takes the first branch of `complete` and nothing else: one slot
//! line read, one event written, the slot released when the completion is its last. Errors,
//! posted messages and the completions the backend consumes itself all have a result below zero
//! or a generation of zero, and leave the straight path at one of two compares.
//!
//! One of the six hot files decision 7 names. This is the plain version: no technique of that
//! decision's list is used, and docs/hot-path-ledger.md has no row for this file.
const std = @import("std");
const assert = std.debug.assert;
const assert_class_a = core.assertion_class.assert_class_a;
const linux = std.os.linux;
const core = @import("core");
const constants = @import("constants.zig");
const errno_module = @import("uring_errno.zig");
const uring = @import("uring.zig");
const group_wake = @import("uring_group.zig");
const shared_datagram = @import("linux_shared").datagram;

const Loop = uring.Loop;
const Event = core.Event;
const Handle = core.Handle;
const Slot = core.Slot;

/// The kernel's flag bits an event carries unchanged: `core.Event.Flags` puts `buffer`, `more`
/// and `buffer_id` where io_uring puts them, so the reap masks and does not re-encode.
const flags_passed: u32 = linux.IORING_CQE_F_BUFFER | linux.IORING_CQE_F_MORE |
    (buffer_id_mask << linux.IORING_CQE_BUFFER_SHIFT);
const buffer_id_mask: u32 = std.math.maxInt(u16);

comptime {
    const Flags = Event.Flags;
    assert(@as(u32, 1) << @bitOffsetOf(Flags, "buffer") == linux.IORING_CQE_F_BUFFER);
    assert(@as(u32, 1) << @bitOffsetOf(Flags, "more") == linux.IORING_CQE_F_MORE);
    assert(@bitOffsetOf(Flags, "buffer_id") == linux.IORING_CQE_BUFFER_SHIFT);
    assert(@sizeOf(linux.io_uring_cqe) == @sizeOf(Event));
}

/// Turns the completions the kernel has posted into events, oldest first, until `events` is full
/// or none is left. A completion that yields no event, a cancel's answer or an operation being
/// resubmitted, is consumed all the same. Returns the events written.
///
/// A coalesced datagram goes over as one event per datagram (decision 15, amendment of 2026-11-05).
/// The events that do not fit wait in `loop.split`, and the next reap hands them over first.
pub fn reap(loop: *Loop, events: []Event) u32 {
    var produced: u32 = 0;
    // Read only while a split waits, so a reap with none touches nothing of it.
    if (loop.split.pending()) {
        produced = loop.split.take(events);
        if (loop.split.pending()) return produced;
    }
    const ready = loop.ring.cq_ready();
    var consumed: u32 = 0;
    while (consumed < ready and produced < events.len) : (consumed += 1) {
        const event = complete(loop, loop.ring.cqe_at(consumed)) orelse continue;
        // Only an event that names a buffer can have begun a split, and the bit is in hand.
        if (event.flags.buffer and loop.split.pending()) {
            produced += loop.split.take(events[produced..]);
        } else {
            events[produced] = event;
            produced += 1;
        }
    }
    loop.ring.cq_advance(consumed);
    assert(produced <= events.len);
    return produced;
}

/// The event one completion entry yields, or null when it yields none.
pub fn complete(loop: *Loop, cqe: *const linux.io_uring_cqe) ?Event {
    if (cqe.res < 0) return complete_negative(loop, cqe);
    const handle = Handle.from_bits(cqe.user_data);
    // A completion that names no operation is one the backend submitted for itself.
    if (handle.is_none()) return own(loop, cqe);
    const slot = submitted_slot(loop, handle);
    var event: Event = .{
        .user_data = slot.user_data,
        // A datagram's completion counts the prefix in front of it too, so the result the caller
        // sees is the count less a constant the group fixed (decision 15). The probe measured
        // that `cqe.res` less the prefix is exactly the payload length.
        .result = if (slot.code == .receive_from) cqe.res - loop.datagram_prefix else cqe.res,
        .flags = @bitCast(cqe.flags & flags_passed),
    };
    event.flags.dispatched = slot.flags.dispatched;
    if (!event.flags.more) loop.tables.finish(handle.index, slot);
    if (event.flags.buffer and slot.code == .receive_from) begin_split(loop, slot.buffer_index, event);
    return event;
}

/// Starts splitting `event` when its buffer holds a coalesced datagram: the kernel wrote the
/// datagrams' size into the control block in front of them.
fn begin_split(loop: *Loop, group_id: u16, event: Event) void {
    const group = &loop.groups[group_id];
    const buffer = group.bytes_of(event.flags.buffer_id);
    const segment_bytes = shared_datagram.segment_bytes_of(buffer, loop.datagram_shape.options);
    _ = loop.split.begin(event, segment_bytes, group.holders);
}

/// A completion of an entry the backend submitted for itself, which yields no event. The read of a
/// group's eventfd is noted, so the next flush queues it again (decision 21, point 3), and so is the
/// wait timer's (decision 6, amended 2026-09-27).
fn own(loop: *Loop, cqe: *const linux.io_uring_cqe) ?Event {
    if (cqe.user_data == constants.user_data_group_wake) group_wake.completed(loop, cqe.res);
    // The wait timer fired, or was cancelled with the ring: either way it is no longer armed.
    if (cqe.user_data == constants.user_data_wait_timer) loop.wait_timer_deadline_ns = 0;
    return null;
}

/// The slot a completion's handle names. It still holds that operation: its final event has not
/// been handed over, so its generation has not moved.
fn submitted_slot(loop: *Loop, handle: Handle) *Slot {
    const slot = loop.tables.table.at(handle.index);
    assert_class_a(slot.generation == handle.generation);
    assert_class_a(slot.state == .submitted);
    return slot;
}

/// A result below zero: a completion the backend consumes, or an operation that failed. Kept out
/// of `complete` so the path of a success stays short.
fn complete_negative(loop: *Loop, cqe: *const linux.io_uring_cqe) ?Event {
    assert(cqe.res < 0);
    const handle = Handle.from_bits(cqe.user_data);
    if (handle.is_none()) return own(loop, cqe);
    const slot = submitted_slot(loop, handle);
    const errno = errno_module.errno_of(cqe.res);
    if (should_retry(slot, errno)) {
        slot.retries += 1;
        loop.tables.requeue(handle.index);
        return null;
    }
    var code = errno_module.code_of(errno, .{ .from_group = slot.flags.buffer_group });
    // An operation that a cancel is waiting for, and that the kernel ended having transferred
    // nothing, was cancelled as far as its caller can tell: EAGAIN and EINTR are not retried
    // once a cancel is asked for, and they are not the caller's to interpret.
    if (slot.flags.cancel_requested and errno_module.is_retryable(errno)) code = .canceled;
    // The kernel reports a cancel the same way whoever asked. When the loop asked, because the
    // operation's deadline passed, the caller hears `timeout` (decision 5, rule 4).
    if (code == .canceled and slot.flags.timed_out) code = .timeout;
    var event = Event.failure(slot.user_data, code);
    event.flags.dispatched = slot.flags.dispatched;
    event.flags.more = cqe.flags & linux.IORING_CQE_F_MORE != 0;
    if (!event.flags.more) loop.tables.finish(handle.index, slot);
    return event;
}

/// EAGAIN and EINTR transferred nothing, so the operation goes back on the pending list, unless
/// it ran out of retries or a cancel is waiting for it.
fn should_retry(slot: *const Slot, errno: linux.E) bool {
    if (!errno_module.is_retryable(errno)) return false;
    if (slot.flags.cancel_requested) return false;
    return slot.retries < core.constants.transfer_retries_max;
}
