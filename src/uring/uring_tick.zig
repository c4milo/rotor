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
    const tables = &loop.tables;
    tables.begin_tick(events.len, wait_ns);
    tables.now_ns = clock_ns();
    submit_module.flush(loop);
    expire(loop);
    cancel_module.flush(loop);
    var produced = tables.drain_finished(events);
    const wait = if (produced == 0) wait_for(loop, wait_ns) else null;
    const entered = try loop.ring.enter(wait);
    // The kernel has read every address of this flush's connects, and every message header of
    // its datagram operations, unless it took no entry. Both scratches are one per entry and are
    // reused from the start each tick; a counter that only rose would stop the loop after
    // `entries` datagrams, which is what `bench/datagram/rotor_datagram.zig` found.
    if (entered == .submitted) {
        loop.addresses_used = 0;
        loop.messages_used = 0;
    }
    produced += reap_module.reap(loop, events[produced..]);
    if (produced == 0 and wait != null) {
        // The wait may have ended because a deadline came due.
        tables.now_ns = clock_ns();
        expire(loop);
        produced += tables.drain_finished(events[produced..]);
    }
    assert(produced <= events.len);
    return produced;
}

/// How long the enter may block: not at all while a cancel waits for its entry, and otherwise
/// what `core.Tables` allows.
fn wait_for(loop: *const Loop, wait_ns: u64) ?u64 {
    if (loop.cancels.count != 0) return null;
    return loop.tables.wait_bound(wait_ns);
}

/// Finishes every timer that is due, and asks for the cancel of every operation whose deadline
/// passed (decision 5, rule 4). At most the heap's entries can be due, which bounds the loop.
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
    var now: linux.timespec = undefined;
    const rc = linux.clock_gettime(.MONOTONIC, &now);
    assert(linux.errno(rc) == .SUCCESS);
    assert(now.sec >= 0);
    const seconds: u64 = @intCast(now.sec);
    const nanoseconds: u64 = @intCast(now.nsec);
    return seconds * core.constants.ns_per_s + nanoseconds;
}
