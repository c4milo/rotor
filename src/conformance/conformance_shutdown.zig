//! Shutdown of a shared loop on every backend (decisions 5, 26 and 27). `core/shutdown.zig` tests
//! `drain` on a fake loop whose tasks are a counter. These scenarios run `drain`, `discard_tasks`
//! and `deinit` on a real loop, with records in flight and tasks queued.
//!
//! Each scenario checks the once rule and non-negotiable 5. Each record counts its final events,
//! and the count is exactly 1. Each task counts its runs. At the end the loop holds no operation
//! and no task, and owes no callback. The scenarios read `callbacks_outstanding` directly from the
//! tables, because it is not on the surface.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const reactor_module = @import("reactor");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const tcp = @import("conformance_tcp.zig");

const ReactorHarness = conformance.ReactorHarness;
const Event = core.Event;
const Operation = core.Operation;
const sync = backend.sync;

const ms = core.constants.ns_per_ms;

/// The most ticks a scenario makes while it waits for a record's final event.
pub const rounds_max = 400;
/// The longest one of those ticks waits.
pub const wait_ns = 10 * ms;

/// The delay of a timer that must stay in flight for the whole scenario: an hour.
pub const never_ns = 3600 * core.constants.ns_per_s;

/// The bound of the short `drain` calls below. A long timer is still in flight after this many
/// ticks of `short_wait_ns`, and a task that schedules itself is still queued.
const short_rounds = 4;
const short_wait_ns = ms;

/// A record that counts the events of its operations, and keeps the last final event.
pub const Record = struct {
    completion: reactor_module.Completion = .init(Record, "completion", called),
    mores: u32 = 0,
    finals: u32 = 0,
    final: ?Event = null,
    /// A task to queue at the final event, or null.
    queue_at_final: ?*reactor_module.Task = null,
    reactor: ?*conformance.Reactor = null,

    fn called(record: *Record, event: Event) void {
        record.note(event);
    }

    /// Counts `event`, and queues `queue_at_final` at the final event. A record of another type
    /// that wraps a `Record` calls it from its own callback.
    pub fn note(record: *Record, event: Event) void {
        std.debug.assert(event.flags.dispatched);
        if (event.flags.more) {
            record.mores += 1;
            return;
        }
        record.finals += 1;
        record.final = event;
        const task = record.queue_at_final orelse return;
        record.reactor.?.schedule(task) catch unreachable;
    }

    pub fn finished(record: *const Record) bool {
        return record.finals != 0;
    }
};

/// A task that counts its runs, and queues `then` from its run when it names one.
pub const Counted = struct {
    task: reactor_module.Task = .init(Counted, "task", ran),
    runs: u32 = 0,
    then: ?*reactor_module.Task = null,
    reactor: ?*conformance.Reactor = null,

    fn ran(counted: *Counted) void {
        counted.runs += 1;
        const then = counted.then orelse return;
        counted.reactor.?.schedule(then) catch unreachable;
    }
};

/// A task that schedules itself again on every run.
pub const Forever = struct {
    task: reactor_module.Task = .init(Forever, "task", ran),
    reactor: *conformance.Reactor,
    runs: u32 = 0,

    fn ran(forever: *Forever) void {
        forever.runs += 1;
        forever.reactor.schedule(&forever.task) catch unreachable;
    }
};

/// Fails unless the loop holds no operation and no task, and owes no callback.
pub fn expect_empty(harness: *ReactorHarness) !void {
    try testing.expectEqual(@as(u32, 0), harness.reactor.in_flight());
    try testing.expectEqual(@as(u32, 0), harness.reactor.tasks_queued());
    try testing.expectEqual(@as(u32, 0), harness.reactor.loop.tables.outstanding);
}

/// Fails unless each record of `records` received exactly one final event.
pub fn expect_one_final(records: []const Record) !void {
    for (records) |*record| try testing.expectEqual(@as(u32, 1), record.finals);
}

/// Ticks until `done` returns true, and fails when it does not within `rounds_max` ticks. Returns
/// the count of events the ticks handed to the caller: the events of operations without a record.
pub fn tick_until(harness: *ReactorHarness, context: anytype, comptime done: fn (@TypeOf(context)) bool) !u32 {
    var events: [8]Event = undefined;
    var plain: u32 = 0;
    var round: u32 = 0;
    while (!done(context) and round < rounds_max) : (round += 1) {
        plain += try harness.reactor.tick(&events, wait_ns);
    }
    try testing.expect(done(context));
    return plain;
}

test "drain ends the records in flight and runs the queued tasks, each exactly once" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: ReactorHarness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const listener = try tcp.Listener.open();
    defer sync.close_now(listener.descriptor);
    const pair = try tcp.connected_pair(&harness, &listener);
    defer for (pair) |descriptor| sync.close_now(descriptor);

    var records: [4]Record = @splat(.{});
    var bytes: [8]u8 = undefined;
    try harness.submit(&.{
        reactor_module.Completion.mark(&records[0].completion, Operation.timer(0, ms, 0)),
        reactor_module.Completion.mark(&records[1].completion, Operation.timer(0, 3 * ms, 0)),
        reactor_module.Completion.mark(&records[2].completion, Operation.receive(0, pair[1], &bytes)),
        reactor_module.Completion.mark(&records[3].completion, Operation.send(0, pair[0], "drain")),
    }, &.{});
    var tasks: [3]Counted = @splat(.{});
    for (&tasks) |*counted| try harness.reactor.schedule(&counted.task);
    try testing.expectEqual(@as(u32, 4 + 3), harness.reactor.loop.tables.outstanding);

    var scratch: [8]Event = undefined;
    try harness.reactor.drain(&scratch);
    try expect_one_final(&records);
    for (&tasks) |*counted| try testing.expectEqual(@as(u32, 1), counted.runs);
    try testing.expectEqual(@as(u32, 5), try records[2].final.?.outcome());
    try expect_empty(&harness);
}

test "a task that a record queues at its final event in the drain runs, and so does its task" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: ReactorHarness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    // The record queues `first` in the end of the tick that ends the timer. `first` runs in that
    // end and queues `second`, which only a later tick runs. When that tick comes, the loop holds no
    // operation, so only a drain that also counts the queued tasks reaches it.
    var second: Counted = .{};
    var first: Counted = .{ .then = &second.task, .reactor = &harness.reactor };
    var record: Record = .{ .queue_at_final = &first.task, .reactor = &harness.reactor };
    try harness.submit(&.{reactor_module.Completion.mark(&record.completion, Operation.timer(0, ms, 0))}, &.{});

    var scratch: [8]Event = undefined;
    try harness.reactor.drain(&scratch);
    try testing.expectEqual(@as(u32, 1), record.finals);
    try testing.expectEqual(@as(u32, 1), first.runs);
    try testing.expectEqual(@as(u32, 1), second.runs);
    try expect_empty(&harness);
}

test "drain reports an operation in flight before it reports a queued task" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: ReactorHarness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var record: Record = .{};
    var handles: [1]core.Handle = undefined;
    try harness.submit(&.{reactor_module.Completion.mark(&record.completion, Operation.timer(0, never_ns, 0))}, &handles);
    var forever: Forever = .{ .reactor = &harness.reactor };
    try harness.reactor.schedule(&forever.task);

    // Both are left at the bound. The kernel still holds the timer, so the memory must not go.
    var scratch: [8]Event = undefined;
    const dispatch = &harness.reactor.dispatch;
    try testing.expectError(error.StillInFlight, dispatch.drain_within(&harness.reactor.loop, &scratch, short_rounds, short_wait_ns));
    try testing.expectEqual(@as(u32, short_rounds), forever.runs);
    try testing.expectEqual(@as(u32, 0), record.finals);

    // With the timer ended, only the task is left.
    harness.reactor.cancel(handles[0]);
    try testing.expectError(error.TasksStillQueued, dispatch.drain_within(&harness.reactor.loop, &scratch, short_rounds, short_wait_ns));
    try testing.expectEqual(@as(u32, 1), record.finals);
    try testing.expectError(error.Canceled, record.final.?.outcome());
    try testing.expectEqual(@as(u32, 1), harness.reactor.discard_tasks());

    // A tick after the discard runs nothing, and the loop has outstanding nothing.
    const runs = forever.runs;
    _ = try harness.reactor.tick(&scratch, 0);
    try testing.expectEqual(runs, forever.runs);
    try expect_empty(&harness);
}

fn all_finished(records: *const [3]Record) bool {
    return records[0].finished() and records[1].finished() and records[2].finished();
}

test "discard_tasks with records in flight leaves the records owed, and later ticks end them" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: ReactorHarness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const listener = try tcp.Listener.open();
    defer sync.close_now(listener.descriptor);
    const pair = try tcp.connected_pair(&harness, &listener);
    defer for (pair) |descriptor| sync.close_now(descriptor);

    // No record can end before the discard. The timer ends only at its cancel, and the receive
    // ends only when the send after the discard gives it data. A short timer could expire during
    // the first tick when the host preempts the thread, and the loop then owes one record.
    var records: [3]Record = @splat(.{});
    var bytes: [8]u8 = undefined;
    var handles: [2]core.Handle = undefined;
    try harness.submit(&.{
        reactor_module.Completion.mark(&records[0].completion, Operation.timer(0, never_ns, 0)),
        reactor_module.Completion.mark(&records[1].completion, Operation.receive(0, pair[1], &bytes)),
    }, &handles);
    var scratch: [8]Event = undefined;
    _ = try harness.reactor.tick(&scratch, 0);
    var tasks: [3]Counted = @splat(.{});
    for (&tasks) |*counted| try harness.reactor.schedule(&counted.task);

    try testing.expectEqual(@as(u32, 3), harness.reactor.discard_tasks());
    try testing.expectEqual(@as(u32, 0), harness.reactor.tasks_queued());
    // The loop still owes the two records their final events, and nothing for the tasks.
    try testing.expectEqual(@as(u32, 2), harness.reactor.loop.tables.outstanding);

    harness.reactor.cancel(handles[0]);
    try harness.submit(&.{reactor_module.Completion.mark(&records[2].completion, Operation.send(0, pair[0], "discard"))}, &.{});
    try testing.expectEqual(@as(u32, 0), try tick_until(&harness, &records, all_finished));
    try expect_one_final(&records);
    try testing.expectError(error.Canceled, records[0].final.?.outcome());
    try testing.expectEqual(@as(u32, 7), try records[1].final.?.outcome());
    for (&tasks) |*counted| try testing.expectEqual(@as(u32, 0), counted.runs);
    try expect_empty(&harness);
    // The deferred `deinit` checks the same: it halts while an operation or a task is left.
}
