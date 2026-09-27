//! `tick`: one turn of the loop, and the one system call it makes (decision 3, source 4). In
//! order: read the clock once, hand queued operations to the kernel and posts to the mailbox rings,
//! finish the timers that are due and cancel the operations whose deadline passed, give waiting
//! cancels their entries, hand the caller the events the loop produced itself and the messages
//! other loops posted, enter the kernel, reap, and read the mailboxes again. An enter that blocks
//! carries no timeout, because the loop's wait timer, armed in the same batch, bounds it; when that
//! timer fires before this tick's deadline, the tick waits again (decision 6, amended 2026-09-27).
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
const constants = @import("constants.zig");

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
    const entering = enter_bounded(loop, wait);
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

/// The tick's enter. A poll returns at once. A wait carries no timeout, because the loop's wait timer
/// bounds it (decision 6, amended 2026-09-27): the timer's entry rides in the same enter, so arming
/// it costs no system call. The enter carries the timeout itself only when the submission ring has
/// no room for the timer's entry.
fn enter_bounded(loop: *Loop, wait: ?u64) TickError!ring_module.Entered {
    const bound_ns = wait orelse return loop.ring.enter(null);
    const deadline_ns = loop.tables.now_ns + bound_ns;
    if (!arm_wait_timer(loop, loop.tables.now_ns, deadline_ns)) return loop.ring.enter(bound_ns);
    const entered = try loop.ring.enter_until_completion();
    if (entered == .submitted) try wait_past_early_timer(loop, deadline_ns);
    return entered;
}

/// A wait timer an earlier tick armed can fire before this tick's deadline, and a timer that moved
/// answers with a completion of its own. When the ring holds the timer's completions and nothing
/// else, the tick takes them, arms the timer again if it fired, and waits for the time that is
/// left, so a tick with nothing to hand over takes its whole wait, as the conformance suite requires.
fn wait_past_early_timer(loop: *Loop, deadline_ns: u64) TickError!void {
    for (0..constants.wait_timer_rearms_max) |_| {
        const ready = loop.ring.cq_ready();
        if (!only_wait_timer(loop, ready)) return;
        take_wait_timer(loop, ready);
        const now_ns = clock_ns();
        if (now_ns >= deadline_ns) return;
        if (!arm_wait_timer(loop, now_ns, deadline_ns)) {
            _ = try loop.ring.enter(deadline_ns - now_ns);
            return;
        }
        if (try loop.ring.enter_until_completion() != .submitted) return;
    }
}

/// True when the ring holds at least one completion and every one is the wait timer's.
fn only_wait_timer(loop: *Loop, ready: u32) bool {
    if (ready == 0) return false;
    for (0..ready) |offset| {
        if (!is_wait_timer(loop.ring.cqe_at(@intCast(offset)).user_data)) return false;
    }
    return true;
}

fn is_wait_timer(user_data: u64) bool {
    return user_data == constants.user_data_wait_timer or
        user_data == constants.user_data_wait_timer_update;
}

/// Consumes the wait timer's completions, which yield no event, as the reap would.
fn take_wait_timer(loop: *Loop, ready: u32) void {
    for (0..ready) |offset| {
        const cqe = loop.ring.cqe_at(@intCast(offset));
        assert(is_wait_timer(cqe.user_data));
        if (cqe.user_data == constants.user_data_wait_timer) loop.wait_timer_deadline_ns = 0;
    }
    loop.ring.cq_advance(ready);
}

/// Decision 6, amended 2026-09-27: on Linux an `io_uring_enter` that waits with a timeout costs
/// about 600 more instructions in the kernel than one without, whatever the timeout, and a timeout
/// entry that is already armed costs a wait nothing (measured on 2026-09-26). So a wait carries no
/// timeout, and the loop's one wait timer bounds it. The timer is left in place when it fires no
/// later than this wait's deadline and has not fired yet, so a loop that waits often arms it about
/// once per wait bound. One that already passed its time has a completion on its way, which ends
/// the wait, and `wait_past_early_timer` arms it again. One that fires after this deadline is moved
/// earlier. Returns false when the submission ring has no room for the entry, and the enter must
/// carry the timeout instead. A deadline that `now_ns` has reached is never armed: the tick is
/// over.
fn arm_wait_timer(loop: *Loop, now_ns: u64, deadline_ns: u64) bool {
    assert(deadline_ns > now_ns);
    const armed_ns = loop.wait_timer_deadline_ns;
    if (armed_ns != 0 and armed_ns <= deadline_ns) return true;
    const sqe = loop.ring.get_sqe() orelse return false;
    loop.wait_timer_timespec = .{
        .sec = @intCast(deadline_ns / core.constants.ns_per_s),
        .nsec = @intCast(deadline_ns % core.constants.ns_per_s),
    };
    if (armed_ns == 0) {
        submit_module.prepare_wait_timer(sqe, &loop.wait_timer_timespec);
    } else {
        submit_module.prepare_wait_timer_update(sqe, &loop.wait_timer_timespec);
    }
    loop.wait_timer_deadline_ns = deadline_ns;
    return true;
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

const testing = std.testing;
const builtin = @import("builtin");

test "only the wait timer's own entries count as the timer's completions" {
    try testing.expect(is_wait_timer(constants.user_data_wait_timer));
    try testing.expect(is_wait_timer(constants.user_data_wait_timer_update));
    try testing.expect(!is_wait_timer(constants.user_data_wake));
    try testing.expect(!is_wait_timer(constants.user_data_cancel));
    try testing.expect(!is_wait_timer(constants.user_data_group_wake));
}

/// A `nop` ends a wait at once and yields one event, so a tick shows what it did with the timer.
const one_nop = [_]core.Operation{.{ .user_data = 1, .kind = .nop }};

test "the wait timer stays armed for a later deadline and moves for an earlier one" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var memory: [Loop.memory_bytes(.{ .operations = 2 })]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, .{ .operations = 2 });
    defer loop.deinit();
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u64, 0), loop.wait_timer_deadline_ns);

    try testing.expectEqual(@as(u32, 1), loop.submit(&one_nop, &.{}));
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, core.constants.ns_per_s));
    const first_ns = loop.wait_timer_deadline_ns;
    try testing.expect(first_ns > loop.tables.now_ns);

    // A later deadline leaves the timer where it was: no entry for it.
    try testing.expectEqual(@as(u32, 1), loop.submit(&one_nop, &.{}));
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, 2 * core.constants.ns_per_s));
    try testing.expectEqual(first_ns, loop.wait_timer_deadline_ns);

    // An earlier deadline moves it, to fire first.
    try testing.expectEqual(@as(u32, 1), loop.submit(&one_nop, &.{}));
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, 10 * core.constants.ns_per_ms));
    try testing.expect(loop.wait_timer_deadline_ns < first_ns);

    // The moved timer fires where it was moved to: a quiet tick that keeps it ends at its own
    // deadline, not a second later where the timer was first.
    const wait_ns = 30 * core.constants.ns_per_ms;
    const before = clock_ns();
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, wait_ns));
    const waited = clock_ns() - before;
    try testing.expect(waited >= wait_ns - core.constants.ns_per_ms);
    try testing.expect(waited < core.constants.ns_per_s / 2);
}

test "a wait timer an earlier tick armed does not cut a later wait short" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var memory: [Loop.memory_bytes(.{ .operations = 2 })]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, .{ .operations = 2 });
    defer loop.deinit();
    var events: [4]Event = undefined;

    // A nop ends a short wait at once, and its timer stays armed.
    const short_ns = 20 * core.constants.ns_per_ms;
    try testing.expectEqual(@as(u32, 1), loop.submit(&one_nop, &.{}));
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, short_ns));
    try testing.expect(loop.wait_timer_deadline_ns != 0);

    // The next wait is longer, so it keeps that timer, which fires first. The tick waits out the
    // rest: a quiet tick takes its whole wait, as the conformance suite requires of every backend.
    const long_ns = 3 * short_ns;
    const before = clock_ns();
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, long_ns));
    try testing.expect(clock_ns() - before >= long_ns - core.constants.ns_per_ms);
    // The last timer fired, and the tick took its completion.
    try testing.expectEqual(@as(u64, 0), loop.wait_timer_deadline_ns);
}

/// Seconds the timeouts that fill a submission ring wait: an hour, far past any test, so a wait
/// with no bound of its own would hang the test rather than end when they fire.
const far_s = 3600;

/// Fills the submission ring with timeouts that end long after any test, so an enter that submits
/// them does not end because of them.
fn fill_submission_ring(loop: *Loop, far: *const linux.kernel_timespec) void {
    while (loop.ring.get_sqe()) |sqe| {
        sqe.* = std.mem.zeroes(linux.io_uring_sqe);
        sqe.opcode = .TIMEOUT;
        sqe.fd = -1;
        sqe.addr = @intFromPtr(far);
        sqe.len = 1;
        sqe.user_data = constants.user_data_cancel;
    }
}

test "a wait with no room for the timer's entry carries its timeout and takes its whole wait" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var memory: [Loop.memory_bytes(.{ .operations = 2 })]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, .{ .operations = 2 });
    defer loop.deinit();
    var events: [4]Event = undefined;
    const far: linux.kernel_timespec = .{ .sec = far_s, .nsec = 0 };
    fill_submission_ring(&loop, &far);

    const wait_ns = 20 * core.constants.ns_per_ms;
    const before = clock_ns();
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, wait_ns));
    const waited = clock_ns() - before;
    try testing.expect(waited >= wait_ns - core.constants.ns_per_ms);
    try testing.expect(waited < core.constants.ns_per_s);
    try testing.expectEqual(@as(u64, 0), loop.wait_timer_deadline_ns);
}

test "a timer that fired early with no room to arm it again leaves the rest to a timeout" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var memory: [Loop.memory_bytes(.{ .operations = 2 })]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, .{ .operations = 2 });
    defer loop.deinit();

    // A timer 5 ms out, given time to fire, and an enter that posts its completion.
    loop.tables.now_ns = clock_ns();
    const now_ns = loop.tables.now_ns;
    try testing.expect(arm_wait_timer(&loop, now_ns, now_ns + 5 * core.constants.ns_per_ms));
    _ = try loop.ring.enter(null);
    _ = try loop.ring.enter(20 * core.constants.ns_per_ms);
    try testing.expectEqual(@as(u32, 1), loop.ring.cq_ready());

    const far: linux.kernel_timespec = .{ .sec = far_s, .nsec = 0 };
    fill_submission_ring(&loop, &far);
    const wait_ns = 20 * core.constants.ns_per_ms;
    const before = clock_ns();
    try wait_past_early_timer(&loop, before + wait_ns);
    const waited = clock_ns() - before;
    try testing.expect(waited >= wait_ns - core.constants.ns_per_ms);
    try testing.expect(waited < core.constants.ns_per_s);
    try testing.expectEqual(@as(u64, 0), loop.wait_timer_deadline_ns);
}
