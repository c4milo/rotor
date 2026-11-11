//! Halt scenarios for the scheduling groups of decision 30: `reactor.Groups`, its rule, and
//! the parts of `reactor.Dispatch` that hold it, over a loop of the port of decision 33 alone. Each reaches its check through the
//! function's own parameters, or through a state of the groups that a scenario sets by hand, and
//! enters no kernel. With the check deleted, each scenario returns, and says how.
const core = @import("core");
const reactor = @import("reactor");
const scenario = @import("scenario.zig");

const Dispatch = reactor.Dispatch;
const Groups = reactor.Groups;
const SchedulingGroup = core.SchedulingGroup;
const Port = @import("reactor_scenarios_call.zig").Port;
const Task = reactor.Task;

fn ran(_: *Task) void {}

const ran_call: Task.Call = .{ .name = "ran", .function = ran };
/// A hand-written entry with a cost that `Task.init_cost` refuses to compile.
const free_call: Task.Call = .{ .name = "free", .function = ran, .cost = 0 };

/// The tasks of one run past the tick's bound, and one more.
const tasks_held = reactor.constants.tasks_per_tick_max + 1;

var tasks: [tasks_held]Task align(@alignOf(Task)) = @splat(.{ .call = &ran_call });
var dispatch: Dispatch align(@alignOf(Dispatch)) = .empty;
var groups: Groups align(@alignOf(Groups)) = undefined;
/// The loop under the reactor's state, and its heartbeat line.
var port: Port align(@alignOf(Port)) = .{};
const heartbeat = &port.heartbeat;

/// A dispatch with no task and groups with `reserved` groups at the default shares.
fn start(reserved: u8) void {
    port = .{};
    dispatch.start(&groups, .{ .id = 0, .in_group = false, .named_groups = &.empty });
    for (0..reserved) |_| _ = groups.reserve(reactor.constants.scheduling_shares_default) catch return;
    tasks = @splat(.{ .call = &ran_call });
}

/// One tick with no events: `begin`, then `end`.
fn tick() void {
    _ = dispatch.begin(&port, 0);
    _ = dispatch.end(&port, &.{});
}

/// A forged id: `@enumFromInt` of a group the loop did not reserve. With the check deleted, the
/// task is queued in that lane and the call returns.
fn queue_a_task_in_a_group_the_loop_did_not_reserve() void {
    start(1);
    scenario.reached_violation();
    dispatch.schedule_in(&port, @enumFromInt(5), &tasks[0]) catch return;
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
    _ = groups.reserve(reactor.constants.scheduling_shares_max + 1) catch return;
}

/// One task queued in two groups. With the check deleted, the second push links it again and
/// returns.
fn queue_one_task_in_two_groups() void {
    start(2);
    dispatch.schedule_in(&port, @enumFromInt(1), &tasks[0]) catch return;
    scenario.reached_violation();
    dispatch.schedule_in(&port, @enumFromInt(2), &tasks[0]) catch return;
}

/// A charge between ticks. With the check deleted, the charge changes nothing and returns.
fn charge_a_task_outside_its_run() void {
    start(0);
    scenario.reached_violation();
    dispatch.charge_task(&port, 1);
}

fn charge_too_much(_: *Task) void {
    scenario.reached_violation();
    dispatch.charge_task(&port, reactor.constants.task_charge_max);
}

const charge_too_much_call: Task.Call = .{ .name = "charge_too_much", .function = charge_too_much };

/// A charge of `task_charge_max`, in a run of `.default` alone: with the task's cost of 1, the run
/// costs more than `task_charge_max`. With the check deleted, the run keeps no account, and the
/// tick returns.
fn charge_more_than_the_most_units() void {
    start(0);
    tasks[0] = .{ .call = &charge_too_much_call };
    dispatch.schedule(&port, &tasks[0]) catch return;
    tick();
}

fn charge_past_the_floor(_: *Task) void {
    scenario.reached_violation();
    dispatch.charge_task(&port, reactor.constants.task_charge_max - 1);
}

const charge_past_the_floor_call: Task.Call = .{
    .name = "charge_past_the_floor",
    .function = charge_past_the_floor,
    .cost = reactor.constants.task_charge_max,
};

/// A task of the largest cost that charges the largest charge again, on the groups path: its
/// group's deficit goes below the least one. With the check deleted, the deficit holds the debt
/// and the tick returns.
fn charge_a_group_past_its_least_deficit() void {
    start(1);
    tasks[0] = .{ .call = &charge_past_the_floor_call };
    dispatch.schedule_in(&port, @enumFromInt(1), &tasks[0]) catch return;
    scenario.reached_violation();
    tick();
}

/// A hand-written `Call` of cost 0 on the groups path. With the check deleted, the task runs, its
/// group pays nothing, and the tick returns.
fn run_a_task_whose_call_costs_nothing() void {
    start(1);
    tasks[0] = .{ .call = &free_call };
    dispatch.schedule_in(&port, @enumFromInt(1), &tasks[0]) catch return;
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
    port.word = 1;
    scenario.reached_violation();
    tick();
}

/// Groups that hold one task more than the loop owes callbacks. With the check deleted, the run
/// starts `tasks_per_tick_max` of them, the count reaches 0, and the tick returns.
fn run_groups_that_hold_more_tasks_than_the_loop_owes() void {
    start(1);
    for (&tasks) |*task| dispatch.schedule_in(&port, @enumFromInt(1), task) catch return;
    port.word = reactor.constants.tasks_per_tick_max;
    scenario.reached_violation();
    tick();
}

/// A loop that ends with a task queued in a group other than `.default`: the task is the library's
/// memory, which it may free once the loop has ended. With the check deleted, the check returns.
fn end_a_loop_with_a_task_queued_in_a_group() void {
    start(1);
    dispatch.schedule_in(&port, @enumFromInt(1), &tasks[0]) catch return;
    scenario.reached_violation();
    dispatch.assert_empty();
}

/// A forged named id, above the ids a table can hold. With the check deleted, the call returns
/// the id as a `SchedulingGroup`.
fn take_the_group_of_a_forged_name() void {
    var forged: reactor.NamedSchedulingGroup = @enumFromInt(core.constants.scheduling_groups_max);
    scenario.reached_violation();
    forged = @enumFromInt(@intFromEnum(forged.group()));
}

/// The budget of a run whose `left` is above the tick's bound. With the check deleted, the call
/// returns the starts it reads.
fn read_the_budget_of_a_run_past_its_bound() void {
    start(1);
    dispatch.tasks.left = reactor.constants.tasks_per_tick_max + 1;
    scenario.reached_violation();
    _ = reactor.scheduling.rule.budget_left(&groups, &dispatch.tasks, 0);
}

/// As above, through the dispatch on the path with one group. With the check deleted, the call
/// returns.
fn read_the_task_budget_past_its_bound() void {
    start(0);
    dispatch.tasks.left = reactor.constants.tasks_per_tick_max + 1;
    scenario.reached_violation();
    _ = dispatch.task_budget_left(&port);
}

/// The budget with bit 0 of the ready mask set, which only `tasks.count` may say. With the check
/// deleted, the call returns.
fn read_the_budget_with_the_default_bit_ready() void {
    start(1);
    dispatch.tasks.left = 1;
    scenario.reached_violation();
    _ = reactor.scheduling.rule.budget_left(&groups, &dispatch.tasks, 1);
}

/// A run of the groups with bit 0 of the ready mask set. Lane 0's count is set too, so the next
/// check of the snapshot holds. With the check deleted, the run starts `.default`'s task and
/// returns.
fn run_the_groups_with_the_default_bit_ready() void {
    start(0);
    dispatch.schedule(&port, &tasks[0]) catch return;
    groups.lanes[0].count = 1;
    var ready: u16 = 1;
    scenario.reached_violation();
    _ = reactor.scheduling.rule.run(&groups, &dispatch.tasks, &ready, heartbeat);
}

/// A run of the groups with no group ready. With the check deleted, the run starts `.default`'s
/// task and returns.
fn run_the_groups_with_none_ready() void {
    start(0);
    dispatch.schedule(&port, &tasks[0]) catch return;
    var ready: u16 = 0;
    scenario.reached_violation();
    _ = reactor.scheduling.rule.run(&groups, &dispatch.tasks, &ready, heartbeat);
}

/// A run of the groups whose ready mask names an empty lane, past the class B shape check of the
/// dispatch. With the check deleted, the run closes that lane, starts `.default`'s task and
/// returns.
fn run_the_groups_with_an_empty_lane_ready() void {
    start(1);
    dispatch.schedule(&port, &tasks[0]) catch return;
    var ready: u16 = 1 << 1;
    scenario.reached_violation();
    _ = reactor.scheduling.rule.run(&groups, &dispatch.tasks, &ready, heartbeat);
}

/// An open visit whose group holds no credit, which only the tick's bound may leave open, and
/// then with credit. With the check deleted, the run closes the visit, starts the task and
/// returns.
fn resume_an_open_visit_with_no_credit() void {
    start(1);
    dispatch.schedule_in(&port, @enumFromInt(1), &tasks[0]) catch return;
    groups.visit_open = true;
    groups.cursor = 1;
    scenario.reached_violation();
    tick();
}

/// Groups with more named groups than reserved ones. With the check deleted, the sum returns.
fn count_the_tasks_of_more_names_than_groups() void {
    start(1);
    groups.named = 2;
    scenario.reached_violation();
    _ = groups.queued();
}

/// A lane that holds more tasks than its cap and every call's task (decision 32). With the check
/// deleted, the sum returns.
fn count_the_tasks_of_a_lane_past_its_cap() void {
    start(1);
    groups.lanes[1].count = reactor.constants.tasks_queued_max + reactor.constants.call_tasks_max + 1;
    scenario.reached_violation();
    _ = groups.queued();
}

/// `.default` with more tasks than `task_queue_length_max`. With the check deleted, the count
/// returns.
fn count_the_tasks_of_default_past_its_cap() void {
    start(0);
    dispatch.tasks.count = reactor.constants.task_queue_length_max + 1;
    scenario.reached_violation();
    _ = dispatch.tasks_queued(&port);
}

/// `reserve_scheduling_group` inside a tick (class C): a reserve while a run walks the groups.
/// With the check deleted, the reserve returns the group.
fn reserve_a_group_inside_a_tick() void {
    start(0);
    _ = dispatch.begin(&port, 0);
    scenario.reached_violation();
    _ = dispatch.reserve_scheduling_group(&port, 100) catch return;
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
    .{ .name = "scheduling: take the group of a forged name", .run = take_the_group_of_a_forged_name },
    .{
        .name = "scheduling: read the budget of a run past its bound",
        .run = read_the_budget_of_a_run_past_its_bound,
    },
    .{ .name = "scheduling: read the task budget past its bound", .run = read_the_task_budget_past_its_bound },
    .{
        .name = "scheduling: read the budget with the default bit ready",
        .run = read_the_budget_with_the_default_bit_ready,
    },
    .{
        .name = "scheduling: run the groups with the default bit ready",
        .run = run_the_groups_with_the_default_bit_ready,
    },
    .{ .name = "scheduling: run the groups with none ready", .run = run_the_groups_with_none_ready },
    .{
        .name = "scheduling: run the groups with an empty lane ready",
        .run = run_the_groups_with_an_empty_lane_ready,
    },
    .{
        .name = "scheduling: resume an open visit with no credit",
        .run = resume_an_open_visit_with_no_credit,
    },
    .{
        .name = "scheduling: count the tasks of more names than groups",
        .run = count_the_tasks_of_more_names_than_groups,
    },
    .{
        .name = "scheduling: count the tasks of a lane past its cap",
        .run = count_the_tasks_of_a_lane_past_its_cap,
    },
    .{
        .name = "scheduling: count the tasks of default past its cap",
        .run = count_the_tasks_of_default_past_its_cap,
    },
} ++
    // The cross-core call of decision 32 runs in the groups, and its scenarios follow theirs.
    @import("reactor_scenarios_call.zig").scenarios;
