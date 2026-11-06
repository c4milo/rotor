//! `drain`: what a caller that is shutting down runs after `cancel_all` (decision 5, rule 7).
//! Every backend's `drain` calls it with the named bounds of `constants.zig`, so the bound is one
//! piece of code, and a test reaches it with a loop that never empties, in no time.
const std = @import("std");
const assert = std.debug.assert;
const event_module = @import("event.zig");

const Event = event_module.Event;

/// Ticks `loop` until it has nothing in flight and no task queued (decision 27), discarding the
/// events into `scratch`, and waits `wait_ns` at most in each tick. When `rounds_max` ticks were not
/// enough it fails: with `StillInFlight` while the kernel still holds an operation, so the loop's
/// memory must not be freed, and with `TasksStillQueued` when only tasks are left. The kernel then
/// holds nothing, and `discard_tasks` lets the program end the loop.
pub fn drain(loop: anytype, scratch: []Event, rounds_max: u32, wait_ns: u64) !void {
    assert(scratch.len >= 1);
    assert(rounds_max >= 1);
    var round: u32 = 0;
    while (loop.in_flight() != 0 or loop.tasks_queued() != 0) : (round += 1) {
        if (round == rounds_max) {
            if (loop.in_flight() != 0) return error.StillInFlight;
            return error.TasksStillQueued;
        }
        _ = try loop.tick(scratch, wait_ns);
    }
    assert(loop.in_flight() == 0);
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

    fn in_flight(fake: *const Fake) u32 {
        return fake.remaining;
    }

    fn tasks_queued(fake: *const Fake) u32 {
        return fake.tasks;
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
    try drain(&fake, &scratch, 8, test_wait_ns);
    try testing.expectEqual(@as(u32, 0), fake.remaining);
    try testing.expectEqual(@as(u32, 3), fake.ticks);
    try testing.expectEqual(@as(u64, 3 * test_wait_ns), fake.waited_ns);

    var empty: Fake = .{ .remaining = 0 };
    try drain(&empty, &scratch, 8, test_wait_ns);
    try testing.expectEqual(@as(u32, 0), empty.ticks);
}

test "drain gives up with StillInFlight after exactly its bound of ticks" {
    var scratch: [2]Event = undefined;
    // The operation would end at tick 6. A drain that ignores its bound of 5 gets there and
    // succeeds, so this test fails and does not hang.
    var fake: Fake = .{ .remaining = 1, .ends_from = 5 };
    try testing.expectError(error.StillInFlight, drain(&fake, &scratch, 5, test_wait_ns));
    try testing.expectEqual(@as(u32, 5), fake.ticks);
    try testing.expectEqual(@as(u32, 1), fake.remaining);

    // A loop that empties at the last tick the bound allows is drained.
    var last: Fake = .{ .remaining = 1, .ends_from = 4 };
    try drain(&last, &scratch, 5, test_wait_ns);
    try testing.expectEqual(@as(u32, 5), last.ticks);
}

test "a tick's error ends the drain and reaches the caller" {
    var scratch: [2]Event = undefined;
    var fake: Fake = .{ .remaining = 4, .refuses_at = 2 };
    try testing.expectError(error.Refused, drain(&fake, &scratch, 8, test_wait_ns));
    try testing.expectEqual(@as(u32, 2), fake.ticks);
    try testing.expectEqual(@as(u32, 2), fake.remaining);
}

test "drain runs the queued tasks of a loop with nothing in flight" {
    var scratch: [2]Event = undefined;
    var fake: Fake = .{ .remaining = 0, .tasks = 3 };
    try drain(&fake, &scratch, 8, test_wait_ns);
    try testing.expectEqual(@as(u32, 0), fake.tasks);
    try testing.expectEqual(@as(u32, 3), fake.ticks);
}

test "drain gives up with TasksStillQueued when only tasks are left at its bound" {
    var scratch: [2]Event = undefined;
    // A task that schedules itself forever: the queue never empties.
    var forever: Fake = .{ .remaining = 1, .tasks = 1, .tasks_from = 100 };
    try testing.expectError(error.TasksStillQueued, drain(&forever, &scratch, 5, test_wait_ns));
    try testing.expectEqual(@as(u32, 0), forever.remaining);
    // An operation still in flight at the bound is the error, whatever the queue holds.
    var both: Fake = .{ .remaining = 1, .ends_from = 9, .tasks = 1, .tasks_from = 100 };
    try testing.expectError(error.StillInFlight, drain(&both, &scratch, 5, test_wait_ns));
}
