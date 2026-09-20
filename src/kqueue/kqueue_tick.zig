//! `tick`: one turn of the loop. In order: read the clock once, try the queued operations and
//! register the ones that must wait, finish the timers that are due and end the operations whose
//! deadline passed, hand over the events the loop produced itself and the messages other loops
//! posted, make the one `kevent` call, and perform what became ready.
//!
//! "One system call per tick" is not claimed here (decision 12, point 1): every transfer is its
//! own call. The one `kevent` call carries the tick's registrations in and its readiness out.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const constants = @import("constants.zig");
const cancel_module = @import("kqueue_cancel.zig");
const queue_module = @import("kqueue_queue.zig");
const reap_module = @import("kqueue_reap.zig");
const submit_module = @import("kqueue_submit.zig");
const kqueue = @import("kqueue.zig");

const Loop = kqueue.Loop;
const Event = core.Event;

pub const TickError = queue_module.ExchangeError;

/// Writes up to `events.len` events and returns how many. With `wait_ns` above 0 and nothing to
/// hand over at once, blocks until a descriptor is ready, a message arrives, the nearest deadline
/// passes, or the wait does.
pub fn tick(loop: *Loop, events: []Event, wait_ns: u64) TickError!u32 {
    const tables = &loop.tables;
    tables.assert_owner();
    assert(events.len >= 1);
    assert(events.len <= core.constants.batch_max);
    tables.now_ns = clock_ns();
    submit_module.flush(loop);
    expire(loop);
    var produced = tables.drain_finished(events);
    produced += loop.drain_mailboxes(events[produced..]);

    const wait = if (produced == 0) loop.settle_to_sleep(tables.wait_bound(wait_ns)) else null;
    const room = @min(events.len - produced, constants.readiness_max);
    const changes = loop.changes[0..loop.changes_used];
    const ready = loop.queue.exchange(changes, loop.readiness[0..room], wait);
    loop.changes_used = 0;
    loop.wake_up();
    const ready_count = try ready;

    produced += reap_module.reap(loop, loop.readiness[0..ready_count], events[produced..]);
    produced += loop.drain_mailboxes(events[produced..]);
    if (produced == 0 and wait != null) {
        // The wait may have ended because a deadline came due.
        tables.now_ns = clock_ns();
        expire(loop);
        produced += tables.drain_finished(events[produced..]);
    }
    assert(produced <= events.len);
    return produced;
}

/// Finishes every timer that is due, and ends every operation whose deadline passed with
/// `timeout` (decision 5, rule 4). At most the heap's entries can be due, which bounds the loop.
fn expire(loop: *Loop) void {
    const armed = loop.tables.timers.count;
    var expired: u32 = 0;
    while (expired < armed) : (expired += 1) {
        const index = loop.tables.next_expired() orelse break;
        cancel_module.request(loop, index, loop.tables.table.at(index));
    }
    assert(loop.tables.timers.count <= armed);
}

/// The monotonic clock, in nanoseconds. Read once per tick, and once more after a wait that
/// produced nothing (decision 9, rule 4).
fn clock_ns() u64 {
    var now: std.c.timespec = undefined;
    const rc = std.c.clock_gettime(.MONOTONIC, &now);
    assert(rc == 0);
    assert(now.sec >= 0);
    const seconds: u64 = @intCast(now.sec);
    const nanoseconds: u64 = @intCast(now.nsec);
    return seconds * core.constants.ns_per_s + nanoseconds;
}
