//! The reference model of `scheduling_test.zig`: plain deficit round robin with exact integers,
//! written from decision 30's rule and not from `scheduling_run.zig`. It has no bulk credit: a
//! group in debt is skipped one visit at a time, which is what the bulk credit adds up in one
//! pass. It keeps each queue as an array of job ids.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("../constants.zig");

/// The jobs one run draws from.
pub const jobs_pool = 24;

/// The most groups one run uses, `.default` included.
pub const groups_used_max = 6;

/// The most runs of one tick that the trace holds.
pub const trace_max = constants.tasks_per_tick_max;

/// The visits the model makes at most in one tick: a group at shares 1 in a debt of 6,399
/// hundredths needs 6,400 skips, and each start can follow a pass of them.
const model_visits_max = constants.tasks_per_tick_max * groups_used_max * 6_400 * 2;

const credit: i64 = constants.scheduling_unit_credit;

pub const Model = struct {
    reserved: u8 = 0,
    shares: [groups_used_max]u16 = @splat(constants.scheduling_shares_default),
    deficit: [groups_used_max]i64 = @splat(0),
    startable: [groups_used_max]u32 = @splat(0),
    queue: [groups_used_max][jobs_pool]u32 = undefined,
    queue_len: [groups_used_max]u32 = @splat(0),
    cursor: u8 = 0,
    visit_open: bool = false,
    /// Each job's group, units in all, and runs left in which it schedules itself again.
    job_group: [jobs_pool]u8 = @splat(0),
    job_units: [jobs_pool]u16 = @splat(1),
    job_again: [jobs_pool]u32 = @splat(0),
    queued: [jobs_pool]bool = @splat(false),
    trace: [trace_max]u32 = undefined,
    trace_len: u32 = 0,
    /// For each group: the tasks scheduled, run and discarded (G5), and the credit given, the
    /// units served and the credit dropped (G3), all since the run began.
    scheduled: [groups_used_max]u64 = @splat(0),
    ran: [groups_used_max]u64 = @splat(0),
    discarded: [groups_used_max]u64 = @splat(0),
    credited: [groups_used_max]i64 = @splat(0),
    served: [groups_used_max]i64 = @splat(0),
    dropped: [groups_used_max]i64 = @splat(0),

    pub fn reserve(model: *Model, shares: u16) u8 {
        assert(model.reserved + 1 < groups_used_max);
        model.reserved += 1;
        model.shares[model.reserved] = shares;
        model.deficit[model.reserved] = 0;
        return model.reserved;
    }

    pub fn schedule(model: *Model, id: u32, group: u8, units: u16, again: u32) void {
        assert(!model.queued[id]);
        model.job_group[id] = group;
        model.job_units[id] = units;
        model.job_again[id] = again;
        model.queued[id] = true;
        model.push(group, id);
    }

    fn push(model: *Model, group: u8, id: u32) void {
        model.queue[group][model.queue_len[group]] = id;
        model.queue_len[group] += 1;
        model.scheduled[group] += 1;
    }

    fn pop(model: *Model, group: u8) u32 {
        const id = model.queue[group][0];
        const len = model.queue_len[group];
        std.mem.copyForwards(u32, model.queue[group][0 .. len - 1], model.queue[group][1..len]);
        model.queue_len[group] = len - 1;
        return id;
    }

    /// The tasks queued in every group.
    pub fn queued_count(model: *const Model) u32 {
        var sum: u32 = 0;
        for (model.queue_len) |len| sum += len;
        return sum;
    }

    pub fn discard(model: *Model) u32 {
        var sum: u32 = 0;
        for (0..groups_used_max) |group| {
            sum += model.queue_len[group];
            model.discarded[group] += model.queue_len[group];
            model.queue_len[group] = 0;
            model.dropped[group] += model.deficit[group];
            model.deficit[group] = 0;
            model.startable[group] = 0;
        }
        model.queued = @splat(false);
        model.cursor = 0;
        model.visit_open = false;
        return sum;
    }

    /// One tick's run of the tasks.
    pub fn tick(model: *Model) void {
        model.trace_len = 0;
        var others: u32 = 0;
        for (model.queue_len[1..]) |len| others += len;
        if (others == 0) return model.run_default();
        for (0..groups_used_max) |group| model.startable[group] = model.queue_len[group];
        if (model.visit_open and model.startable[model.cursor] == 0) model.close_at(model.cursor);
        var visits: u64 = 0;
        while (visits < model_visits_max) : (visits += 1) {
            if (model.trace_len == constants.tasks_per_tick_max) return;
            const group = model.next_startable() orelse return;
            model.cursor = group;
            if (!model.visit_open) {
                model.deficit[group] += model.shares[group];
                model.credited[group] += model.shares[group];
                model.visit_open = true;
            }
            model.start(group);
            if (model.deficit[group] > 0 and model.startable[group] > 0) return;
            model.close_at(group);
            model.cursor = @intCast((@as(u32, group) + 1) % constants.scheduling_groups_max);
        }
        unreachable;
    }

    fn close_at(model: *Model, group: u8) void {
        const deficit = model.deficit[group];
        if (deficit > 0) model.dropped[group] += deficit;
        model.deficit[group] = @min(deficit, 0);
        model.visit_open = false;
    }

    fn next_startable(model: *const Model) ?u8 {
        for (0..constants.scheduling_groups_max) |offset| {
            const group = (model.cursor + offset) % constants.scheduling_groups_max;
            if (group < groups_used_max and model.startable[group] > 0) return @intCast(group);
        }
        return null;
    }

    fn start(model: *Model, group: u8) void {
        while (model.deficit[group] > 0 and model.startable[group] > 0 and
            model.trace_len < constants.tasks_per_tick_max)
        {
            const id = model.pop(group);
            model.startable[group] -= 1;
            model.deficit[group] -= model.job_units[id] * credit;
            model.served[group] += model.job_units[id];
            model.run_job(group, id);
        }
    }

    fn run_job(model: *Model, group: u8, id: u32) void {
        model.ran[group] += 1;
        model.trace[model.trace_len] = id;
        model.trace_len += 1;
        if (model.job_again[id] == 0) {
            model.queued[id] = false;
            return;
        }
        model.job_again[id] -= 1;
        model.push(group, id);
    }

    /// Decision 27's run: `.default` alone, with no account.
    fn run_default(model: *Model) void {
        const startable = @min(model.queue_len[0], constants.tasks_per_tick_max);
        for (0..startable) |_| model.run_job(0, model.pop(0));
    }
};
