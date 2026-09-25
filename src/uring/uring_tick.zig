//! `tick`: one turn of the loop, and the one system call it makes (decision 3, source 4). In
//! order: read the clock once, hand queued operations to the kernel and posts to the mailbox rings,
//! finish the timers that are due and cancel the operations whose deadline passed, give waiting
//! cancels their entries, hand the caller the events the loop produced itself and the messages
//! other loops posted, enter the kernel, reap, and read the mailboxes again.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");
const cancel_module = @import("uring_cancel.zig");
const reap_module = @import("uring_reap.zig");
const ring_module = @import("uring_ring.zig");
const submit_module = @import("uring_submit.zig");
const uring = @import("uring.zig");
const group_wake = @import("uring_group.zig");

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
    loop.tables.expire(loop, cancel_module.request);
    cancel_module.flush(loop);
    var produced = tables.drain_finished(events);
    produced += loop.drain_mailboxes(events[produced..]);
    // The loop says it sleeps before it waits, and reads its mailboxes once more, so a post that
    // came before the flag was set is not slept on (decision 12, point 6). It says it is awake
    // again before an error can leave the tick.
    const wait = if (produced == 0) loop.settle_to_sleep(wait_for(loop, wait_ns)) else null;
    const entering = loop.ring.enter(wait);
    loop.wake_up();
    const entered = try entering;
    // The kernel has read every address of this flush's connects, and every message header of
    // its datagram operations, unless it took no entry. Both scratches are one per entry and are
    // reused from the start each tick; a counter that only rose would stop the loop after
    // `entries` datagrams, which is what `bench/datagram/rotor_datagram.zig` found.
    if (entered == .submitted) {
        loop.addresses_used = 0;
        loop.messages_used = 0;
    }
    produced += reap_module.reap(loop, events[produced..]);
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

/// Decision 13: polls with ticks that do not wait until one spin budget after the loop last handed
/// over an event, and blocks for what is left of `wait_ns` only if nothing came. A poll is `tick`
/// with a zero wait and nothing else, so what arrives while the loop polls is handed over as a
/// blocking tick would hand it. A tick after that window, or with a timer due inside it, does not
/// poll. `Loop.tick` calls this only when `core.spin.applies`.
pub fn spin_then_wait(loop: *Loop, events: []Event, wait_ns: u64) TickError!u32 {
    const tables = &loop.tables;
    assert(core.spin.applies(tables.spin.budget_ns, wait_ns));
    const first = try tick(loop, events, 0);
    if (first != 0) return first;
    const start_ns = tables.now_ns;
    const earliest_ns = tables.timers.earliest_ns();
    const budget_ns = tables.spin.budget_ns;
    var spin = core.spin.Spin.begin(budget_ns, start_ns, tables.spin.active_ns, earliest_ns) orelse
        return tick(loop, events, wait_ns);
    while (spin.more(tables.now_ns)) {
        const produced = try tick(loop, events, 0);
        if (produced != 0) return produced;
    }
    return tick(loop, events, core.spin.remaining_ns(wait_ns, start_ns, tables.now_ns));
}

/// How long the enter may block: not at all while a cancel waits for its entry, a wake waits for
/// room in the submission ring, or a loop of a group has no poll of its eventfd in the ring, and
/// otherwise what `core.Tables` allows.
fn wait_for(loop: *const Loop, wait_ns: u64) ?u64 {
    if (loop.cancels.count != 0) return null;
    if (loop.wakes.targets.count() != 0) return null;
    if (group_wake.unarmed(loop)) return null;
    return loop.tables.wait_bound(wait_ns);
}

/// The monotonic clock both Linux backends read (`linux_shared_clock.zig`).
const clock_ns = @import("linux_shared").clock.clock_ns;
