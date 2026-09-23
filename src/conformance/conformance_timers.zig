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

fn repeating(user_data: u64, after_ns: u64, repeat_ns: u64) Operation {
    return .{ .user_data = user_data, .kind = .{ .timer = .{
        .after_ns = after_ns,
        .repeat_ns = repeat_ns,
    } } };
}

/// Busy-waits without ticking, which is what a caller that is slow looks like to the loop.
fn hold_off(nanoseconds: u64) void {
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
    try harness.submit(&.{repeating(7, period_ns, period_ns)}, &handles);

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
        repeating(21, period_ns, period_ns),
        repeating(22, period_ns, period_ns),
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
    // fire, by the owner's ruling of 2026-09-23: the next event is that final one, and it says
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
    try harness.submit(&.{repeating(9, period_ns, period_ns)}, &handles);
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

/// Attempts the drift measurement gets. A loop that schedules from the clock drifts on every one
/// of them, so the verdict is the best attempt, not the first: the noise here is one-sided.
/// Preempting this thread can only make a punctual loop look late, never make a late loop look
/// punctual, so a single attempt fails on a busy machine while proving nothing. The first version
/// took one attempt and failed `zig build test`, which runs the suites in parallel.
///
/// Ten and not five, because the worst load this test meets is the run right after a rebuild,
/// when the compiler holds every core and the drift signal is three quarters of a period. The
/// scenario returns on the first attempt under the bound, so the count costs nothing when the
/// machine is quiet.
const drift_attempts = 10;

test "a repeating timer's period is measured from its deadline, so a late loop does not drift" {
    if (conformance.unsupported()) return error.SkipZigTest;
    // Two periods without drift; 2.75 with. The bound sits between them, a quarter of a period
    // from each, which a busy machine has to eat before it can turn one verdict into the other.
    const drifted_ns = period_ns * 11 / 4;
    const bound_ns = (2 * period_ns + drifted_ns) / 2;

    var best_ns: u64 = std.math.maxInt(u64);
    var attempt: u32 = 0;
    while (attempt < drift_attempts) : (attempt += 1) {
        best_ns = @min(best_ns, try measure_two_fires());
        if (best_ns < bound_ns) return;
    }
    try testing.expect(best_ns < bound_ns);
}

/// One attempt: how long two fires of a repeating timer take, measured from the tick that armed
/// it, with the loop held off before the first fire is taken.
fn measure_two_fires() !u64 {
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();

    var handles: [1]core.Handle = undefined;
    try harness.submit(&.{repeating(11, period_ns, period_ns)}, &handles);
    var events: [8]Event = undefined;
    // The submit arms nothing; this tick does, and it is when the first deadline starts running.
    _ = try harness.loop.tick(&events, 0);
    const started_ns = now_ns();

    // Be late *before* the first fire is taken, not after. That is the whole of this test: the
    // loop must notice the first deadline three quarters of a period after it passed, and the
    // second deadline must still be two periods from the start.
    //
    // A loop that schedules the next fire from the clock puts it at 1.75 + 1 periods. One that
    // schedules from the deadline puts it at 2. Holding off *after* taking a fire cannot tell
    // them apart, because the re-arm has already happened by then, and the first version of this
    // test did exactly that and passed against a loop that drifted.
    hold_off(period_ns * 7 / 4);

    var fired: u32 = 0;
    while (fired < 2) {
        const count = try harness.loop.tick(&events, core.constants.ns_per_s);
        for (events[0..count]) |event| try testing.expect(event.flags.more);
        fired += count;
    }
    const elapsed_ns = now_ns() - started_ns;

    harness.loop.cancel(handles[0]);
    try harness.loop.drain(&events);
    return elapsed_ns;
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

    // The next tick arms the timer at its own reading plus the wait, and that reading is at or past
    // this one, so the tick that hands the fire over read at least this one plus the wait. Each
    // tick's reading is at or past the one before.
    var handles: [1]core.Handle = undefined;
    try harness.submit(&.{repeating(9, period_ns, 0)}, &handles);
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
