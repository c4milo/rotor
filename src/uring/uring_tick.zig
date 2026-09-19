//! `tick`: one turn of the loop, and the one system call it makes (decision 3, source 4). In
//! order: read the clock once, hand queued operations to the kernel, finish the timers that are
//! due and cancel the operations whose deadline passed, give waiting cancels their entries, hand
//! the caller the events the loop produced itself, enter the kernel, and reap.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");
const cancel_module = @import("uring_cancel.zig");
const reap_module = @import("uring_reap.zig");
const ring_module = @import("uring_ring.zig");
const submit_module = @import("uring_submit.zig");
const uring = @import("uring.zig");

const Loop = uring.Loop;
const Event = core.Event;

pub const TickError = ring_module.EnterError;

/// Writes up to `events.len` events and returns how many. With `wait_ns` above 0 and nothing to
/// hand over at once, blocks until a completion arrives, the nearest deadline passes, or the
/// wait does.
pub fn tick(loop: *Loop, events: []Event, wait_ns: u64) TickError!u32 {
    loop.assert_owner();
    assert(events.len >= 1);
    assert(events.len <= core.constants.batch_max);
    assert(wait_ns <= core.constants.wait_ns_max);
    loop.now_ns = clock_ns();
    submit_module.flush(loop);
    expire(loop);
    cancel_module.flush(loop);
    var produced = drain_finished(loop, events);
    const wait = if (produced == 0) wait_for(loop, wait_ns) else null;
    const entered = try loop.ring.enter(wait);
    // The kernel has read every address of this flush's connects, unless it took no entry.
    if (entered == .submitted) loop.addresses_used = 0;
    produced += reap_module.reap(loop, events[produced..]);
    if (produced == 0 and wait != null) {
        // The wait may have ended because a deadline came due.
        loop.now_ns = clock_ns();
        expire(loop);
        produced += drain_finished(loop, events[produced..]);
    }
    assert(produced <= events.len);
    return produced;
}

/// How long the enter may block: not at all while work the next tick must submit is waiting,
/// and never past the nearest deadline.
fn wait_for(loop: *const Loop, wait_ns: u64) ?u64 {
    if (wait_ns == 0) return null;
    if (loop.pending.count != 0 or loop.cancels.count != 0) return null;
    const earliest = loop.timers.earliest_ns() orelse return wait_ns;
    if (earliest <= loop.now_ns) return null;
    return @min(wait_ns, earliest - loop.now_ns);
}

/// Finishes every timer that is due, and asks for the cancel of every operation whose deadline
/// passed (decision 5, rule 4). At most the heap's entries can be due, which bounds the loop.
fn expire(loop: *Loop) void {
    const armed = loop.timers.count;
    var fired: u32 = 0;
    while (fired < armed) : (fired += 1) {
        const index = loop.timers.pop_due(loop.now_ns) orelse break;
        const slot = loop.table.at(index);
        assert(slot.state == .submitted);
        if (slot.code == .timer) {
            loop.finish_local(index, 0);
        } else {
            slot.flags.timed_out = true;
            cancel_module.request(loop, index, slot);
        }
    }
    assert(loop.timers.count <= armed);
}

/// Hands the caller the final events the loop produced itself, oldest first, and releases their
/// slots: the moment decision 5, rule 1 names.
fn drain_finished(loop: *Loop, events: []Event) u32 {
    var produced: u32 = 0;
    while (produced < events.len) : (produced += 1) {
        const index = loop.finished.pop(loop.table.slots) orelse break;
        const slot = loop.table.at(index);
        assert(slot.state == .finishing);
        events[produced] = .{ .user_data = slot.user_data, .result = slot.result, .flags = .{} };
        loop.table.release(index);
    }
    assert(produced <= events.len);
    return produced;
}

/// The monotonic clock, in nanoseconds. Read once per tick, and once more after a wait that
/// produced nothing (decision 9, rule 4).
fn clock_ns() u64 {
    var now: linux.timespec = undefined;
    const rc = linux.clock_gettime(.MONOTONIC, &now);
    assert(linux.errno(rc) == .SUCCESS);
    assert(now.sec >= 0);
    const seconds: u64 = @intCast(now.sec);
    const nanoseconds: u64 = @intCast(now.nsec);
    return seconds * core.constants.ns_per_s + nanoseconds;
}
