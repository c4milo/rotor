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
    loop.tables.expire(loop, cancel_module.request);
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
        loop.tables.expire(loop, cancel_module.request);
        produced += tables.drain_finished(events[produced..]);
    }
    assert(produced <= events.len);
    return produced;
}

/// Decision 13: polls with ticks that do not wait, for the loop's spin budget, and blocks for what
/// is left of `wait_ns` only if nothing came. A poll is `tick` with a zero wait and nothing else, so
/// what arrives while the loop polls is handed over as a blocking tick would hand it. A timer due
/// inside the budget ends the spin before it starts, and the tick blocks until it. `Loop.tick`
/// calls this only when `core.spin.applies`.
pub fn spin_then_wait(loop: *Loop, events: []Event, wait_ns: u64) TickError!u32 {
    const tables = &loop.tables;
    assert(core.spin.applies(tables.spin_budget_ns, wait_ns));
    const first = try tick(loop, events, 0);
    if (first != 0) return first;
    const start_ns = tables.now_ns;
    const earliest_ns = tables.timers.earliest_ns();
    var spin = core.spin.Spin.begin(tables.spin_budget_ns, start_ns, earliest_ns) orelse
        return tick(loop, events, wait_ns);
    while (spin.more(tables.now_ns)) {
        const produced = try tick(loop, events, 0);
        if (produced != 0) return produced;
    }
    return tick(loop, events, core.spin.remaining_ns(wait_ns, start_ns, tables.now_ns));
}

/// How long the enter may block: not at all while a cancel waits for its entry, and otherwise
/// what `core.Tables` allows.
fn wait_for(loop: *const Loop, wait_ns: u64) ?u64 {
    if (loop.cancels.count != 0) return null;
    return loop.tables.wait_bound(wait_ns);
}

/// The monotonic clock both Linux backends read (`linux_shared_clock.zig`).
const clock_ns = @import("linux_shared").clock.clock_ns;
