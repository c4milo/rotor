//! The unit tests of decision 30's groups, with no `Loop`: a `Dispatch`, its `Groups` and a
//! heartbeat, ticked with no events. Each test is a row of decision 30's table "Unit tests".
const std = @import("std");
const testing = std.testing;
const constants = @import("../constants.zig");
const Dispatch = @import("../dispatch/dispatch.zig").Dispatch;
const scheduling = @import("scheduling.zig");
const stall = @import("../stall.zig");
const statistics_module = @import("../statistics.zig");
const tasks_module = @import("../tasks.zig");

const Groups = scheduling.Groups;
const Heartbeat = stall.Heartbeat;
const Named = scheduling.Named;
const NamedTable = scheduling.NamedTable;
const SchedulingGroup = scheduling.SchedulingGroup;
const Task = tasks_module.Task;
const WaitLimit = @import("../dispatch/dispatch.zig").WaitLimit;

/// The most runs one test's `Bench` notes.
const trace_max = 512;

/// A dispatch, its groups and its heartbeat, and the ids of the tasks in the order they ran.
pub const Bench = struct {
    dispatch: Dispatch,
    groups: Groups,
    heartbeat: Heartbeat,
    trace: [trace_max]u32,
    trace_len: u32,

    pub fn init(bench: *Bench, table: *const NamedTable) void {
        bench.dispatch = .empty;
        bench.groups.init(table);
        bench.heartbeat = .init(null);
        bench.trace_len = 0;
    }

    /// One tick with no events. Returns the tasks it ran.
    pub fn tick(bench: *Bench) u32 {
        // `end` adds the tasks it ran to the turn, and no clock stamp zeroes the turn here.
        const before = bench.heartbeat.turn.ended;
        _ = bench.dispatch.begin(&bench.heartbeat, 1);
        _ = bench.dispatch.end(&bench.heartbeat, &bench.groups, &.{});
        bench.groups.assert_lanes(bench.dispatch.groups_ready);
        bench.dispatch.tasks.assert_queue();
        return @intCast(bench.heartbeat.turn.ended - before);
    }

    pub fn schedule(bench: *Bench, group: SchedulingGroup, task: *Task) !void {
        try bench.dispatch.schedule_in(&bench.groups, group, task);
    }

    fn note(bench: *Bench, id: u32) void {
        bench.trace[bench.trace_len] = id;
        bench.trace_len += 1;
    }

    pub fn traced(bench: *const Bench) []const u32 {
        return bench.trace[0..bench.trace_len];
    }

    pub fn deficit(bench: *const Bench, group: SchedulingGroup) i32 {
        return bench.groups.lanes[@intFromEnum(group)].deficit;
    }
};

/// A library's task in one group: it notes its id, charges `charge` units, and schedules itself
/// again `again` times.
const Job = struct {
    task: Task = .init(Job, "task", ran),
    id: u32,
    group: SchedulingGroup,
    bench: *Bench,
    charge: u16 = 0,
    again: u32 = 0,
    /// What `task_budget_left` read in the last run.
    budget: u32 = 0,

    fn ran(job: *Job) void {
        job.bench.note(job.id);
        job.budget = job.bench.dispatch.task_budget_left(&job.bench.groups);
        if (job.charge != 0) job.bench.dispatch.charge_task(&job.bench.groups, job.charge);
        if (job.again == 0) return;
        job.again -= 1;
        job.bench.schedule(job.group, &job.task) catch unreachable;
    }
};

/// A task of cost 8.
const Heavy = struct {
    task: Task = .init_cost(Heavy, "task", ran, 8),
    runs: u32 = 0,

    fn ran(heavy: *Heavy) void {
        heavy.runs += 1;
    }
};

fn jobs_in(bench: *Bench, jobs: []Job, group: SchedulingGroup, first_id: u32) !void {
    for (jobs, 0..) |*job, offset| {
        job.* = .{ .id = first_id + @as(u32, @intCast(offset)), .group = group, .bench = bench };
        try bench.schedule(group, &job.task);
    }
}

test "a reserve takes the lowest id, until every id is reserved" {
    var bench: Bench = undefined;
    bench.init(&.empty);
    for (1..constants.scheduling_groups_max) |id| {
        const group = try bench.groups.reserve(100);
        try testing.expectEqual(@as(u8, @intCast(id)), @intFromEnum(group));
    }
    try testing.expectError(error.SchedulingGroupsFull, bench.groups.reserve(100));
}

test "init gives the named groups ids 1 to n at their shares, and a reserve then returns n + 1" {
    const Declared = Named(.{ .low = 100, .high = 300 });
    var bench: Bench = undefined;
    bench.init(&Declared.table);
    try testing.expectEqual(@as(u8, 2), bench.groups.named);
    try testing.expectEqual(@as(u16, 100), bench.groups.lanes[1].shares);
    try testing.expectEqual(@as(u16, 300), bench.groups.lanes[2].shares);
    try testing.expectEqual(constants.scheduling_shares_default, bench.groups.lanes[0].shares);
    const reserved = try bench.groups.reserve(50);
    try testing.expectEqual(@as(u8, 3), @intFromEnum(reserved));
    try testing.expectEqual(@as(u16, 50), bench.groups.lanes[3].shares);
}

test "two full groups at shares 100 and 300 are served units 1 to 3 in each round" {
    var bench: Bench = undefined;
    bench.init(&.empty);
    const low = try bench.groups.reserve(100);
    const high = try bench.groups.reserve(300);
    var lows: [40]Job = undefined;
    var highs: [60]Job = undefined;
    try jobs_in(&bench, &lows, low, 0);
    try jobs_in(&bench, &highs, high, 100);
    try testing.expectEqual(constants.tasks_per_tick_max, bench.tick());
    // Four rounds: one task of `low`, then three of `high`, each round.
    const expected = [_]u32{ 0, 100, 101, 102, 1, 103, 104, 105, 2, 106, 107, 108, 3, 109, 110, 111 };
    try testing.expectEqualSlices(u32, &expected, bench.traced()[0..16]);
    var served_low: u32 = 0;
    for (bench.traced()) |id| served_low += @intFromBool(id < 100);
    try testing.expectEqual(@as(u32, 16), served_low);
}

test "a charge of 64 units at shares 1 skips through one bulk credit, and the run ends" {
    var bench: Bench = undefined;
    bench.init(&.empty);
    const slow = try bench.groups.reserve(1);
    var jobs: [2]Job = undefined;
    try jobs_in(&bench, &jobs, slow, 0);
    for (&jobs) |*job| job.charge = constants.task_charge_max - 1;
    // The first start leaves a debt of 6,399 hundredths. The bulk credit pays it in one pass, so
    // the second task starts in the same run.
    try testing.expectEqual(@as(u32, 2), bench.tick());
    try testing.expectEqual(@as(i32, 1 - 64 * 100), bench.deficit(slow));
}

test "a close drops credit that is left, and keeps debt" {
    var bench: Bench = undefined;
    bench.init(&.empty);
    const rich = try bench.groups.reserve(300);
    const poor = try bench.groups.reserve(100);
    var one: [1]Job = undefined;
    var other: [1]Job = undefined;
    try jobs_in(&bench, &one, rich, 0);
    try jobs_in(&bench, &other, poor, 1);
    other[0].charge = 5;
    try testing.expectEqual(@as(u32, 2), bench.tick());
    try testing.expectEqual(@as(i32, 0), bench.deficit(rich));
    try testing.expectEqual(@as(i32, 100 - 100 - 500), bench.deficit(poor));
}

test "a visit the tick's bound cut resumes in the next run with no second credit" {
    var bench: Bench = undefined;
    bench.init(&.empty);
    const wide = try bench.groups.reserve(1000);
    const narrow = try bench.groups.reserve(100);
    var wides: [70]Job = undefined;
    var narrows: [10]Job = undefined;
    try jobs_in(&bench, &wides, wide, 0);
    try jobs_in(&bench, &narrows, narrow, 100);
    // Rounds of 10 and 1: five rounds take 55 starts, and `wide` starts 9 more before the bound.
    try testing.expectEqual(constants.tasks_per_tick_max, bench.tick());
    try testing.expect(bench.groups.visit_open);
    try testing.expectEqual(@as(u8, @intFromEnum(wide)), bench.groups.cursor);
    try testing.expectEqual(@as(i32, 100), bench.deficit(wide));
    bench.trace_len = 0;
    _ = bench.tick();
    // The open visit holds one unit: `wide` runs once, and then `narrow` takes its turn.
    try testing.expectEqualSlices(u32, &.{ 59, 105 }, bench.traced()[0..2]);
}

test "a task that a task queues in another group runs in the next tick" {
    var bench: Bench = undefined;
    bench.init(&.empty);
    const first = try bench.groups.reserve(100);
    const second = try bench.groups.reserve(100);
    var queued: Job = .{ .id = 2, .group = second, .bench = &bench };
    const Queueing = struct {
        task: Task = .init(@This(), "task", ran),
        bench: *Bench,
        then: *Job,

        fn ran(queueing: *@This()) void {
            queueing.bench.note(1);
            queueing.bench.schedule(queueing.then.group, &queueing.then.task) catch unreachable;
        }
    };
    var queueing: Queueing = .{ .bench = &bench, .then = &queued };
    try bench.schedule(first, &queueing.task);
    try testing.expectEqual(@as(u32, 1), bench.tick());
    try testing.expectEqualSlices(u32, &.{1}, bench.traced());
    try testing.expectEqual(@as(u32, 1), bench.tick());
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, bench.traced());
}

test "a run of the groups starts at most tasks_per_tick_max tasks" {
    var bench: Bench = undefined;
    bench.init(&.empty);
    var groups_held: [4]SchedulingGroup = undefined;
    for (&groups_held) |*group| group.* = try bench.groups.reserve(400);
    var jobs: [4][30]Job = undefined;
    for (&jobs, groups_held, 0..) |*row, group, index| try jobs_in(&bench, row, group, @intCast(index * 100));
    try testing.expectEqual(constants.tasks_per_tick_max, bench.tick());
    try testing.expectEqual(@as(u32, 4 * 30 - 64), bench.dispatch.tasks_queued(&bench.groups));
    try testing.expectEqual(@as(u32, 4 * 30 - 64), bench.tick());
}

test "a change of shares counts from the group's next visit" {
    // A task of `changed` sets its shares to 200 inside its own visit: that visit keeps 1 unit.
    const Setting = struct {
        task: Task = .init(@This(), "task", ran),
        bench: *Bench,
        group: SchedulingGroup,

        fn ran(setting: *@This()) void {
            setting.bench.note(999);
            setting.bench.groups.set_shares(setting.group, 200);
        }
    };
    var bench: Bench = undefined;
    bench.init(&.empty);
    const changed = try bench.groups.reserve(100);
    const steady = try bench.groups.reserve(100);
    var changes: [10]Job = undefined;
    var steadies: [10]Job = undefined;
    var setting: Setting = .{ .bench = &bench, .group = changed };
    try bench.schedule(changed, &setting.task);
    try jobs_in(&bench, &changes, changed, 0);
    try jobs_in(&bench, &steadies, steady, 100);
    _ = bench.tick();
    const expected = [_]u32{ 999, 100, 0, 1, 101, 2, 3, 102 };
    try testing.expectEqualSlices(u32, &expected, bench.traced()[0..8]);
}

test "discard_tasks empties every group and resets each deficit and the cursor" {
    var bench: Bench = undefined;
    bench.init(&.empty);
    const debtor = try bench.groups.reserve(100);
    var jobs: [3]Job = undefined;
    try jobs_in(&bench, jobs[0..1], debtor, 0);
    jobs[0].charge = 10;
    _ = bench.tick();
    try testing.expectEqual(@as(i32, -1000), bench.deficit(debtor));
    try testing.expectEqual(@as(u8, 2), bench.groups.cursor);
    try jobs_in(&bench, jobs[1..], debtor, 1);
    var defaults: [2]Job = undefined;
    try jobs_in(&bench, &defaults, .default, 10);
    try testing.expectEqual(@as(u32, 4), bench.dispatch.discard_tasks(&bench.groups));
    try testing.expectEqual(@as(u32, 0), bench.dispatch.tasks_queued(&bench.groups));
    try testing.expectEqual(@as(u32, 0), bench.dispatch.callbacks_outstanding);
    try testing.expectEqual(@as(u16, 0), bench.dispatch.groups_ready);
    try testing.expectEqual(@as(i32, 0), bench.deficit(debtor));
    try testing.expectEqual(@as(u8, 0), bench.groups.cursor);
    try testing.expect(!bench.groups.visit_open);
    for (&jobs) |*job| try testing.expect(job.task.next == null);
    bench.groups.assert_lanes(bench.dispatch.groups_ready);
}

test "a full group refuses one more task while another group schedules" {
    var groups: Groups = undefined;
    groups.init(&.empty);
    const full = try groups.reserve(100);
    const open = try groups.reserve(100);
    var bench: Bench = undefined;
    bench.init(&.empty);
    var jobs: [6]Job = undefined;
    for (&jobs, 0..) |*job, id| job.* = .{ .id = @intCast(id), .group = full, .bench = &bench };
    for (jobs[0..4]) |*job| try groups.push(full, &job.task, 4);
    try testing.expectError(error.TasksFull, groups.push(full, &jobs[4].task, 4));
    try groups.push(open, &jobs[5].task, 4);
    try testing.expectEqual(@as(u32, 5), groups.queued());
}

test "a task of cost 8 takes 800 hundredths of its group's credit" {
    var bench: Bench = undefined;
    bench.init(&.empty);
    const heavy_group = try bench.groups.reserve(1000);
    var heavy: Heavy = .{};
    try bench.schedule(heavy_group, &heavy.task);
    _ = bench.tick();
    try testing.expectEqual(@as(u32, 1), heavy.runs);
    // 1000 of credit less 800, and the close drops what is left.
    try testing.expectEqual(@as(i32, 0), bench.deficit(heavy_group));
    var heavier: [2]Heavy = .{ .{}, .{} };
    for (&heavier) |*one| try bench.schedule(heavy_group, &one.task);
    bench.groups.set_shares(heavy_group, 900);
    _ = bench.tick();
    // 900 less 800 leaves 100, so the second task starts and leaves a debt of 700.
    try testing.expectEqual(@as(i32, -700), bench.deficit(heavy_group));
}

test "a task queued in a group keeps a host from sleeping, and counts in tasks_queued" {
    var bench: Bench = undefined;
    bench.init(&.empty);
    const group = try bench.groups.reserve(100);
    var job: Job = .{ .id = 0, .group = group, .bench = &bench };
    try testing.expectEqual(WaitLimit.none, bench.dispatch.limit_between_ticks());
    try bench.schedule(group, &job.task);
    try testing.expectEqual(WaitLimit.now, bench.dispatch.limit_between_ticks());
    try testing.expectEqual(@as(u32, 1), bench.dispatch.tasks_queued(&bench.groups));
    try testing.expectEqual(@as(u32, 1), bench.tick());
    try testing.expectEqual(WaitLimit.none, bench.dispatch.limit_between_ticks());
}

test "the end mark makes a task queued in one group read as queued for every other" {
    var bench: Bench = undefined;
    bench.init(&.empty);
    var job: Job = .{ .id = 0, .group = undefined, .bench = &bench };
    const third = try bench.groups.reserve(100);
    try bench.schedule(third, &job.task);
    // The tail of group 3 links to the end mark, so `holds` is true, as the class A check of
    // `schedule_in` and of `schedule` reads it.
    try testing.expect(job.task.next == &bench.groups.end_mark);
    try testing.expect(bench.dispatch.tasks.holds(&job.task));
}

test "with no group ready the run is decision 27's, and no lane changes" {
    var bench: Bench = undefined;
    bench.init(&.empty);
    const unused = try bench.groups.reserve(300);
    var jobs: [5]Job = undefined;
    try jobs_in(&bench, &jobs, .default, 0);
    _ = bench.tick();
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4 }, bench.traced());
    try testing.expectEqual(@as(i32, 0), bench.deficit(.default));
    try testing.expectEqual(@as(i32, 0), bench.deficit(unused));
    try testing.expectEqual(@as(u8, 0), bench.groups.cursor);
    // A task's budget is the run's starts left, as decision 27 states it.
    try testing.expectEqual(constants.tasks_per_tick_max - 5, jobs[4].budget);
}

test "the budget on the groups path is the whole units left in the visit" {
    var bench: Bench = undefined;
    bench.init(&.empty);
    const wide = try bench.groups.reserve(500);
    const narrow = try bench.groups.reserve(100);
    var wides: [3]Job = undefined;
    var narrows: [1]Job = undefined;
    try jobs_in(&bench, &wides, wide, 0);
    try jobs_in(&bench, &narrows, narrow, 10);
    _ = bench.tick();
    // 500 of credit: after the first start 400 are left, 4 units.
    try testing.expectEqual(@as(u32, 4), wides[0].budget);
    try testing.expectEqual(@as(u32, 2), wides[2].budget);
    // The last group to run has no other group ready: the starts left in the tick.
    try testing.expectEqual(constants.tasks_per_tick_max - 4, narrows[0].budget);
}

test "a stall of one task names its group, and a stall of one record names none" {
    var bench: Bench = undefined;
    bench.init(&.empty);
    bench.heartbeat = .init(10);
    var starts: [1]u64 = .{0};
    var statistics: statistics_module.Statistics = undefined;
    statistics.init(.{}, &starts);
    const named = try bench.groups.reserve(100);
    var job: Job = .{ .id = 0, .group = named, .bench = &bench };
    try bench.schedule(named, &job.task);
    bench.heartbeat.note_clock(&statistics, &bench.dispatch.pollers, 100);
    _ = bench.tick();
    bench.heartbeat.note_clock(&statistics, &bench.dispatch.pollers, 200);
    try testing.expectEqual(@as(u32, 1), statistics.last_stall.callbacks);
    try testing.expectEqual(@as(?SchedulingGroup, named), statistics.last_stall.group);
    // One record in the next turn: no group.
    bench.heartbeat.enter(&job.task.call.name);
    bench.heartbeat.leave(1);
    bench.heartbeat.note_clock(&statistics, &bench.dispatch.pollers, 300);
    try testing.expectEqual(@as(?SchedulingGroup, null), statistics.last_stall.group);
    // One task of `.default`, on the path with one group: group 0.
    try bench.schedule(.default, &job.task);
    _ = bench.tick();
    bench.heartbeat.note_clock(&statistics, &bench.dispatch.pollers, 400);
    try testing.expectEqual(@as(?SchedulingGroup, .default), statistics.last_stall.group);
}
