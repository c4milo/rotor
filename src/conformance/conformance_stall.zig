//! The stall check of the scenarios, and the scenarios of the loop's own stall count. A callback
//! that runs too long holds the loop, and Seastar reports such a task as a reactor stall. The check
//! here times one handler, in this suite only. The loop's count of decision 28 times a turn, in
//! each loop, from the stamps its backend reads, and the scenarios at the end of this file hold it.
//!
//! A scenario makes its records, pollers and tasks with `completion`, `poller` and `task`. Each
//! one reads the thread's CPU clock before and after its handler. A run that used more CPU time
//! than `constants.callback_stall_ns_max` is kept, and the next `Harness.tick` or `Harness.drain`
//! returns `error.CallbackStalled`. A callback returns nothing, so it cannot fail the test itself.
//!
//! The check reads CPU time and not the wall clock, by Camilo's ruling of 2026-11-07 (decision 28,
//! its amendment of that day). The kernel can take the thread off the processor inside a small
//! callback on a loaded machine, and the wall clock counts that time. The CPU clock does not. So
//! the check does not catch a callback that blocks in a wait: the scenario below shows that gap.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const constants = @import("constants.zig");

const Event = core.Event;
const clock_ns = backend.testing.monotonic_ns;
/// The clock of the check: the CPU time that the calling thread used.
const cpu_ns = backend.testing.thread_cpu_ns;

/// The longest callback run over the limit since the last `check`, in nanoseconds, or 0. The
/// callbacks of a loop run on the thread that ticks it, so each thread keeps its own.
threadlocal var stalled_ns: u64 = 0;

/// Fails with `error.CallbackStalled` when a callback of this thread ran past the limit since the
/// last call, and forgets that run.
pub fn check() error{CallbackStalled}!void {
    const stalled = stalled_ns;
    stalled_ns = 0;
    if (stalled == 0) return;
    std.debug.assert(stalled > constants.callback_stall_ns_max);
    return error.CallbackStalled;
}

/// Keeps the run that began at `started_ns`, a reading of `cpu_ns`, when it used more CPU time
/// than the limit.
fn measure(started_ns: u64) void {
    const elapsed_ns = cpu_ns() - started_ns;
    if (elapsed_ns > constants.callback_stall_ns_max) stalled_ns = @max(stalled_ns, elapsed_ns);
}

/// `core.Completion.init`, with the handler timed.
pub fn completion(
    comptime Parent: type,
    comptime field: []const u8,
    comptime handler: fn (parent: *Parent, event: Event) void,
) core.Completion {
    return .init(Parent, field, struct {
        fn timed(parent: *Parent, event: Event) void {
            const started_ns = cpu_ns();
            handler(parent, event);
            measure(started_ns);
        }
    }.timed);
}

/// `core.Poller.init`, with the handler timed.
pub fn poller(
    comptime Parent: type,
    comptime field: []const u8,
    comptime handler: fn (parent: *Parent) core.WaitLimit,
) core.Poller {
    return .init(Parent, field, struct {
        fn timed(parent: *Parent) core.WaitLimit {
            const started_ns = cpu_ns();
            const limit = handler(parent);
            measure(started_ns);
            return limit;
        }
    }.timed);
}

/// `core.Task.init`, with the handler timed.
pub fn task(
    comptime Parent: type,
    comptime field: []const u8,
    comptime handler: fn (parent: *Parent) void,
) core.Task {
    return .init(Parent, field, struct {
        fn timed(parent: *Parent) void {
            const started_ns = cpu_ns();
            handler(parent);
            measure(started_ns);
        }
    }.timed);
}

const conformance = @import("conformance.zig");
const Harness = conformance.Harness;

/// Holds the thread until it used more CPU time than the limit, as a callback with too much work
/// would. It reads the CPU clock and not the wall clock: on a loaded machine the kernel takes the
/// thread away during the spin, and a spin timed by the wall clock could end under the limit.
fn hold_past_limit() void {
    const started_ns = cpu_ns();
    while (cpu_ns() - started_ns <= constants.callback_stall_ns_max) {
        std.atomic.spinLoopHint();
    }
}

/// A record, a poller and a task whose handlers hold the loop past the limit when `slow` is set.
const Slow = struct {
    completion: core.Completion = completion(Slow, "completion", completed),
    poller: core.Poller = poller(Slow, "poller", polled),
    task: core.Task = task(Slow, "task", ran),
    slow: bool,
    calls: u32 = 0,
    /// The calls of the record.
    events: u32 = 0,

    fn completed(slow: *Slow, event: Event) void {
        _ = event;
        slow.events += 1;
        slow.called();
    }

    fn polled(slow: *Slow) core.WaitLimit {
        slow.called();
        return .none;
    }

    fn ran(slow: *Slow) void {
        slow.called();
    }

    fn called(slow: *Slow) void {
        slow.calls += 1;
        if (slow.slow) hold_past_limit();
    }
};

/// Ticks until `slow` saw a call, and returns what the harness returned.
fn tick_until_called(harness: *Harness, slow: *Slow) !void {
    var events: [8]Event = undefined;
    var round: u32 = 0;
    while (slow.calls == 0 and round < conformance.collect_rounds_max) : (round += 1) {
        _ = try harness.tick(&events, core.constants.ns_per_ms);
    }
    try testing.expect(slow.calls > 0);
}

test "a record that holds the loop past the limit fails the tick that called it" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var slow: Slow = .{ .slow = true };
    const timer = core.Operation.timer(0, core.constants.ns_per_ms, 0);
    try harness.submit(&.{timer.completion(&slow.completion)}, &.{});
    try testing.expectError(error.CallbackStalled, tick_until_called(&harness, &slow));
    // The check forgets the run it reported.
    try check();
}

test "a poller that holds the loop past the limit fails the tick that called it" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var slow: Slow = .{ .slow = true };
    try harness.loop.add_poller(&slow.poller);
    defer harness.loop.remove_poller(&slow.poller);
    var events: [8]Event = undefined;
    try testing.expectError(error.CallbackStalled, harness.tick(&events, 0));
    try testing.expectEqual(@as(u32, 1), slow.calls);
}

test "a task that holds the loop past the limit fails the tick and the drain that ran it" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var slow: Slow = .{ .slow = true };
    var events: [8]Event = undefined;
    try harness.loop.schedule(&slow.task);
    try testing.expectError(error.CallbackStalled, harness.tick(&events, 0));
    try harness.loop.schedule(&slow.task);
    try testing.expectError(error.CallbackStalled, harness.drain(&events));
    try testing.expectEqual(@as(u32, 2), slow.calls);
}

test "callbacks under the limit pass" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var quick: Slow = .{ .slow = false };
    try harness.loop.add_poller(&quick.poller);
    defer harness.loop.remove_poller(&quick.poller);
    try harness.loop.schedule(&quick.task);
    const timer = core.Operation.timer(0, core.constants.ns_per_ms, 0);
    try harness.submit(&.{timer.completion(&quick.completion)}, &.{});
    var events: [8]Event = undefined;
    var round: u32 = 0;
    while (quick.events == 0 and round < conformance.collect_rounds_max) : (round += 1) {
        _ = try harness.tick(&events, core.constants.ns_per_ms);
    }
    try testing.expectEqual(@as(u32, 1), quick.events);
    // A poller call in each tick, the task and the record.
    try testing.expectEqual(round + 2, quick.calls);
}

/// A record whose handler waits in the kernel past the limit and uses almost no CPU time: it ticks
/// a second loop that has no work, as a callback that blocks in a wait would.
const Waiting = struct {
    completion: core.Completion = completion(Waiting, "completion", completed),
    other: *Loop,
    /// The wall time the handler waited, in nanoseconds.
    waited_ns: u64 = 0,

    fn completed(waiting: *Waiting, event: Event) void {
        _ = event;
        var events: [1]Event = undefined;
        const started_ns = clock_ns();
        var round: u32 = 0;
        while (waiting.waited_ns <= constants.callback_stall_ns_max and
            round < conformance.collect_rounds_max) : (round += 1)
        {
            _ = waiting.other.tick(&events, constants.callback_stall_ns_max) catch return;
            waiting.waited_ns = clock_ns() - started_ns;
        }
    }
};

test "a record that waits in the kernel past the limit passes, because the check reads CPU time" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var other: Fixture = undefined;
    try other.init(stall_turn_ns);
    defer other.loop.deinit();
    var waiting: Waiting = .{ .other = &other.loop };
    const timer = core.Operation.timer(0, 0, 0);
    try harness.submit(&.{timer.completion(&waiting.completion)}, &.{});
    var events: [8]Event = undefined;
    var round: u32 = 0;
    while (waiting.waited_ns == 0 and round < conformance.collect_rounds_max) : (round += 1) {
        _ = try harness.tick(&events, ns_per_ms);
    }
    // The handler held the loop past the limit by the wall clock, and the check let it pass.
    try testing.expect(waiting.waited_ns > constants.callback_stall_ns_max);
}

// The stall count and the heartbeat of decision 28, on every backend. A turn runs from one tick's
// first clock stamp to the next tick's, and holds no kernel wait. The loop counts a turn at or
// above `Options.stall_turn_ns` in `statistics()`, and a watch on another thread names the callback
// that holds the loop: `conformance_stall_watch.zig` holds those scenarios. Each hold stays under
// `constants.callback_stall_ns_max`, so the check above passes. A busy machine adds stalls, so each
// check asks for at least the stall the scenario made.

const Loop = backend.Loop;
const ns_per_ms = core.constants.ns_per_ms;

/// The threshold of the scenarios that make a stall.
pub const stall_turn_ns = 5 * ns_per_ms;
/// How long a scenario holds the loop: four times the threshold, and under the harness's limit.
const hold_ns = 20 * ns_per_ms;
/// The wait of a tick that blocks with no work. A turn that held the wait would start this long
/// before the stamp after the wait. The comptime block below keeps it over twice `hold_ns`.
const blocked_wait_ns = 50 * ns_per_ms;
/// The delay of a timer that a tick blocks for.
const timer_delay_ns = 2 * ns_per_ms;

comptime {
    std.debug.assert(hold_ns >= 2 * stall_turn_ns);
    std.debug.assert(hold_ns < constants.callback_stall_ns_max);
    std.debug.assert(blocked_wait_ns > 2 * hold_ns);
}

const options: Loop.Options = .{ .operations = 4, .entries = 4 };

/// One loop with a stall threshold of its own.
pub const Fixture = struct {
    memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment),
    loop: Loop,

    pub fn init(fixture: *Fixture, turn_ns: u64) !void {
        var with_threshold = options;
        with_threshold.stall_turn_ns = turn_ns;
        with_threshold.spin_budget_ns = conformance.spin_budget_ns();
        try fixture.loop.init(&fixture.memory, &with_threshold);
    }
};

/// Holds the thread for `span_ns`. A spin and not a sleep, so the thread keeps the loop the whole
/// time, as a callback with too much work would.
fn hold_for(span_ns: u64) void {
    const started_ns = clock_ns();
    while (clock_ns() - started_ns < span_ns) std.atomic.spinLoopHint();
}

/// A record that holds the loop for `hold_ns` when its event comes. Its hold is the stall the
/// scenario counts, so it is made with `core.Completion.init` and not timed by the harness. The
/// scenario tests the loop's count, and the harness's check stays out of it.
const Holding = struct {
    completion: core.Completion = .init(Holding, "completion", completed),
    events: u32 = 0,

    fn completed(holding: *Holding, event: Event) void {
        _ = event;
        holding.events += 1;
        hold_for(hold_ns);
    }
};

test "a record that holds the loop past the threshold makes a stall that names it" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(stall_turn_ns);
    defer fixture.loop.deinit();
    var holding: Holding = .{};
    // A timer that the tick waits for, so the record runs in the turn that the stamp after the
    // wait starts.
    const timer = core.Operation.timer(0, timer_delay_ns, 0).completion(&holding.completion);
    try testing.expectEqual(@as(u32, 1), fixture.loop.submit(&.{timer}, &.{}));
    var events: [4]Event = undefined;
    var round: u32 = 0;
    while (holding.events == 0 and round < conformance.collect_rounds_max) : (round += 1) {
        _ = try fixture.loop.tick(&events, blocked_wait_ns);
    }
    try testing.expectEqual(@as(u32, 1), holding.events);
    // The next tick's first clock stamp ends the turn that held the record.
    _ = try fixture.loop.tick(&events, 0);
    const statistics = fixture.loop.statistics();
    try testing.expect(statistics.stalls >= 1);
    try testing.expect(statistics.stall_ns_max >= hold_ns);
    const last = statistics.last_stall;
    try testing.expectEqual(@as(u32, 1), last.callbacks);
    try testing.expect(last.span_ns >= hold_ns);
    try testing.expect(last.end_ns == fixture.loop.now_ns());
    try testing.expectEqualStrings(@typeName(Holding) ++ ".completion", std.mem.span(last.name.?));
    try check();
}

test "program code that holds the loop between ticks makes a stall of no callback" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(stall_turn_ns);
    defer fixture.loop.deinit();
    var events: [4]Event = undefined;
    _ = try fixture.loop.tick(&events, 0);
    hold_for(hold_ns);
    _ = try fixture.loop.tick(&events, 0);
    const statistics = fixture.loop.statistics();
    try testing.expect(statistics.stalls >= 1);
    const last = statistics.last_stall;
    try testing.expectEqual(@as(u32, 0), last.callbacks);
    try testing.expectEqual(@as(?[*:0]const u8, null), last.name);
    try testing.expect(last.span_ns >= hold_ns);
}

test "a tick that blocks with no work is in no turn, and the next turn starts after its wait" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(stall_turn_ns);
    defer fixture.loop.deinit();
    var events: [4]Event = undefined;
    _ = try fixture.loop.tick(&events, 0);
    const before_ns = clock_ns();
    try testing.expectEqual(@as(u32, 0), try fixture.loop.tick(&events, blocked_wait_ns));
    // A tick that blocked sets `now_ns` to the stamp after its wait (decision 9, rule 4).
    const woken_ns = fixture.loop.now_ns();
    try testing.expect(woken_ns - before_ns >= blocked_wait_ns - ns_per_ms);
    // Program code after the wait makes a stall. Its turn starts at the stamp after the wait: a
    // turn that held the wait too would start before `woken_ns`, and a turn with no start would
    // not be a stall. The check compares the loop's own stamps, so it holds however long a busy
    // machine makes the hold.
    hold_for(hold_ns);
    _ = try fixture.loop.tick(&events, 0);
    const last = fixture.loop.statistics().last_stall;
    try testing.expectEqual(fixture.loop.now_ns(), last.end_ns);
    try testing.expectEqual(@as(u32, 0), last.callbacks);
    try testing.expect(last.span_ns >= hold_ns);
    try testing.expectEqual(last.end_ns - woken_ns, last.span_ns);
}

test "a null threshold counts no stall" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    var without = options;
    without.stall_turn_ns = null;
    try fixture.loop.init(&fixture.memory, &without);
    defer fixture.loop.deinit();
    var events: [4]Event = undefined;
    _ = try fixture.loop.tick(&events, 0);
    hold_for(hold_ns);
    _ = try fixture.loop.tick(&events, 0);
    try testing.expectEqual(@as(u64, 0), fixture.loop.statistics().stalls);
}
