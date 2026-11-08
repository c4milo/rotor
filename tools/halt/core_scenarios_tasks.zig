//! Halt scenarios for the task queue of decision 27: `core.tasks.Tasks` and the parts of
//! `core.dispatch.Dispatch` that hold it. Each reaches its check through the function's own
//! parameters and enters no kernel. With the check deleted, each scenario returns, and says how.
const core = @import("core");
const scenario = @import("scenario.zig");

const Task = core.Task;
const Tasks = core.tasks.Tasks;
const Dispatch = core.dispatch.Dispatch;

fn ran(_: *Task) void {}

const ran_call: Task.Call = .{ .name = "ran", .function = ran };
var first: Task align(@alignOf(Task)) = .{ .call = &ran_call };
var second: Task align(@alignOf(Task)) = .{ .call = &ran_call };
var tasks: Tasks align(@alignOf(Tasks)) = .empty;
var dispatch: Dispatch align(@alignOf(Dispatch)) = .empty;
/// What a run stores each task's name in (decision 28).
var heartbeat: core.Heartbeat align(@alignOf(core.Heartbeat)) = .init(null);
/// The loop's groups (decision 30).
var groups: core.scheduling.Groups align(@alignOf(core.scheduling.Groups)) = undefined;

/// One task pushed twice: the queue would link the task to itself. With the check deleted, the
/// second push does so, and the run of two tasks calls it twice and returns.
fn push_one_task_twice() void {
    tasks = .empty;
    first = .{ .call = &ran_call };
    tasks.push(&first, core.constants.tasks_queued_max) catch return;
    scenario.reached_violation();
    tasks.push(&first, core.constants.tasks_queued_max) catch return;
    _ = tasks.run(&heartbeat);
}

/// A queue whose count says two and whose links hold one. With the check deleted, the second pop
/// finds no head and the run ends.
fn run_a_queue_shorter_than_its_count() void {
    first = .{ .call = &ran_call };
    tasks = .{ .head = &first, .tail = &first, .count = 2, .left = 0 };
    scenario.reached_violation();
    _ = tasks.run(&heartbeat);
}

/// A queue with a head and no tail. With the check deleted, the run pops the one task and returns.
fn run_a_queue_with_a_head_and_no_tail() void {
    first = .{ .call = &ran_call };
    tasks = .{ .head = &first, .tail = null, .count = 1, .left = 0 };
    scenario.reached_violation();
    _ = tasks.run(&heartbeat);
}

/// The walk of a queue whose count says three and whose links hold two. With the walk's checks
/// deleted, it returns.
fn walk_a_queue_shorter_than_its_count() void {
    second = .{ .call = &ran_call };
    first = .{ .call = &ran_call, .next = &second };
    tasks = .{ .head = &first, .tail = &second, .count = 3, .left = 0 };
    scenario.reached_violation();
    tasks.assert_queue();
}

/// `discard_tasks` inside a tick: a task would discard the queue its own run walks. With the check
/// deleted, the discard empties the queue and returns.
fn discard_the_tasks_inside_a_tick() void {
    dispatch = .empty;
    groups.init(&.empty);
    first = .{ .call = &ran_call };
    dispatch.schedule(&first) catch return;
    _ = dispatch.begin(&heartbeat, 0);
    scenario.reached_violation();
    _ = dispatch.discard_tasks(&groups);
}

/// A loop that ends with a task queued: the task is the library's memory, which it may free once
/// the loop has ended. With the check deleted, the check returns.
fn end_a_loop_with_a_task_queued() void {
    dispatch = .empty;
    first = .{ .call = &ran_call };
    dispatch.schedule(&first) catch return;
    scenario.reached_violation();
    dispatch.assert_empty();
}

pub const scenarios = [_]scenario.Scenario{
    .{ .name = "tasks: push one task twice", .run = push_one_task_twice },
    .{ .name = "tasks: run a queue shorter than its count", .run = run_a_queue_shorter_than_its_count },
    .{ .name = "tasks: run a queue with a head and no tail", .run = run_a_queue_with_a_head_and_no_tail },
    .{ .name = "tasks: walk a queue shorter than its count", .run = walk_a_queue_shorter_than_its_count },
    .{ .name = "tasks: discard the tasks inside a tick", .run = discard_the_tasks_inside_a_tick },
    .{ .name = "tasks: end a loop with a task queued", .run = end_a_loop_with_a_task_queued },
};
