//! `tick`: one turn of the loop. In order: read the clock once, try the queued operations and
//! register the ones that must wait, finish the timers that are due and end the operations whose
//! deadline passed, hand over the events the loop produced itself and the messages other loops
//! posted, make the one `kevent` call, and perform what became ready.
//!
//! "One system call per tick" is not claimed here (decision 12, point 1): every transfer is its
//! own call. The one `kevent` call carries the tick's registrations in and its readiness out. A
//! call that blocks carries no timeout, because the loop's wait timer bounds it; when that timer
//! fires before this tick's deadline, the tick waits again (decision 12, point 7).
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
const Kevent = queue_module.Kevent;

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
    // A poll with no change to carry in and no operation waiting for readiness makes no call. The
    // kernel could report only this loop's own wake event, which names no operation, and what a
    // wake announces, a message or an offload's result, is read from its ring above and below. A
    // trigger another loop sent stays set for the next call that waits, which then ends at once:
    // the wasted wake decision 12, point 6 already allows. A trigger this loop armed and has not
    // seen come back is not left: that call is made, and hands it back.
    const quiet = loop.changes_used == 0 and loop.waiters.used == 0 and !loop.trigger_armed;
    const idle = wait == null and quiet;
    if (wait == null and room != 0 and !idle) arm_poll(loop);
    const nothing: queue_module.ExchangeError!u32 = 0;
    const readiness = loop.readiness[0..room];
    const ready = if (idle) nothing else call_kernel(loop, readiness, wait);
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

/// The tick's one `kevent` call, carrying the changelist. A poll returns at once. A call that blocks
/// carries no timeout, because the loop's wait timer bounds it (decision 12, point 7). It carries
/// the timeout itself only when the changelist has no room left to arm the timer.
fn call_kernel(loop: *Loop, readiness: []Kevent, wait: ?u64) queue_module.ExchangeError!u32 {
    const bound_ns = wait orelse
        return loop.queue.exchange(loop.changes[0..loop.changes_used], readiness, null);
    assert(readiness.len >= 1);
    const deadline_ns = loop.tables.now_ns + bound_ns;
    if (!arm_wait_timer(loop, bound_ns)) {
        return loop.queue.exchange(loop.changes[0..loop.changes_used], readiness, bound_ns);
    }
    const count = try loop.queue.wait(loop.changes[0..loop.changes_used], readiness);
    return wait_past_early_timer(loop, readiness, count, deadline_ns);
}

/// A wait timer an earlier tick armed can fire before this tick's deadline. When its event is all
/// the call returned, the tick arms the timer for the time that is left and waits again, so a tick
/// with nothing to hand over takes its whole wait, as the conformance suite requires. Returns what
/// the last call wrote into `readiness`, which the reap then serves.
fn wait_past_early_timer(
    loop: *Loop,
    readiness: []Kevent,
    first_count: u32,
    deadline_ns: u64,
) queue_module.ExchangeError!u32 {
    var count = first_count;
    for (0..constants.wait_timer_rearms_max) |_| {
        if (!only_wait_timer(readiness[0..count])) return count;
        const now_ns = clock_ns();
        if (now_ns >= deadline_ns) return count;
        const again = [1]Kevent{queue_module.wait_timer(deadline_ns - now_ns)};
        loop.wait_timer_deadline_ns = deadline_ns;
        count = try loop.queue.wait(&again, readiness);
    }
    return count;
}

/// True when the call returned the wait timer's event and nothing else. A timer the kernel refused
/// to arm comes back with `EV_ERROR`, and waiting again would not end.
fn only_wait_timer(readiness: []const Kevent) bool {
    if (readiness.len != 1) return false;
    const ready = &readiness[0];
    return ready.filter == std.c.EVFILT.TIMER and ready.flags & std.c.EV.ERROR == 0;
}

/// Decision 12, point 7: on macOS a `kevent` call with a timeout costs about 1,000 more
/// instructions in the kernel than one without, whatever the timeout, and an `EVFILT_TIMER` that is
/// already armed costs a call nothing (measured on macOS 26.6.2 on 2026-09-26). So a wait carries
/// no timeout, and the loop's one wait timer bounds it. The timer is left in place when it fires
/// no later than this wait's deadline and has not fired yet, so a loop that waits often arms it
/// about once per wait bound. Such a timer can fire before a later wait's own deadline, and
/// `wait_past_early_timer` then waits out the rest. Returns false when the changelist is full, and
/// the call must carry the timeout instead.
fn arm_wait_timer(loop: *Loop, bound_ns: u64) bool {
    assert(bound_ns >= 1);
    const now_ns = loop.tables.now_ns;
    const deadline_ns = now_ns + bound_ns;
    const armed_ns = loop.wait_timer_deadline_ns;
    if (armed_ns > now_ns and armed_ns <= deadline_ns) return true;
    if (loop.changes_used == constants.changes_max) return false;
    loop.changes[loop.changes_used] = queue_module.wait_timer(bound_ns);
    loop.changes_used += 1;
    loop.wait_timer_deadline_ns = deadline_ns;
    return true;
}

/// A poll carries the loop's own wake trigger in its changelist. On macOS a `kevent` that finds
/// nothing ready parks the thread through the scheduler even with a zero timeout: 12 µs, against
/// 444 ns when one event is ready, measured on 2026-09-22 on macOS 26.6.2
/// (`bench/alternatives/README.md`, the cross-core message). The kernel applies the trigger, finds
/// the wake event ready, and returns in the same call; the reap drops the wake event, which names
/// no operation. A changelist that is already full triggers with a call of its own, which costs
/// the rare tick that registers `changes_max` descriptors while polling one more system call.
fn arm_poll(loop: *Loop) void {
    loop.trigger_armed = true;
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
///
/// It is `CLOCK_MONOTONIC_RAW`, which on macOS counts in 41 ns steps and costs 14.5 ns a read.
/// `CLOCK_MONOTONIC` there counts in 1,000 ns steps and costs 20.1 ns, measured on macOS 26.6.2 on
/// 2026-09-26. Both keep counting while the machine sleeps. `bench/harness/clock.zig` reads the
/// same clock, so a benchmark's spans and a loop's deadlines agree.
pub fn clock_ns() u64 {
    var now: std.c.timespec = undefined;
    const rc = std.c.clock_gettime(.MONOTONIC_RAW, &now);
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

test "a tick with a message to hand over and nothing waiting on a socket polls nothing" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const loops = 2;
    const receiver: core.LoopId = 1;
    const sender: core.LoopId = 0;
    var registry_memory: [kqueue.Registry.memory_bytes(loops)]u8 align(core.layout.memory_alignment) =
        undefined;
    var registry: kqueue.Registry = undefined;
    registry.init(&registry_memory, loops);
    const sizing: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(sizing)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, .{ .operations = 2, .id = receiver, .registry = &registry });
    defer loop.deinit();

    // Another loop posts, and wakes this one as a post to a loop that sleeps does.
    try testing.expect(registry.mailbox(sender, receiver).push(.{ .tag = 7, .payload = 1 }));
    queue_module.Queue.wake(loop.queue.descriptor);

    // The message is handed over. No operation waits for readiness and no change is queued, so the
    // kernel could report only the wake, and the tick does not ask it: the wake stays set for the
    // next call that waits. A tick that polled would have taken it.
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, 0));
    try testing.expect(events[0].flags.message);
    try testing.expectEqual(@as(u32, 1), try loop.queue.exchange(&.{}, loop.readiness[0..1], 0));
}

test "a loop whose own wake trigger came back skips the poll again" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const loops = 2;
    const receiver: core.LoopId = 1;
    const sender: core.LoopId = 0;
    var registry_memory: [kqueue.Registry.memory_bytes(loops)]u8 align(core.layout.memory_alignment) =
        undefined;
    var registry: kqueue.Registry = undefined;
    registry.init(&registry_memory, loops);
    const sizing: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(sizing)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, .{ .operations = 2, .id = receiver, .registry = &registry });
    defer loop.deinit();
    const pair = try kqueue.testing.nonblocking_pair();
    defer for (pair) |descriptor| sync_close(descriptor);

    // A receive waits for readiness, so a tick that asks for none polls, and arms the trigger.
    var buffer: [8]u8 = undefined;
    var handles: [1]core.Handle = undefined;
    const receive = core.Operation.receive(3, pair[0], &buffer);
    try testing.expectEqual(@as(u32, 1), loop.submit(&.{receive}, &handles));
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, 0));
    loop.cancel(handles[0]);
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, 0));
    try testing.expectEqual(@as(u32, 0), loop.in_flight());

    // Nothing waits now, and the trigger came back from the polls above, so a tick with a message
    // to hand over makes no call and leaves the post's wake set, as in the test above.
    try testing.expect(registry.mailbox(sender, receiver).push(.{ .tag = 7, .payload = 1 }));
    queue_module.Queue.wake(loop.queue.descriptor);
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, 0));
    try testing.expect(events[0].flags.message);
    try testing.expectEqual(@as(u32, 1), try loop.queue.exchange(&.{}, loop.readiness[0..1], 0));
}

test "the wait timer stays armed for a later deadline and moves for an earlier one" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const options: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, options);
    defer loop.deinit();
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u64, 0), loop.wait_timer_deadline_ns);

    // A wake ends each wait below at once, before its timer fires, and the tick hands over nothing,
    // as a wasted wake does. So each tick shows what it did with the timer and nothing else.
    queue_module.Queue.wake(loop.queue.descriptor);
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, core.constants.ns_per_s));
    const first_ns = loop.wait_timer_deadline_ns;
    try testing.expect(first_ns > loop.tables.now_ns);

    // A later deadline leaves the timer where it was: no change, no system call's worth of work.
    queue_module.Queue.wake(loop.queue.descriptor);
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, 2 * core.constants.ns_per_s));
    try testing.expectEqual(first_ns, loop.wait_timer_deadline_ns);

    // An earlier deadline arms it again, to fire first.
    queue_module.Queue.wake(loop.queue.descriptor);
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, 10 * core.constants.ns_per_ms));
    try testing.expect(loop.wait_timer_deadline_ns < first_ns);
}

test "a wait timer an earlier tick armed does not cut a later wait short" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const options: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, options);
    defer loop.deinit();
    var events: [4]Event = undefined;

    // A wake ends a short wait at once, and its timer stays armed.
    const short_ns = 20 * core.constants.ns_per_ms;
    queue_module.Queue.wake(loop.queue.descriptor);
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, short_ns));
    try testing.expect(loop.wait_timer_deadline_ns != 0);

    // The next wait is longer, so it keeps that timer, which fires first. The tick waits out the
    // rest: a quiet tick takes its whole wait, as the conformance suite requires of every backend.
    const long_ns = 3 * short_ns;
    const before = clock_ns();
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, long_ns));
    const waited = clock_ns() - before;
    try testing.expect(waited >= long_ns - core.constants.ns_per_ms);
    // The last timer fired, and the reap took its event.
    try testing.expectEqual(@as(u64, 0), loop.wait_timer_deadline_ns);
}

test "a wait whose changelist is full carries its timeout and leaves the timer alone" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const options: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, options);
    defer loop.deinit();
    var events: [4]Event = undefined;

    // A changelist with no room left: each change triggers the loop's own wake event, which is a
    // change the kernel takes, and makes the wait end at once.
    @memset(&loop.changes, queue_module.poll_trigger());
    loop.changes_used = constants.changes_max;
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, core.constants.ns_per_s));
    try testing.expectEqual(@as(u64, 0), loop.wait_timer_deadline_ns);
    try testing.expectEqual(@as(u32, 0), loop.changes_used);
}

test "a wait timer the kernel refused is not waited on again" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const options: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, options);
    defer loop.deinit();

    // The kernel reports a change it refused as the change itself, flagged `EV_ERROR`. Waiting
    // again on a timer that never armed would wait for nothing to fire.
    var refused = queue_module.wait_timer(core.constants.ns_per_s);
    refused.flags |= std.c.EV.ERROR;
    var readiness = [1]Kevent{refused};
    const before = clock_ns();
    const deadline_ns = before + core.constants.ns_per_s;
    try testing.expectEqual(@as(u32, 1), try wait_past_early_timer(&loop, &readiness, 1, deadline_ns));
    try testing.expect(clock_ns() - before < 100 * core.constants.ns_per_ms);
}

fn sync_close(descriptor: i32) void {
    _ = std.c.close(descriptor);
}

/// Darwin's `setpriority`, which Zig's standard library does not declare. With `PRIO_DARWIN_THREAD`
/// it marks the calling thread as background, the tier macOS delays timers for the most.
extern "c" fn setpriority(which: c_int, who: u32, priority: c_int) c_int;

test "the wait timer fires when it is due, even for a thread the system runs as background" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const prio_darwin_thread: c_int = 3;
    const prio_darwin_bg: c_int = 0x1000;
    try testing.expectEqual(@as(c_int, 0), setpriority(prio_darwin_thread, 0, prio_darwin_bg));
    defer _ = setpriority(prio_darwin_thread, 0, 0);
    const options: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, options);
    defer loop.deinit();
    var events: [4]Event = undefined;

    // Without `NOTE_CRITICAL` macOS fired this timer about 100 ms late for a background thread,
    // measured on 2026-09-27. The best of five quiet ticks must end within 20 ms of its wait.
    const wait_ns = 5 * core.constants.ns_per_ms;
    var best_late_ns: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const before = clock_ns();
        try testing.expectEqual(@as(u32, 0), try loop.tick(&events, wait_ns));
        best_late_ns = @min(best_late_ns, (clock_ns() - before) -| wait_ns);
    }
    try testing.expect(best_late_ns < 20 * core.constants.ns_per_ms);
}
