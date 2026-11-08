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
const scheduling = @import("../scheduling/scheduling.zig");
const scheduling_run = @import("../scheduling/scheduling_run.zig");
const Groups = @import("../scheduling/scheduling_groups.zig").Groups;
const SchedulingGroup = scheduling.SchedulingGroup;
const Task = tasks_module.Task;
const Tasks = tasks_module.Tasks;
const ScheduleError = tasks_module.ScheduleError;

const callbacks = @import("dispatch_callbacks.zig");
/// What an operation names to have the tick call its function: `dispatch_callbacks.zig`.
pub const Completion = callbacks.Completion;
/// What a library adds to have the loop call its function in each tick: `dispatch_callbacks.zig`.
pub const Poller = callbacks.Poller;
/// How long a tick may wait, which a poller returns: `dispatch_callbacks.zig`.
pub const WaitLimit = callbacks.WaitLimit;
/// The name of the callback at `field` of `Parent`: `dispatch_callbacks.zig`.
pub const name_of = callbacks.name_of;

comptime {
    // The heartbeat is not here: it is on a line of its own, so `Dispatch` keeps the size and the
    // alignment it had before decision 28. `until_ns` adds 8 B (decision 29). Decision 30 merges
    // two flags into `phase`, and `groups_ready` takes the freed byte and the padding.
    assert(@sizeOf(Dispatch) == 104);
    assert(@alignOf(Dispatch) == 8);
}

pub const AddPollerError = error{PollersFull};

/// The calls every backend's `Loop` exports: `dispatch_calls.zig`.
pub const Calls = @import("dispatch_calls.zig").Calls;

/// Where a tick is (decision 30). One byte, where decision 26 held two flags.
pub const Phase = enum(u8) {
    /// Between ticks.
    idle,
    /// `begin` calls the pollers: a poller that adds or removes a poller halts, because the loop
    /// is walking the table.
    polling,
    /// From the end of the pollers to the end of `end`, decision 27's run of `.default` included.
    /// A callback may add or remove a poller. That run stores no phase of its own: `tasks.left`
    /// is above 0 only inside a task's call, which is what `charge_task` checks.
    records,
    /// The run of the groups by DRR (decision 30).
    group_tasks,
};

/// The state of the dispatch, which `Tables` holds. Size 104 B, alignment 8.
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
    /// Not `.idle` from `begin` to `end`: a callback or a poller that calls `tick` halts.
    phase: Phase,
    /// The ready mask of groups 1 to 15: bit `g` is set while group `g` holds a task (decision 30).
    /// Bit 0 stays clear: `tasks.count` says whether `.default` holds one. While it is 0, `end`
    /// runs decision 27's run and touches no line of `Groups`.
    groups_ready: u16,
    /// The task queue of `.default` (decision 27).
    tasks: Tasks,
    /// The least limit the pollers answered in the last `begin` (decision 29). A wake, and an
    /// `end` that called a callback, store `.now` while a poller is in the table. It is `.none`
    /// while the table is empty, so a tick on the fast path never reads a stale limit.
    until_ns: WaitLimit,

    pub const empty: Dispatch = .{
        .pollers = undefined,
        .poller_count = 0,
        .callbacks_outstanding = 0,
        .phase = .idle,
        .groups_ready = 0,
        .tasks = .empty,
        .until_ns = .none,
    };

    pub fn add_poller(dispatch: *Dispatch, poller: *Poller) AddPollerError!void {
        assert(dispatch.phase != .polling);
        assert(dispatch.poller_count <= constants.pollers_max);
        for (dispatch.pollers[0..dispatch.poller_count]) |added| assert(added != poller);
        if (dispatch.poller_count == constants.pollers_max) return error.PollersFull;
        dispatch.pollers[dispatch.poller_count] = poller;
        dispatch.poller_count += 1;
    }

    /// Removes `poller`, which must have been added. The pollers after it keep their order. A
    /// removal that empties the table writes `.none` in `until_ns` (decision 29).
    pub fn remove_poller(dispatch: *Dispatch, poller: *Poller) void {
        assert(dispatch.phase != .polling);
        const count = dispatch.poller_count;
        const found = std.mem.indexOfScalar(*Poller, dispatch.pollers[0..count], poller);
        assert(found != null);
        const index = found orelse return;
        const after = dispatch.pollers[index + 1 .. count];
        std.mem.copyForwards(*Poller, dispatch.pollers[index .. count - 1], after);
        dispatch.poller_count = count - 1;
        if (dispatch.poller_count == 0) dispatch.until_ns = .none;
    }

    /// A `Message.wake` that a drain took (decision 29): the next tick must not block before its
    /// pollers run. It stores `.now` only while a poller is in the table, because only then does a
    /// tick run `begin`, which writes the limit again.
    pub fn note_wake(dispatch: *Dispatch) void {
        if (dispatch.poller_count != 0) dispatch.until_ns = .now;
    }

    /// The limit a host reads before it sleeps (decision 29): `.now` while a task is queued, and
    /// `until_ns` otherwise. Halts inside a tick (class B): only the program calls it, between
    /// ticks.
    pub fn limit_between_ticks(dispatch: *const Dispatch) WaitLimit {
        assert(dispatch.phase == .idle);
        if (dispatch.tasks.count != 0 or dispatch.groups_ready != 0) return .now;
        return dispatch.until_ns;
    }

    /// Halts inside a tick, or when a poller is still added or a task is still queued: what
    /// `deinit` checks, because each is memory the library owns and may free once the loop has
    /// ended (decision 8, class C). A record, a poller or a task that ends the loop halts at once
    /// (decision 28).
    pub fn assert_empty(dispatch: *const Dispatch) void {
        assert(dispatch.phase == .idle);
        assert(dispatch.poller_count == 0);
        assert(dispatch.tasks.count == 0);
        assert(dispatch.groups_ready == 0);
    }

    /// Queues `task` in `.default`, which the `end` of a tick calls once (decision 27).
    pub fn schedule(dispatch: *Dispatch, task: *Task) ScheduleError!void {
        try dispatch.tasks.push(task, constants.tasks_queued_max);
        dispatch.callbacks_outstanding += 1;
    }

    /// Queues `task` in `group` (decision 30). Returns `TasksFull` when that group holds
    /// `tasks_queued_max` tasks. `.default` is `schedule`, and touches no line of `groups`.
    pub fn schedule_in(
        dispatch: *Dispatch,
        groups: *Groups,
        group: SchedulingGroup,
        task: *Task,
    ) ScheduleError!void {
        if (group == .default) return dispatch.schedule(task);
        groups.assert_reserved(group);
        // The end mark makes every queued task's `next` not null, so this one compare finds a task
        // queued in any group of the loop (decision 8, class A).
        assert_class_a(!dispatch.tasks.holds(task));
        try groups.push(group, task, constants.tasks_queued_max);
        dispatch.groups_ready |= @as(u16, 1) << @intCast(@intFromEnum(group));
        dispatch.callbacks_outstanding += 1;
    }

    /// Queues the task of a cross-core call in `group` with the limit `task_queue_length_max`, so a
    /// group that the program filled takes it (decision 32, ruling item 11). The calls bound their
    /// tasks at `call_tasks_max`, so a full queue halts (class B). The drain queues it inside a
    /// tick, and `Tables.wait_bound` keeps that tick from blocking before its `end`.
    pub fn schedule_call(dispatch: *Dispatch, groups: *Groups, group: SchedulingGroup, task: *Task) void {
        const limit = constants.task_queue_length_max;
        if (group == .default) {
            dispatch.tasks.push(task, limit) catch unreachable;
        } else {
            groups.assert_reserved(group);
            // The end mark makes every queued task's `next` not null (decision 8, class A).
            assert_class_a(!dispatch.tasks.holds(task));
            groups.push(group, task, limit) catch unreachable;
            dispatch.groups_ready |= @as(u16, 1) << @intCast(@intFromEnum(group));
        }
        dispatch.callbacks_outstanding += 1;
    }

    /// Adds `units` to the cost of the task that runs now (decision 30). Halts outside a task's
    /// call, and on a charge that no task may make: every task costs at least 1, so one charge is
    /// below `task_charge_max` (class B). On the path with one group it changes no deficit: no
    /// other group waits.
    pub fn charge_task(dispatch: *const Dispatch, groups: *Groups, units: u16) void {
        assert(dispatch.tasks.left != 0);
        assert(units < constants.task_charge_max);
        if (dispatch.phase == .group_tasks) scheduling_run.charge(groups, units);
    }

    /// `tasks_per_tick_max` less the tasks the run started, and on the groups path at most the
    /// whole units left in the group's visit (decision 30). 0 outside a run.
    pub fn task_budget_left(dispatch: *const Dispatch, groups: *const Groups) u32 {
        assert(dispatch.tasks.left <= constants.tasks_per_tick_max);
        if (dispatch.phase != .group_tasks) return dispatch.tasks.left -| 1;
        return scheduling_run.budget_left(groups, &dispatch.tasks, dispatch.groups_ready);
    }

    /// The tasks queued in every group.
    pub fn tasks_queued(dispatch: *const Dispatch, groups: *const Groups) u32 {
        assert(dispatch.tasks.count <= constants.tasks_queued_max);
        if (dispatch.groups_ready == 0) return dispatch.tasks.count;
        return dispatch.tasks.count + groups.queued();
    }

    /// Unlinks every queued task of every group without a call, and resets every deficit, the
    /// cursor and the open visit. Halts inside a tick: only the program calls it, between ticks,
    /// after `drain` returned `TasksStillQueued`.
    pub fn discard_tasks(dispatch: *Dispatch, groups: *Groups) u32 {
        assert(dispatch.phase == .idle);
        const discarded = dispatch.tasks.discard() + groups.discard();
        dispatch.groups_ready = 0;
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

    /// The start of a tick: halts inside another tick, then calls every poller once and stores the
    /// least of their limits in `until_ns` (decision 29). Returns the wait the tick may block for:
    /// 0 when that limit is `.now` or a task is queued, and `wait_ns` otherwise. The tick bounds
    /// that wait at `until_ns` later, in `Tables.wait_bound`. A task queued now runs in this tick's
    /// `end`, so the tick must not sleep first. `heartbeat` is the loop's (decision 28): it names
    /// each poller while it runs.
    pub fn begin(dispatch: *Dispatch, heartbeat: *Heartbeat, wait_ns: u64) u64 {
        assert_class_a(dispatch.phase == .idle);
        dispatch.phase = .polling;
        var least: u64 = @intFromEnum(WaitLimit.none);
        // A poller cannot add or remove one, so the count read here is the count it calls.
        const polled = dispatch.poller_count;
        for (dispatch.pollers[0..polled]) |poller| {
            heartbeat.enter(&poller.call.name);
            least = @min(least, @intFromEnum(poller.call.function(poller)));
        }
        // A `begin` with no poller leaves the heartbeat as it is: `running` is null already.
        if (polled != 0) heartbeat.leave_polling(polled);
        dispatch.phase = .records;
        dispatch.until_ns = @enumFromInt(least);
        const queued = dispatch.tasks.count | dispatch.groups_ready;
        return if (dispatch.until_ns == .now or queued != 0) 0 else wait_ns;
    }

    /// The end of a tick: calls the record of each event that has one, and moves the other events
    /// to the front of `events`, in order. Then it runs the tasks queued so far, so a task that a
    /// record or a poller queued runs in this tick (decision 27). Returns how many events are at
    /// the front. `phase` stays not `.idle` while the tasks run, so a task that ticks halts.
    /// `heartbeat` is the loop's, as in `begin`. While no group other than `.default` holds a task,
    /// it runs decision 27's run and touches no line of `groups` (decision 30).
    pub fn end(dispatch: *Dispatch, heartbeat: *Heartbeat, groups: *Groups, events: []Event) u32 {
        assert_class_a(dispatch.phase == .records);
        defer dispatch.phase = .idle;
        const kept = dispatch.call_records(heartbeat, events);
        // Each subtraction's overflow check halts on a callback the count never saw. While a task
        // is queued, a stray final event lowers the count without an underflow, and the halt comes
        // at the latest when the queue empties. `run` is called first and its count subtracted
        // after: a task that schedules a task adds to the count during the run, and a compound
        // `-=` would read the count before the call and lose that addition.
        const ran = if (dispatch.groups_ready == 0)
            dispatch.tasks.run(heartbeat)
        else
            dispatch.run_groups(groups, heartbeat);
        dispatch.callbacks_outstanding -= ran;
        // A record or a task can change what a poller would answer, so a host that reads the limit
        // now does not sleep (decision 29). The next `begin` writes `until_ns` again before any
        // `wait_bound` reads it, so only `wait_limit` reads this store.
        const called = kept != events.len or ran != 0;
        if (called and dispatch.poller_count != 0) dispatch.until_ns = .now;
        return kept;
    }

    /// Ends a tick that failed, so the next tick may begin.
    pub fn abandon(dispatch: *Dispatch) void {
        assert(dispatch.phase != .idle);
        dispatch.phase = .idle;
    }

    /// The run of the groups by DRR, in a tick where a group other than `.default` holds a task
    /// (decision 30). It checks the shape of each ready lane first (class B, once in each run).
    fn run_groups(dispatch: *Dispatch, groups: *Groups, heartbeat: *Heartbeat) u32 {
        dispatch.phase = .group_tasks;
        const outstanding = dispatch.callbacks_outstanding;
        groups.assert_ready_shape(&dispatch.tasks, dispatch.groups_ready, outstanding);
        return scheduling_run.run(groups, &dispatch.tasks, &dispatch.groups_ready, heartbeat);
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
