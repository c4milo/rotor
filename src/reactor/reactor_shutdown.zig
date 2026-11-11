//! The drain of a reactor: what a program that is shutting down runs after `cancel_all` (decision 5,
//! rule 7). It is the loop's drain, and it also waits for the reactor's tasks (decision 27) and
//! calls (decision 32). The loop's own drain, in `core/shutdown.zig`, waits on `in_flight` alone.
//! Moved from the core at step 3 of decision 33. `Dispatch` declares `drain`.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const dispatch_module = @import("dispatch/dispatch.zig");

const Dispatch = dispatch_module.Dispatch;
const Event = core.Event;

/// Why the drain of a reactor over `LoopPointer`'s loop gave up, or the tick's error.
pub fn DrainError(comptime LoopPointer: type) type {
    return dispatch_module.TickError(LoopPointer) || error{ StillInFlight, TasksStillQueued };
}

/// Ticks the reactor of `dispatch` over `loop` until nothing is in flight and `outstanding` is 0,
/// with the bounds of `core.constants` (`rounds`).
pub fn drain(dispatch: *Dispatch, loop: anytype, scratch: []Event) DrainError(@TypeOf(loop))!void {
    return drain_within(dispatch, loop, scratch, core.constants.drain_rounds_max, core.constants.drain_wait_ns);
}

/// `drain` with its bounds named: `rounds_max` ticks, each of `wait_ns` at most. A scenario reaches
/// the bound in a short time with it.
pub fn drain_within(
    dispatch: *Dispatch,
    loop: anytype,
    scratch: []Event,
    rounds_max: u32,
    wait_ns: u64,
) DrainError(@TypeOf(loop))!void {
    var driven: Driven(@TypeOf(loop)) = .{ .dispatch = dispatch, .loop = loop };
    return rounds(&driven, scratch, rounds_max, wait_ns);
}

/// A reactor as `rounds` drives it: its state and its loop.
fn Driven(comptime LoopPointer: type) type {
    return struct {
        dispatch: *Dispatch,
        loop: LoopPointer,

        fn in_flight(driven: *const @This()) u32 {
            return driven.loop.in_flight();
        }

        fn callbacks_outstanding(driven: *const @This()) u32 {
            return driven.loop.outstanding().*;
        }

        fn tasks_queued(driven: *const @This()) u32 {
            return driven.dispatch.tasks_queued(driven.loop);
        }

        fn tick(driven: *@This(), events: []Event, wait_ns: u64) dispatch_module.TickError(LoopPointer)!u32 {
            return driven.dispatch.tick(driven.loop, events, wait_ns);
        }
    };
}

/// Ticks `reactor` until it has nothing in flight, no task queued (decision 27), and no call out
/// or held (decision 32), discarding the events into `scratch`, and waits `wait_ns` at most in each
/// tick. `callbacks_outstanding` counts the tasks and the calls. When `rounds_max` ticks were not
/// enough it fails: with `StillInFlight` while the kernel still holds an operation or a call is out
/// or held, so the memory must not be freed, and with `TasksStillQueued` when only tasks are left.
/// The kernel then holds nothing, and `discard_tasks` lets the program end the reactor.
pub fn rounds(reactor: anytype, scratch: []Event, rounds_max: u32, wait_ns: u64) !void {
    assert(scratch.len >= 1);
    assert(rounds_max >= 1);
    var round: u32 = 0;
    while (reactor.in_flight() != 0 or reactor.callbacks_outstanding() != 0) : (round += 1) {
        if (round == rounds_max) {
            if (reactor.in_flight() != 0) return error.StillInFlight;
            // With nothing in flight, a callback that is not a queued task is a call.
            if (reactor.callbacks_outstanding() > reactor.tasks_queued()) return error.StillInFlight;
            return error.TasksStillQueued;
        }
        _ = try reactor.tick(scratch, wait_ns);
    }
    assert(reactor.in_flight() == 0);
}

const testing = std.testing;

/// A loop with `remaining` operations in flight, which ends one at each tick from tick
/// `ends_from` on, and refuses tick `refuses_at`.
const Fake = struct {
    remaining: u32,
    ends_from: u32 = 0,
    refuses_at: ?u32 = null,
    ticks: u32 = 0,
    waited_ns: u64 = 0,

    /// Tasks queued, of which each tick runs one, from tick `tasks_from` on.
    tasks: u32 = 0,
    tasks_from: u32 = 0,

    /// Calls out, which no tick ends.
    calls: u32 = 0,

    fn in_flight(fake: *const Fake) u32 {
        return fake.remaining;
    }

    fn tasks_queued(fake: *const Fake) u32 {
        return fake.tasks;
    }

    /// The tasks, and the calls out.
    fn callbacks_outstanding(fake: *const Fake) u32 {
        return fake.tasks + fake.calls;
    }

    fn tick(fake: *Fake, events: []Event, wait_ns: u64) error{Refused}!u32 {
        assert(events.len >= 1);
        if (fake.refuses_at == fake.ticks) return error.Refused;
        fake.ticks += 1;
        fake.waited_ns += wait_ns;
        if (fake.tasks != 0 and fake.ticks > fake.tasks_from) fake.tasks -= 1;
        if (fake.remaining == 0 or fake.ticks <= fake.ends_from) return 0;
        fake.remaining -= 1;
        return 1;
    }
};

const test_wait_ns = 7;

test "drain ticks until the loop is empty, no further, and waits what it was told in each" {
    var scratch: [2]Event = undefined;
    var fake: Fake = .{ .remaining = 3 };
    try rounds(&fake, &scratch, 8, test_wait_ns);
    try testing.expectEqual(@as(u32, 0), fake.remaining);
    try testing.expectEqual(@as(u32, 3), fake.ticks);
    try testing.expectEqual(@as(u64, 3 * test_wait_ns), fake.waited_ns);

    var empty: Fake = .{ .remaining = 0 };
    try rounds(&empty, &scratch, 8, test_wait_ns);
    try testing.expectEqual(@as(u32, 0), empty.ticks);
}

test "drain gives up with StillInFlight after exactly its bound of ticks" {
    var scratch: [2]Event = undefined;
    // The operation would end at tick 6. A drain that ignores its bound of 5 gets there and
    // succeeds, so this test fails and does not hang.
    var fake: Fake = .{ .remaining = 1, .ends_from = 5 };
    try testing.expectError(error.StillInFlight, rounds(&fake, &scratch, 5, test_wait_ns));
    try testing.expectEqual(@as(u32, 5), fake.ticks);
    try testing.expectEqual(@as(u32, 1), fake.remaining);

    // A loop that empties at the last tick the bound allows is drained.
    var last: Fake = .{ .remaining = 1, .ends_from = 4 };
    try rounds(&last, &scratch, 5, test_wait_ns);
    try testing.expectEqual(@as(u32, 5), last.ticks);
}

test "a tick's error ends the drain and reaches the caller" {
    var scratch: [2]Event = undefined;
    var fake: Fake = .{ .remaining = 4, .refuses_at = 2 };
    try testing.expectError(error.Refused, rounds(&fake, &scratch, 8, test_wait_ns));
    try testing.expectEqual(@as(u32, 2), fake.ticks);
    try testing.expectEqual(@as(u32, 2), fake.remaining);
}

test "drain runs the queued tasks of a loop with nothing in flight" {
    var scratch: [2]Event = undefined;
    var fake: Fake = .{ .remaining = 0, .tasks = 3 };
    try rounds(&fake, &scratch, 8, test_wait_ns);
    try testing.expectEqual(@as(u32, 0), fake.tasks);
    try testing.expectEqual(@as(u32, 3), fake.ticks);
}

test "drain gives up with TasksStillQueued when only tasks are left at its bound" {
    var scratch: [2]Event = undefined;
    // A task that schedules itself forever: the queue never empties.
    var forever: Fake = .{ .remaining = 1, .tasks = 1, .tasks_from = 100 };
    try testing.expectError(error.TasksStillQueued, rounds(&forever, &scratch, 5, test_wait_ns));
    try testing.expectEqual(@as(u32, 0), forever.remaining);
    // An operation still in flight at the bound is the error, whatever the queue holds.
    var both: Fake = .{ .remaining = 1, .ends_from = 9, .tasks = 1, .tasks_from = 100 };
    try testing.expectError(error.StillInFlight, rounds(&both, &scratch, 5, test_wait_ns));
}

test "drain gives up with StillInFlight while a call is out, with nothing in flight" {
    var scratch: [2]Event = undefined;
    var fake: Fake = .{ .remaining = 0, .tasks = 1, .calls = 1 };
    try testing.expectError(error.StillInFlight, rounds(&fake, &scratch, 4, test_wait_ns));
    try testing.expectEqual(@as(u32, 4), fake.ticks);
}
