//! `tick`: one turn of the loop, and the one system call it makes (decision 3, source 4). In
//! order: read the clock once, hand queued operations to the kernel and posts to the mailbox rings,
//! finish the due timers at the head of the heap, give waiting cancels their entries, hand the
//! caller the events the loop produced itself and the messages other loops posted, enter the
//! kernel, reap, read the mailboxes again, and last cancel the operations whose deadline passed,
//! with any due timer behind them. An enter that blocks carries no timeout, because the loop's wait
//! timer, armed in the same batch, bounds it; when that timer fires before this tick's deadline,
//! the tick waits again (decision 6, amended 2026-09-27).
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
    // The first stamp of the tick ends the open turn, and counts it if it is a stall (decision 28).
    tables.note_clock(clock_ns());
    submit_module.flush(loop);
    tables.finish_due_timers();
    cancel_module.flush(loop);
    // The lists stop short of the reserves of the mailboxes and of the kernel, so neither waits
    // behind a long list (W3, ruled 2026-11-07). A completion that names no operation takes no
    // place, so the kernel's reserve adds no own entry.
    const first = core.tick_share.drain_first(
        tables,
        events,
        true,
        loop.inbox.registry != null,
        constants.own_entries_max,
        core.constants.batch_max,
    );
    var produced = first.produced;
    produced += loop.drain_mailboxes(events[produced .. events.len - first.kernel_min]);
    // The loop says it sleeps before it waits, and reads its mailboxes once more, so a post that
    // came before the flag was set is not slept on (decision 12, point 6). It says it is awake
    // again before an error can leave the tick.
    const wait = if (produced == 0) loop.settle_to_sleep(wait_for(loop, wait_ns)) else null;
    // A tick that blocks is in no turn, from here to the stamp after the wait (decision 28).
    if (wait != null) tables.note_asleep();
    const entering = enter_bounded(loop, wait);
    loop.wake_up();
    // A tick that blocked reads the clock again before it hands anything over, so `now_ns`, the
    // reap's stamps on sampled operations and the spin window all start after the wait, whatever
    // ended it (decision 9, rule 4, amended 2026-09-27). A wait that failed reads it too, before
    // the tick returns. So the turn after the failure starts, and a stall or a watch can see it
    // (decision 28).
    if (wait != null) tables.note_woken(clock_ns());
    // A failed enter after events were produced returns those events, whose slots are released
    // already, and the next tick returns the error (decision 5, amendment of 2026-11-06).
    const entered = entering catch |failure|
        return loop.kept_error.keep(&tables.dispatch, failure, produced);
    // The kernel has read every address of this flush's connects, and every message header of
    // its datagram operations, unless it took no entry. Both scratches are one per entry and are
    // reused from the start each tick; a counter that only rose would stop the loop after
    // `entries` datagrams, which is what `bench/datagram/rotor_datagram.zig` found.
    if (entered == .submitted) {
        loop.addresses_used = 0;
        loop.messages_used = 0;
    }
    const reaped = reap_module.reap(loop, events[produced..]);
    // A test build permutes the batch the kernel answered (decision 10, amendment of 2026-11-06).
    if (core.shuffle.enabled) tables.shuffle.reaped(events[produced..][0..reaped]);
    produced += reaped;
    // The places the kernel's reserve kept and the reap did not use go back to the mailboxes, and
    // then to the lists when the lists filled their share (W3).
    produced += loop.drain_mailboxes(events[produced..]);
    if (first.capped) produced += tables.drain_finished(events[produced..]);
    // After the reap, so a completion the kernel had ready wins over the deadline (issue 10). With
    // `DEFER_TASKRUN` a completion is posted only inside an enter, so the deadline's cancel entry
    // goes to the kernel in the next tick, and that tick does not block while it waits.
    produced += tables.expire_after_reap(loop, cancel_module.request, events[produced..]);
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

    // The first deadline is seconds away, so a busy machine does not reach it in this test.
    const first_wait_ns = core.constants.wait_ns_max / 2;
    try testing.expectEqual(@as(u32, 1), loop.submit(&one_nop, &.{}));
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, first_wait_ns));
    const first_ns = loop.wait_timer_deadline_ns;
    try testing.expect(first_ns > loop.tables.now_ns);

    // A later deadline leaves the timer where it was: no entry for it.
    try testing.expectEqual(@as(u32, 1), loop.submit(&one_nop, &.{}));
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, core.constants.wait_ns_max));
    try testing.expectEqual(first_ns, loop.wait_timer_deadline_ns);

    // An earlier deadline moves it, to fire first.
    try testing.expectEqual(@as(u32, 1), loop.submit(&one_nop, &.{}));
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, 10 * core.constants.ns_per_ms));
    try testing.expect(loop.wait_timer_deadline_ns < first_ns);

    // The moved timer fires where it was moved to: a quiet tick that keeps it takes its whole
    // wait and ends before the first deadline, where a timer the kernel did not move fires. A
    // busy machine makes a wait longer and never shorter, so it cannot break the first check,
    // and the second has seconds to spare.
    const wait_ns = 30 * core.constants.ns_per_ms;
    const before = clock_ns();
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, wait_ns));
    const after = clock_ns();
    try testing.expect(after - before >= wait_ns - core.constants.ns_per_ms);
    try testing.expect(after < first_ns);
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

/// How long a test waits for a completion of its own setup before it fails: the longest wait a tick
/// allows, far past the 5 ms timer the test arms. Only a lost completion reaches this bound.
const setup_wait_ns = core.constants.wait_ns_max;

/// The enters a setup wait makes at most. An enter ends at a completion, at the bound, or early
/// with none posted, so more than one can be necessary (`constants.empty_wakes_max`).
const setup_enters_max = 16;

/// Waits up to `setup_wait_ns` for the kernel to post a completion. When none comes, it fails the
/// test with a message. An enter with no bound would wait forever.
fn wait_for_completion(loop: *Loop) !void {
    const start_ns = clock_ns();
    const deadline_ns = start_ns + setup_wait_ns;
    for (0..setup_enters_max) |_| {
        if (loop.ring.cq_ready() != 0) return;
        const now_ns = clock_ns();
        if (now_ns >= deadline_ns) break;
        const entered = try loop.ring.enter(deadline_ns - now_ns);
        try testing.expectEqual(ring_module.Entered.submitted, entered);
    }
    if (loop.ring.cq_ready() != 0) return;
    std.debug.print("the kernel posted no completion in {d} ms\n", .{
        (clock_ns() - start_ns) / core.constants.ns_per_ms,
    });
    return error.TestUnexpectedResult;
}

test "a timer that fired early with no room to arm it again leaves the rest to a timeout" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var memory: [Loop.memory_bytes(.{ .operations = 2 })]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, .{ .operations = 2 });
    defer loop.deinit();

    // A timer 5 ms out, and enters that wait for its completion up to `setup_wait_ns`. A bound of
    // 20 ms ended first once, on a GitHub arm64 runner running every test binary at once (run
    // 36607058823). A bound of 1 s ended once with no completion posted, at a load of 17.
    loop.tables.now_ns = clock_ns();
    const now_ns = loop.tables.now_ns;
    try testing.expect(arm_wait_timer(&loop, now_ns, now_ns + 5 * core.constants.ns_per_ms));
    _ = try loop.ring.enter(null);
    try wait_for_completion(&loop);
    try testing.expectEqual(@as(u32, 1), loop.ring.cq_ready());

    const far: linux.kernel_timespec = .{ .sec = far_s, .nsec = 0 };
    fill_submission_ring(&loop, &far);
    const wait_ns = 20 * core.constants.ns_per_ms;
    const before = clock_ns();
    try wait_past_early_timer(&loop, before + wait_ns);
    const waited = clock_ns() - before;
    // A busy machine makes a wait longer and never shorter. So the upper bound has seconds to
    // spare, and it still fails a wait to the longest bound a tick allows.
    try testing.expect(waited >= wait_ns - core.constants.ns_per_ms);
    try testing.expect(waited < core.constants.wait_ns_max / 2);
    try testing.expectEqual(@as(u64, 0), loop.wait_timer_deadline_ns);
}

/// A record that counts the final events it receives (decision 26).
const Record = struct {
    completion: core.Completion = .init(Record, "completion", called),
    finals: u32 = 0,

    fn called(record: *Record, event: Event) void {
        assert(!event.flags.more);
        record.finals += 1;
    }
};

test "a tick whose enter fails after it produced events returns them, and the next tick fails" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var memory: [Loop.memory_bytes(.{ .operations = 4 })]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, .{ .operations = 4 });
    defer loop.deinit();
    var ends: [2]i32 = undefined;
    const kind = linux.SOCK.STREAM | linux.SOCK.CLOEXEC;
    try testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, kind, 0, &ends));
    defer for (ends) |end| {
        _ = linux.close(end);
    };

    // Two timers end in the next tick before its enter: one with a record, one without. The nop
    // gives the enter an entry to submit, and a socket in place of the ring makes it fail.
    var record: Record = .{};
    const operations = [_]core.Operation{
        .timer(2, 0, 0),
        core.Operation.timer(0, 0, 0).completion(&record.completion),
        one_nop[0],
    };
    try testing.expectEqual(@as(u32, 3), loop.submit(&operations, &.{}));
    const ring = loop.ring.io.fd;
    const saved: i32 = @intCast(linux.dup(ring));
    try testing.expectEqual(@as(usize, @intCast(ring)), linux.dup3(ends[1], ring, 0));

    // The tick hands over the timer without a record and calls the other's record. The kept
    // error takes the next tick off the fast path.
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, 0));
    try testing.expectEqual(@as(u64, 2), events[0].user_data);
    try testing.expectEqual(@as(u32, 1), record.finals);
    try testing.expect(!loop.tables.dispatch.idle());
    // The next tick returns the kept error before anything else. A tick that produced nothing
    // returns its own error at once: the nop's entry is still there to submit.
    try testing.expectError(error.Unexpected, loop.tick(&events, 0));
    try testing.expect(loop.tables.dispatch.idle());
    try testing.expectError(error.Unexpected, loop.tick(&events, 0));
    // A tick that waits and fails reads the clock after the failure, so a turn is open: the time
    // until the next tick can be a stall, and a watch can see it (decision 28).
    try testing.expectError(error.Unexpected, loop.tick(&events, core.constants.ns_per_s));
    try testing.expect(loop.tables.heartbeat.beat_ns.load(.monotonic) != core.stall.asleep);

    _ = linux.dup3(saved, ring, 0);
    _ = linux.close(saved);
    // A failed tick that produced nothing keeps nothing, so this tick runs, and the nop ends.
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, core.constants.ns_per_s));
    try testing.expectEqual(one_nop[0].user_data, events[0].user_data);
    try testing.expectEqual(@as(u32, 0), loop.in_flight());
}
