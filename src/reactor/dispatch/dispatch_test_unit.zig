//! The unit tests of `dispatch.zig`: records, pollers and the task queue of `.default`. In a file
//! of their own for the 500-line limit of `dispatch.zig`, since decision 30 added the groups.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const constants = @import("../constants.zig");
const dispatch_module = @import("dispatch.zig");
const reactor_module = @import("../reactor.zig");
const Words = @import("dispatch_test_model.zig").Words;

const Completion = reactor_module.Completion;
const Dispatch = dispatch_module.Dispatch;
const Event = core.Event;
const Groups = reactor_module.Groups;
const Poller = reactor_module.Poller;
const Task = reactor_module.Task;
const WaitLimit = core.WaitLimit;

/// A reactor's state with no group other than `.default`, and the words of its loop.
const Bed = struct {
    dispatch: Dispatch,
    groups: Groups,
    words: Words,

    fn init(bed: *Bed) void {
        bed.words = .{};
        bed.dispatch.start(&bed.groups, .{ .id = 0, .in_group = false, .named_groups = &.empty });
    }

    /// No poller is added and no callback is outstanding: the reactor's tick takes the fast path.
    fn idle(bed: *const Bed) bool {
        return bed.dispatch.poller_count == 0 and bed.words.word == 0;
    }

    fn begin(bed: *Bed, wait_ns: u64) u64 {
        return bed.dispatch.begin(&bed.words, wait_ns);
    }

    fn end(bed: *Bed, events: []Event) u32 {
        return bed.dispatch.end(&bed.words, events);
    }

    fn schedule(bed: *Bed, task: *Task) !void {
        return bed.dispatch.schedule(&bed.words, task);
    }
};

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
    var bed: Bed = undefined;
    bed.init();
    var counting: Counting = .{};
    // What the reactor's `submit` adds for the one operation with a record.
    bed.words.word += 1;
    var events = [_]Event{
        .{ .user_data = 1, .result = 0, .flags = .{} },
        dispatched_event(&counting.completion, 5, true),
        .{ .user_data = 2, .result = 0, .flags = .{} },
        dispatched_event(&counting.completion, 6, false),
    };
    try testing.expectEqual(@as(u64, 7), bed.begin(7));
    const kept = bed.end(&events);
    try testing.expectEqual(@as(u32, 2), kept);
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectEqual(@as(u64, 2), events[1].user_data);
    try testing.expectEqual(@as(u32, 2), counting.events);
    try testing.expectEqual(@as(i32, 6), counting.last_result);
    // The `more` event kept the operation in flight, and the final one ended it.
    try testing.expectEqual(@as(u32, 0), bed.words.word);
    try testing.expect(bed.dispatch.phase == .idle);
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
    var bed: Bed = undefined;
    bed.init();
    var idle: Polling = .{};
    var busy: Polling = .{ .worked = true };
    try bed.dispatch.add_poller(&bed.words, &idle.poller);
    try testing.expectEqual(@as(u64, 9), bed.begin(9));
    _ = bed.end(&.{});
    try bed.dispatch.add_poller(&bed.words, &busy.poller);
    try testing.expectEqual(@as(u64, 0), bed.begin(9));
    _ = bed.end(&.{});
    try testing.expectEqual(@as(u32, 2), idle.calls);
    try testing.expectEqual(@as(u32, 1), busy.calls);
    bed.dispatch.remove_poller(&bed.words, &busy.poller);
    try testing.expectEqual(@as(u64, 9), bed.begin(9));
    _ = bed.end(&.{});
    try testing.expectEqual(@as(u32, 1), busy.calls);
    try testing.expectEqual(@as(u32, 3), idle.calls);
}

test "a full table of pollers refuses one more, and a removal keeps the order of the rest" {
    var bed: Bed = undefined;
    bed.init();
    var pollers: [constants.pollers_max + 1]Polling = @splat(.{});
    for (pollers[0..constants.pollers_max]) |*polling| try bed.dispatch.add_poller(&bed.words, &polling.poller);
    try testing.expectError(error.PollersFull, bed.dispatch.add_poller(&bed.words, &pollers[constants.pollers_max].poller));
    bed.dispatch.remove_poller(&bed.words, &pollers[1].poller);
    try testing.expectEqual(&pollers[0].poller, bed.dispatch.pollers[0]);
    try testing.expectEqual(&pollers[2].poller, bed.dispatch.pollers[1]);
    try bed.dispatch.add_poller(&bed.words, &pollers[constants.pollers_max].poller);
}

test "the line names the first poller after each add and remove, and none after the last" {
    var bed: Bed = undefined;
    bed.init();
    var first: Polling = .{};
    var second: Polling = .{};
    try testing.expectEqual(@as(?*const [:0]const u8, null), bed.words.heartbeat.poller_name);
    try bed.dispatch.add_poller(&bed.words, &first.poller);
    try bed.dispatch.add_poller(&bed.words, &second.poller);
    try testing.expectEqual(&first.poller.call.name, bed.words.heartbeat.poller_name.?);
    bed.dispatch.remove_poller(&bed.words, &first.poller);
    try testing.expectEqual(&second.poller.call.name, bed.words.heartbeat.poller_name.?);
    bed.dispatch.remove_poller(&bed.words, &second.poller);
    try testing.expectEqual(@as(?*const [:0]const u8, null), bed.words.heartbeat.poller_name);
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

/// A record that queues `queued` on `bed` when it is called.
const Scheduling = struct {
    completion: Completion = .init(Scheduling, "completion", called),
    bed: *Bed,
    queued: *Task,
    order: *Order,

    fn called(scheduling: *Scheduling, event: Event) void {
        _ = event;
        scheduling.order.note('r');
        scheduling.bed.schedule(scheduling.queued) catch unreachable;
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
    var bed: Bed = undefined;
    bed.init();
    var order: Order = .{};
    var noting: Noting = .{ .order = &order };
    var first: Scheduling = .{ .bed = &bed, .queued = &noting.task, .order = &order };
    var second: Recording = .{ .order = &order };
    bed.words.word += 2;
    var events = [_]Event{
        dispatched_event(&first.completion, 0, false),
        dispatched_event(&second.completion, 0, false),
    };
    _ = bed.begin(5);
    _ = bed.end(&events);
    try testing.expectEqualSlices(u8, "rrt", order.marks[0..order.len]);
    try testing.expectEqual(@as(u32, 0), bed.dispatch.tasks.count);
    try testing.expect(bed.idle());
}

/// A poller that queues `queued` the first time it runs.
const Queueing = struct {
    poller: Poller = .init(Queueing, "poller", polled),
    bed: *Bed,
    queued: ?*Task,

    fn polled(queueing: *Queueing) WaitLimit {
        const task = queueing.queued orelse return .none;
        queueing.queued = null;
        queueing.bed.schedule(task) catch unreachable;
        return .none;
    }
};

/// A task that schedules itself again from its own run, `again` times.
const Again = struct {
    task: Task = .init(Again, "task", ran),
    bed: *Bed,
    again: u32,

    fn ran(again: *Again) void {
        if (again.again == 0) return;
        again.again -= 1;
        again.bed.schedule(&again.task) catch unreachable;
    }
};

test "a task that schedules itself keeps its callback outstanding until its last run" {
    var bed: Bed = undefined;
    bed.init();
    var again: Again = .{ .bed = &bed, .again = 2 };
    try bed.schedule(&again.task);
    for (0..2) |_| {
        _ = bed.begin(9);
        _ = bed.end(&.{});
        // The run took one task and the task queued itself: one callback is still outstanding.
        try testing.expectEqual(@as(u32, 1), bed.words.word);
        try testing.expect(!bed.idle());
    }
    _ = bed.begin(9);
    _ = bed.end(&.{});
    try testing.expectEqual(@as(u32, 0), bed.words.word);
    try testing.expect(bed.idle());
}

test "discarding the queue clears the outstanding callbacks, so the next tick skips the dispatch" {
    var bed: Bed = undefined;
    bed.init();
    var order: Order = .{};
    var noting: Noting = .{ .order = &order };
    try bed.schedule(&noting.task);
    try testing.expect(!bed.idle());
    try testing.expectEqual(@as(u32, 1), bed.dispatch.discard_tasks(&bed.words));
    try testing.expectEqual(@as(u32, 0), bed.words.word);
    try testing.expect(bed.idle());
    try testing.expectEqual(@as(u32, 0), order.len);
}

test "a queued task keeps begin from blocking, and a poller's task runs in the same end" {
    var bed: Bed = undefined;
    bed.init();
    var order: Order = .{};
    var noting: Noting = .{ .order = &order };
    var queueing: Queueing = .{ .bed = &bed, .queued = &noting.task };
    try bed.dispatch.add_poller(&bed.words, &queueing.poller);
    // The poller queues the task in begin, which then may not block.
    try testing.expectEqual(@as(u64, 0), bed.begin(9));
    try testing.expect(!bed.idle());
    _ = bed.end(&.{});
    try testing.expectEqualSlices(u8, "t", order.marks[0..order.len]);
    // Nothing is queued now, so the next begin may block for the whole wait.
    try testing.expectEqual(@as(u64, 9), bed.begin(9));
    _ = bed.end(&.{});
    bed.dispatch.remove_poller(&bed.words, &queueing.poller);
    try testing.expect(bed.idle());

    // A task the program queued between ticks makes the dispatch busy until a tick runs it.
    try bed.schedule(&noting.task);
    try testing.expect(!bed.idle());
    try testing.expectEqual(@as(u64, 0), bed.begin(9));
    _ = bed.end(&.{});
    try testing.expect(bed.idle());
    try testing.expectEqualSlices(u8, "tt", order.marks[0..order.len]);
}
