//! The task queue of decision 27 on every backend. Only the program ticks the loop; libraries
//! continue their work in records, pollers and tasks, and every task runs exactly once.
//!
//! `conformance_stall.zig` makes every record, poller and task here except `Forever`, and the
//! harness ticks the loop, so a callback that holds the loop past its limit fails the scenario.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const conformance = @import("conformance.zig");
const stall = @import("conformance_stall.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Operation = core.Operation;

const ms = core.constants.ns_per_ms;

/// Ticks the scenarios may take. A queued task keeps every tick from blocking, so a tick is short,
/// and this bounds a scenario whose timer never fires.
const ticks_max = 1_000_000;

/// A wait that a tick must not take while a task is queued: long enough that a tick which blocked
/// fails the bound below by far.
const long_wait_ns = 2 * core.constants.ns_per_s;

/// A task that schedules itself again on every run, as a library with endless work would. Its run
/// is not timed. It runs once in each of thousands of ticks, and a loaded host held the thread
/// for 94 ms inside one run that used 11 µs of CPU. The timed run then failed with
/// `CallbackStalled`. The run only counts and schedules, so a long run can come only from the host.
const Forever = struct {
    task: core.Task = .init(Forever, "task", ran),
    loop: *Harness,
    runs: u32 = 0,

    fn ran(forever: *Forever) void {
        forever.runs += 1;
        forever.loop.loop.schedule(&forever.task) catch unreachable;
    }
};

/// A library with a timer that names a record.
const Timed = struct {
    completion: core.Completion = stall.completion(Timed, "completion", fired),
    fires: u32 = 0,

    fn fired(timed: *Timed, event: Event) void {
        _ = event;
        timed.fires += 1;
    }
};

test "a task that never stops runs once a tick, and another library's timer still fires" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var forever: Forever = .{ .loop = &harness };
    var timed: Timed = .{};
    try harness.loop.schedule(&forever.task);
    try harness.submit(&.{Operation.timer(0, 5 * ms, 0).completion(&timed.completion)}, &.{});
    var events: [8]Event = undefined;
    var ticks: u32 = 0;
    while (timed.fires == 0 and ticks < ticks_max) : (ticks += 1) {
        try testing.expectEqual(@as(u32, 0), try harness.tick(&events, long_wait_ns));
        // The task ran exactly once in each tick, and is queued for the next.
        try testing.expectEqual(ticks + 1, forever.runs);
        try testing.expect(harness.loop.is_scheduled(&forever.task));
    }
    try testing.expectEqual(@as(u32, 1), timed.fires);
    // The task never stops, so the drain gives up on it, and the program discards it.
    var scratch: [8]Event = undefined;
    try testing.expectError(error.TasksStillQueued, harness.drain(&scratch));
    try testing.expectEqual(@as(u32, 1), harness.loop.discard_tasks());
    try testing.expectEqual(@as(u32, 0), harness.loop.tasks_queued());
    try testing.expect(!harness.loop.is_scheduled(&forever.task));
}

/// Where each task ran: the tick count of the harness when its run came.
const Placed = struct {
    task: core.Task = stall.task(Placed, "task", ran),
    tick: *const u32,
    ran_at: ?u32 = null,
    /// A task this one queues from its own run.
    then: ?*Placed = null,
    loop: *Harness,

    fn ran(placed: *Placed) void {
        placed.ran_at = placed.tick.*;
        const then = placed.then orelse return;
        placed.loop.loop.schedule(&then.task) catch unreachable;
    }
};

/// A record that queues `queued` when its event arrives.
const Queueing = struct {
    completion: core.Completion = stall.completion(Queueing, "completion", called),
    loop: *Harness,
    queued: *Placed,

    fn called(queueing: *Queueing, event: Event) void {
        _ = event;
        queueing.loop.loop.schedule(&queueing.queued.task) catch unreachable;
    }
};

/// A poller that queues `queued` once, in the tick numbered `at`.
const Polling = struct {
    poller: core.Poller = stall.poller(Polling, "poller", polled),
    loop: *Harness,
    queued: *Placed,
    tick: *const u32,
    at: u32,

    fn polled(polling: *Polling) core.WaitLimit {
        if (polling.tick.* == polling.at) polling.loop.loop.schedule(&polling.queued.task) catch unreachable;
        return .none;
    }
};

test "a task runs in the tick that queued it from a record or a poller, and a task's task next" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var tick: u32 = 0;
    var next: Placed = .{ .tick = &tick, .loop = &harness };
    var from_record: Placed = .{ .tick = &tick, .loop = &harness, .then = &next };
    var from_poller: Placed = .{ .tick = &tick, .loop = &harness };
    var queueing: Queueing = .{ .loop = &harness, .queued = &from_record };
    var polling: Polling = .{ .loop = &harness, .queued = &from_poller, .tick = &tick, .at = 0 };
    try harness.loop.add_poller(&polling.poller);
    defer harness.loop.remove_poller(&polling.poller);
    try harness.submit(&.{Operation.timer(0, ms, 0).completion(&queueing.completion)}, &.{});
    var events: [8]Event = undefined;
    // Tick 0: the poller queues its task, which runs in the same tick.
    _ = try harness.tick(&events, 0);
    try testing.expectEqual(@as(?u32, 0), from_poller.ran_at);
    tick = 1;
    while (from_record.ran_at == null and tick < ticks_max) : (tick += 1) {
        _ = try harness.tick(&events, 10 * ms);
    }
    // The timer's record queued a task that ran in the same tick; that task's own task waits.
    const fired_at = from_record.ran_at.?;
    try testing.expectEqual(fired_at + 1, tick);
    try testing.expectEqual(@as(?u32, null), next.ran_at);
    try testing.expectEqual(@as(u32, 1), harness.loop.tasks_queued());
    // The next tick runs it, and does not block although it may wait two seconds.
    const before = harness.loop.now_ns();
    _ = try harness.tick(&events, long_wait_ns);
    try testing.expect(harness.loop.now_ns() - before < long_wait_ns / 2);
    try testing.expectEqual(@as(?u32, tick), next.ran_at);
    try testing.expectEqual(@as(u32, 0), harness.loop.tasks_queued());
}

/// A task that counts its runs.
const Counted = struct {
    task: core.Task = stall.task(Counted, "task", ran),
    runs: u32 = 0,

    fn ran(counted: *Counted) void {
        counted.runs += 1;
    }
};

test "drain runs the queued tasks of a loop with nothing in flight" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var counted: [3]Counted = @splat(.{});
    for (&counted) |*one| try harness.loop.schedule(&one.task);
    try testing.expectEqual(@as(u32, 3), harness.loop.tasks_queued());
    try testing.expectEqual(@as(u32, 0), harness.loop.in_flight());
    var scratch: [8]Event = undefined;
    try harness.drain(&scratch);
    for (&counted) |*one| try testing.expectEqual(@as(u32, 1), one.runs);
    try testing.expectEqual(@as(u32, 0), harness.loop.tasks_queued());
}
