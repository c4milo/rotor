//! The unit tests of `dispatch.zig`: records, pollers and the task queue of `.default`. In a file
//! of their own for the 500-line limit of `dispatch.zig`, since decision 30 added the groups.
const std = @import("std");
const testing = std.testing;
const constants = @import("../constants.zig");
const dispatch_module = @import("dispatch.zig");
const Event = @import("../event.zig").Event;
const Heartbeat = @import("../stall.zig").Heartbeat;
const Groups = @import("../scheduling/scheduling_groups.zig").Groups;
const NamedTable = @import("../scheduling/scheduling.zig").NamedTable;
const Task = @import("../tasks.zig").Task;

const Completion = dispatch_module.Completion;
const Dispatch = dispatch_module.Dispatch;
const Poller = dispatch_module.Poller;
const WaitLimit = dispatch_module.WaitLimit;

/// The groups of a loop with no group other than `.default`.
fn no_groups() Groups {
    var groups: Groups = undefined;
    groups.init(&NamedTable.empty);
    return groups;
}

const Counting = struct {
    /// A field before the record, so the parent's address differs from the record's.
    events: u32 = 0,
    completion: Completion = .init(Counting, "completion", called),
    last_result: i32 = 0,

    fn called(counting: *Counting, event: Event) void {
        counting.events += 1;
        counting.last_result = event.result;
    }
};

fn dispatched_event(record: *Completion, result: i32, more: bool) Event {
    return .{ .user_data = @intFromPtr(record), .result = result, .flags = .{ .more = more, .dispatched = true } };
}

test "events with a record reach it, and the rest keep their order at the front" {
    var dispatch: Dispatch = .empty;
    var groups = no_groups();
    var heartbeat: Heartbeat = .init(null);
    var counting: Counting = .{};
    dispatch.note_submitted(1);
    var events = [_]Event{
        .{ .user_data = 1, .result = 0, .flags = .{} },
        dispatched_event(&counting.completion, 5, true),
        .{ .user_data = 2, .result = 0, .flags = .{} },
        dispatched_event(&counting.completion, 6, false),
    };
    try testing.expectEqual(@as(u64, 7), dispatch.begin(&heartbeat, 7));
    const kept = dispatch.end(&heartbeat, &groups, &events);
    try testing.expectEqual(@as(u32, 2), kept);
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectEqual(@as(u64, 2), events[1].user_data);
    try testing.expectEqual(@as(u32, 2), counting.events);
    try testing.expectEqual(@as(i32, 6), counting.last_result);
    // The `more` event kept the operation in flight, and the final one ended it.
    try testing.expectEqual(@as(u32, 0), dispatch.callbacks_outstanding);
    try testing.expect(dispatch.phase == .idle);
}

const Polling = struct {
    calls: u32 = 0,
    poller: Poller = .init(Polling, "poller", polled),
    worked: bool = false,

    fn polled(polling: *Polling) WaitLimit {
        polling.calls += 1;
        return if (polling.worked) .now else .none;
    }
};

test "each poller runs once a tick, and one that did work makes the tick wait 0 ns" {
    var dispatch: Dispatch = .empty;
    var groups = no_groups();
    var heartbeat: Heartbeat = .init(null);
    var idle: Polling = .{};
    var busy: Polling = .{ .worked = true };
    try dispatch.add_poller(&idle.poller);
    try testing.expectEqual(@as(u64, 9), dispatch.begin(&heartbeat, 9));
    _ = dispatch.end(&heartbeat, &groups, &.{});
    try dispatch.add_poller(&busy.poller);
    try testing.expectEqual(@as(u64, 0), dispatch.begin(&heartbeat, 9));
    _ = dispatch.end(&heartbeat, &groups, &.{});
    try testing.expectEqual(@as(u32, 2), idle.calls);
    try testing.expectEqual(@as(u32, 1), busy.calls);
    dispatch.remove_poller(&busy.poller);
    try testing.expectEqual(@as(u64, 9), dispatch.begin(&heartbeat, 9));
    _ = dispatch.end(&heartbeat, &groups, &.{});
    try testing.expectEqual(@as(u32, 1), busy.calls);
    try testing.expectEqual(@as(u32, 3), idle.calls);
}

test "a full table of pollers refuses one more, and a removal keeps the order of the rest" {
    var dispatch: Dispatch = .empty;
    var pollers: [constants.pollers_max + 1]Polling = @splat(.{});
    for (pollers[0..constants.pollers_max]) |*polling| try dispatch.add_poller(&polling.poller);
    try testing.expectError(error.PollersFull, dispatch.add_poller(&pollers[constants.pollers_max].poller));
    dispatch.remove_poller(&pollers[1].poller);
    try testing.expectEqual(&pollers[0].poller, dispatch.pollers[0]);
    try testing.expectEqual(&pollers[2].poller, dispatch.pollers[1]);
    try dispatch.add_poller(&pollers[constants.pollers_max].poller);
}

/// The most marks one test's `Order` holds.
const order_marks_max = 4;

/// Who ran, in order: `r` for a record, `t` for a task.
const Order = struct {
    marks: [order_marks_max]u8 = @splat(0),
    len: u32 = 0,

    fn note(order: *Order, mark: u8) void {
        order.marks[order.len] = mark;
        order.len += 1;
    }
};

/// A record that queues `queued` on `dispatch` when it is called.
const Scheduling = struct {
    completion: Completion = .init(Scheduling, "completion", called),
    dispatch: *Dispatch,
    queued: *Task,
    order: *Order,

    fn called(scheduling: *Scheduling, event: Event) void {
        _ = event;
        scheduling.order.note('r');
        scheduling.dispatch.schedule(scheduling.queued) catch unreachable;
    }
};

/// A task that notes `t`.
const Noting = struct {
    task: Task = .init(Noting, "task", ran),
    order: *Order,

    fn ran(noting: *Noting) void {
        noting.order.note('t');
    }
};

/// A record that notes `r`.
const Recording = struct {
    completion: Completion = .init(Recording, "completion", called),
    order: *Order,

    fn called(recording: *Recording, event: Event) void {
        _ = event;
        recording.order.note('r');
    }
};

test "a task a record queues runs in the same end, after every record" {
    var dispatch: Dispatch = .empty;
    var groups = no_groups();
    var heartbeat: Heartbeat = .init(null);
    var order: Order = .{};
    var noting: Noting = .{ .order = &order };
    var first: Scheduling = .{ .dispatch = &dispatch, .queued = &noting.task, .order = &order };
    var second: Recording = .{ .order = &order };
    dispatch.note_submitted(2);
    var events = [_]Event{
        dispatched_event(&first.completion, 0, false),
        dispatched_event(&second.completion, 0, false),
    };
    _ = dispatch.begin(&heartbeat, 5);
    _ = dispatch.end(&heartbeat, &groups, &events);
    try testing.expectEqualSlices(u8, "rrt", order.marks[0..order.len]);
    try testing.expectEqual(@as(u32, 0), dispatch.tasks.count);
    try testing.expect(dispatch.idle());
}

/// A poller that queues `queued` the first time it runs.
const Queueing = struct {
    poller: Poller = .init(Queueing, "poller", polled),
    dispatch: *Dispatch,
    queued: ?*Task,

    fn polled(queueing: *Queueing) WaitLimit {
        const task = queueing.queued orelse return .none;
        queueing.queued = null;
        queueing.dispatch.schedule(task) catch unreachable;
        return .none;
    }
};

/// A task that schedules itself again from its own run, `again` times.
const Again = struct {
    task: Task = .init(Again, "task", ran),
    dispatch: *Dispatch,
    again: u32,

    fn ran(again: *Again) void {
        if (again.again == 0) return;
        again.again -= 1;
        again.dispatch.schedule(&again.task) catch unreachable;
    }
};

test "a task that schedules itself keeps its callback outstanding until its last run" {
    var dispatch: Dispatch = .empty;
    var groups = no_groups();
    var heartbeat: Heartbeat = .init(null);
    var again: Again = .{ .dispatch = &dispatch, .again = 2 };
    try dispatch.schedule(&again.task);
    for (0..2) |_| {
        _ = dispatch.begin(&heartbeat, 9);
        _ = dispatch.end(&heartbeat, &groups, &.{});
        // The run took one task and the task queued itself: one callback is still outstanding.
        try testing.expectEqual(@as(u32, 1), dispatch.callbacks_outstanding);
        try testing.expect(!dispatch.idle());
    }
    _ = dispatch.begin(&heartbeat, 9);
    _ = dispatch.end(&heartbeat, &groups, &.{});
    try testing.expectEqual(@as(u32, 0), dispatch.callbacks_outstanding);
    try testing.expect(dispatch.idle());
}

test "discarding the queue clears the outstanding callbacks, so the next tick skips the dispatch" {
    var dispatch: Dispatch = .empty;
    var groups = no_groups();
    var order: Order = .{};
    var noting: Noting = .{ .order = &order };
    try dispatch.schedule(&noting.task);
    try testing.expect(!dispatch.idle());
    try testing.expectEqual(@as(u32, 1), dispatch.discard_tasks(&groups));
    try testing.expectEqual(@as(u32, 0), dispatch.callbacks_outstanding);
    try testing.expect(dispatch.idle());
    try testing.expectEqual(@as(u32, 0), order.len);
}

test "a queued task keeps begin from blocking, and a poller's task runs in the same end" {
    var dispatch: Dispatch = .empty;
    var groups = no_groups();
    var heartbeat: Heartbeat = .init(null);
    var order: Order = .{};
    var noting: Noting = .{ .order = &order };
    var queueing: Queueing = .{ .dispatch = &dispatch, .queued = &noting.task };
    try dispatch.add_poller(&queueing.poller);
    // The poller queues the task in begin, which then may not block.
    try testing.expectEqual(@as(u64, 0), dispatch.begin(&heartbeat, 9));
    try testing.expect(!dispatch.idle());
    _ = dispatch.end(&heartbeat, &groups, &.{});
    try testing.expectEqualSlices(u8, "t", order.marks[0..order.len]);
    // Nothing is queued now, so the next begin may block for the whole wait.
    try testing.expectEqual(@as(u64, 9), dispatch.begin(&heartbeat, 9));
    _ = dispatch.end(&heartbeat, &groups, &.{});
    dispatch.remove_poller(&queueing.poller);
    try testing.expect(dispatch.idle());

    // A task the program queued between ticks makes the dispatch busy until a tick runs it.
    try dispatch.schedule(&noting.task);
    try testing.expect(!dispatch.idle());
    try testing.expectEqual(@as(u64, 0), dispatch.begin(&heartbeat, 9));
    _ = dispatch.end(&heartbeat, &groups, &.{});
    try testing.expect(dispatch.idle());
    try testing.expectEqualSlices(u8, "tt", order.marks[0..order.len]);
}
