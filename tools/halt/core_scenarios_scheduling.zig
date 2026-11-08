//! Halt scenarios for the scheduling groups of decision 30: `core.scheduling.Groups`, its rule, and
//! the parts of `core.dispatch.Dispatch` that hold it. Each reaches its check through the
//! function's own parameters, or through a state of the groups that a scenario sets by hand, and
//! enters no kernel. With the check deleted, each scenario returns, and says how.
const core = @import("core");
const scenario = @import("scenario.zig");

const Dispatch = core.dispatch.Dispatch;
const Groups = core.scheduling.Groups;
const SchedulingGroup = core.SchedulingGroup;
const Task = core.Task;

fn ran(_: *Task) void {}

const ran_call: Task.Call = .{ .name = "ran", .function = ran };
/// A hand-written entry with a cost that `Task.init_cost` refuses to compile.
const free_call: Task.Call = .{ .name = "free", .function = ran, .cost = 0 };

/// The tasks of one run past the tick's bound, and one more.
const tasks_held = core.constants.tasks_per_tick_max + 1;

var tasks: [tasks_held]Task align(@alignOf(Task)) = @splat(.{ .call = &ran_call });
var dispatch: Dispatch align(@alignOf(Dispatch)) = .empty;
var groups: Groups align(@alignOf(Groups)) = undefined;
var heartbeat: core.Heartbeat align(@alignOf(core.Heartbeat)) = .init(null);

/// A dispatch with no task and groups with `reserved` groups at the default shares.
fn start(reserved: u8) void {
    dispatch = .empty;
    groups.init(&.empty);
    for (0..reserved) |_| _ = groups.reserve(core.constants.scheduling_shares_default) catch return;
    tasks = @splat(.{ .call = &ran_call });
}

/// One tick with no events: `begin`, then `end`.
fn tick() void {
    _ = dispatch.begin(&heartbeat, 0);
    _ = dispatch.end(&heartbeat, &groups, &.{});
}

/// A forged id: `@enumFromInt` of a group the loop did not reserve. With the check deleted, the
/// task is queued in that lane and the call returns.
fn queue_a_task_in_a_group_the_loop_did_not_reserve() void {
    start(1);
    scenario.reached_violation();
    dispatch.schedule_in(&groups, @enumFromInt(5), &tasks[0]) catch return;
}

/// With the check deleted, the lane's shares change and the call returns.
fn set_the_shares_of_a_group_the_loop_did_not_reserve() void {
    start(1);
    scenario.reached_violation();
    groups.set_shares(@enumFromInt(5), 100);
}

/// With the check deleted, the reserve returns the group.
fn reserve_a_group_with_no_shares() void {
    start(0);
    scenario.reached_violation();
    _ = groups.reserve(0) catch return;
}

/// With the check deleted, the reserve returns the group.
fn reserve_a_group_with_shares_above_the_most() void {
    start(0);
    scenario.reached_violation();
    _ = groups.reserve(core.constants.scheduling_shares_max + 1) catch return;
}

/// One task queued in two groups. With the check deleted, the second push links it again and
/// returns.
fn queue_one_task_in_two_groups() void {
    start(2);
    dispatch.schedule_in(&groups, @enumFromInt(1), &tasks[0]) catch return;
    scenario.reached_violation();
    dispatch.schedule_in(&groups, @enumFromInt(2), &tasks[0]) catch return;
}

/// A charge between ticks. With the check deleted, the charge changes nothing and returns.
fn charge_a_task_outside_its_run() void {
    start(0);
    scenario.reached_violation();
    dispatch.charge_task(&groups, 1);
}

fn charge_too_much(_: *Task) void {
    scenario.reached_violation();
    dispatch.charge_task(&groups, core.constants.task_charge_max + 1);
}

const charge_too_much_call: Task.Call = .{ .name = "charge_too_much", .function = charge_too_much };

/// A charge above `task_charge_max`, in a run of `.default` alone. With the check deleted, the run
/// keeps no account, and the tick returns.
fn charge_more_than_the_most_units() void {
    start(0);
    tasks[0] = .{ .call = &charge_too_much_call };
    dispatch.schedule(&tasks[0]) catch return;
    tick();
}

fn charge_past_the_floor(_: *Task) void {
    scenario.reached_violation();
    dispatch.charge_task(&groups, core.constants.task_charge_max);
}

const charge_past_the_floor_call: Task.Call = .{
    .name = "charge_past_the_floor",
    .function = charge_past_the_floor,
    .cost = core.constants.task_charge_max,
};

/// A task of the largest cost that charges the largest count again, on the groups path: its
/// group's deficit goes below the least one. With the check deleted, the deficit holds the debt
/// and the tick returns.
fn charge_a_group_past_its_least_deficit() void {
    start(1);
    tasks[0] = .{ .call = &charge_past_the_floor_call };
    dispatch.schedule_in(&groups, @enumFromInt(1), &tasks[0]) catch return;
    scenario.reached_violation();
    tick();
}

/// A hand-written `Call` of cost 0 on the groups path. With the check deleted, the task runs, its
/// group pays nothing, and the tick returns.
fn run_a_task_whose_call_costs_nothing() void {
    start(1);
    tasks[0] = .{ .call = &free_call };
    dispatch.schedule_in(&groups, @enumFromInt(1), &tasks[0]) catch return;
    scenario.reached_violation();
    tick();
}

/// A lane whose head is the end mark, which links to itself. With the check deleted, the pop
/// hands out the end mark and returns.
fn pop_the_end_mark() void {
    start(1);
    groups.end_mark.next = &groups.end_mark;
    groups.lanes[1].head = &groups.end_mark;
    groups.lanes[1].tail = &groups.end_mark;
    groups.lanes[1].count = 2;
    scenario.reached_violation();
    _ = groups.pop(1);
}

/// A ready bit for a lane that holds no task, with a head and a tail left in it. With the check
/// deleted, the run takes no task from it, clears its bit, and the tick returns.
fn run_a_ready_group_that_holds_no_task() void {
    start(1);
    tasks[0].next = &groups.end_mark;
    groups.lanes[1].head = &tasks[0];
    groups.lanes[1].tail = &tasks[0];
    dispatch.groups_ready = 1 << 1;
    scenario.reached_violation();
    tick();
}

/// A lane of one task with a head and no tail. With the check deleted, the run pops the task,
/// which ends the queue, calls it, and the tick returns.
fn run_a_ready_group_with_a_head_and_no_tail() void {
    start(1);
    tasks[0].next = &groups.end_mark;
    groups.lanes[1].head = &tasks[0];
    groups.lanes[1].count = 1;
    dispatch.groups_ready = 1 << 1;
    dispatch.callbacks_outstanding = 1;
    scenario.reached_violation();
    tick();
}

/// Groups that hold one task more than the loop owes callbacks. With the check deleted, the run
/// starts `tasks_per_tick_max` of them, the count reaches 0, and the tick returns.
fn run_groups_that_hold_more_tasks_than_the_loop_owes() void {
    start(1);
    for (&tasks) |*task| dispatch.schedule_in(&groups, @enumFromInt(1), task) catch return;
    dispatch.callbacks_outstanding = core.constants.tasks_per_tick_max;
    scenario.reached_violation();
    tick();
}

/// A loop that ends with a task queued in a group other than `.default`: the task is the library's
/// memory, which it may free once the loop has ended. With the check deleted, the check returns.
fn end_a_loop_with_a_task_queued_in_a_group() void {
    start(1);
    dispatch.schedule_in(&groups, @enumFromInt(1), &tasks[0]) catch return;
    scenario.reached_violation();
    dispatch.assert_empty();
}

/// A loop of no backend: the fields that `dispatch_calls.Calls(Host)` reads.
const Host = struct {
    tables: core.Tables,
    inbox: core.inbox.Inbox,
    kept_error: core.tick_error.Kept(error{Unexpected}),
};

const host_slots = 1;
var slots: [host_slots]core.Slot align(@alignOf(core.Slot)) = undefined;
var entries: [host_slots]core.timer_heap.TimerHeap.Entry align(@alignOf(core.timer_heap.TimerHeap.Entry)) = undefined;
var starts: [host_slots]u64 = undefined;
var host: Host align(@alignOf(Host)) = undefined;

/// `reserve_scheduling_group` inside a tick (class C): a reserve while a run walks the groups.
/// With the check deleted, the reserve returns the group.
fn reserve_a_group_inside_a_tick() void {
    host.tables.init(&slots, &entries, &starts, &heartbeat, &groups, .{});
    _ = host.tables.dispatch.begin(&heartbeat, 0);
    scenario.reached_violation();
    _ = core.dispatch.Calls(Host).reserve_scheduling_group(&host, 100) catch return;
}

pub const scenarios = [_]scenario.Scenario{
    .{
        .name = "scheduling: queue a task in a group the loop did not reserve",
        .run = queue_a_task_in_a_group_the_loop_did_not_reserve,
    },
    .{
        .name = "scheduling: set the shares of a group the loop did not reserve",
        .run = set_the_shares_of_a_group_the_loop_did_not_reserve,
    },
    .{ .name = "scheduling: reserve a group with no shares", .run = reserve_a_group_with_no_shares },
    .{
        .name = "scheduling: reserve a group with shares above the most",
        .run = reserve_a_group_with_shares_above_the_most,
    },
    .{ .name = "scheduling: queue one task in two groups", .run = queue_one_task_in_two_groups },
    .{ .name = "scheduling: charge a task outside its run", .run = charge_a_task_outside_its_run },
    .{ .name = "scheduling: charge more than the most units", .run = charge_more_than_the_most_units },
    .{
        .name = "scheduling: charge a group past its least deficit",
        .run = charge_a_group_past_its_least_deficit,
    },
    .{
        .name = "scheduling: run a task whose call costs nothing",
        .run = run_a_task_whose_call_costs_nothing,
    },
    .{ .name = "scheduling: pop the end mark", .run = pop_the_end_mark },
    .{
        .name = "scheduling: run a ready group that holds no task",
        .run = run_a_ready_group_that_holds_no_task,
    },
    .{
        .name = "scheduling: run a ready group with a head and no tail",
        .run = run_a_ready_group_with_a_head_and_no_tail,
    },
    .{
        .name = "scheduling: run groups that hold more tasks than the loop owes",
        .run = run_groups_that_hold_more_tasks_than_the_loop_owes,
    },
    .{ .name = "scheduling: reserve a group inside a tick", .run = reserve_a_group_inside_a_tick },
    .{
        .name = "scheduling: end a loop with a task queued in a group",
        .run = end_a_loop_with_a_task_queued_in_a_group,
    },
};
