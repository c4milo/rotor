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
const offload_module = @import("kqueue_offload.zig");
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
    // Only a poll with room to take the trigger's event arms it. A trigger the call applies and
    // cannot deliver stays set, because `EV_CLEAR` clears an event as it is delivered, and it ends
    // the next tick that waits at once. That is what a tick whose events were already full did
    // until 2026-09-22, which the conformance suite's multishot accept caught once a second loop
    // made its late connection. Whether such a tick parks as a poll with room does is not measured.
    if (wait == null and room != 0) arm_poll(loop);
    const changes = loop.changes[0..loop.changes_used];
    const ready = loop.queue.exchange(changes, loop.readiness[0..room], wait);
    loop.changes_used = 0;
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

/// A poll carries the loop's own wake trigger in its changelist. On macOS a `kevent` that finds
/// nothing ready parks the thread through the scheduler even with a zero timeout: 12 µs, against
/// 444 ns when one event is ready, measured on 2026-09-22 on macOS 26.6.2
/// (`bench/alternatives/README.md`, the cross-core message). The kernel applies the trigger, finds
/// the wake event ready, and returns in the same call; the reap drops the wake event, which names
/// no operation. A changelist that is already full triggers with a call of its own, which costs
/// the rare tick that registers `changes_max` descriptors while polling one more system call.
fn arm_poll(loop: *Loop) void {
    if (loop.changes_used < constants.changes_max) {
        loop.changes[loop.changes_used] = queue_module.poll_trigger();
        loop.changes_used += 1;
    } else {
        queue_module.Queue.wake(loop.queue.descriptor);
    }
}

/// The monotonic clock, in nanoseconds. Read once per tick, and once more after a wait that
/// produced nothing (decision 9, rule 4). `kqueue_testing.zig` hands it to the tests, so a test
/// measures with the clock the tick reads.
pub fn clock_ns() u64 {
    var now: std.c.timespec = undefined;
    const rc = std.c.clock_gettime(.MONOTONIC, &now);
    assert(rc == 0);
    assert(now.sec >= 0);
    const seconds: u64 = @intCast(now.sec);
    const nanoseconds: u64 = @intCast(now.nsec);
    return seconds * core.constants.ns_per_s + nanoseconds;
}

const testing = std.testing;
const builtin = @import("builtin");

test "a poll returns at once, and five hundred of them stay far under the kernel's park" {
    // On macOS a `kevent` with nothing ready and a zero timeout parks the thread for about 12 µs
    // (2026-09-22, macOS 26.6.2); with the trigger a poll is under a microsecond. Five hundred
    // polls are about 6 ms parked and under half a millisecond with the trigger. The bound sits
    // between, with room on both sides, so a build without `arm_poll` fails here.
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const bound_ns = 3 * core.constants.ns_per_ms;
    const options: Loop.Options = .{ .operations = 4, .entries = 4, .id = 0 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, options);
    defer loop.deinit();
    var events: [4]Event = undefined;
    // The best of several bursts, as the cost gates of `conformance_cost.zig` do it: other work on
    // the machine makes a burst slower and never faster. One burst alone failed this test while a
    // dependency compiled beside it (2026-09-22), and the 6 ms park it guards against cannot hide
    // in a minimum: without the trigger every burst is over the bound.
    var best_ns: u64 = std.math.maxInt(u64);
    for (0..poll_attempts) |_| best_ns = @min(best_ns, try poll_burst_ns(&loop, &events));
    try testing.expect(best_ns < bound_ns);
    // The trigger left nothing behind: the changelist is empty for the next tick.
    try testing.expectEqual(@as(u32, 0), loop.changes_used);
}

/// Bursts the test times, the best one deciding. Ten of them cost about five milliseconds with the
/// trigger and sixty without, so a build that lost `arm_poll` still fails quickly.
const poll_attempts = 10;

/// Polls this loop `poll_polls` times and answers what the burst took. Every poll must report no
/// event: a poll that found one would be timing something else.
fn poll_burst_ns(loop: *Loop, events: []Event) !u64 {
    const poll_polls = 500;
    const before = clock_ns();
    for (0..poll_polls) |_| try testing.expectEqual(@as(u32, 0), try loop.tick(events, 0));
    return clock_ns() - before;
}
