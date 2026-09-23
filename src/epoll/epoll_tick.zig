//! `tick`: one turn of the loop. In order: read the clock once, try the queued operations and
//! register the ones that must wait, finish the timers that are due and end the operations whose
//! deadline passed, hand over the events the loop produced itself and the messages other loops
//! posted, make the one `epoll_pwait2` call, and perform what became ready.
//!
//! This is `kqueue_tick.zig` less two things. There is no changelist to carry into the wait,
//! because the flush registered each descriptor as it went. And there is no poll trigger: macOS
//! parks a `kevent` that finds nothing ready for about 12 µs even with a zero timeout, and the
//! trigger is how the kqueue backend avoids that. Whether Linux's `epoll_pwait2` does anything like
//! it has not been measured, so this file does not work around it; `conformance_cost.zig`'s poll
//! bound is what would say so.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");
const constants = @import("constants.zig");
const cancel_module = @import("epoll_cancel.zig");
const queue_module = @import("epoll_queue.zig");
const reap_module = @import("epoll_reap.zig");
const offload_module = @import("epoll_offload.zig");
const submit_module = @import("epoll_submit.zig");
const epoll = @import("epoll.zig");

const Loop = epoll.Loop;
const Event = core.Event;

pub const TickError = queue_module.WaitError;

/// Writes up to `events.len` events and returns how many. With `wait_ns` above 0 and nothing to
/// hand over at once, blocks until a descriptor is ready, a message arrives, the nearest deadline
/// passes, or the wait does.
pub fn tick(loop: *Loop, events: []Event, wait_ns: u64) TickError!u32 {
    const tables = &loop.tables;
    tables.begin_tick(events.len, wait_ns);
    tables.now_ns = clock_ns();
    submit_module.flush(loop);
    loop.tables.expire(loop, cancel_module.request);
    // Before the finished list is drained, so a result a worker pushed becomes its operation's
    // final event in this tick and not the next (decision 18).
    _ = offload_module.drain(loop);
    var produced = tables.drain_finished(events);
    produced += loop.drain_mailboxes(events[produced..]);

    const wait = if (produced == 0) loop.settle_to_sleep(tables.wait_bound(wait_ns)) else null;
    const room = @min(events.len - produced, constants.readiness_max);
    // A tick whose events are already full asks the kernel nothing: what is ready now is ready at
    // the next tick too, because every registration is level triggered.
    const nothing: TickError!u32 = 0;
    const readiness = loop.readiness[0..room];
    const ready = if (room == 0) nothing else loop.queue.wait(readiness, wait orelse 0);
    loop.wake_up();
    const ready_count = try ready;

    produced += reap_module.reap(loop, loop.readiness[0..ready_count], events[produced..]);
    // A worker may have answered while this tick waited, and the wake is what ended the wait.
    if (offload_module.drain(loop) != 0) {
        produced += tables.drain_finished(events[produced..]);
    }
    produced += loop.drain_mailboxes(events[produced..]);
    if (produced == 0 and wait != null) {
        // The wait may have ended because a deadline came due.
        tables.now_ns = clock_ns();
        loop.tables.expire(loop, cancel_module.request);
        produced += tables.drain_finished(events[produced..]);
    }
    assert(produced <= events.len);
    return produced;
}

/// The monotonic clock, in nanoseconds. Read once per tick, and once more after a wait that
/// produced nothing (decision 9, rule 4). `epoll_testing.zig` hands it to the tests, so a test
/// measures with the clock the tick reads.
pub fn clock_ns() u64 {
    var now: linux.timespec = undefined;
    const rc = linux.clock_gettime(.MONOTONIC, &now);
    assert(linux.errno(rc) == .SUCCESS);
    assert(now.sec >= 0);
    const seconds: u64 = @intCast(now.sec);
    const nanoseconds: u64 = @intCast(now.nsec);
    return seconds * core.constants.ns_per_s + nanoseconds;
}
