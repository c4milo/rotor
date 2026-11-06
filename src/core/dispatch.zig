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
const assert_class_a = @import("assertion_class.zig").assert_class_a;
const constants = @import("constants.zig");
const Event = @import("event.zig").Event;
const tasks_module = @import("tasks.zig");

const Task = tasks_module.Task;
const Tasks = tasks_module.Tasks;
const ScheduleError = tasks_module.ScheduleError;

/// What an operation names to have the tick call `callback` for each of its events. The library
/// puts it inside its own struct. `init` writes the callback that finds that struct again.
pub const Completion = struct {
    callback: *const fn (completion: *Completion, event: Event) void,

    /// A record at `field` of `Parent` that calls `handler` with its parent for each event. The
    /// compiler checks the field, the parent and the handler, and the callback it makes costs the
    /// same indirect call as one written by hand.
    pub fn init(
        comptime Parent: type,
        comptime field: []const u8,
        comptime handler: fn (parent: *Parent, event: Event) void,
    ) Completion {
        comptime assert(@FieldType(Parent, field) == Completion);
        return .{ .callback = struct {
            fn call(completion: *Completion, event: Event) void {
                const parent: *Parent = @alignCast(@fieldParentPtr(field, completion));
                handler(parent, event);
            }
        }.call };
    }
};

/// What a library adds to have the loop call `poll` once in each tick, before the tick waits.
/// `poll` returns true when the tick must not block, for example because work is left: the tick
/// then waits 0 ns. True means nothing else.
pub const Poller = struct {
    poll: *const fn (poller: *Poller) bool,

    /// A poller at `field` of `Parent` that calls `handler` with its parent.
    pub fn init(
        comptime Parent: type,
        comptime field: []const u8,
        comptime handler: fn (parent: *Parent) bool,
    ) Poller {
        comptime assert(@FieldType(Parent, field) == Poller);
        return .{ .poll = struct {
            fn call(poller: *Poller) bool {
                const parent: *Parent = @alignCast(@fieldParentPtr(field, poller));
                return handler(parent);
            }
        }.call };
    }
};

pub const AddPollerError = error{PollersFull};

/// The state of the dispatch, which `Tables` holds.
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

    /// Halts when a poller is still added or a task is still queued: what `deinit` checks, because
    /// each is memory the library owns and may free once the loop has ended (decision 8, class C).
    pub fn assert_empty(dispatch: *const Dispatch) void {
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
    pub fn begin(dispatch: *Dispatch, wait_ns: u64) u64 {
        assert_class_a(!dispatch.ticking);
        dispatch.ticking = true;
        dispatch.polling = true;
        var worked = false;
        for (dispatch.pollers[0..dispatch.poller_count]) |poller| {
            if (poller.poll(poller)) worked = true;
        }
        dispatch.polling = false;
        return if (worked or dispatch.tasks.count != 0) 0 else wait_ns;
    }

    /// The end of a tick: calls the record of each event that has one, and moves the other events
    /// to the front of `events`, in order. Then it runs the tasks queued so far, so a task that a
    /// record or a poller queued runs in this tick (decision 27). Returns how many events are at
    /// the front. `ticking` stays set while the tasks run, so a task that ticks halts.
    pub fn end(dispatch: *Dispatch, events: []Event) u32 {
        assert_class_a(dispatch.ticking);
        defer dispatch.ticking = false;
        const kept = dispatch.call_records(events);
        // Each subtraction's overflow check halts on a callback the count never saw. While a task
        // is queued, a stray final event lowers the count without an underflow, and the halt comes
        // at the latest when the queue empties. `run` is called first and its count subtracted
        // after: a task that schedules a task adds to the count during the run, and a compound
        // `-=` would read the count before the call and lose that addition.
        const ran = dispatch.tasks.run();
        dispatch.callbacks_outstanding -= ran;
        return kept;
    }

    /// Ends a tick that failed, so the next tick may begin.
    pub fn abandon(dispatch: *Dispatch) void {
        assert(dispatch.ticking);
        dispatch.ticking = false;
    }

    fn call_records(dispatch: *Dispatch, events: []Event) u32 {
        var kept: u32 = 0;
        for (events) |event| {
            if (!event.flags.dispatched) {
                events[kept] = event;
                kept += 1;
                continue;
            }
            const record: *Completion = @ptrFromInt(event.user_data);
            record.callback(record, event);
            // After the call: inside the last record's callback the count is still above 0, so a
            // `tick` there leaves the fast path and halts in `begin`.
            if (!event.flags.more) dispatch.callbacks_outstanding -= 1;
        }
        assert(kept <= events.len);
        return kept;
    }
};

/// The calls of decisions 26 and 27 that every backend's `Loop` exports, written once. `Loop` has a
/// `tables: Tables` field. Each call checks that the loop's own thread makes it (decision 8,
/// class B).
pub fn Calls(comptime Loop: type) type {
    return struct {
        /// Adds `poller`, which the loop calls once in each tick (decision 26).
        pub fn add_poller(loop: *Loop, poller: *Poller) AddPollerError!void {
            loop.tables.assert_owner();
            return loop.tables.dispatch.add_poller(poller);
        }

        /// Removes `poller`, which must have been added.
        pub fn remove_poller(loop: *Loop, poller: *Poller) void {
            loop.tables.assert_owner();
            loop.tables.dispatch.remove_poller(poller);
        }

        /// Asks the loop to call `task.run` once, later (decision 27). The order is the order of
        /// the calls. A task queued by the program between ticks, by a poller or by a record runs
        /// in the `end` of the next tick to reach it; a task queued by a task runs one tick later.
        /// A task belongs to this loop while it is queued: do not schedule it on another loop.
        pub fn schedule(loop: *Loop, task: *Task) ScheduleError!void {
            loop.tables.assert_owner();
            return loop.tables.dispatch.schedule(task);
        }

        /// True while `task` is queued on this loop.
        pub fn is_scheduled(loop: *const Loop, task: *const Task) bool {
            loop.tables.assert_owner();
            return loop.tables.dispatch.tasks.holds(task);
        }

        /// The tasks queued now. A host that sleeps in its own wait reads it before it sleeps
        /// (decision 23), and a program reads it before `deinit`.
        pub fn tasks_queued(loop: *const Loop) u32 {
            loop.tables.assert_owner();
            return loop.tables.dispatch.tasks.count;
        }

        /// `tasks_per_tick_max` less the tasks the current run started, the task that reads it
        /// included, and 0 outside a run. A long task that splits its work does at most this many
        /// slices plus one in one call, then schedules itself again. It counts, and never reads the
        /// clock.
        pub fn task_budget_left(loop: *const Loop) u32 {
            loop.tables.assert_owner();
            return loop.tables.dispatch.tasks.left;
        }

        /// Unlinks every queued task without a call, and returns the count (decision 27,
        /// "Shutdown"). Only the program calls it, between ticks, after `drain` returned
        /// `TasksStillQueued`. Halts inside a tick.
        pub fn discard_tasks(loop: *Loop) u32 {
            loop.tables.assert_owner();
            return loop.tables.dispatch.discard_tasks();
        }
    };
}

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
    var counting: Counting = .{};
    dispatch.note_submitted(1);
    var events = [_]Event{
        .{ .user_data = 1, .result = 0, .flags = .{} },
        dispatched_event(&counting.completion, 5, true),
        .{ .user_data = 2, .result = 0, .flags = .{} },
        dispatched_event(&counting.completion, 6, false),
    };
    try testing.expectEqual(@as(u64, 7), dispatch.begin(7));
    const kept = dispatch.end(&events);
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
    var idle: Polling = .{};
    var busy: Polling = .{ .worked = true };
    try dispatch.add_poller(&idle.poller);
    try testing.expectEqual(@as(u64, 9), dispatch.begin(9));
    _ = dispatch.end(&.{});
    try dispatch.add_poller(&busy.poller);
    try testing.expectEqual(@as(u64, 0), dispatch.begin(9));
    _ = dispatch.end(&.{});
    try testing.expectEqual(@as(u32, 2), idle.calls);
    try testing.expectEqual(@as(u32, 1), busy.calls);
    dispatch.remove_poller(&busy.poller);
    try testing.expectEqual(@as(u64, 9), dispatch.begin(9));
    _ = dispatch.end(&.{});
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
    var order: Order = .{};
    var noting: Noting = .{ .order = &order };
    var first: Scheduling = .{ .dispatch = &dispatch, .queued = &noting.task, .order = &order };
    var second: Recording = .{ .order = &order };
    dispatch.note_submitted(2);
    var events = [_]Event{
        dispatched_event(&first.completion, 0, false),
        dispatched_event(&second.completion, 0, false),
    };
    _ = dispatch.begin(5);
    _ = dispatch.end(&events);
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
    var again: Again = .{ .dispatch = &dispatch, .again = 2 };
    try dispatch.schedule(&again.task);
    for (0..2) |_| {
        _ = dispatch.begin(9);
        _ = dispatch.end(&.{});
        // The run took one task and the task queued itself: one callback is still outstanding.
        try testing.expectEqual(@as(u32, 1), dispatch.callbacks_outstanding);
        try testing.expect(!dispatch.idle());
    }
    _ = dispatch.begin(9);
    _ = dispatch.end(&.{});
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
    var order: Order = .{};
    var noting: Noting = .{ .order = &order };
    var queueing: Queueing = .{ .dispatch = &dispatch, .queued = &noting.task };
    try dispatch.add_poller(&queueing.poller);
    // The poller queues the task in begin, which then may not block.
    try testing.expectEqual(@as(u64, 0), dispatch.begin(9));
    try testing.expect(!dispatch.idle());
    _ = dispatch.end(&.{});
    try testing.expectEqualSlices(u8, "t", order.marks[0..order.len]);
    // Nothing is queued now, so the next begin may block for the whole wait.
    try testing.expectEqual(@as(u64, 9), dispatch.begin(9));
    _ = dispatch.end(&.{});
    dispatch.remove_poller(&queueing.poller);
    try testing.expect(dispatch.idle());

    // A task the program queued between ticks makes the dispatch busy until a tick runs it.
    try dispatch.schedule(&noting.task);
    try testing.expect(!dispatch.idle());
    try testing.expectEqual(@as(u64, 0), dispatch.begin(9));
    _ = dispatch.end(&.{});
    try testing.expect(dispatch.idle());
    try testing.expectEqualSlices(u8, "tt", order.marks[0..order.len]);
}
