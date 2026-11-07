//! Repeating timers (decision 14). The three rules that record makes, each checked on whichever
//! kernel the build gives this suite, because a timer is the one thing both backends do entirely
//! in rotor's own heap and so the two must agree exactly.
//!
//! Rules 3 and 4 are the reason the record exists, and they are checked by holding the loop off
//! its tick on purpose: a caller that is late must not make the period late, and the deadlines it
//! missed must still be handed over.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Operation = core.Operation;

const ms = core.constants.ns_per_ms;

/// The period the scenarios repeat at. Long enough that a busy machine does not turn one period
/// into two, short enough that a scenario runs in well under a second.
const period_ns = 20 * ms;

/// Busy-waits without ticking, which is what a caller that is slow looks like to the loop.
pub fn hold_off(nanoseconds: u64) void {
    const until = now_ns() + nanoseconds;
    while (now_ns() < until) {}
}

/// The backend's own monotonic clock. This file read one itself until 2026-09-22, spelling the
/// syscall twice for the two kernels, which both backends already export for their own tests. The
/// determinism rule reads `src/` outside the backends, so a clock spelled here was a clock it could
/// not see; taking the backend's keeps one definition per kernel and the rule's scope intact.
const now_ns = backend.testing.monotonic_ns;

const fires_wanted = 3;

test "a repeating timer fires again and again, and a cancel ends it with one final event" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();

    var handles: [1]core.Handle = undefined;
    try harness.submit(&.{Operation.timer(7, period_ns, period_ns)}, &handles);

    var events: [4]Event = undefined;
    var fired: u32 = 0;
    while (fired < fires_wanted) {
        const count = try harness.loop.tick(&events, core.constants.ns_per_s);
        for (events[0..count]) |event| {
            try testing.expectEqual(@as(u64, 7), event.user_data);
            try testing.expectEqual(@as(u32, 0), try event.outcome());
            // Every fire but the last says there is more to come (decision 14, rule 2).
            try testing.expect(event.flags.more);
            fired += 1;
        }
    }
    // It is still the loop's: one operation, however many events it has produced.
    try testing.expectEqual(@as(u32, 1), harness.loop.in_flight());

    harness.loop.cancel(handles[0]);
    var last: [1]Event = undefined;
    try harness.collect(&last);
    try testing.expectEqual(@as(u64, 7), last[0].user_data);
    try testing.expectError(error.Canceled, last[0].outcome());
    try testing.expect(!last[0].flags.more);
    try testing.expectEqual(@as(u32, 0), harness.loop.in_flight());
}

/// Ticks the scenarios below wait for a cancelled timer's final event, each up to a period. A timer
/// whose cancel was lost fires with `more` in every one of them.
const final_rounds_max = 8;

/// Submits two repeating timers in one batch, so one flush arms both for the same deadline, and
/// ticks with room for one event until a fire arrives. Both are due in that tick, and the tick
/// hands over one: the other timer's fire stays queued in the loop for the next tick. Answers the
/// position in `handles` of the timer whose fire was not handed over.
fn one_fire_left_queued(harness: *Harness, handles: *[2]core.Handle) !usize {
    try harness.submit(&.{
        Operation.timer(21, period_ns, period_ns),
        Operation.timer(22, period_ns, period_ns),
    }, handles);
    var one: [1]Event = undefined;
    try harness.collect(&one);
    try testing.expect(one[0].flags.more);
    try testing.expectEqual(@as(u32, 2), harness.loop.in_flight());
    return if (one[0].user_data == 21) 1 else 0;
}

/// Ticks until the event for `user_data` that says no `more` arrives, and answers it, with how many
/// events for `user_data` came before it. Fails when it has not come in `final_rounds_max` ticks.
fn await_final(harness: *Harness, user_data: u64, before: *u32) !Event {
    var events: [4]Event = undefined;
    var round: u32 = 0;
    while (round < final_rounds_max) : (round += 1) {
        const count = try harness.loop.tick(&events, period_ns);
        for (events[0..count]) |event| {
            if (event.user_data != user_data) continue;
            if (!event.flags.more) return event;
            before.* += 1;
        }
    }
    return error.FinalEventMissing;
}

test "a cancel of a repeating timer whose fire is queued and not handed over still ends it" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();

    var handles: [2]core.Handle = undefined;
    const left = try one_fire_left_queued(&harness, &handles);
    const left_user_data: u64 = if (left == 0) 21 else 22;

    // The cancel comes between the tick that queued the fire and the tick that hands it over.
    // Decision 5, rule 2 answers it with the timer's final event. The cancel replaces the queued
    // fire, by Camilo's ruling of 2026-09-23: the next event is that final one, and it says
    // `canceled` (decision 14, rule 5).
    harness.loop.cancel(handles[left]);
    var before: u32 = 0;
    const final = try await_final(&harness, left_user_data, &before);
    try testing.expectEqual(@as(u32, 0), before);
    try testing.expectError(error.Canceled, final.outcome());
    // The other timer still repeats, and nothing else of the cancelled one is left in the loop.
    try testing.expectEqual(@as(u32, 1), harness.loop.in_flight());

    harness.loop.cancel(handles[1 - left]);
    var events: [4]Event = undefined;
    try harness.loop.drain(&events);
}

test "cancel_all and drain end a repeating timer whose fire is queued and not handed over" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();

    var handles: [2]core.Handle = undefined;
    _ = try one_fire_left_queued(&harness, &handles);
    // Decision 5, rule 7: every operation ends, the one whose fire is queued among them.
    harness.loop.cancel_all();
    var events: [4]Event = undefined;
    try harness.loop.drain(&events);
    try testing.expectEqual(@as(u32, 0), harness.loop.in_flight());
}

/// Periods a held-off loop misses before it ticks again.
const missed = 4;

test "a loop held off its tick is handed the deadlines it missed, and does not skip them" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();

    var handles: [1]core.Handle = undefined;
    try harness.submit(&.{Operation.timer(9, period_ns, period_ns)}, &handles);
    // The submit arms nothing: the next tick does. One tick with no wait starts the clock.
    var events: [8]Event = undefined;
    _ = try harness.loop.tick(&events, 0);

    // Now be a slow caller, through more than `missed` whole periods.
    hold_off((missed + 1) * period_ns);

    // Every deadline that passed is handed over, one per tick, and none is swallowed
    // (decision 14, rule 4).
    var fired: u32 = 0;
    var rounds: u32 = 0;
    while (fired < missed and rounds < 64) : (rounds += 1) {
        const count = try harness.loop.tick(&events, ms);
        for (events[0..count]) |event| {
            try testing.expectEqual(@as(u64, 9), event.user_data);
            try testing.expect(event.flags.more);
            fired += 1;
        }
    }
    try testing.expect(fired >= missed);

    harness.loop.cancel(handles[0]);
    try harness.loop.drain(&events);
}

/// Attempts the drift scenario gets. An attempt decides only when a tick reads the clock in the
/// window where the two kinds of loop differ. A thread preempted through that whole window makes
/// no tick there, and the attempt decides nothing. It cannot pass a loop that drifts. The
/// scenario returns at the first attempt that decides, so the count costs nothing on a quiet
/// machine.
///
/// Until 2026-11-07 the scenario timed two fires with the host clock and compared them to a bound.
/// Under load on macOS, 16 copies of the suite beside 12 busy loops, the best of ten attempts
/// measured 49.1 ms against a bound of 47.5 ms. Preemption of the test thread made a punctual
/// loop look late. The window check reads only `now_ns`, so the time the thread waits to run
/// cannot change the verdict.
const drift_attempts = 10;

test "a repeating timer's period is measured from its deadline, so a late loop does not drift" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var attempt: u32 = 0;
    while (attempt < drift_attempts) : (attempt += 1) {
        if (try second_fire_decides()) return;
    }
    // No attempt made a tick in the window, so none could tell a punctual loop from one that drifts.
    return error.NoTickInDriftWindow;
}

/// One attempt. Takes the first fire of a repeating timer late, then ticks without a wait until the
/// second fire comes. Returns whether the tick that handed the second fire read the clock in the
/// window between two second deadlines: the one measured from the first deadline, and the one a
/// loop that drifts measures from the clock.
fn second_fire_decides() !bool {
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();

    var handles: [1]core.Handle = undefined;
    try harness.submit(&.{Operation.timer(11, period_ns, period_ns)}, &handles);
    var events: [8]Event = undefined;
    // The submit arms nothing. This tick arms the timer, and its reading starts the first period.
    _ = try harness.loop.tick(&events, 0);
    // The second deadline, measured from the first deadline (decision 14, rule 3).
    const second_due_ns = harness.loop.now_ns() + 2 * period_ns;

    // Be late before the first fire is taken. The loop sees the first deadline three quarters of
    // a period after it passed, and the second deadline stays two periods from the start.
    //
    // A loop that schedules the next fire from the clock puts it one period after the tick that
    // took the first fire: 2.75 periods or later. A hold after the first fire cannot tell the two
    // loops apart, because the re-arm happened before the hold. The first version of this test
    // held off there, and passed against a loop that drifted.
    hold_off(period_ns * 7 / 4);

    // The first deadline passed, so the next tick hands its fire. A hold that overran the second
    // deadline too gets that fire in the same tick, after the re-arm.
    var fired = try take_fires(&harness, &events, 0, second_due_ns);
    try testing.expect(fired >= 1);
    // A loop that drifts measures the second deadline from this reading.
    const drifted_due_ns = harness.loop.now_ns() + period_ns;
    while (fired < 2) fired = try take_fires(&harness, &events, fired, second_due_ns);
    const fired_ns = harness.loop.now_ns();
    // A fire comes no earlier than its deadline.
    try testing.expect(fired_ns >= second_due_ns);

    harness.loop.cancel(handles[0]);
    try harness.loop.drain(&events);
    // The second fire came at a tick before the deadline of a loop that drifts. Such a loop would
    // have handed only the first fire by then, and `take_fires` would have failed.
    return fired_ns < drifted_due_ns;
}

/// One tick without a wait, for the drift scenario. Returns how many fires the scenario has after
/// it, from `fired` before it. A tick that read the clock at or past the second deadline has handed
/// the second fire. A loop that drifts holds that fire until its own deadline, and fails here when
/// a tick reads the clock between the two. The check also ends the scenario's loop, because the
/// clock passes the second deadline.
fn take_fires(harness: *Harness, events: []Event, fired: u32, second_due_ns: u64) !u32 {
    const count = try harness.loop.tick(events, 0);
    for (events[0..count]) |event| {
        try testing.expectEqual(@as(u64, 11), event.user_data);
        try testing.expect(event.flags.more);
    }
    const total = fired + count;
    try testing.expect(total >= 2 or harness.loop.now_ns() < second_due_ns);
    return total;
}

test "now_ns is 0 before the first tick, and the tick that fires a timer has read its deadline" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    try testing.expectEqual(@as(u64, 0), harness.loop.now_ns());

    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&events, 0));
    const submitted_ns = harness.loop.now_ns();
    // The backend's own monotonic clock, read after the tick, is at or past what the tick read.
    try testing.expect(submitted_ns >= 1);
    try testing.expect(submitted_ns <= now_ns());

    // The timer's delay runs from this reading (decision 14, rule 6), so the tick that hands the
    // fire over read at least this one plus the wait. Each tick's reading is at or past the one
    // before.
    var handles: [1]core.Handle = undefined;
    try harness.submit(&.{Operation.timer(9, period_ns, 0)}, &handles);
    var previous_ns = submitted_ns;
    var count: u32 = 0;
    while (count == 0) {
        count = try harness.loop.tick(&events, core.constants.ns_per_s);
        try testing.expect(harness.loop.now_ns() >= previous_ns);
        previous_ns = harness.loop.now_ns();
    }
    try testing.expectEqual(@as(u32, 1), count);
    try testing.expectEqual(@as(u64, 9), events[0].user_data);
    try testing.expect(harness.loop.now_ns() >= submitted_ns + period_ns);
}

/// How long the caller holds the loop off before it submits, in the scenario of a timer's start.
const held_ns = 50 * ms;

/// That scenario's delay: twice the hold.
const delay_ns = 2 * held_ns;

/// The delay of that scenario's second timer, which the caller arms after the tick that arms the
/// first. That tick reads the clock at least a hold after the first timer's start. If the first
/// timer starts at the reading the caller saw, the second is due a half hold after it. If the first
/// starts at the tick that armed it, the second is due a half hold before it.
const second_delay_ns = delay_ns - held_ns / 2;

/// The fires of the scenario of a timer's start, in the order the loop hands them over. Each fire
/// keeps `now_ns` of the tick that handed it over.
const Fires = struct {
    user_data: [2]u64 = .{ 0, 0 },
    fired_ns: [2]u64 = .{ 0, 0 },
    count: u32 = 0,

    fn tick(fires: *Fires, harness: *Harness, wait_ns: u64) !void {
        var events: [2]Event = undefined;
        const count = try harness.loop.tick(&events, wait_ns);
        try testing.expect(fires.count + count <= fires.user_data.len);
        for (events[0..count]) |event| {
            try testing.expectEqual(@as(u32, 0), try event.outcome());
            fires.user_data[fires.count] = event.user_data;
            fires.fired_ns[fires.count] = harness.loop.now_ns();
            fires.count += 1;
        }
    }
};

// Until 2026-11-07 this scenario also required the fire within one delay of the submit, by the
// host clock. Under load the process ran late: a fire came 136 ms and 184 ms after the submit,
// against 100 ms. The order of two timers checks the same start and needs no bound on lateness.
test "a timer's delay runs from now_ns as the caller saw it, not from the tick after the submit" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&events, 0));
    const seen_ns = harness.loop.now_ns();

    // The caller works for a while after the tick, then arms a timer. Its delay starts at the
    // reading the caller saw (decision 14, rule 6).
    hold_off(held_ns);
    try harness.submit(&.{Operation.timer(12, delay_ns, 0)}, &.{});
    var fires: Fires = .{};
    try fires.tick(&harness, 0);
    const armed_ns = harness.loop.now_ns();
    try testing.expect(armed_ns >= seen_ns + held_ns);

    // The loop hands over due timers in deadline order. So the order of the two fires shows where
    // the first delay started, and a late tick does not change the order.
    try harness.submit(&.{Operation.timer(13, second_delay_ns, 0)}, &.{});
    while (fires.count < 2) try fires.tick(&harness, core.constants.ns_per_s);
    try testing.expectEqual([2]u64{ 12, 13 }, fires.user_data);
    // Never earlier than the reading plus the delay, which is the promise.
    try testing.expect(fires.fired_ns[0] >= seen_ns + delay_ns);
    try testing.expect(fires.fired_ns[1] >= armed_ns + second_delay_ns);
}

test "a timer submitted before any tick runs its delay from the first tick's reading" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    // No tick has read the clock, so `now_ns` is 0 and cannot be the start: the first tick is.
    try harness.submit(&.{Operation.timer(13, period_ns, 0)}, &.{});
    hold_off(2 * period_ns);
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&events, 0));
    const first_ns = harness.loop.now_ns();
    var count: u32 = 0;
    while (count == 0) count = try harness.loop.tick(&events, core.constants.ns_per_s);
    try testing.expect(harness.loop.now_ns() >= first_ns + period_ns);
}

test "a tick with an event of its own to hand over still fires the timer that is due" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();

    var handles: [2]core.Handle = undefined;
    try harness.submit(&.{Operation.timer(9, period_ns, 0)}, handles[0..1]);
    var events: [2]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&events, 0));
    hold_off(2 * period_ns);

    // A cancel of a timer still queued ends it in the next flush, so that tick has an event to
    // hand over before it asks the kernel anything, and nothing waits for readiness. It hands the
    // due timer over all the same (issue 10).
    try harness.submit(&.{Operation.timer(8, period_ns, 0)}, handles[1..2]);
    harness.loop.cancel(handles[1]);
    try testing.expectEqual(@as(u32, 2), try harness.loop.tick(&events, 0));
    // The due timer waits on the fired list, so it can come first (W3, ruled 2026-11-07).
    try testing.expectError(error.Canceled, (try Harness.find(&events, 8)).outcome());
    try testing.expectEqual(@as(u32, 0), try (try Harness.find(&events, 9)).outcome());
    try testing.expectEqual(@as(u32, 0), harness.loop.in_flight());
}
