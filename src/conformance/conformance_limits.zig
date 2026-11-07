//! The limits of decisions 26 and 27, reached through the real `Loop` on every backend: a full task
//! queue, a full table of pollers, a full slot table while records are owed, a batch that the table
//! takes in part, the run bound of one tick, and the bound of `drain`. Each oracle is an exact count.
//! The scenarios read `tables.dispatch.callbacks_outstanding` directly, because no call of the surface
//! reports it, and a wrong count shows only later, as a tick that skips its dispatch.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const conformance = @import("conformance.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Operation = core.Operation;
const constants = core.constants;

const ms = constants.ns_per_ms;

/// A timer delay that no scenario waits for: each one cancels its timers first.
const long_delay_ns = constants.ns_per_s;

/// Ticks a scenario may take while its loop runs tasks. A queued task keeps every tick from
/// blocking, so a tick is short.
const ticks_max = 1_000_000;

/// The callbacks the loop has outstanding now.
fn owed(harness: *const Harness) u32 {
    return harness.loop.tables.dispatch.callbacks_outstanding;
}

/// The runs of every task of one scenario.
const Tally = struct { runs: u32 = 0 };

/// A task that counts its own runs and the runs of its scenario.
const Counted = struct {
    task: core.Task = .init(Counted, "task", ran),
    tally: ?*Tally = null,
    runs: u32 = 0,
    /// A task this one queues from its first run.
    then: ?*Counted = null,
    harness: ?*Harness = null,

    fn ran(counted: *Counted) void {
        counted.runs += 1;
        if (counted.tally) |tally| tally.runs += 1;
        const then = counted.then orelse return;
        counted.then = null;
        counted.harness.?.loop.schedule(&then.task) catch unreachable;
    }
};

/// A poller that counts the ticks. It never asks a tick not to block.
const TickCount = struct {
    poller: core.Poller = .init(TickCount, "poller", polled),
    ticks: u32 = 0,

    fn polled(tick_count: *TickCount) core.WaitLimit {
        tick_count.ticks += 1;
        return .none;
    }
};

/// Ticks a full queue takes to drain: each tick runs `tasks_per_tick_max` of them.
const full_queue_ticks = constants.tasks_queued_max / constants.tasks_per_tick_max;

comptime {
    // A full queue drains within the bound of `drain`, so the scenario below can count its ticks.
    std.debug.assert(constants.tasks_queued_max % constants.tasks_per_tick_max == 0);
    std.debug.assert(full_queue_ticks <= constants.drain_rounds_max);
}

/// The tasks of the full queue, and one more that the loop refuses. Tasks are the caller's memory,
/// and this is too large for a stack.
var full_queue: [constants.tasks_queued_max + 1]Counted align(@alignOf(Counted)) = undefined;

test "a full task queue refuses one more task and changes nothing, then drains in exact ticks" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var tally: Tally = .{};
    for (&full_queue) |*one| one.* = .{ .tally = &tally };
    for (full_queue[0..constants.tasks_queued_max]) |*one| try harness.loop.schedule(&one.task);
    try testing.expectEqual(constants.tasks_queued_max, harness.loop.tasks_queued());
    try testing.expectEqual(constants.tasks_queued_max, owed(&harness));
    const refused = &full_queue[constants.tasks_queued_max];
    try testing.expectError(error.TasksFull, harness.loop.schedule(&refused.task));
    // The refusal queued nothing and counted nothing.
    try testing.expectEqual(constants.tasks_queued_max, harness.loop.tasks_queued());
    try testing.expectEqual(constants.tasks_queued_max, owed(&harness));
    try testing.expect(!harness.loop.is_scheduled(&refused.task));

    var tick_count: TickCount = .{};
    try harness.loop.add_poller(&tick_count.poller);
    defer harness.loop.remove_poller(&tick_count.poller);
    var scratch: [8]Event = undefined;
    try harness.loop.drain(&scratch);
    try testing.expectEqual(full_queue_ticks, tick_count.ticks);
    try testing.expectEqual(constants.tasks_queued_max, tally.runs);
    for (full_queue[0..constants.tasks_queued_max]) |*one| try testing.expectEqual(@as(u32, 1), one.runs);
    try testing.expectEqual(@as(u32, 0), refused.runs);
    try testing.expectEqual(@as(u32, 0), owed(&harness));
}

test "a full table of pollers refuses one more, and each added poller runs once a tick" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var counts: [constants.pollers_max + 1]TickCount = @splat(.{});
    const last = &counts[constants.pollers_max];
    for (counts[0..constants.pollers_max]) |*one| try harness.loop.add_poller(&one.poller);
    try testing.expectError(error.PollersFull, harness.loop.add_poller(&last.poller));
    try testing.expectEqual(constants.pollers_max, harness.loop.tables.dispatch.poller_count);
    var events: [8]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&events, 0));
    for (counts[0..constants.pollers_max]) |*one| try testing.expectEqual(@as(u32, 1), one.ticks);
    try testing.expectEqual(@as(u32, 0), last.ticks);
    // A removal makes room for exactly one more.
    harness.loop.remove_poller(&counts[0].poller);
    try harness.loop.add_poller(&last.poller);
    try testing.expectError(error.PollersFull, harness.loop.add_poller(&counts[0].poller));
    try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&events, 0));
    try testing.expectEqual(@as(u32, 1), counts[0].ticks);
    for (counts[1..constants.pollers_max]) |*one| try testing.expectEqual(@as(u32, 2), one.ticks);
    try testing.expectEqual(@as(u32, 1), last.ticks);
    for (counts[1..]) |*one| harness.loop.remove_poller(&one.poller);
    try testing.expectEqual(@as(u8, 0), harness.loop.tables.dispatch.poller_count);
}

/// A library's record that counts the events it receives.
const Owed = struct {
    completion: core.Completion = .init(Owed, "completion", called),
    finals: u32 = 0,
    canceled: u32 = 0,

    fn called(record: *Owed, event: Event) void {
        std.debug.assert(event.flags.dispatched);
        if (event.flags.more) return;
        record.finals += 1;
        if (event.result == -@as(i32, @intFromEnum(core.event.Code.canceled))) record.canceled += 1;
    }
};

/// Cancels every operation and ticks until none is in flight. Returns the events that reached the
/// caller, which are the events of the operations without a record.
fn cancel_and_settle(harness: *Harness) !u32 {
    harness.loop.cancel_all();
    var events: [conformance.operations]Event = undefined;
    var plain: u32 = 0;
    var round: u32 = 0;
    while (harness.loop.in_flight() != 0 and round < conformance.collect_rounds_max) : (round += 1) {
        plain += try harness.loop.tick(&events, 10 * ms);
    }
    try testing.expectEqual(@as(u32, 0), harness.loop.in_flight());
    return plain;
}

test "a full slot table refuses an operation with a record, and the count of owed callbacks holds" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var record: Owed = .{};
    const named = Operation.timer(0, long_delay_ns, 0).completion(&record.completion);
    const fill: [conformance.operations]Operation = @splat(named);
    try testing.expectEqual(@as(u32, conformance.operations), harness.loop.submit(&fill, &.{}));
    try testing.expectEqual(@as(u32, conformance.operations), owed(&harness));
    // The table is full: neither an operation with a record nor one without is taken.
    try testing.expectEqual(@as(u32, 0), harness.loop.submit(&.{named}, &.{}));
    try testing.expectEqual(@as(u32, 0), harness.loop.submit(&.{Operation.timer(1, ms, 0)}, &.{}));
    try testing.expectEqual(@as(u32, conformance.operations), owed(&harness));
    // A task takes no slot, so the loop queues it while the table is full.
    var counted: Counted = .{};
    try harness.loop.schedule(&counted.task);
    try testing.expectEqual(@as(u32, conformance.operations + 1), owed(&harness));
    var events: [8]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&events, 0));
    try testing.expectEqual(@as(u32, 1), counted.runs);
    try testing.expectEqual(@as(u32, conformance.operations), owed(&harness));
    try testing.expectEqual(@as(u32, 0), try cancel_and_settle(&harness));
    try testing.expectEqual(@as(u32, conformance.operations), record.finals);
    try testing.expectEqual(@as(u32, conformance.operations), record.canceled);
    try testing.expectEqual(@as(u32, 0), owed(&harness));
    try testing.expect(harness.loop.tables.dispatch.idle());
}

/// Slots the partial batch scenario leaves free, so the table takes two operations of four.
const free_slots = 2;

test "a batch the table takes in part counts only the records it took" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const fill: [conformance.operations - free_slots]Operation = @splat(Operation.timer(1, long_delay_ns, 0));
    try harness.submit(&fill, &.{});
    try testing.expectEqual(@as(u32, 0), owed(&harness));
    var taken_record: Owed = .{};
    var refused_record: Owed = .{};
    // The first two are taken. The third names a record and is refused, so it is not counted.
    const batch = [_]Operation{
        Operation.timer(0, long_delay_ns, 0).completion(&taken_record.completion),
        Operation.timer(2, long_delay_ns, 0),
        Operation.timer(0, long_delay_ns, 0).completion(&refused_record.completion),
        Operation.timer(3, long_delay_ns, 0),
    };
    var handles: [batch.len]core.Handle = undefined;
    try testing.expectEqual(@as(u32, free_slots), harness.loop.submit(&batch, &handles));
    try testing.expectEqual(@as(u32, 1), owed(&harness));
    try testing.expectEqual(@as(u32, conformance.operations), harness.loop.in_flight());
    // A batch the table refuses whole counts nothing.
    try testing.expectEqual(@as(u32, 0), harness.loop.submit(batch[2..], handles[2..]));
    try testing.expectEqual(@as(u32, 1), owed(&harness));
    // Every operation without a record reaches the caller, and the one record gets its one end.
    const plain = try cancel_and_settle(&harness);
    try testing.expectEqual(@as(u32, conformance.operations - 1), plain);
    try testing.expectEqual(@as(u32, 1), taken_record.finals);
    try testing.expectEqual(@as(u32, 0), refused_record.finals);
    try testing.expectEqual(@as(u32, 0), owed(&harness));
    try testing.expect(harness.loop.tables.dispatch.idle());
}

/// Tasks the run bound scenario queues: two full runs and five more.
const backlog = 2 * constants.tasks_per_tick_max + 5;

/// Ticks one tick with no event, and checks the runs so far and the tasks left.
fn tick_tasks(harness: *Harness, tally: *const Tally, runs: u32, left: u32) !void {
    var events: [8]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&events, conformance.collect_rounds_max * ms));
    try testing.expectEqual(runs, tally.runs);
    try testing.expectEqual(left, harness.loop.tasks_queued());
    try testing.expectEqual(left, owed(harness));
}

test "each tick runs the tasks queued at its start, up to the bound of one run" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var tally: Tally = .{};
    var extra: Counted = .{ .tally = &tally };
    var queued: [backlog]Counted = @splat(.{ .tally = &tally });
    // The first task queues one more, which waits behind the backlog.
    queued[0].then = &extra;
    queued[0].harness = &harness;
    for (&queued) |*one| try harness.loop.schedule(&one.task);
    const per_tick = constants.tasks_per_tick_max;
    try tick_tasks(&harness, &tally, per_tick, backlog - per_tick + 1);
    // The run is FIFO: the first full run took the head of the backlog.
    for (queued[0..per_tick]) |*one| try testing.expectEqual(@as(u32, 1), one.runs);
    for (queued[per_tick..]) |*one| try testing.expectEqual(@as(u32, 0), one.runs);
    try tick_tasks(&harness, &tally, 2 * per_tick, backlog - 2 * per_tick + 1);
    // Fewer than one run's bound are queued: the tick runs exactly those.
    try tick_tasks(&harness, &tally, backlog + 1, 0);
    try testing.expectEqual(@as(u32, 1), extra.runs);
    try tick_tasks(&harness, &tally, backlog + 1, 0);
}

/// A task that schedules itself again on every run, as a library with endless work would.
const Forever = struct {
    task: core.Task = .init(Forever, "task", ran),
    tally: *Tally,
    harness: *Harness,

    fn ran(forever: *Forever) void {
        forever.tally.runs += 1;
        forever.harness.loop.schedule(&forever.task) catch unreachable;
    }
};

/// A record that notes the tick it ran in, and the task runs before it.
const Noted = struct {
    completion: core.Completion = .init(Noted, "completion", called),
    tick: *const u32,
    tally: *const Tally,
    fired_at: ?u32 = null,
    runs_before: u32 = 0,

    fn called(noted: *Noted, event: Event) void {
        std.debug.assert(!event.flags.more);
        noted.fired_at = noted.tick.*;
        noted.runs_before = noted.tally.runs;
    }
};

/// Tasks that never stop in the backlog scenario: more than one run takes.
const endless = constants.tasks_per_tick_max + 36;

test "a backlog of tasks does not delay a record's callback past the tick of its event" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var tally: Tally = .{};
    var tasks: [endless]Forever = @splat(.{ .tally = &tally, .harness = &harness });
    for (&tasks) |*one| try harness.loop.schedule(&one.task);
    var tick: u32 = 0;
    var noted: Noted = .{ .tick = &tick, .tally = &tally };
    // Two timers with one deadline end in one tick. The one without a record shows the caller
    // which tick that is.
    try harness.submit(&.{
        Operation.timer(0, 2 * ms, 0).completion(&noted.completion),
        Operation.timer(5, 2 * ms, 0),
    }, &.{});
    var events: [8]Event = undefined;
    var arrived: u32 = 0;
    while (arrived == 0 and tick < ticks_max) : (tick += 1) {
        arrived = try harness.loop.tick(&events, constants.ns_per_s);
        if (arrived == 0) try testing.expectEqual(@as(?u32, null), noted.fired_at);
    }
    try testing.expectEqual(@as(u32, 1), arrived);
    try testing.expectEqual(@as(u64, 5), events[0].user_data);
    // The record ran in that tick, before the tasks of that tick and after every earlier run.
    const at = tick - 1;
    try testing.expectEqual(@as(?u32, at), noted.fired_at);
    try testing.expectEqual(at * constants.tasks_per_tick_max, noted.runs_before);
    try testing.expectEqual(tick * constants.tasks_per_tick_max, tally.runs);
    try testing.expectEqual(@as(u32, endless), harness.loop.discard_tasks());
    try testing.expectEqual(@as(u32, 0), owed(&harness));
}

/// A task that schedules itself again `again` times.
const Again = struct {
    task: core.Task = .init(Again, "task", ran),
    harness: *Harness,
    again: u32,
    runs: u32 = 0,

    fn ran(again: *Again) void {
        again.runs += 1;
        if (again.again == 0) return;
        again.again -= 1;
        again.harness.loop.schedule(&again.task) catch unreachable;
    }
};

/// Queues `again` and drains the loop. When the drain fails, checks that it took exactly its bound
/// of ticks, and returns its error.
fn drain_chain(harness: *Harness, tick_count: *TickCount, again: *Again) !void {
    try harness.loop.schedule(&again.task);
    var scratch: [8]Event = undefined;
    harness.loop.drain(&scratch) catch |err| {
        try testing.expectEqual(constants.drain_rounds_max, tick_count.ticks);
        return err;
    };
}

test "drain ends a chain of tasks at its last allowed tick, and gives up one run later" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var tick_count: TickCount = .{};
    try harness.loop.add_poller(&tick_count.poller);
    defer harness.loop.remove_poller(&tick_count.poller);
    // One run a tick, `drain_rounds_max` runs: the last tick the bound allows empties the queue.
    var fits: Again = .{ .harness = &harness, .again = constants.drain_rounds_max - 1 };
    try drain_chain(&harness, &tick_count, &fits);
    try testing.expectEqual(constants.drain_rounds_max, fits.runs);
    try testing.expectEqual(constants.drain_rounds_max, tick_count.ticks);
    try testing.expectEqual(@as(u32, 0), harness.loop.tasks_queued());
    // One run more than the bound: the drain gives up with the last run still queued.
    tick_count.ticks = 0;
    var over: Again = .{ .harness = &harness, .again = constants.drain_rounds_max };
    try testing.expectError(error.TasksStillQueued, drain_chain(&harness, &tick_count, &over));
    try testing.expectEqual(constants.drain_rounds_max, over.runs);
    try testing.expectEqual(@as(u32, 1), harness.loop.tasks_queued());
    try testing.expectEqual(@as(u32, 1), harness.loop.discard_tasks());
    try testing.expectEqual(@as(u32, 0), owed(&harness));
}
