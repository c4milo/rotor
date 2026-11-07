//! A loop that several libraries share (decision 26). An operation may name a `Completion`, a
//! record in the library's own memory, and the tick calls it for each event of that operation. A
//! library may also add a `Poller`, which the loop calls once in each tick. An event whose operation
//! named no record goes back to the caller of `tick`, as before.
//!
//! The records and the pollers live in memory the library owns, so the loop allocates nothing. The
//! loop calls through a record's address and never decides anything from its value
//! (non-negotiable 2). The callbacks run in the order of the events.
const std = @import("std");
const assert = std.debug.assert;
const assert_class_a = @import("../assertion_class.zig").assert_class_a;
const constants = @import("../constants.zig");
const Event = @import("../event.zig").Event;
const tasks_module = @import("../tasks.zig");

const Heartbeat = @import("../stall.zig").Heartbeat;
const Task = tasks_module.Task;
const Tasks = tasks_module.Tasks;
const ScheduleError = tasks_module.ScheduleError;

/// What an operation names to have the tick call its function for each of its events. The library
/// puts it inside its own struct. `init` points it at a static `Call` that finds that struct again.
/// Size 8 B, alignment 8.
pub const Completion = struct {
    call: *const Call,

    /// A static entry: the callback's name and its function (decision 28). `init` makes one,
    /// named `@typeName(Parent) ++ "." ++ field`. A `Call` written by hand is a container-level
    /// `const` with a literal name: another thread may read the name after a library frees its
    /// record, so it must be static data, and the compiler cannot refuse one on the stack.
    pub const Call = struct {
        name: [:0]const u8,
        function: *const fn (completion: *Completion, event: Event) void,
    };

    /// A record at `field` of `Parent` that calls `handler` with its parent for each event. The
    /// compiler checks the field, the parent and the handler, and the callback it makes costs the
    /// same indirect call as one written by hand, after one load of the static `Call`.
    pub fn init(
        comptime Parent: type,
        comptime field: []const u8,
        comptime handler: fn (parent: *Parent, event: Event) void,
    ) Completion {
        comptime assert(@FieldType(Parent, field) == Completion);
        const Static = struct {
            fn function(completion: *Completion, event: Event) void {
                const parent: *Parent = @alignCast(@fieldParentPtr(field, completion));
                handler(parent, event);
            }
            const call: Call = .{ .name = name_of(Parent, field), .function = function };
        };
        return .{ .call = &Static.call };
    }
};

/// What a library adds to have the loop call its function once in each tick, before the tick waits.
/// The function returns true when the tick must not block, for example because work is left: the
/// tick then waits 0 ns. True means nothing else. Size 8 B, alignment 8.
pub const Poller = struct {
    call: *const Call,

    /// A static entry, as `Completion.Call` is.
    pub const Call = struct {
        name: [:0]const u8,
        function: *const fn (poller: *Poller) bool,
    };

    /// A poller at `field` of `Parent` that calls `handler` with its parent.
    pub fn init(
        comptime Parent: type,
        comptime field: []const u8,
        comptime handler: fn (parent: *Parent) bool,
    ) Poller {
        comptime assert(@FieldType(Parent, field) == Poller);
        const Static = struct {
            fn function(poller: *Poller) bool {
                const parent: *Parent = @alignCast(@fieldParentPtr(field, poller));
                return handler(parent);
            }
            const call: Call = .{ .name = name_of(Parent, field), .function = function };
        };
        return .{ .call = &Static.call };
    }
};

comptime {
    assert(@sizeOf(Completion) == 8);
    assert(@sizeOf(Poller) == 8);
    // The heartbeat is not here: it is on a line of its own, so `Dispatch` keeps the size and the
    // alignment it had before decision 28.
    assert(@sizeOf(Dispatch) == 96);
    assert(@alignOf(Dispatch) == 8);
}

/// The name of the callback at `field` of `Parent`, for example `colibri.client.Client.receive`.
pub const name_of = @import("../stall.zig").name_of;

pub const AddPollerError = error{PollersFull};

/// The calls every backend's `Loop` exports: `dispatch_calls.zig`.
pub const Calls = @import("dispatch_calls.zig").Calls;

/// The state of the dispatch, which `Tables` holds. Size 96 B, alignment 8.
pub const Dispatch = struct {
    pollers: [constants.pollers_max]*Poller,
    poller_count: u8,
    /// The callbacks still outstanding: operations in flight that named a record, and tasks queued
    /// (decision 27, open question 3). A kernel error a tick kept counts as one too, so the next
    /// tick leaves the fast path and returns it (`tick_error.zig`). With no poller, the tick
    /// dispatches only while this is above 0, so a program that names no record and queues no task
    /// pays two compares in each tick. One word and not two, because a third compare cost the work
    /// gate's post 4 instructions and post-operation 7 on `mac` (decision 27, "What was built").
    callbacks_outstanding: u32,
    /// True from `begin` to `end`: a callback or a poller that calls `tick` halts.
    ticking: bool,
    /// True while `begin` calls the pollers: a poller that adds or removes a poller halts, because
    /// the loop is walking the table. A callback may add or remove one.
    polling: bool,
    /// The task queue (decision 27). Its count is the third word `idle` reads.
    tasks: Tasks,

    pub const empty: Dispatch = .{
        .pollers = undefined,
        .poller_count = 0,
        .callbacks_outstanding = 0,
        .ticking = false,
        .polling = false,
        .tasks = .empty,
    };

    pub fn add_poller(dispatch: *Dispatch, poller: *Poller) AddPollerError!void {
        assert(!dispatch.polling);
        assert(dispatch.poller_count <= constants.pollers_max);
        for (dispatch.pollers[0..dispatch.poller_count]) |added| assert(added != poller);
        if (dispatch.poller_count == constants.pollers_max) return error.PollersFull;
        dispatch.pollers[dispatch.poller_count] = poller;
        dispatch.poller_count += 1;
    }

    /// Removes `poller`, which must have been added. The pollers after it keep their order.
    pub fn remove_poller(dispatch: *Dispatch, poller: *Poller) void {
        assert(!dispatch.polling);
        const count = dispatch.poller_count;
        const found = std.mem.indexOfScalar(*Poller, dispatch.pollers[0..count], poller);
        assert(found != null);
        const index = found orelse return;
        const after = dispatch.pollers[index + 1 .. count];
        std.mem.copyForwards(*Poller, dispatch.pollers[index .. count - 1], after);
        dispatch.poller_count = count - 1;
    }

    /// Halts inside a tick, or when a poller is still added or a task is still queued: what
    /// `deinit` checks, because each is memory the library owns and may free once the loop has
    /// ended (decision 8, class C). A record, a poller or a task that ends the loop halts at once
    /// (decision 28).
    pub fn assert_empty(dispatch: *const Dispatch) void {
        assert(!dispatch.ticking);
        assert(dispatch.poller_count == 0);
        assert(dispatch.tasks.count == 0);
    }

    /// Queues `task`, which the `end` of a tick calls once (decision 27).
    pub fn schedule(dispatch: *Dispatch, task: *Task) ScheduleError!void {
        try dispatch.tasks.push(task, constants.tasks_queued_max);
        dispatch.callbacks_outstanding += 1;
    }

    /// Unlinks every queued task without a call. Halts inside a tick: only the program calls it,
    /// between ticks, after `drain` returned `TasksStillQueued`.
    pub fn discard_tasks(dispatch: *Dispatch) u32 {
        assert(!dispatch.ticking);
        const discarded = dispatch.tasks.discard();
        dispatch.callbacks_outstanding -= discarded;
        return discarded;
    }

    /// Counts the `records` operations with a record that one `submit` took.
    pub fn note_submitted(dispatch: *Dispatch, records: u32) void {
        dispatch.callbacks_outstanding += records;
    }

    /// True when no poller is added, no operation with a record is in flight and no task is queued:
    /// no callback can run in the next tick, so the tick skips `begin` and `end`.
    pub fn idle(dispatch: *const Dispatch) bool {
        return dispatch.poller_count == 0 and dispatch.callbacks_outstanding == 0;
    }

    /// The start of a tick: halts inside another tick, then calls every poller once. Returns the
    /// wait the tick may block for: 0 when a poller did work or a task is queued, and `wait_ns`
    /// otherwise. A task queued now runs in this tick's `end`, so the tick must not sleep first.
    /// `heartbeat` is the loop's (decision 28): it names each poller while it runs.
    pub fn begin(dispatch: *Dispatch, heartbeat: *Heartbeat, wait_ns: u64) u64 {
        assert_class_a(!dispatch.ticking);
        dispatch.ticking = true;
        dispatch.polling = true;
        var worked = false;
        // A poller cannot add or remove one, so the count read here is the count it calls.
        const polled = dispatch.poller_count;
        for (dispatch.pollers[0..polled]) |poller| {
            heartbeat.enter(&poller.call.name);
            if (poller.call.function(poller)) worked = true;
        }
        // A `begin` with no poller leaves the heartbeat as it is: `running` is null already.
        if (polled != 0) heartbeat.leave_polling(polled);
        dispatch.polling = false;
        return if (worked or dispatch.tasks.count != 0) 0 else wait_ns;
    }

    /// The end of a tick: calls the record of each event that has one, and moves the other events
    /// to the front of `events`, in order. Then it runs the tasks queued so far, so a task that a
    /// record or a poller queued runs in this tick (decision 27). Returns how many events are at
    /// the front. `ticking` stays set while the tasks run, so a task that ticks halts. `heartbeat`
    /// is the loop's, as in `begin`.
    pub fn end(dispatch: *Dispatch, heartbeat: *Heartbeat, events: []Event) u32 {
        assert_class_a(dispatch.ticking);
        defer dispatch.ticking = false;
        const kept = dispatch.call_records(heartbeat, events);
        // Each subtraction's overflow check halts on a callback the count never saw. While a task
        // is queued, a stray final event lowers the count without an underflow, and the halt comes
        // at the latest when the queue empties. `run` is called first and its count subtracted
        // after: a task that schedules a task adds to the count during the run, and a compound
        // `-=` would read the count before the call and lose that addition.
        const ran = dispatch.tasks.run(heartbeat);
        dispatch.callbacks_outstanding -= ran;
        return kept;
    }

    /// Ends a tick that failed, so the next tick may begin.
    pub fn abandon(dispatch: *Dispatch) void {
        assert(dispatch.ticking);
        dispatch.ticking = false;
    }

    fn call_records(dispatch: *Dispatch, heartbeat: *Heartbeat, events: []Event) u32 {
        var kept: u32 = 0;
        for (events) |event| {
            if (!event.flags.dispatched) {
                events[kept] = event;
                kept += 1;
                continue;
            }
            const record: *Completion = @ptrFromInt(event.user_data);
            heartbeat.enter(&record.call.name);
            record.call.function(record, event);
            // After the call: inside the last record's callback the count is still above 0, so a
            // `tick` there leaves the fast path and halts in `begin`.
            if (!event.flags.more) dispatch.callbacks_outstanding -= 1;
        }
        assert(kept <= events.len);
        // Every event with a record called its record, and `kept` are the others. A batch that
        // called no record leaves the heartbeat as it is: `running` is null since `begin`.
        const called = events.len - kept;
        if (called != 0) heartbeat.leave(called);
        return kept;
    }
};

const testing = std.testing;

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
    const kept = dispatch.end(&heartbeat, &events);
    try testing.expectEqual(@as(u32, 2), kept);
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectEqual(@as(u64, 2), events[1].user_data);
    try testing.expectEqual(@as(u32, 2), counting.events);
    try testing.expectEqual(@as(i32, 6), counting.last_result);
    // The `more` event kept the operation in flight, and the final one ended it.
    try testing.expectEqual(@as(u32, 0), dispatch.callbacks_outstanding);
    try testing.expect(!dispatch.ticking);
}

const Polling = struct {
    calls: u32 = 0,
    poller: Poller = .init(Polling, "poller", polled),
    worked: bool = false,

    fn polled(polling: *Polling) bool {
        polling.calls += 1;
        return polling.worked;
    }
};

test "each poller runs once a tick, and one that did work makes the tick wait 0 ns" {
    var dispatch: Dispatch = .empty;
    var heartbeat: Heartbeat = .init(null);
    var idle: Polling = .{};
    var busy: Polling = .{ .worked = true };
    try dispatch.add_poller(&idle.poller);
    try testing.expectEqual(@as(u64, 9), dispatch.begin(&heartbeat, 9));
    _ = dispatch.end(&heartbeat, &.{});
    try dispatch.add_poller(&busy.poller);
    try testing.expectEqual(@as(u64, 0), dispatch.begin(&heartbeat, 9));
    _ = dispatch.end(&heartbeat, &.{});
    try testing.expectEqual(@as(u32, 2), idle.calls);
    try testing.expectEqual(@as(u32, 1), busy.calls);
    dispatch.remove_poller(&busy.poller);
    try testing.expectEqual(@as(u64, 9), dispatch.begin(&heartbeat, 9));
    _ = dispatch.end(&heartbeat, &.{});
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
    _ = dispatch.end(&heartbeat, &events);
    try testing.expectEqualSlices(u8, "rrt", order.marks[0..order.len]);
    try testing.expectEqual(@as(u32, 0), dispatch.tasks.count);
    try testing.expect(dispatch.idle());
}

/// A poller that queues `queued` the first time it runs.
const Queueing = struct {
    poller: Poller = .init(Queueing, "poller", polled),
    dispatch: *Dispatch,
    queued: ?*Task,

    fn polled(queueing: *Queueing) bool {
        const task = queueing.queued orelse return false;
        queueing.queued = null;
        queueing.dispatch.schedule(task) catch unreachable;
        return false;
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
    var heartbeat: Heartbeat = .init(null);
    var again: Again = .{ .dispatch = &dispatch, .again = 2 };
    try dispatch.schedule(&again.task);
    for (0..2) |_| {
        _ = dispatch.begin(&heartbeat, 9);
        _ = dispatch.end(&heartbeat, &.{});
        // The run took one task and the task queued itself: one callback is still outstanding.
        try testing.expectEqual(@as(u32, 1), dispatch.callbacks_outstanding);
        try testing.expect(!dispatch.idle());
    }
    _ = dispatch.begin(&heartbeat, 9);
    _ = dispatch.end(&heartbeat, &.{});
    try testing.expectEqual(@as(u32, 0), dispatch.callbacks_outstanding);
    try testing.expect(dispatch.idle());
}

test "discarding the queue clears the outstanding callbacks, so the next tick skips the dispatch" {
    var dispatch: Dispatch = .empty;
    var order: Order = .{};
    var noting: Noting = .{ .order = &order };
    try dispatch.schedule(&noting.task);
    try testing.expect(!dispatch.idle());
    try testing.expectEqual(@as(u32, 1), dispatch.discard_tasks());
    try testing.expectEqual(@as(u32, 0), dispatch.callbacks_outstanding);
    try testing.expect(dispatch.idle());
    try testing.expectEqual(@as(u32, 0), order.len);
}

test "a queued task keeps begin from blocking, and a poller's task runs in the same end" {
    var dispatch: Dispatch = .empty;
    var heartbeat: Heartbeat = .init(null);
    var order: Order = .{};
    var noting: Noting = .{ .order = &order };
    var queueing: Queueing = .{ .dispatch = &dispatch, .queued = &noting.task };
    try dispatch.add_poller(&queueing.poller);
    // The poller queues the task in begin, which then may not block.
    try testing.expectEqual(@as(u64, 0), dispatch.begin(&heartbeat, 9));
    try testing.expect(!dispatch.idle());
    _ = dispatch.end(&heartbeat, &.{});
    try testing.expectEqualSlices(u8, "t", order.marks[0..order.len]);
    // Nothing is queued now, so the next begin may block for the whole wait.
    try testing.expectEqual(@as(u64, 9), dispatch.begin(&heartbeat, 9));
    _ = dispatch.end(&heartbeat, &.{});
    dispatch.remove_poller(&queueing.poller);
    try testing.expect(dispatch.idle());

    // A task the program queued between ticks makes the dispatch busy until a tick runs it.
    try dispatch.schedule(&noting.task);
    try testing.expect(!dispatch.idle());
    try testing.expectEqual(@as(u64, 0), dispatch.begin(&heartbeat, 9));
    _ = dispatch.end(&heartbeat, &.{});
    try testing.expect(dispatch.idle());
    try testing.expectEqualSlices(u8, "tt", order.marks[0..order.len]);
}
