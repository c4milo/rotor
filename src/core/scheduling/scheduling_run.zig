//! The rule of decision 30: deficit round robin (DRR) in cost units, over the groups of one loop.
//! A task costs the units of its static `Call`, plus the units it adds with `charge_task`. Shares
//! are in hundredths of a unit, so equal groups at the default shares take turns task by task.
//!
//! One run does these steps (decision 30, "The rule"):
//!
//! 1. Snapshot: each ready group may start the tasks it holds now, and none that a task queues.
//! 2. Visit: from the cursor, take the next group that may start a task. A visit that is not open
//!    adds the group's shares to its deficit.
//! 3. Start: while the deficit is above 0, the group may start a task and the tick has starts
//!    left, pop the head, subtract its cost, and call it. A deficit below 0 is debt.
//! 4. Close: drop unused credit, keep debt, and move the cursor on.
//! 5. Bulk credit: after one full pass of visits that started no task, add the credit of the
//!    passes that would start none, in one pass of arithmetic.
//! 6. Stop after `tasks_per_tick_max` starts, or when no group may start a task.
//!
//! Ties break by group index, and the order is a function of the calls alone: nothing here reads
//! a clock or decides from an address's value (non-negotiable 2).
const std = @import("std");
const assert = std.debug.assert;
const assert_class_a = @import("../assertion_class.zig").assert_class_a;
const constants = @import("../constants.zig");
const groups_module = @import("scheduling_groups.zig");
const tasks_module = @import("../tasks.zig");

const Groups = groups_module.Groups;
const Heartbeat = @import("../stall.zig").Heartbeat;
const Tasks = tasks_module.Tasks;
const Task = tasks_module.Task;

/// The credit of one unit, as the deficits count it.
const unit_credit: i32 = constants.scheduling_unit_credit;

/// The least deficit a group may hold: one task of the largest cost, started at a credit of 1.
pub const deficit_min: i32 = 1 - @as(i32, constants.task_charge_max) * unit_credit;

/// Runs at most `tasks_per_tick_max` tasks of the groups, by DRR, and returns the count it ran.
/// `tasks` is `.default`'s queue, and `ready` the mask of the other groups that hold a task. Before
/// each call it stores the task's name in `heartbeat`, and after the last one it counts the tasks
/// there, with the group of the last one (decisions 28 and 30). A visit that the tick's bound cut
/// stays open, so the next run resumes it with no second credit.
pub fn run(groups: *Groups, tasks: *Tasks, ready: *u16, heartbeat: *Heartbeat) u32 {
    var run_state: Run = .{ .startable = snapshot(groups, tasks, ready.*) };
    close_stale_visit(groups, run_state.startable);
    tasks.left = constants.tasks_per_tick_max;
    defer tasks.left = 0;
    var ended = false;
    for (0..constants.visits_per_run_max) |_| {
        if (run_state.startable == 0 or run_state.started == constants.tasks_per_tick_max) {
            ended = true;
            break;
        }
        if (visit(groups, tasks, ready, heartbeat, &run_state) == .cut) {
            ended = true;
            break;
        }
    }
    // A run ends within `visits_per_run_max` visits (decision 8, class A).
    assert_class_a(ended);
    if (run_state.started != 0) heartbeat.leave_group_tasks(run_state.started, run_state.last);
    return run_state.started;
}

/// What one run counts as it goes.
const Run = struct {
    /// The mask of the groups that may still start a task in this run.
    startable: u16,
    started: u32 = 0,
    /// The visits in a row that started no task.
    skipped: u32 = 0,
    /// True when a bulk credit came after the last start.
    credited: bool = false,
    /// The group of the last task started.
    last: u8 = 0,
};

const Visit = enum { closed, cut };

/// One visit of the group at or after the cursor.
fn visit(groups: *Groups, tasks: *Tasks, ready: *u16, heartbeat: *Heartbeat, run_state: *Run) Visit {
    const index = next_at(run_state.startable, groups.cursor);
    groups.cursor = index;
    const lane = &groups.lanes[index];
    if (!groups.visit_open) {
        lane.deficit += lane.shares;
        groups.visit_open = true;
    }
    const before = run_state.started;
    run_state.started = start(groups, index, tasks, heartbeat, before);
    if (lane.deficit > 0 and lane.startable > 0) {
        // Only the tick's bound ends a start with credit and a task left.
        assert(run_state.started == constants.tasks_per_tick_max);
        run_state.last = index;
        return .cut;
    }
    close(groups, index, tasks, ready, &run_state.startable);
    if (run_state.started != before) {
        run_state.last = index;
        run_state.skipped = 0;
        run_state.credited = false;
        return .closed;
    }
    run_state.skipped += 1;
    if (run_state.skipped < @popCount(run_state.startable)) return .closed;
    // A bulk credit is followed by a start within one pass (decision 8, class A).
    assert_class_a(!run_state.credited);
    bulk_credit(groups, run_state.startable);
    run_state.credited = true;
    run_state.skipped = 0;
    return .closed;
}

/// Starts the tasks of the group at `index` while its deficit is above 0, it may start one, and
/// the run has started fewer than `tasks_per_tick_max`. Returns the run's starts after it.
fn start(groups: *Groups, index: u8, tasks: *Tasks, heartbeat: *Heartbeat, started_before: u32) u32 {
    const lane = &groups.lanes[index];
    var started = started_before;
    for (started_before..constants.tasks_per_tick_max) |_| {
        if (lane.deficit <= 0 or lane.startable == 0) break;
        const task = if (index == 0) tasks.pop() else groups.pop(index);
        // The cost is read before the call, because the call may free the task's parent.
        const cost = task.call.cost;
        // A hand-written `Call` holds a cost that `init_cost` would refuse (decision 8, class A).
        assert_class_a(cost >= 1 and cost <= constants.task_charge_max);
        lane.startable -= 1;
        lane.deficit -= @as(i32, cost) * unit_credit;
        started += 1;
        heartbeat.enter(&task.call.name);
        task.call.function(task);
        // After the call, as in decision 27's run: `left` is at least 1 inside a call.
        tasks.left -= 1;
    }
    return started;
}

/// Closes the visit of the group at `index`: unused credit is dropped and debt is kept. A group
/// that is empty leaves the ready mask, and one that may start no more leaves the run's mask.
fn close(groups: *Groups, index: u8, tasks: *const Tasks, ready: *u16, startable: *u16) void {
    const lane = &groups.lanes[index];
    lane.deficit = @min(lane.deficit, 0);
    groups.visit_open = false;
    const bit = @as(u16, 1) << @intCast(index);
    if (lane.startable == 0) startable.* &= ~bit;
    if (index != 0 and lane.count == 0) ready.* &= ~bit;
    if (index == 0) assert(tasks.count >= lane.startable);
    groups.cursor = @intCast((@as(u32, index) + 1) % constants.scheduling_groups_max);
}

/// Every group of `startable` is in debt after one full pass: adds the credit of the passes that
/// would start no task. With `r` the least count of visits that takes a group's deficit above 0,
/// it adds `r - 1` visits of credit to each, so the next pass starts a task.
fn bulk_credit(groups: *Groups, startable: u16) void {
    var rounds: i64 = std.math.maxInt(i64);
    var mask = startable;
    for (0..constants.scheduling_groups_max) |_| {
        if (mask == 0) break;
        const index = @ctz(mask);
        mask &= mask - 1;
        const lane = &groups.lanes[index];
        assert(lane.deficit <= 0);
        rounds = @min(rounds, std.math.divCeil(i64, 1 - @as(i64, lane.deficit), lane.shares) catch unreachable);
    }
    assert(rounds >= 1);
    mask = startable;
    for (0..constants.scheduling_groups_max) |_| {
        if (mask == 0) break;
        const index = @ctz(mask);
        mask &= mask - 1;
        const lane = &groups.lanes[index];
        lane.deficit += @intCast((rounds - 1) * lane.shares);
        assert(lane.deficit <= 0);
    }
}

/// The run's snapshot: each ready group may start the tasks it holds now. Returns their mask.
fn snapshot(groups: *Groups, tasks: *const Tasks, ready: u16) u16 {
    // Bit 0 of the ready mask stays clear: `tasks.count` says whether `.default` holds a task.
    assert(ready & 1 == 0);
    assert(ready != 0);
    groups.lanes[0].startable = tasks.count;
    var startable: u16 = @intFromBool(tasks.count != 0);
    var mask = ready;
    for (0..constants.scheduling_groups_max) |_| {
        if (mask == 0) break;
        const index = @ctz(mask);
        mask &= mask - 1;
        const lane = &groups.lanes[index];
        // A ready group holds a task.
        assert(lane.count != 0);
        lane.startable = lane.count;
        startable |= @as(u16, 1) << @intCast(index);
    }
    return startable;
}

/// A visit that a run cut stays open. When its group may start nothing in this run, because the
/// path with one group ran its tasks since, the visit closes here, with its credit dropped.
fn close_stale_visit(groups: *Groups, startable: u16) void {
    assert(startable != 0);
    // Only the tick's bound leaves a visit open, and it leaves its credit above 0.
    assert(!groups.visit_open or groups.lanes[groups.cursor].deficit > 0);
    if (!groups.visit_open) return;
    if ((startable >> @intCast(groups.cursor)) & 1 == 1) return;
    const lane = &groups.lanes[groups.cursor];
    lane.deficit = @min(lane.deficit, 0);
    groups.visit_open = false;
}

/// The first group of `mask` at or after `cursor`, in the order of the ids, after the last id the
/// first one again. `mask` is not 0.
pub fn next_at(mask: u16, cursor: u8) u8 {
    assert(mask != 0);
    const rotated = std.math.rotr(u16, mask, cursor);
    return @intCast((@as(u32, cursor) + @ctz(rotated)) % @bitSizeOf(u16));
}

/// Adds `units` to the cost of the task that runs now, on the groups path. The deficit stays at
/// or above `deficit_min` (decision 8, class A, one compare).
pub fn charge(groups: *Groups, units: u16) void {
    const lane = &groups.lanes[groups.cursor];
    lane.deficit -= @as(i32, units) * unit_credit;
    assert_class_a(lane.deficit >= deficit_min);
}

/// What `task_budget_left` answers on the groups path: the smaller of the starts left in the tick
/// and the whole units left in the visit. With no other group ready, it is the starts left, as on
/// the path with one group.
pub fn budget_left(groups: *const Groups, tasks: *const Tasks, ready: u16) u32 {
    // Inside a task's call `left` counts that task too, so the starts left are one fewer.
    assert(tasks.left <= constants.tasks_per_tick_max);
    // Bit 0 of the ready mask stays clear, as in `snapshot`.
    assert(ready & 1 == 0);
    const starts_left = tasks.left - 1;
    const all = ready | @intFromBool(tasks.count != 0);
    const others = all & ~(@as(u16, 1) << @intCast(groups.cursor));
    if (others == 0) return starts_left;
    const deficit = groups.lanes[groups.cursor].deficit;
    const units: u32 = @intCast(@divFloor(@max(deficit, 0), unit_credit));
    return @min(starts_left, units);
}

comptime {
    // `next_at` rotates a 16-bit mask, so the ids fit it.
    assert(constants.scheduling_groups_max <= 16);
}
