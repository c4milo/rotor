//! Halt scenarios for a loop's spin budget (decision 13): the caller names it in the loop's
//! options, so a budget over `spin_budget_ns_max` is a caller's mistake that halts in
//! `core.Tables.init`. Split from `core_scenarios.zig` for the 500-line limit.
//!
//! With the assertion deleted, `init` stores the budget and returns.
const std = @import("std");
const core = @import("core");
const scenario = @import("scenario.zig");

const Slot = core.Slot;
const TimerHeap = core.timer_heap.TimerHeap;

const slots_count = 4;

var slots: [slots_count]Slot align(@alignOf(Slot)) = undefined;
var entries: [slots_count]TimerHeap.Entry align(@alignOf(TimerHeap.Entry)) = undefined;
var starts: [slots_count]u64 = undefined;

fn give_a_loop_a_spin_budget_over_the_most() void {
    var tables: core.Tables = undefined;
    scenario.reached_violation();
    tables.init(&slots, &entries, &starts, .{
        .spin_budget_ns = core.constants.spin_budget_ns_max + 1,
    });
}

pub const scenarios = [_]scenario.Scenario{
    .{
        .name = "tables: give a loop a spin budget over the most",
        .run = give_a_loop_a_spin_budget_over_the_most,
    },
};
