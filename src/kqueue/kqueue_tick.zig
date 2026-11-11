//! `tick`: one turn of the loop. In order: read the clock once, try the queued operations and
//! register the ones that must wait, finish the due timers at the head of the heap, hand over the
//! events the loop produced itself and the messages other loops posted, make the one `kevent` call,
//! perform what became ready, and last end the operations whose deadline passed, with any due timer
//! behind them.
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
pub const recover_module = @import("kqueue_tick_recover.zig");
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
    // The first stamp of the tick ends the open turn, and counts it if it is a stall (decision 28).
    tables.note_clock(clock_ns());
    submit_module.flush(loop);
    tables.finish_due_timers();
    // Before the finished list is drained, so a result a worker pushed becomes its operation's
    // final event in this tick and not the next (decision 18). A loop with no offload holds no
    // ring, and makes no call: the drain's entry alone cost each tick of such a loop about 40
    // instructions on epoll, measured with cachegrind on 2026-11-06 (decision 18, ruling (d)). The
    // check stays here, at the call: inside a helper, the compiler moved the drain's entry with it.
    const offloads = loop.inbox.completions.len != 0;
    if (offloads) _ = offload_module.drain(loop);
    // A poll with no change to carry in and no operation waiting for readiness makes no call. The
    // kernel could report only this loop's own wake event, which names no operation, and what a
    // wake announces, a message or an offload's result, is read from its ring above and below. A
    // trigger another loop sent stays set for the next call that waits, which then ends at once:
    // the wasted wake decision 12, point 6 already allows. A trigger this loop armed and has not
    // seen come back is not left: that call is made, and hands it back. The drains below change
    // none of these inputs.
    const quiet = loop.changes_used == 0 and loop.waiters.used == 0 and !loop.trigger_armed;
    // The lists stop short of the reserves of the mailboxes and of the kernel, so neither waits
    // behind a long list (W3, ruled 2026-11-07).
    const first = core.tick_share.drain_first(
        tables,
        events,
        !quiet,
        loop.inbox.registry != null,
        constants.own_entries_max,
        constants.kernel_room_max,
    );
    var produced = first.produced;
    produced += loop.drain_mailboxes(events[produced .. events.len - first.kernel_min]);

    // `settle_to_sleep` answers null at once for a tick with no bound.
    const bound = block_bound(loop, produced, wait_ns);
    const wait = loop.settle_to_sleep(bound);
    // A tick that blocks is in no turn, from here to the stamp after the wait (decision 28).
    if (wait != null) tables.note_asleep();
    const room = @min(events.len - produced, constants.readiness_max);
    // Only a poll with room to take the trigger's event arms it. A trigger the call applies and
    // cannot deliver stays set, because `EV_CLEAR` clears an event as it is delivered, and it ends
    // the next tick that waits at once. That is what a tick whose events were already full did
    // until 2026-09-22, which the conformance suite's multishot accept caught once a second loop
    // made its late connection. Whether such a tick parks as a poll with room does is not measured.
    const idle = wait == null and quiet;
    // The changes the flush and the reaps queued, before the tick adds its trigger or its timer.
    const registrations = loop.changes_used;
    if (wait == null and room != 0 and !idle) arm_poll(loop);
    const nothing: queue_module.ExchangeError!u32 = 0;
    const readiness = loop.readiness[0..room];
    const called = if (idle) nothing else call_kernel(loop, readiness, wait);
    // A failed call keeps the registrations it may not have applied (decision 12, point 10).
    const ready = recover_module.settle_changes(loop, registrations, called);
    loop.wake_up();
    // A poll that made no call has nothing to reap. What arrived since the drains above waits for
    // the next tick, which does not block while a ring holds it. It still expires, so a stream of
    // messages cannot hold a due timer off.
    //
    // A tick that was to wait and did not, because a message or a worker's result arrived after
    // the drains above, makes no call either. It takes the drains below, so the caller gets what
    // ended its wait from this tick. Without them the tick returned 0 with the result in its ring,
    // which the conformance suite saw about once in 100 loaded runs (decision 18).
    const poll = idle and bound == null;
    if (poll) return produced + after_idle(loop, events[produced..], first.capped);
    // A tick that blocked reads the clock again before it hands anything over, so `now_ns`, the
    // reap's stamps on sampled operations and the spin window all start after the wait, whatever
    // ended it (decision 9, rule 4, amended 2026-09-27). A wait that failed reads it too, before
    // the tick returns. So the turn after the failure starts, and a stall or a watch can see it
    // (decision 28).
    if (wait != null) tables.note_woken(clock_ns());
    // A failed call after events were produced returns those events, whose slots are released
    // already, and the next tick returns the error (decision 5, amendment of 2026-11-06).
    const ready_count = ready catch |failure|
        return loop.kept_error.keep(&tables.outstanding, failure, produced);
    return after_kernel(loop, events, produced, ready_count, offloads, first.capped);
}

/// The last steps of a tick that made no call: the places the reserves kept and nothing used go
/// back to the lists when the lists filled their share (W3), then the deadlines. A quiet loop keeps
/// no kernel reserve, so the mailboxes already had every place they could use. Returns how many
/// events it wrote into `events`.
fn after_idle(loop: *Loop, events: []Event, capped: bool) u32 {
    const tables = &loop.tables;
    var produced: u32 = 0;
    if (capped) produced += tables.drain_finished(events);
    produced += tables.expire_after_reap(loop, cancel_module.request, events[produced..]);
    assert(produced <= events.len);
    return produced;
}

/// The tick's last steps, after a kernel call that succeeded or a sleep the inbox refused: the
/// reap, the posted messages, the results a worker pushed while the tick waited, the lists again,
/// and the deadlines. `before` events are already in `events`. The places the kernel's reserve
/// kept and the reap did not use go back to the mailboxes, and then to the lists when the lists
/// filled their share (W3, ruled 2026-11-07). Returns how many events there are now.
fn after_kernel(
    loop: *Loop,
    events: []Event,
    before: u32,
    ready_count: u32,
    offloads: bool,
    capped: bool,
) u32 {
    const tables = &loop.tables;
    var produced = before;
    const reaped = reap_module.reap(loop, loop.readiness[0..ready_count], events[produced..]);
    // A test build permutes the batch the kernel answered (decision 10, amendment of 2026-11-06).
    if (core.shuffle.enabled) tables.shuffle.reaped(events[produced..][0..reaped]);
    produced += reaped;
    produced += loop.drain_mailboxes(events[produced..]);
    // A worker may have answered while this tick waited, and the wake is what ended the wait.
    const moved = offloads and offload_module.drain(loop) != 0;
    if (capped or moved) produced += tables.drain_finished(events[produced..]);
    // After the reap, so a descriptor the kernel reported ready ends its operation with the
    // transfer's result and not with `timeout` (issue 10).
    const full = ready_count == @min(events.len - before, constants.readiness_max);
    produced += expire_after_reap(loop, events[produced..], full, ready_count);
    assert(produced <= events.len);
    return produced;
}

/// The tick's expiry, after the reap. While a deadline is due and the kernel's answer was full,
/// the answer may have left readiness in the kernel, which `reap_past_own_entries` reaps first.
/// Returns how many events it wrote into `events`.
fn expire_after_reap(loop: *Loop, events: []Event, full: bool, answered: u32) u32 {
    const tables = &loop.tables;
    const earliest_ns = tables.timers.earliest_ns() orelse return 0;
    if (earliest_ns > tables.now_ns) return 0;
    const reaped = if (full) reap_past_own_entries(loop, events, answered) else 0;
    return reaped + tables.expire_after_reap(loop, cancel_module.request, events[reaped..]);
}

/// A full answer can hold entries that name no operation, the wake trigger, the wait timer or the
/// group watch, in the places of readiness the kernel still holds. A deadline due in this tick
/// would then end such an operation with `timeout` and not with its result (issue 10). So while a
/// deadline is due and the last answer was full and held such entries, the tick polls again for
/// that many places and reaps them. The loop's own entries clear as they are delivered, so each
/// call finds fewer of them. A call that continues delivered at least one own entry, so the count
/// of own entries, `own_entries_max`, also bounds the count of calls. Returns how many events it
/// wrote into `events`.
fn reap_past_own_entries(loop: *Loop, events: []Event, answered: u32) u32 {
    const tables = &loop.tables;
    var own = own_entries(loop, loop.readiness[0..answered]);
    var produced: u32 = 0;
    var calls: u32 = 0;
    while (own != 0 and calls < constants.own_entries_max) : (calls += 1) {
        const room = @min(own, events.len - produced);
        if (room == 0) break;
        const readiness = loop.readiness[0..room];
        // A call that fails here fails again in the next tick, which returns the error.
        const count = loop.queue.exchange(&.{}, readiness, null) catch break;
        const reaped = reap_module.reap(loop, readiness[0..count], events[produced..]);
        if (core.shuffle.enabled) tables.shuffle.reaped(events[produced..][0..reaped]);
        produced += reaped;
        own = if (count == room) own_entries(loop, readiness[0..count]) else 0;
    }
    assert(produced <= events.len);
    return produced;
}

/// How many entries of `readiness` name no operation: the wake trigger, the wait timer and the
/// group watch, as `reap` tells them apart.
fn own_entries(loop: *const Loop, readiness: []const Kevent) u32 {
    var count: u32 = 0;
    for (readiness) |*ready| {
        const watch = ready.ident == loop.group_watch and ready.filter == std.c.EVFILT.READ;
        const own = watch or ready.filter == std.c.EVFILT.TIMER or ready.filter == std.c.EVFILT.USER;
        if (own) count += 1;
    }
    return count;
}

/// Decision 13: polls with ticks that do not wait until one spin budget after the loop last handed
/// over an event, and blocks for what is left of `wait_ns` only if nothing came. A poll is `tick`
/// with a zero wait and nothing else, so what arrives while the loop polls is handed over as a
/// blocking tick would hand it. A tick after that window, or with a timer or a poller's limit due
/// inside it, does not poll. `Loop.tick` calls this only when `core.spin.applies`.
pub fn spin_then_wait(loop: *Loop, events: []Event, wait_ns: u64) TickError!u32 {
    const tables = &loop.tables;
    assert(core.spin.applies(tables.spin.budget_ns, wait_ns));
    const first = try tick(loop, events, 0);
    if (first != 0) return first;
    const start_ns = tables.now_ns;
    const earliest_ns = tables.earliest_deadline_ns();
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
/// the timeout itself only when the changelist has no room left to arm the timer. When the first
/// wait succeeds and a later one fails, the first applied the list, and `recover` sends it again.
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
pub fn wait_past_early_timer(
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

/// How long a tick that produced `produced` events may block, or null when it may not. A drain
/// that handed a call or a return to a reactor's hook queued a task, which the next tick runs: this
/// tick does not block, as after an event (decision 33, "The reserved hook"). Only a tick that
/// would block takes the flag, so a poll of the spin of decision 13 keeps it for the tick that
/// ends the spin.
fn block_bound(loop: *Loop, produced: u32, wait_ns: u64) ?u64 {
    if (produced != 0) return null;
    const bound = loop.tables.wait_bound(wait_ns) orelse return null;
    if (loop.inbox.take_handed()) return null;
    return bound;
}

/// The monotonic clock, in nanoseconds. Read once per tick, and once more after a wait that
/// blocked (decision 9, rule 4). `kqueue_testing.zig` hands it to the tests, so a test
/// measures with the clock the tick reads.
///
/// It is `CLOCK_MONOTONIC_RAW`, which on macOS counts in 41 ns steps. `CLOCK_MONOTONIC` there
/// counts in 1,000 ns steps and costs 20.1 ns a read, measured on macOS 26.6.2 on 2026-09-26. Both
/// keep counting while the machine sleeps. `bench/harness/clock.zig` reads the same clock, so a
/// benchmark's spans and a loop's deadlines agree.
///
/// It is read with `clock_gettime_nsec_np`, which answers nanoseconds. `clock_gettime` calls it
/// and then splits the answer into a `timespec`, which this function would join again: 17.1 ns a
/// read against 11.0, measured on macOS 26.6.2 on 2026-09-29 at a load average of about 11.
pub fn clock_ns() u64 {
    const now = clock_gettime_nsec_np(.MONOTONIC_RAW);
    // It answers 0 only for a clock it does not know, and it knows this one.
    assert(now != 0);
    return now;
}

/// Darwin's `clock_gettime_nsec_np`, which Zig's standard library does not declare.
extern "c" fn clock_gettime_nsec_np(clock: std.c.clockid_t) u64;
