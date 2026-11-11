//! The calls of decisions 26 to 30 on the reactor's state and its loop: the count of records at
//! submit, the tasks and their scheduling groups, and the host's wait limit. `Dispatch` declares
//! each one, so a reactor writes `reactor.dispatch.schedule(&reactor.loop, task)`. Each call that a
//! program or a library makes checks that the loop's own thread makes it (decision 8, class B).
//! Split from `dispatch.zig` for the 500-line limit.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const assert_class_a = core.assertion_class.assert_class_a;
const constants = @import("../constants.zig");
const dispatch_module = @import("dispatch.zig");
const scheduling = @import("../scheduling/scheduling.zig");
const scheduling_run = @import("../scheduling/scheduling_run.zig");
const tasks_module = @import("../tasks.zig");
const reactor_module = @import("../reactor.zig");

const Dispatch = dispatch_module.Dispatch;
const Handle = core.Handle;
const Operation = core.Operation;
const ReserveSchedulingGroupError = scheduling.ReserveSchedulingGroupError;
const ScheduleError = tasks_module.ScheduleError;
const SchedulingGroup = core.SchedulingGroup;
const Task = reactor_module.Task;
const WaitLimit = core.WaitLimit;

/// The loop's `submit`, then the count of the operations it took that named a record (decision
/// 26): each raises `outstanding` until its final event. A plain loop counts nothing, so a reactor
/// counts here, after the core took the batch (decision 33, open question 11, first form).
pub fn submit(dispatch: *Dispatch, loop: anytype, operations: []const Operation, handles: []Handle) u32 {
    _ = dispatch;
    const taken = loop.submit(operations, handles);
    // Summed here and added once after the loop, so the count stays in a register.
    var records: u32 = 0;
    for (operations[0..taken]) |*operation| records += @intFromBool(operation.dispatched);
    loop.outstanding().* += records;
    return taken;
}

/// Asks the reactor to call `task.run` once, later (decision 27). The order is the order of the
/// calls. A task queued by the program between ticks, by a poller or by a record runs in the `end`
/// of the next tick to reach it; a task queued by a task runs one tick later. A task belongs to
/// this reactor while it is queued: do not schedule it on another.
pub fn schedule(dispatch: *Dispatch, loop: anytype, task: *Task) ScheduleError!void {
    loop.assert_owner();
    try dispatch.tasks.push(task, constants.tasks_queued_max);
    loop.outstanding().* += 1;
}

/// Queues `task` in `group` (decision 30). Returns `TasksFull` when that group holds
/// `tasks_queued_max` tasks. `.default` is `schedule`, and touches no line of the groups. Halts on
/// an id this reactor did not reserve.
pub fn schedule_in(dispatch: *Dispatch, loop: anytype, group: SchedulingGroup, task: *Task) ScheduleError!void {
    // The owner check comes before the branch, as at v0.10.0. `schedule` checks again, and the
    // compiler merges the two checks. After the branch, the check took one more instruction on
    // x86-64: a load of the owner before the branch, and a compare in each branch.
    loop.assert_owner();
    if (group == .default) return schedule(dispatch, loop, task);
    const groups = dispatch.groups;
    groups.assert_reserved(group);
    // The end mark makes every queued task's `next` not null, so this one compare finds a task
    // queued in any group of the reactor (decision 8, class A).
    assert_class_a(!dispatch.tasks.holds(task));
    try groups.push(group, task, constants.tasks_queued_max);
    dispatch.groups_ready |= @as(u16, 1) << @intCast(@intFromEnum(group));
    loop.outstanding().* += 1;
}

/// Queues the task of a cross-core call in `group` with the limit `task_queue_length_max`, so a
/// group that the program filled takes it (decision 32, ruling item 11). The calls bound their
/// tasks at `call_tasks_max`, so a full queue halts (class B). The drain queues it inside a tick,
/// and tells the tick, which then does not block before the next tick runs it (`Inbox.handed`).
pub fn schedule_call(dispatch: *Dispatch, loop: anytype, group: SchedulingGroup, task: *Task) void {
    const limit = constants.task_queue_length_max;
    if (group == .default) {
        dispatch.tasks.push(task, limit) catch unreachable;
    } else {
        const groups = dispatch.groups;
        groups.assert_reserved(group);
        // The end mark makes every queued task's `next` not null (decision 8, class A).
        assert_class_a(!dispatch.tasks.holds(task));
        groups.push(group, task, limit) catch unreachable;
        dispatch.groups_ready |= @as(u16, 1) << @intCast(@intFromEnum(group));
    }
    loop.outstanding().* += 1;
}

/// Inside a task's call only: adds `units`, less than `task_charge_max`, to the cost of the task
/// that runs now (decision 30). Halts outside a task's call, and on a charge that no task may make:
/// every task costs at least 1, so one charge is below `task_charge_max` (class B). On the path with
/// one group it changes no deficit: no other group waits.
pub fn charge_task(dispatch: *Dispatch, loop: anytype, units: u16) void {
    loop.assert_owner();
    assert(dispatch.tasks.left != 0);
    assert(units < constants.task_charge_max);
    if (dispatch.phase == .group_tasks) scheduling_run.charge(dispatch.groups, units);
}

/// `tasks_per_tick_max` less the tasks the run started, and on the groups path at most the whole
/// units left in the group's visit (decision 30). 0 outside a run.
pub fn task_budget_left(dispatch: *const Dispatch, loop: anytype) u32 {
    loop.assert_owner();
    assert(dispatch.tasks.left <= constants.tasks_per_tick_max);
    if (dispatch.phase != .group_tasks) return dispatch.tasks.left -| 1;
    return scheduling_run.budget_left(dispatch.groups, &dispatch.tasks, dispatch.groups_ready);
}

/// The tasks queued in every group. The queue of `.default` also holds the tasks of the calls
/// (decision 32), so its bound is `task_queue_length_max`. A host that sleeps in its own wait reads
/// it before it sleeps (decision 23), and a program reads it before `deinit`.
pub fn tasks_queued(dispatch: *const Dispatch, loop: anytype) u32 {
    loop.assert_owner();
    assert(dispatch.tasks.count <= constants.task_queue_length_max);
    if (dispatch.groups_ready == 0) return dispatch.tasks.count;
    return dispatch.tasks.count + dispatch.groups.queued();
}

/// True while `task` is queued in a group of this reactor.
pub fn is_scheduled(dispatch: *const Dispatch, loop: anytype, task: *const Task) bool {
    loop.assert_owner();
    return dispatch.tasks.holds(task);
}

/// Unlinks every queued task of every group without a call, resets every deficit, the cursor and
/// the open visit, and returns the count (decision 27, "Shutdown"). Halts inside a tick: only the
/// program calls it, between ticks, after `drain` returned `TasksStillQueued`.
pub fn discard_tasks(dispatch: *Dispatch, loop: anytype) u32 {
    loop.assert_owner();
    assert(dispatch.phase == .idle);
    const discarded = dispatch.tasks.discard() + dispatch.groups.discard();
    dispatch.groups_ready = 0;
    loop.outstanding().* -= discarded;
    return discarded;
}

/// Reserves the lowest free group id with `shares`, in 1 to `scheduling_shares_max` (decision 30).
/// The named groups hold ids 1 to n from init, so the first reserve returns n + 1. The id belongs
/// to this reactor only, until `deinit`: no call gives it back. `SchedulingGroupsFull` when every
/// id is reserved. Program only, between ticks: inside a tick it halts (class C).
pub fn reserve_scheduling_group(
    dispatch: *Dispatch,
    loop: anytype,
    shares: u16,
) ReserveSchedulingGroupError!SchedulingGroup {
    loop.assert_owner();
    assert(dispatch.phase == .idle);
    return dispatch.groups.reserve(shares);
}

/// Sets the shares of `.default` or of a reserved group of this reactor, in 1 to
/// `scheduling_shares_max` (decision 30). It counts from the group's next visit. The shares of a
/// named group change on this reactor only. Program only.
pub fn set_scheduling_group_shares(dispatch: *Dispatch, loop: anytype, group: SchedulingGroup, shares: u16) void {
    loop.assert_owner();
    dispatch.groups.set_shares(group, shares);
}

/// The host's last call before it sleeps in its own wait (decision 29): `.now` while a task is
/// queued, and the loop's `wait_limit` otherwise. It reads no clock and changes no state. Program
/// only, and it halts inside a tick (class B).
pub fn wait_limit(dispatch: *const Dispatch, loop: anytype) WaitLimit {
    loop.assert_owner();
    assert(dispatch.phase == .idle);
    if (dispatch.tasks.count != 0 or dispatch.groups_ready != 0) return .now;
    return loop.wait_limit();
}

/// The part of a reactor's `deinit` that decision 32 adds, which a halt scenario reaches through
/// its parameters: no station that serves, and no station that the groups count, which a later
/// reactor of the id would find (class C). The loop's `deinit` checks that no call is out or held:
/// each counts in `outstanding`.
pub fn assert_calls_ended(dispatch: *const Dispatch) void {
    assert(dispatch.groups.serving == 0);
    assert(dispatch.groups.stations == 0);
}
