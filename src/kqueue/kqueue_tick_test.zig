//! The tests of `kqueue_tick.zig`, split from that file for the 500-line limit. They cover a poll
//! and its trigger (decision 12, point 6), the wait timer (decision 12, point 7), and a `kevent`
//! call that fails: the events it returns (decision 5, amendment of 2026-11-06) and the
//! registrations it keeps (decision 12, point 10, proposed on 2026-11-06).
const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const core = @import("core");
const constants = @import("constants.zig");
const kqueue = @import("kqueue.zig");
const queue_module = @import("kqueue_queue.zig");
const submit_module = @import("kqueue_submit.zig");
const tick_module = @import("kqueue_tick.zig");

const Loop = kqueue.Loop;
const Event = core.Event;
const Kevent = queue_module.Kevent;
const Operation = core.Operation;
const clock_ns = tick_module.clock_ns;
const wait_past_early_timer = tick_module.wait_past_early_timer;

const testing = std.testing;

/// A record that counts the final events it receives (decision 26).
const Record = struct {
    completion: core.Completion = .init(Record, "completion", called),
    finals: u32 = 0,

    fn called(record: *Record, event: Event) void {
        assert(!event.flags.more);
        record.finals += 1;
    }
};

test "a tick whose call fails after it produced events returns them, and the next tick fails" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const options: Loop.Options = .{ .operations = 4 };
    var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, &options);
    defer loop.deinit();
    const ends = try kqueue.testing.nonblocking_pair();
    defer for (ends) |end| {
        _ = std.c.close(end);
    };

    // A receive waits for readiness, so a tick that polls asks the kernel.
    var buffer: [8]u8 = undefined;
    var events: [4]Event = undefined;
    const receive = Operation.receive(1, ends[0], &buffer);
    try testing.expectEqual(@as(u32, 1), loop.submit(&.{receive}, &.{}));
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, 0));

    // Two timers end in the next tick before its call: one with a record, one without. A socket
    // in place of the kqueue makes the call fail.
    var record: Record = .{};
    const timers = [_]Operation{
        .timer(2, 0, 0),
        Operation.timer(0, 0, 0).completion(&record.completion),
    };
    try testing.expectEqual(@as(u32, 2), loop.submit(&timers, &.{}));
    const queue = loop.queue.descriptor;
    const saved = std.c.dup(queue);
    try testing.expect(saved >= 0);
    try testing.expectEqual(queue, std.c.dup2(ends[1], queue));

    // The tick hands over the timer without a record and calls the other's record. The kept
    // error takes the next tick off the fast path.
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, 0));
    try testing.expectEqual(@as(u64, 2), events[0].user_data);
    try testing.expectEqual(@as(u32, 1), record.finals);
    try testing.expect(!loop.tables.dispatch.idle());
    // The next tick returns the kept error before anything else. A tick that produced nothing
    // returns its own error at once.
    try testing.expectError(error.Unexpected, loop.tick(&events, 0));
    try testing.expect(loop.tables.dispatch.idle());
    try testing.expectError(error.Unexpected, loop.tick(&events, 0));

    _ = std.c.dup2(saved, queue);
    _ = std.c.close(saved);
    // A failed tick that produced nothing keeps nothing, so this tick runs, and the receive ends.
    try testing.expectEqual(@as(isize, 1), std.c.write(ends[1], "x", 1));
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, core.constants.ns_per_s));
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectEqual(@as(u32, 0), loop.in_flight());
}

/// Puts `replacement` in place of the loop's kqueue, so the next `kevent` call fails with EBADF,
/// and answers a copy of the kqueue for `restore`.
fn break_queue(loop: *const Loop, replacement: core.Descriptor) !core.Descriptor {
    const queue = loop.queue.descriptor;
    const saved = std.c.dup(queue);
    try testing.expect(saved >= 0);
    try testing.expectEqual(queue, std.c.dup2(replacement, queue));
    return saved;
}

fn restore(loop: *const Loop, saved: core.Descriptor) !void {
    try testing.expectEqual(loop.queue.descriptor, std.c.dup2(saved, loop.queue.descriptor));
    _ = std.c.close(saved);
}

test "a failed call keeps the registration it carried, and the receive ends when the kqueue is back" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const options: Loop.Options = .{ .operations = 4 };
    var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, &options);
    defer loop.deinit();
    const ends = try kqueue.testing.nonblocking_pair();
    defer for (ends) |end| {
        _ = std.c.close(end);
    };

    // The receive would block, so the tick puts its registration on the list for its call.
    var buffer: [8]u8 = undefined;
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 1), loop.submit(&.{Operation.receive(1, ends[0], &buffer)}, &.{}));
    const saved = try break_queue(&loop, ends[1]);

    // A tick that waits fails. The registration stays, without a receipt, and the timer goes.
    try testing.expectError(error.Unexpected, loop.tick(&events, core.constants.ns_per_s));
    // The tick read the clock after the failed wait, so a turn is open: the time until the next
    // tick can be a stall, and a watch can see it (decision 28).
    try testing.expect(loop.tables.heartbeat.beat_ns.load(.monotonic) != core.stall.asleep);
    try testing.expectEqual(@as(u32, 1), loop.changes_used);
    try testing.expectEqual(@as(u16, 0), loop.changes[0].flags & std.c.EV.RECEIPT);
    try testing.expectEqual(@as(u64, 0), loop.wait_timer_deadline_ns);
    // A tick that polls fails the same way, and its trigger goes.
    try testing.expectError(error.Unexpected, loop.tick(&events, 0));
    try testing.expectEqual(@as(u32, 1), loop.changes_used);

    // The kqueue is back. The next call carries the registration, and the byte ends the receive.
    try restore(&loop, saved);
    try testing.expectEqual(@as(isize, 1), std.c.write(ends[1], "x", 1));
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, core.constants.ns_per_s));
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectEqual(@as(u32, 0), loop.in_flight());
}

test "a change refused with no room for its answer loses no registration behind it" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const options: Loop.Options = .{ .operations = 4 };
    var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, &options);
    defer loop.deinit();
    const ends = try kqueue.testing.nonblocking_pair();
    const other = try kqueue.testing.nonblocking_pair();
    defer for (ends ++ other) |end| {
        _ = std.c.close(end);
    };

    // A delete of a filter that is not there, which the kernel refuses with ENOENT, comes first on
    // the list. The receive's registration follows it.
    submit_module.unregister(&loop, other[0], .read);
    var buffer: [8]u8 = undefined;
    const operations = [_]Operation{ .receive(1, ends[0], &buffer), .timer(2, 0, 0) };
    try testing.expectEqual(@as(u32, 2), loop.submit(&operations, &.{}));

    // The timer fills the one event, so the call has no room for the refusal and fails at it,
    // before it applies the registration. The tick applies the list again and returns the timer.
    var one: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 1), try loop.tick(&one, 0));
    try testing.expectEqual(@as(u64, 2), one[0].user_data);
    // The refused delete is back on the list, for the next call to report.
    try testing.expectEqual(@as(u32, 1), loop.changes_used);
    try testing.expectEqual(@as(usize, @intCast(other[0])), loop.changes[0].ident);

    // The next call reports the refusal, which names no waiter, and returns before it reads any
    // readiness. The call after it finds the receive's filter ready.
    try testing.expectEqual(@as(isize, 1), std.c.write(ends[1], "x", 1));
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, core.constants.ns_per_s));
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, core.constants.ns_per_s));
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectEqual(@as(u32, 0), loop.in_flight());
}

test "a poll returns at once, and five hundred of them stay far under the kernel's park" {
    // On macOS a `kevent` with nothing ready and a zero timeout parks the thread for about 12 µs
    // (2026-09-22, macOS 26.6.2); with the trigger a poll is under a microsecond. Five hundred
    // polls are about 6 ms parked and under half a millisecond with the trigger. The bound sits
    // between, with room on both sides, so a build without `arm_poll` fails here.
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const bound_ns = 3 * core.constants.ns_per_ms;
    const options: Loop.Options = .{ .operations = 4, .entries = 4, .id = 0 };
    var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, &options);
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
    // Runs after the loop's `deinit`: the registry keeps the loop's wake until then.
    defer kqueue.wake_module.close_kept(&registry);
    const sizing: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(&sizing)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, &.{ .operations = 2, .id = receiver, .registry = &registry });
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

test "a tick that makes no call keeps no place for the kernel, so the mailboxes take every place" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const loops = 2;
    const receiver: core.LoopId = 1;
    const sender: core.LoopId = 0;
    var registry_memory: [kqueue.Registry.memory_bytes(loops)]u8 align(core.layout.memory_alignment) =
        undefined;
    var registry: kqueue.Registry = undefined;
    registry.init(&registry_memory, loops);
    // Runs after the loop's `deinit`: the registry keeps the loop's wake until then.
    defer kqueue.wake_module.close_kept(&registry);
    const sizing: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(&sizing)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, &.{ .operations = 2, .id = receiver, .registry = &registry });
    defer loop.deinit();

    // More messages than the tick has events. The loop is quiet: no change, no waiter, no trigger.
    // At 16 events a kernel reserve would keep 16 / 4 + 3 places, and the tick that makes no call
    // gives its unused places to the lists only (W3).
    const events_len = 16;
    for (0..events_len * 2) |payload| {
        try testing.expect(registry.mailbox(sender, receiver).push(.{ .tag = 7, .payload = payload }));
    }
    var events: [events_len]Event = undefined;
    try testing.expectEqual(@as(u32, events_len), try loop.tick(&events, 0));
    for (events, 0..) |event, payload| try testing.expectEqual(@as(u64, payload), event.user_data);
    try testing.expectEqual(@as(u32, events_len), try loop.tick(&events, 0));
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
    // Runs after the loop's `deinit`: the registry keeps the loop's wake until then.
    defer kqueue.wake_module.close_kept(&registry);
    const sizing: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(&sizing)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, &.{ .operations = 2, .id = receiver, .registry = &registry });
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

test "a wake ahead of a socket's readiness does not end its receive with timeout (issue 10)" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const options: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, &options);
    defer loop.deinit();
    const pair = try kqueue.testing.nonblocking_pair();
    defer for (pair) |descriptor| sync_close(descriptor);

    // The deadline is 1 ns after the first tick's stamp, so it is due at the next tick.
    var buffer: [8]u8 = undefined;
    var receive = Operation.receive(1, pair[0], &buffer);
    receive.timeout_ns = 1;
    try testing.expectEqual(@as(u32, 1), loop.submit(&.{receive}, &.{}));
    var events: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, 0));
    const armed_ns = loop.tables.now_ns;
    // The trigger is set before the bytes come, so the kernel answers it first, in the one place.
    queue_module.Queue.wake(loop.queue.descriptor);
    try testing.expectEqual(@as(isize, 2), std.c.write(pair[1], "hi", 2));
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, 0));
    try testing.expect(loop.tables.now_ns > armed_ns);
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectEqual(@as(u32, 2), try events[0].outcome());
}

test "the wait timer stays armed for a later deadline and moves for an earlier one" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const options: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, &options);
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
    var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, &options);
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
    var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, &options);
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
    var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, &options);
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
    var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, &options);
    defer loop.deinit();
    var events: [4]Event = undefined;

    // Without `NOTE_CRITICAL` macOS fired this timer about 100 ms late for a background thread,
    // measured on 2026-09-27, and the best of five quiet ticks here ended 168 to 193 ms late on
    // 2026-09-30. With it the best of five ended 0.02 to 0.55 ms late at a load average of 8. A
    // bound of 20 ms over the best of five failed three times on 2026-09-29 and 30, at load averages
    // of 36 to 98, where a background thread waits for a core as well as for its timer; how late
    // those runs were was not recorded. So the bound is the best of twenty, as the cost gates of
    // `conformance_cost.zig` take it, and 50 ms, under a third of the lateness it guards against.
    const wait_ns = 5 * core.constants.ns_per_ms;
    var best_late_ns: u64 = std.math.maxInt(u64);
    for (0..background_attempts) |_| {
        const before = clock_ns();
        try testing.expectEqual(@as(u32, 0), try loop.tick(&events, wait_ns));
        best_late_ns = @min(best_late_ns, (clock_ns() - before) -| wait_ns);
    }
    try testing.expect(best_late_ns < 50 * core.constants.ns_per_ms);
}

/// Waits the background test times, the best one deciding.
const background_attempts = 20;
