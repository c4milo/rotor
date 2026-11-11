//! Halt scenarios for the heartbeat of decision 28, which the core keeps (decision 33, open question
//! 3): the stall count, the watch and the names of the callbacks. Each reaches its check through the
//! function's own parameters and enters no kernel. Moved from the scenarios of the dispatch and of
//! the scheduling groups at step 3 of decision 33.
const std = @import("std");
const core = @import("core");
const scenario = @import("scenario.zig");

var heartbeat: core.Heartbeat align(@alignOf(core.Heartbeat)) = .init(null);
var stall_starts: [1]u64 = .{0};
var stall_statistics: core.statistics.Statistics align(@alignOf(core.statistics.Statistics)) = undefined;

/// A run of the groups that names a group past the table as its last. With the check deleted,
/// the heartbeat stores it and returns.
fn leave_a_run_with_a_group_past_the_table() void {
    heartbeat = .init(null);
    scenario.reached_violation();
    heartbeat.leave_group_tasks(1, core.constants.scheduling_groups_max);
}

/// A stall of one task of the groups' run whose stored group is past the table. With the check
/// deleted, the stall names that id and the stamp returns.
fn note_a_stall_of_a_group_past_the_table() void {
    stall_statistics.init(.{}, &stall_starts);
    heartbeat = .init(10);
    heartbeat.note_clock(&stall_statistics, 100);
    heartbeat.turn.ended = @as(u64, 1) << core.Heartbeat.Turn.group_task_shift;
    heartbeat.turn_group = core.constants.scheduling_groups_max;
    scenario.reached_violation();
    heartbeat.note_clock(&stall_statistics, 200);
}

/// A loop that ends while a watch reads its heartbeat (decision 28). With the check deleted, the
/// check returns.
fn end_a_loop_that_a_watch_reads() void {
    heartbeat = .init(null);
    _ = core.stall_watch.view_of(&heartbeat).watch();
    scenario.reached_violation();
    heartbeat.assert_unwatched();
}

/// A watch that ends twice: the count of watchers would wrap, and a `deinit` would pass while the
/// first watch still reads. With the check deleted, the count wraps and the call returns.
fn end_one_watch_twice() void {
    heartbeat = .init(null);
    var watch = core.stall_watch.view_of(&heartbeat).watch();
    watch.end();
    scenario.reached_violation();
    watch.end();
}

/// A threshold of 0 ns: every turn would be a stall, a wait included, because a wait spans 0 ns.
/// With the check deleted, the heartbeat is made and the call returns.
fn count_stalls_from_a_threshold_of_nothing() void {
    scenario.reached_violation();
    heartbeat = .init(0);
}

/// A clock stamp after a wait that is the value the heartbeat keeps for a wait: a watch would
/// take the open turn for a wait. With the check deleted, the stamp is stored and the call returns.
fn wake_at_the_stamp_of_a_wait() void {
    heartbeat = .init(null);
    scenario.reached_violation();
    heartbeat.note_woken(core.stall.asleep);
}

/// One watch more than the count holds: the count would wrap to 0, and a `deinit` would pass while
/// every watch still reads. With the check deleted, the count wraps and the call returns.
fn watch_a_heartbeat_whose_count_is_full() void {
    heartbeat = .init(null);
    heartbeat.watchers.store(std.math.maxInt(u32), .release);
    scenario.reached_violation();
    _ = core.stall_watch.view_of(&heartbeat).watch();
}

pub const scenarios = [_]scenario.Scenario{
    .{
        .name = "heartbeat: count stalls from a threshold of 0 ns",
        .run = count_stalls_from_a_threshold_of_nothing,
    },
    .{ .name = "heartbeat: wake at the stamp of a wait", .run = wake_at_the_stamp_of_a_wait },
    .{
        .name = "heartbeat: watch a heartbeat whose count is full",
        .run = watch_a_heartbeat_whose_count_is_full,
    },
    .{ .name = "heartbeat: end a loop that a watch reads", .run = end_a_loop_that_a_watch_reads },
    .{ .name = "heartbeat: end one watch twice", .run = end_one_watch_twice },
    .{
        .name = "heartbeat: leave a run with a group past the table",
        .run = leave_a_run_with_a_group_past_the_table,
    },
    .{
        .name = "heartbeat: note a stall of a group past the table",
        .run = note_a_stall_of_a_group_past_the_table,
    },
};
