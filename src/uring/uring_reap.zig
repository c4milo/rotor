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
const linux = std.os.linux;
const core = @import("core");
const constants = @import("constants.zig");
const errno_module = @import("uring_errno.zig");
const uring = @import("uring.zig");

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
pub fn reap(loop: *Loop, events: []Event) u32 {
    const ready = loop.ring.cq_ready();
    var consumed: u32 = 0;
    var produced: u32 = 0;
    while (consumed < ready and produced < events.len) : (consumed += 1) {
        if (complete(loop, loop.ring.cqe_at(consumed))) |event| {
            events[produced] = event;
            produced += 1;
        }
    }
    loop.ring.cq_advance(consumed);
    assert(produced <= consumed);
    return produced;
}

/// The event one completion entry yields, or null when it yields none.
pub fn complete(loop: *Loop, cqe: *const linux.io_uring_cqe) ?Event {
    if (cqe.res < 0) return complete_negative(loop, cqe);
    const handle = Handle.from_bits(cqe.user_data);
    // A completion that names no operation is one the backend submitted for itself.
    if (handle.is_none()) return null;
    const slot = submitted_slot(loop, handle);
    const event: Event = .{
        .user_data = slot.user_data,
        // A datagram's completion counts the prefix in front of it too, so the result the caller
        // sees is the count less a constant the group fixed (decision 15). The probe measured
        // that `cqe.res` less the prefix is exactly the payload length.
        .result = if (slot.code == .receive_from) cqe.res - loop.datagram_prefix else cqe.res,
        .flags = @bitCast(cqe.flags & flags_passed),
    };
    if (!event.flags.more) loop.tables.finish(handle.index, slot);
    return event;
}

/// The slot a completion's handle names. It still holds that operation: its final event has not
/// been handed over, so its generation has not moved.
fn submitted_slot(loop: *Loop, handle: Handle) *Slot {
    const slot = loop.tables.table.at(handle.index);
    assert(slot.generation == handle.generation);
    assert(slot.state == .submitted);
    return slot;
}

/// A result below zero: a message another loop posted, a completion the backend consumes, or an
/// operation that failed. Kept out of `complete` so the path of a success stays short.
fn complete_negative(loop: *Loop, cqe: *const linux.io_uring_cqe) ?Event {
    assert(cqe.res < 0);
    if (cqe.res < -constants.errno_max) return message_of(cqe);
    const handle = Handle.from_bits(cqe.user_data);
    if (handle.is_none()) return null;
    const slot = submitted_slot(loop, handle);
    const errno = errno_module.errno_of(cqe.res);
    if (should_retry(slot, errno)) {
        slot.retries += 1;
        loop.tables.requeue(handle.index);
        return null;
    }
    var code = errno_module.code_of(errno, .{
        .from_group = slot.flags.buffer_group,
        .is_post = slot.code == .post,
    });
    // An operation that a cancel is waiting for, and that the kernel ended having transferred
    // nothing, was cancelled as far as its caller can tell: EAGAIN and EINTR are not retried
    // once a cancel is asked for, and they are not the caller's to interpret.
    if (slot.flags.cancel_requested and errno_module.is_retryable(errno)) code = .canceled;
    // The kernel reports a cancel the same way whoever asked. When the loop asked, because the
    // operation's deadline passed, the caller hears `timeout` (decision 5, rule 4).
    if (code == .canceled and slot.flags.timed_out) code = .timeout;
    var event = Event.failure(slot.user_data, code);
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

/// A result below every errno is a message: the sender set the top bit of the tag
/// (`constants.message_result_flag`) and put the payload in `user_data`.
fn message_of(cqe: *const linux.io_uring_cqe) Event {
    const bits: u32 = @bitCast(cqe.res);
    assert(bits & constants.message_result_flag != 0);
    const tag = bits & ~constants.message_result_flag;
    assert(tag <= core.constants.message_tag_max);
    return .{
        .user_data = cqe.user_data,
        .result = @intCast(tag),
        .flags = .{ .message = true },
    };
}
