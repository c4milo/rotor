//! Tests of the wait limit of decision 29: what `Dispatch.begin` folds from the pollers, what `end`,
//! `remove_poller` and a wake store, and what `Tables.wait_bound` and `Tables.wait_limit` read. In
//! a file of their own for the 500-line limit of `dispatch.zig`. The drain's part is in
//! `inbox_test.zig`.
const std = @import("std");
const testing = std.testing;
const core = @import("../core.zig");
const dispatch_module = @import("dispatch.zig");

const Completion = dispatch_module.Completion;
const Dispatch = dispatch_module.Dispatch;
const Event = core.Event;
const Heartbeat = core.Heartbeat;
const Poller = dispatch_module.Poller;
const Slot = core.Slot;
const Tables = core.tables.Tables;
const Task = core.Task;
const TimerHeap = core.timer_heap.TimerHeap;
const WaitLimit = dispatch_module.WaitLimit;

/// A poller that answers `limit`.
const Answering = struct {
    poller: Poller = .init(Answering, "poller", polled),
    limit: WaitLimit,

    fn polled(answering: *Answering) WaitLimit {
        return answering.limit;
    }
};

/// A record and a task that do nothing.
const Quiet = struct {
    completion: Completion = .init(Quiet, "completion", completed),
    task: Task = .init(Quiet, "task", ran),

    fn completed(_: *Quiet, _: Event) void {}
    fn ran(_: *Quiet) void {}
};

/// One `begin` and an `end` with no events. Returns the wait `begin` gave.
fn tick_once(dispatch: *Dispatch, heartbeat: *Heartbeat, wait_ns: u64) u64 {
    const wait = dispatch.begin(heartbeat, wait_ns);
    _ = dispatch.end(heartbeat, &.{});
    return wait;
}

test "begin keeps the least limit of its pollers, and blocks only when it is not now" {
    var dispatch: Dispatch = .empty;
    var heartbeat: Heartbeat = .init(null);
    var first: Answering = .{ .limit = .none };
    try dispatch.add_poller(&first.poller);
    try testing.expectEqual(@as(u64, 9), tick_once(&dispatch, &heartbeat, 9));
    try testing.expectEqual(WaitLimit.none, dispatch.until_ns);
    // A limit in the future, and one in the past, both leave the wait to `wait_bound`.
    first.limit = .at(500);
    try testing.expectEqual(@as(u64, 9), tick_once(&dispatch, &heartbeat, 9));
    try testing.expectEqual(WaitLimit.at(500), dispatch.until_ns);
    first.limit = .at(1);
    try testing.expectEqual(@as(u64, 9), tick_once(&dispatch, &heartbeat, 9));
    try testing.expectEqual(WaitLimit.at(1), dispatch.until_ns);
    // Two pollers: the least limit wins, in either order of the table.
    var second: Answering = .{ .limit = .at(200) };
    try dispatch.add_poller(&second.poller);
    first.limit = .at(300);
    _ = tick_once(&dispatch, &heartbeat, 9);
    try testing.expectEqual(WaitLimit.at(200), dispatch.until_ns);
    first.limit = .at(100);
    _ = tick_once(&dispatch, &heartbeat, 9);
    try testing.expectEqual(WaitLimit.at(100), dispatch.until_ns);
    second.limit = .now;
    try testing.expectEqual(@as(u64, 0), tick_once(&dispatch, &heartbeat, 9));
    try testing.expectEqual(WaitLimit.now, dispatch.until_ns);
}

test "end stores now after a record or a task while a poller is in the table, and not otherwise" {
    var dispatch: Dispatch = .empty;
    var heartbeat: Heartbeat = .init(null);
    var quiet: Quiet = .{};
    var answering: Answering = .{ .limit = .at(700) };
    try dispatch.add_poller(&answering.poller);
    // No callback: the limit stays the pollers' answer.
    _ = tick_once(&dispatch, &heartbeat, 9);
    try testing.expectEqual(WaitLimit.at(700), dispatch.until_ns);
    // A record.
    dispatch.note_submitted(1);
    var events = [_]Event{.{
        .user_data = @intFromPtr(&quiet.completion),
        .result = 0,
        .flags = .{ .dispatched = true },
    }};
    _ = dispatch.begin(&heartbeat, 9);
    _ = dispatch.end(&heartbeat, &events);
    try testing.expectEqual(WaitLimit.now, dispatch.until_ns);
    // A task.
    try dispatch.schedule(&quiet.task);
    _ = tick_once(&dispatch, &heartbeat, 9);
    try testing.expectEqual(WaitLimit.now, dispatch.until_ns);
    // With no poller, a task stores nothing.
    dispatch.remove_poller(&answering.poller);
    try dispatch.schedule(&quiet.task);
    _ = tick_once(&dispatch, &heartbeat, 9);
    try testing.expectEqual(WaitLimit.none, dispatch.until_ns);
}

test "a removal that empties the table resets the limit, and a wake stores now only with a poller" {
    var dispatch: Dispatch = .empty;
    var heartbeat: Heartbeat = .init(null);
    var first: Answering = .{ .limit = .at(40) };
    var second: Answering = .{ .limit = .at(50) };
    try dispatch.add_poller(&first.poller);
    try dispatch.add_poller(&second.poller);
    _ = tick_once(&dispatch, &heartbeat, 9);
    dispatch.remove_poller(&first.poller);
    try testing.expectEqual(WaitLimit.at(40), dispatch.until_ns);
    dispatch.note_wake();
    try testing.expectEqual(WaitLimit.now, dispatch.until_ns);
    dispatch.remove_poller(&second.poller);
    try testing.expectEqual(WaitLimit.none, dispatch.until_ns);
    dispatch.note_wake();
    try testing.expectEqual(WaitLimit.none, dispatch.until_ns);
}

const capacity = 4;

/// The tables of a loop with `capacity` slots, with no kernel.
const Fixture = struct {
    slots: [capacity]Slot,
    entries: [capacity]TimerHeap.Entry,
    starts: [capacity]u64,
    heartbeat: Heartbeat,
    tables: Tables,

    fn init(fixture: *Fixture) void {
        fixture.tables.init(&fixture.slots, &fixture.entries, &fixture.starts, &fixture.heartbeat, .{
            .id = 0,
        });
        fixture.tables.now_ns = 1_000;
    }

    /// One tick's `begin` and `end` on the tables' dispatch.
    fn tick(fixture: *Fixture) void {
        _ = tick_once(&fixture.tables.dispatch, &fixture.heartbeat, 9);
    }
};

test "wait_bound stops at a poller's limit before the nearest timer, and at the timer otherwise" {
    var fixture: Fixture = undefined;
    fixture.init();
    const tables = &fixture.tables;
    try testing.expectEqual(@as(?u64, 5_000), tables.wait_bound(5_000));
    tables.timers.arm(0, 3_000);
    try testing.expectEqual(@as(?u64, 2_000), tables.wait_bound(5_000));
    var answering: Answering = .{ .limit = .at(1_500) };
    try tables.dispatch.add_poller(&answering.poller);
    fixture.tick();
    try testing.expectEqual(@as(?u64, 500), tables.wait_bound(5_000));
    answering.limit = .at(4_000);
    fixture.tick();
    try testing.expectEqual(@as(?u64, 2_000), tables.wait_bound(5_000));
    // A limit at the tick's stamp gives no wait.
    answering.limit = .at(1_000);
    fixture.tick();
    try testing.expectEqual(@as(?u64, null), tables.wait_bound(5_000));
    // A removal that empties the table leaves the timer alone in the bound.
    tables.dispatch.remove_poller(&answering.poller);
    try testing.expectEqual(@as(?u64, 2_000), tables.wait_bound(5_000));
}

test "wait_limit reads now while work is left, and the least limit or none otherwise" {
    var fixture: Fixture = undefined;
    fixture.init();
    const tables = &fixture.tables;
    var quiet: Quiet = .{};
    try testing.expectEqual(WaitLimit.none, tables.wait_limit());
    tables.timers.arm(0, 3_000);
    try testing.expectEqual(WaitLimit.at(3_000), tables.wait_limit());
    var answering: Answering = .{ .limit = .at(2_000) };
    try tables.dispatch.add_poller(&answering.poller);
    fixture.tick();
    try testing.expectEqual(WaitLimit.at(2_000), tables.wait_limit());
    // A poller that returned now.
    answering.limit = .now;
    fixture.tick();
    try testing.expectEqual(WaitLimit.now, tables.wait_limit());
    // A wake that the last tick took.
    answering.limit = .none;
    fixture.tick();
    try testing.expectEqual(WaitLimit.at(3_000), tables.wait_limit());
    tables.dispatch.note_wake();
    try testing.expectEqual(WaitLimit.now, tables.wait_limit());
    // A task the last tick called.
    try tables.dispatch.schedule(&quiet.task);
    try testing.expectEqual(WaitLimit.now, tables.wait_limit());
    fixture.tick();
    try testing.expectEqual(WaitLimit.now, tables.wait_limit());
    // A timer that is due.
    fixture.tick();
    tables.now_ns = 3_000;
    try testing.expectEqual(WaitLimit.now, tables.wait_limit());
}

test "wait_limit reads now while an operation waits to be submitted" {
    var fixture: Fixture = undefined;
    fixture.init();
    const tables = &fixture.tables;
    var handles: [1]core.Handle = undefined;
    const timer: core.Operation = .{ .user_data = 1, .kind = .{ .timer = .{ .after_ns = 10 } } };
    try testing.expectEqual(@as(u32, 1), tables.submit(&.{timer}, &handles));
    try testing.expectEqual(WaitLimit.now, tables.wait_limit());
}
