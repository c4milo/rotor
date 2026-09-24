//! Decision 13: a loop given a spin budget polls before it blocks. What the caller is handed does not
//! change, which the rest of the suite checks by running a second time with every harness loop
//! given a budget (`conformance.spin_variable`). This file checks what does change: how the loop
//! spends its thread while it waits. It reads that thread's CPU clock, because a poll spends CPU
//! and a sleep does not.
//!
//! Each bound is read from the best of several attempts, as `conformance_cost.zig`'s are. Other
//! work on the machine takes CPU from a polling thread and never gives it more, so the most one
//! attempt spent is the closest to what the loop asked for, and the least one spent is the closest
//! to what a sleep costs. Every bound is one-sided in the direction that load cannot break.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Operation = core.Operation;

const ms = core.constants.ns_per_ms;

/// The budget these scenarios give a loop: the most there is, so what it spends stands out from
/// what a tick costs.
const budget_ns = core.constants.spin_budget_ns_max;

/// Attempts per bound, the best one deciding.
const attempts = 10;

/// Ticks a loop is asked not to block in, per attempt.
const polls = 20;

const thread_cpu_ns = backend.testing.thread_cpu_ns;
const monotonic_ns = backend.testing.monotonic_ns;

/// What one tick cost the thread and the wall clock, and what it handed over.
const Spent = struct { cpu_ns: u64, wall_ns: u64, produced: u32 };

fn timed_tick(harness: *Harness, events: []Event, wait_ns: u64) !Spent {
    const cpu_before = thread_cpu_ns();
    const wall_before = monotonic_ns();
    const produced = try harness.loop.tick(events, wait_ns);
    return .{
        .cpu_ns = thread_cpu_ns() - cpu_before,
        .wall_ns = monotonic_ns() - wall_before,
        .produced = produced,
    };
}

test "a loop with a spin budget polls for it, then sleeps out the rest of the wait" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init_spin(budget_ns);
    defer harness.deinit();

    const wait_ns = 20 * ms;
    var events: [4]Event = undefined;
    var most_cpu_ns: u64 = 0;
    var least_cpu_ns: u64 = std.math.maxInt(u64);
    for (0..attempts) |_| {
        const spent = try timed_tick(&harness, &events, wait_ns);
        try testing.expectEqual(@as(u32, 0), spent.produced);
        // The wait is the caller's: the poll spends the first part of it, and the sleep the rest.
        // A tick that stopped after the poll would end in about a millisecond.
        try testing.expect(spent.wall_ns >= wait_ns / 2);
        most_cpu_ns = @max(most_cpu_ns, spent.cpu_ns);
        least_cpu_ns = @min(least_cpu_ns, spent.cpu_ns);
    }
    // It polled: a quarter of the budget at least, in the attempt other work took least from.
    try testing.expect(most_cpu_ns >= budget_ns / 4);
    // And it stopped polling when the budget ran out: a loop that polled on would have spent many
    // budgets, up to the whole wait.
    try testing.expect(least_cpu_ns < 3 * budget_ns);
}

test "a tick asked not to block, or given a wait the budget covers, does not poll" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init_spin(budget_ns);
    defer harness.deinit();

    var events: [4]Event = undefined;
    var least_cpu_ns: u64 = std.math.maxInt(u64);
    for (0..attempts) |_| {
        const cpu_before = thread_cpu_ns();
        for (0..polls) |_| try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&events, 0));
        // A wait no longer than the budget is slept, as it was before there were budgets.
        try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&events, budget_ns));
        least_cpu_ns = @min(least_cpu_ns, thread_cpu_ns() - cpu_before);
    }
    // Twenty polls and one sleep cost far less than one budget spent polling.
    try testing.expect(least_cpu_ns < budget_ns / 2);
}

test "a timer due inside the budget ends the spin before it starts, and the loop sleeps until it" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init_spin(budget_ns);
    defer harness.deinit();

    const timer_after_ns = budget_ns / 2;
    var events: [1]Event = undefined;
    var least_cpu_ns: u64 = std.math.maxInt(u64);
    for (0..attempts) |_| {
        try harness.submit(&.{Operation.timer(9, timer_after_ns, 0)}, &.{});
        const cpu_before = thread_cpu_ns();
        try harness.collect(&events);
        least_cpu_ns = @min(least_cpu_ns, thread_cpu_ns() - cpu_before);
        try testing.expectEqual(@as(u64, 9), events[0].user_data);
        try testing.expectEqual(@as(u32, 0), try events[0].outcome());
    }
    // Sleeping until the timer costs a few ticks. Polling until it would cost the time to it.
    try testing.expect(least_cpu_ns < timer_after_ns / 2);
}
