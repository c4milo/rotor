//! The seeded property test of decision 30's groups. A run draws random steps: groups reserved,
//! tasks of random cost and charge scheduled in random groups, tasks that schedule themselves
//! again, changes of shares, ticks and discards. After every step it holds the real `Dispatch`
//! and `Groups` to the model of `scheduling_test_model.zig`. A failure prints the seed that
//! replays it (non-negotiable 6).
//!
//! - G1: the tasks of each tick, in order, equal the model's, and so do the cursor and the visit.
//! - G2: each deficit equals the model's, and stays in [1 - task_charge_max * 100, shares_max].
//!   Each group's units served are its credit less the credit dropped and its deficit.
//! - G3: the window bound. While a group drops no credit, the units it is served differ from the
//!   credit it was given by less than `task_charge_max` units (decision 30, "Bounds").
//! - G4: a tick starts at most `tasks_per_tick_max` tasks.
//! - G5: for each group, scheduled = run + discarded + queued, and the queue lengths agree.
//! - G6: `outstanding` is the sum of the queue lengths.
//! - G7: the same seed gives the same trace with every task at another address.
//! - G8: `begin` waits 0 if and only if a group holds a task, and the ready mask agrees.
//!
//! A job charges a fixed count, up to all that `task_charge_max` leaves past its cost, or follows
//! the rule of `Task.init_cost`: it reads `task_budget_left` and does up to all the slices the rule
//! allows. The budget each job read equals the model's.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const constants = @import("../constants.zig");
const Random = core.random.Random;
const scheduling_run = @import("scheduling_run.zig");
const tasks_module = @import("../tasks.zig");
const unit = @import("scheduling_test_unit.zig");
const model_module = @import("scheduling_test_model.zig");

const Bench = unit.Bench;
const Model = model_module.Model;
const Charge = model_module.Charge;
const budget_unread = model_module.budget_unread;
const Task = @import("../reactor.zig").Task;
const SchedulingGroup = core.SchedulingGroup;
const jobs_pool = model_module.jobs_pool;
const groups_used_max = model_module.groups_used_max;

const seeds = 64;
const steps = 300;

/// The costs a job's static `Call` may hold, the largest included.
const costs = [_]u16{ 1, 2, 3, 8, constants.task_charge_max };

fn job_function(task: *Task) void {
    const job: *Job = @alignCast(@fieldParentPtr("task", task));
    job.ran();
}

const calls = calls: {
    var made: [costs.len]Task.Call = undefined;
    for (&made, costs) |*call, cost| call.* = .{ .name = "scheduling_test.Job", .function = job_function, .cost = cost };
    break :calls made;
};

/// A library's task: its id, its cost and charge for each run, and the runs left in which it
/// schedules itself again.
const Job = struct {
    task: Task,
    id: u32,
    group: SchedulingGroup,
    cost: u16,
    charge: Charge,
    again: u32,
    fixture: *Fixture,

    fn ran(job: *Job) void {
        const fixture = job.fixture;
        const bench = &fixture.bench;
        fixture.trace[fixture.trace_len] = job.id;
        const read = if (job.charge == .rule) bench.dispatch.task_budget_left(&bench.words) else budget_unread;
        fixture.budgets[fixture.trace_len] = read;
        fixture.trace_len += 1;
        const units = job.charge.units(job.cost, read);
        if (units != 0) bench.dispatch.charge_task(&bench.words, units);
        if (job.again == 0) return;
        job.again -= 1;
        fixture.bench.schedule(job.group, &job.task) catch unreachable;
    }
};

const Fixture = struct {
    bench: Bench,
    /// The pool in reverse order of id when `reversed`, so the tasks sit at other addresses.
    jobs: [jobs_pool]Job,
    reversed: bool,
    trace: [model_module.trace_max]u32,
    budgets: [model_module.trace_max]u32,
    trace_len: u32,

    fn job(fixture: *Fixture, id: u32) *Job {
        return &fixture.jobs[if (fixture.reversed) jobs_pool - 1 - id else id];
    }
};

const Run = struct {
    random: Random,
    model: *Model,
    fixture: *Fixture,

    fn step(run: *Run) !void {
        const roll = run.random.below(100);
        if (roll < 50) return run.schedule();
        if (roll < 82) return run.tick();
        if (roll < 92) return run.set_shares();
        if (roll < 96) return run.reserve();
        return run.discard();
    }

    fn reserve(run: *Run) !void {
        if (run.model.reserved + 1 == groups_used_max) return;
        const shares = run.draw_shares();
        const group = try run.fixture.bench.groups.reserve(shares);
        try testing.expectEqual(run.model.reserve(shares), @intFromEnum(group));
    }

    fn draw_shares(run: *Run) u16 {
        if (run.random.chance(1, 8)) return @intCast(run.random.between(1, 5));
        return @intCast(run.random.between(1, constants.scheduling_shares_max));
    }

    fn schedule(run: *Run) !void {
        const id: u32 = @intCast(run.random.below(jobs_pool));
        if (run.model.queued[id]) return;
        const group: u8 = @intCast(run.random.below(@as(u64, run.model.reserved) + 1));
        const cost_index = run.random.below(costs.len);
        const cost = costs[cost_index];
        const charge = run.draw_charge(cost);
        const again: u32 = if (run.random.chance(1, 3)) @intCast(run.random.between(1, 20)) else 0;
        run.model.schedule(id, group, cost, charge, again);
        const job = run.fixture.job(id);
        job.* = .{
            .task = .{ .call = &calls[cost_index] },
            .id = id,
            .group = @enumFromInt(group),
            .cost = cost,
            .charge = charge,
            .again = again,
            .fixture = run.fixture,
        };
        try run.fixture.bench.schedule(job.group, &job.task);
    }

    /// A charge in the whole range a caller may use: a fixed count up to `task_charge_max` units
    /// in all, its largest value included, or the rule for a cost that varies, up to all the
    /// slices it allows.
    fn draw_charge(run: *Run, cost: u16) Charge {
        const roll = run.random.below(8);
        if (roll < 3) return .{ .fixed = 0 };
        if (roll < 4) return .{ .fixed = constants.task_charge_max - cost };
        if (roll < 6) return .{ .fixed = @intCast(run.random.between(0, constants.task_charge_max - cost)) };
        return .{ .rule = @intCast(run.random.between(0, model_module.fraction_max)) };
    }

    fn set_shares(run: *Run) !void {
        const group: u8 = @intCast(run.random.below(@as(u64, run.model.reserved) + 1));
        const shares = run.draw_shares();
        run.model.shares[group] = shares;
        run.fixture.bench.groups.set_shares(@enumFromInt(group), shares);
    }

    fn discard(run: *Run) !void {
        try testing.expectEqual(run.model.discard(), run.fixture.bench.dispatch.discard_tasks(&run.fixture.bench.words));
    }

    fn tick(run: *Run) !void {
        const bench = &run.fixture.bench;
        // G8: the wait of `begin`.
        const wait = bench.dispatch.begin(&bench.words, 7);
        try testing.expectEqual(run.model.queued_count() != 0, wait == 0);
        run.fixture.trace_len = 0;
        _ = bench.dispatch.end(&bench.words, &.{});
        run.model.tick();
        // G1 and G4.
        try testing.expect(run.fixture.trace_len <= constants.tasks_per_tick_max);
        try testing.expectEqualSlices(u32, run.model.trace[0..run.model.trace_len], run.fixture.trace[0..run.fixture.trace_len]);
        try testing.expectEqualSlices(u32, run.model.budgets[0..run.model.trace_len], run.fixture.budgets[0..run.fixture.trace_len]);
    }

    fn check(run: *Run) !void {
        const bench = &run.fixture.bench;
        const model = run.model;
        bench.groups.assert_lanes(bench.dispatch.groups_ready);
        bench.dispatch.tasks.assert_queue();
        try testing.expectEqual(model.cursor, bench.groups.cursor);
        try testing.expectEqual(model.visit_open, bench.groups.visit_open);
        var outstanding: u32 = 0;
        for (0..groups_used_max) |group| {
            const lane = &bench.groups.lanes[group];
            // G2.
            try testing.expectEqual(model.deficit[group], lane.deficit);
            try testing.expect(lane.deficit >= scheduling_run.deficit_min);
            try testing.expect(lane.deficit <= constants.scheduling_shares_max);
            const accounted = model.credited[group] - model.dropped[group] - model.served[group] * 100;
            try testing.expectEqual(model.deficit[group], accounted);
            // G3, between visits: a visit the tick's bound cut holds credit that is not served yet.
            if (!(model.visit_open and model.cursor == group)) {
                const gap = model.window_gap(@intCast(group));
                try testing.expect(@abs(gap) < @as(u64, constants.task_charge_max) * constants.scheduling_unit_credit);
            }
            // G5.
            const count = if (group == 0) bench.dispatch.tasks.count else lane.count;
            try testing.expectEqual(model.queue_len[group], count);
            const settled = model.ran[group] + model.discarded[group] + model.queue_len[group];
            try testing.expectEqual(model.scheduled[group], settled);
            // G8: the ready mask.
            if (group != 0) {
                const ready = (bench.dispatch.groups_ready >> @intCast(group)) & 1 == 1;
                try testing.expectEqual(count != 0, ready);
            }
            outstanding += count;
        }
        // G6.
        try testing.expectEqual(outstanding, bench.words.word);
    }
};

/// Runs `steps` random steps from `seed`, and returns a hash of every task run.
fn property_run(seed: u64, reversed: bool) !u64 {
    errdefer std.debug.print("scheduling property failed: seed {d}, reversed {}\n", .{ seed, reversed });
    var model: Model = .{};
    var fixture: Fixture = undefined;
    fixture.bench.init(&.empty);
    fixture.reversed = reversed;
    fixture.trace_len = 0;
    var run: Run = .{ .random = .init(seed), .model = &model, .fixture = &fixture };
    var hasher: std.hash.Wyhash = .init(seed);
    for (0..steps) |_| {
        try run.step();
        try run.check();
        hasher.update(std.mem.sliceAsBytes(fixture.trace[0..fixture.trace_len]));
        fixture.trace_len = 0;
    }
    // A drain at the end: every task left runs or is discarded, and the loop is empty.
    _ = fixture.bench.dispatch.discard_tasks(&fixture.bench.words);
    fixture.bench.dispatch.assert_empty();
    return hasher.final();
}

test "the groups run what plain DRR runs, keep their bounds, and replay at other addresses" {
    for (0..seeds) |seed| {
        const first = try property_run(seed, false);
        // G7: the same trace twice, and with every task at another address.
        try testing.expectEqual(first, try property_run(seed, false));
        try testing.expectEqual(first, try property_run(seed, true));
    }
}
