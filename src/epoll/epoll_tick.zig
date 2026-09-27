//! `tick`: one turn of the loop. In order: read the clock once, try the queued operations and
//! register the ones that must wait, finish the timers that are due and end the operations whose
//! deadline passed, hand over the events the loop produced itself and the messages other loops
//! posted, make the one `epoll_pwait2` call, and perform what became ready. A call that blocks
//! carries no timeout, because the loop's wait timer bounds it; when that timer fires before this
//! tick's deadline, the tick waits again (decision 20, "The wait timer").
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
const Readiness = queue_module.Event;

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
    // the next tick too, because every registration is level triggered. Nor does a poll with no
    // operation waiting for readiness: the kernel could report only this loop's own eventfd, and
    // what a wake announces is read from its ring above and below. A wake another loop wrote stays
    // readable for the next call that waits, which then ends at once, as decision 12, point 6
    // allows.
    const idle = wait == null and loop.waiters.used == 0;
    const nothing: TickError!u32 = 0;
    const readiness = loop.readiness[0..room];
    const ready = if (room == 0 or idle) nothing else call_kernel(loop, readiness, wait);
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

/// The tick's one `epoll_pwait2` call. A poll returns at once. A call that blocks carries no
/// timeout, because the loop's wait timer bounds it (decision 20, "The wait timer"). It carries the
/// timeout itself only when the kernel refuses to arm the timer.
fn call_kernel(loop: *Loop, readiness: []Readiness, wait: ?u64) TickError!u32 {
    const bound_ns = wait orelse return loop.queue.wait(readiness, 0);
    const deadline_ns = loop.tables.now_ns + bound_ns;
    if (!arm_wait_timer(loop, bound_ns)) return loop.queue.wait(readiness, bound_ns);
    const count = try loop.queue.wait_for_timer(readiness);
    return wait_past_early_timer(loop, readiness, count, deadline_ns);
}

/// A wait timer an earlier tick armed can fire before this tick's deadline. When its readiness is
/// all the call returned, the tick arms the timer for the time that is left and waits again, so a
/// tick with nothing to hand over takes its whole wait, as the conformance suite requires. Returns
/// what the last call wrote into `readiness`, which the reap then serves.
fn wait_past_early_timer(
    loop: *Loop,
    readiness: []Readiness,
    first_count: u32,
    deadline_ns: u64,
) TickError!u32 {
    var count = first_count;
    for (0..constants.wait_timer_rearms_max) |_| {
        if (!only_wait_timer(readiness[0..count])) return count;
        loop.wait_timer_deadline_ns = 0;
        const now_ns = clock_ns();
        if (now_ns >= deadline_ns) return count;
        const left_ns = deadline_ns - now_ns;
        if (!loop.queue.arm_wait_timer(left_ns)) return loop.queue.wait(readiness, left_ns);
        loop.wait_timer_deadline_ns = deadline_ns;
        count = try loop.queue.wait_for_timer(readiness);
    }
    return count;
}

/// True when the call returned the wait timer's readiness and nothing else.
fn only_wait_timer(readiness: []const Readiness) bool {
    return readiness.len == 1 and readiness[0].data.u64 == constants.wait_timer_user_data;
}

/// Decision 20, "The wait timer": on Linux an `epoll_pwait2` with a timeout costs about 850 more
/// instructions in the kernel than one without, whatever the timeout, and a timerfd that is already
/// armed costs a wait nothing (measured on 2026-09-26). So a wait carries no timeout, and the
/// loop's one wait timer bounds it. The timer is left in place when it fires no later than this
/// wait's deadline and has not fired yet, so a loop that waits often arms it about once per wait
/// bound. Arming is a `timerfd_settime` call of its own, which costs more than the timeout it
/// replaces, so arming on every wait would lose. Such a timer can fire before a later wait's own
/// deadline, and `wait_past_early_timer` then waits out the rest. Returns false when the kernel
/// refuses to arm it, and the call must carry the timeout instead.
fn arm_wait_timer(loop: *Loop, bound_ns: u64) bool {
    assert(bound_ns >= 1);
    const now_ns = loop.tables.now_ns;
    const deadline_ns = now_ns + bound_ns;
    const armed_ns = loop.wait_timer_deadline_ns;
    if (armed_ns > now_ns and armed_ns <= deadline_ns) return true;
    if (!loop.queue.arm_wait_timer(bound_ns)) return false;
    loop.wait_timer_deadline_ns = deadline_ns;
    return true;
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

/// The monotonic clock both Linux backends read (`linux_shared_clock.zig`).
const clock_ns = @import("linux_shared").clock.clock_ns;

const testing = std.testing;

test "a tick with a message to hand over and nothing waiting on a socket polls nothing" {
    if (!epoll.supported) return error.SkipZigTest;
    const loops = 2;
    const receiver: core.LoopId = 1;
    const sender: core.LoopId = 0;
    var registry_memory: [epoll.Registry.memory_bytes(loops)]u8 align(core.layout.memory_alignment) =
        undefined;
    var registry: epoll.Registry = undefined;
    registry.init(&registry_memory, loops);
    const sizing: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(sizing)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, .{ .operations = 2, .id = receiver, .registry = &registry });
    defer loop.deinit();

    // Another loop posts, and wakes this one as a post to a loop that sleeps does.
    try testing.expect(registry.mailbox(sender, receiver).push(.{ .tag = 7, .payload = 1 }));
    queue_module.Queue.wake(loop.queue.wake_descriptor);

    // The message is handed over. No operation waits for readiness, so the kernel could report
    // only the wake, and the tick does not ask it: the wake stays unread for the next tick that
    // waits. A tick that polled would have read the wake's counter back to 0.
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, 0));
    try testing.expect(events[0].flags.message);
    var counter: u64 = 0;
    const read = linux.read(loop.queue.wake_descriptor, std.mem.asBytes(&counter), @sizeOf(u64));
    try testing.expectEqual(@as(usize, @sizeOf(u64)), read);
}

test "only the wait timer's readiness, alone, counts as a wait the timer ended" {
    const timer: Readiness = .{ .events = linux.EPOLL.IN, .data = .{ .u64 = constants.wait_timer_user_data } };
    const wake: Readiness = .{ .events = linux.EPOLL.IN, .data = .{ .u64 = constants.wake_user_data } };
    try testing.expect(only_wait_timer(&.{timer}));
    try testing.expect(!only_wait_timer(&.{}));
    try testing.expect(!only_wait_timer(&.{wake}));
    try testing.expect(!only_wait_timer(&.{ timer, wake }));
}

test "the wait timer stays armed for a later deadline and moves for an earlier one" {
    if (!epoll.supported) return error.SkipZigTest;
    var memory: [Loop.memory_bytes(.{ .operations = 2 })]u8 align(core.layout.memory_alignment) =
        undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, .{ .operations = 2 });
    defer loop.deinit();
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u64, 0), loop.wait_timer_deadline_ns);

    // A wake ends each wait below at once, before its timer fires, and the tick hands over nothing,
    // as a wasted wake does. So each tick shows what it did with the timer and nothing else.
    queue_module.Queue.wake(loop.queue.wake_descriptor);
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, core.constants.ns_per_s));
    const first_ns = loop.wait_timer_deadline_ns;
    try testing.expect(first_ns > loop.tables.now_ns);

    // A later deadline leaves the timer where it was: no `timerfd_settime`.
    queue_module.Queue.wake(loop.queue.wake_descriptor);
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, 2 * core.constants.ns_per_s));
    try testing.expectEqual(first_ns, loop.wait_timer_deadline_ns);

    // An earlier deadline arms it again, to fire first.
    queue_module.Queue.wake(loop.queue.wake_descriptor);
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, 10 * core.constants.ns_per_ms));
    try testing.expect(loop.wait_timer_deadline_ns < first_ns);
}

test "a wait timer an earlier tick armed does not cut a later wait short" {
    if (!epoll.supported) return error.SkipZigTest;
    var memory: [Loop.memory_bytes(.{ .operations = 2 })]u8 align(core.layout.memory_alignment) =
        undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, .{ .operations = 2 });
    defer loop.deinit();
    var events: [4]Event = undefined;

    // A wake ends a short wait at once, and its timer stays armed.
    const short_ns = 20 * core.constants.ns_per_ms;
    queue_module.Queue.wake(loop.queue.wake_descriptor);
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, short_ns));
    try testing.expect(loop.wait_timer_deadline_ns != 0);

    // The next wait is longer, so it keeps that timer, which fires first. The tick waits out the
    // rest: a quiet tick takes its whole wait, as the conformance suite requires of every backend.
    const long_ns = 3 * short_ns;
    const before = clock_ns();
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, long_ns));
    const waited = clock_ns() - before;
    try testing.expect(waited >= long_ns - core.constants.ns_per_ms);
    // The last timer fired, and the reap took its readiness.
    try testing.expectEqual(@as(u64, 0), loop.wait_timer_deadline_ns);
}

test "a wait whose timer the kernel refuses carries its timeout and still takes its whole wait" {
    if (!epoll.supported) return error.SkipZigTest;
    var memory: [Loop.memory_bytes(.{ .operations = 2 })]u8 align(core.layout.memory_alignment) =
        undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, .{ .operations = 2 });
    // `timerfd_settime` refuses a descriptor that is not a timerfd, so the eventfd stands in for
    // the timer. The real one goes back before `deinit` closes it.
    const timer = loop.queue.wait_timer_descriptor;
    loop.queue.wait_timer_descriptor = loop.queue.wake_descriptor;
    defer {
        loop.queue.wait_timer_descriptor = timer;
        loop.deinit();
    }
    var events: [4]Event = undefined;
    const wait_ns = 20 * core.constants.ns_per_ms;
    const before = clock_ns();
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, wait_ns));
    try testing.expect(clock_ns() - before >= wait_ns - core.constants.ns_per_ms);
    try testing.expectEqual(@as(u64, 0), loop.wait_timer_deadline_ns);

    // The same when the timer fired early and the tick cannot arm it again for the time left.
    var readiness = [1]Readiness{.{
        .events = linux.EPOLL.IN,
        .data = .{ .u64 = constants.wait_timer_user_data },
    }};
    const again = clock_ns();
    const deadline_ns = again + wait_ns;
    try testing.expectEqual(@as(u32, 0), try wait_past_early_timer(&loop, &readiness, 1, deadline_ns));
    try testing.expect(clock_ns() - again >= wait_ns - core.constants.ns_per_ms);
}
