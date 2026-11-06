//! The stall check of the scenarios. A callback that runs too long holds the loop, and Seastar
//! reports such a task as a reactor stall. `core` reads no clock (non-negotiable 2), so the check
//! lives here, in the harness, and not in the loop.
//!
//! A scenario makes its records, pollers and tasks with `completion`, `poller` and `task`. Each
//! one reads the clock before and after its handler. A run longer than
//! `constants.callback_stall_ns_max` is kept, and the next `Harness.tick` or `Harness.drain`
//! returns `error.CallbackStalled`. A callback returns nothing, so it cannot fail the test itself.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const constants = @import("constants.zig");

const Event = core.Event;
const clock_ns = backend.testing.monotonic_ns;

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

/// Keeps the run that began at `started_ns` when it took longer than the limit.
fn measure(started_ns: u64) void {
    const elapsed_ns = clock_ns() - started_ns;
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
            const started_ns = clock_ns();
            handler(parent, event);
            measure(started_ns);
        }
    }.timed);
}

/// `core.Poller.init`, with the handler timed.
pub fn poller(
    comptime Parent: type,
    comptime field: []const u8,
    comptime handler: fn (parent: *Parent) bool,
) core.Poller {
    return .init(Parent, field, struct {
        fn timed(parent: *Parent) bool {
            const started_ns = clock_ns();
            const worked = handler(parent);
            measure(started_ns);
            return worked;
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
            const started_ns = clock_ns();
            handler(parent);
            measure(started_ns);
        }
    }.timed);
}

const conformance = @import("conformance.zig");
const Harness = conformance.Harness;

/// Holds the thread past the limit. A spin and not a sleep, so that the thread keeps the loop the
/// whole time, as a callback with too much work would.
fn hold_past_limit() void {
    const started_ns = clock_ns();
    while (clock_ns() - started_ns <= constants.callback_stall_ns_max) {
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

    fn polled(slow: *Slow) bool {
        slow.called();
        return false;
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
