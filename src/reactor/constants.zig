//! The named limits of the reactor (decision 33): the pollers, the tasks, the scheduling groups and
//! the cross-core calls. They moved here from the core's `constants.zig` at step 3 of decision 33,
//! with their asserts, and no value changed. The limits that the mailbox rings and the stall line
//! use stay in the core: `calls_per_pair_max`, `mailbox_posts_max`, the reserved tags and
//! `scheduling_groups_max`. This file reads them from there.
const std = @import("std");
const core = @import("core");

// The core's limits that the reactor reads, under the core's names. Each is declared and argued in
// `core/constants.zig`, so a file of this module names one limit through one namespace.

/// `core.constants.batch_max`.
pub const batch_max = core.constants.batch_max;
/// `core.constants.operations_max`.
pub const operations_max = core.constants.operations_max;
/// `core.constants.loops_max`.
pub const loops_max = core.constants.loops_max;
/// `core.constants.scheduling_groups_max`.
pub const scheduling_groups_max = core.constants.scheduling_groups_max;
/// `core.constants.calls_per_pair_max`.
pub const calls_per_pair_max = core.constants.calls_per_pair_max;
/// `core.constants.mailbox_posts_max`.
pub const mailbox_posts_max = core.constants.mailbox_posts_max;
/// `core.constants.mailbox_messages`.
pub const mailbox_messages = core.constants.mailbox_messages;
/// `core.constants.messages_per_drain`.
pub const messages_per_drain = core.constants.messages_per_drain;
/// `core.constants.mailbox_index_alignment`.
pub const mailbox_index_alignment = core.constants.mailbox_index_alignment;
/// `core.constants.message_tag_wake`.
pub const message_tag_wake = core.constants.message_tag_wake;
/// `core.constants.message_tag_call`.
pub const message_tag_call = core.constants.message_tag_call;
/// `core.constants.message_tag_return`.
pub const message_tag_return = core.constants.message_tag_return;

/// The most pollers one reactor may hold (decision 26). colibri and cocuyo need one each today. The
/// reactor keeps a pointer for each, 64 bytes at 8, and calls each one in every tick.
pub const pollers_max: u8 = 8;

comptime {
    std.debug.assert(pollers_max >= 1);
}

/// The most tasks one run of the task queue starts, in the `end` of one tick (decision 27). A prior
/// and not a measurement: of the order of Tokio's `event_interval` of 61 and its budget of 128. At
/// the prior of about 4.3 ns for a hot task, 64 tasks take about 275 ns, less than one `kevent`.
pub const tasks_per_tick_max: u32 = 64;

/// The most tasks queued on one reactor at one time (decision 27). The queue is intrusive and holds
/// no storage of its own, so this bounds a producer that does not stop: `schedule` returns
/// `error.TasksFull` at it.
pub const tasks_queued_max: u32 = 65536;

comptime {
    std.debug.assert(tasks_per_tick_max >= 1);
    std.debug.assert(tasks_per_tick_max <= tasks_queued_max);
}

/// The most shares one group may hold (decision 30). Seastar's header recommends 1 to 1000.
pub const scheduling_shares_max: u16 = 1000;

/// The shares of `.default`, and of each group the program gives no other value: one unit at each
/// visit. Camilo fixed it on 2026-11-08 (decision 30, open question 9). At it each visit starts one
/// task, so `tasks-groups-4` counts more than `tasks-64` (decision 30, "Finish, 2026-11-08"). A
/// program that wants fewer visits gives its groups more shares.
pub const scheduling_shares_default: u16 = 100;

/// The credit of one task unit, in hundredths (decision 30). A share is a hundredth of a unit, so
/// a group at the default shares gets one unit at each visit.
pub const scheduling_unit_credit: u16 = 100;

/// The most units one run of a task may cost: its static cost, and the units it adds with
/// `charge_task` (decision 30). Camilo fixed it on 2026-11-08 (decision 30, open question 9). It
/// is `tasks_per_tick_max`, so a task that follows the rule of `Task.init_cost` stays within it.
pub const task_charge_max: u16 = 64;

/// The most visits one run of the groups takes (decision 30, "The rule"). Each start uses at most
/// two visits of each group, one skip and one start, plus one bulk credit.
pub const visits_per_run_max: u32 = tasks_per_tick_max * (2 * @as(u32, scheduling_groups_max) + 1);

comptime {
    std.debug.assert(scheduling_shares_default >= 1);
    std.debug.assert(scheduling_shares_default <= scheduling_shares_max);
    std.debug.assert(scheduling_unit_credit >= 1);
    std.debug.assert(task_charge_max >= 1);
    // A task that follows the rule for a cost that varies costs at most its static cost, or
    // `task_budget_left() + 1` units, which is at most `tasks_per_tick_max`. So it never passes
    // `task_charge_max` (decision 30, ruling item 11).
    std.debug.assert(tasks_per_tick_max <= task_charge_max);
    // A deficit stays in [1 - task_charge_max * 100, scheduling_shares_max], an `i32`.
    std.debug.assert(@as(i64, task_charge_max) * scheduling_unit_credit < std.math.maxInt(i32));
    // Every queued task of every group, every operation that named a record, and every call out
    // or held with the tasks of calls fit the count of outstanding callbacks, a `u32`. A loop counts
    // a call it sent, a call it holds, and a call to itself twice (decision 32, "Layout").
    const queued_max = @as(u64, scheduling_groups_max) * tasks_queued_max;
    const calls_max = 2 * (@as(u64, loops_max) - 1 + services_max) * calls_per_pair_max + call_tasks_max;
    std.debug.assert(calls_max == 34_176);
    std.debug.assert(queued_max + operations_max + calls_max <= std.math.maxInt(u32));
}

/// The most services one loop serves or calls itself through (decision 32, open question 7). A
/// prior: stompy plans fewer than 8. The byte `Groups.stations` counts them.
pub const services_max: u32 = 16;

/// The most tasks of calls that one loop can hold queued at one time (decision 32, "The task queue
/// and the fair tick"): the calls to it from each other loop, the returns of its own calls to each
/// other loop, and its calls to itself, for each service. A call's task is pushed with the limit
/// `tasks_queued_max + call_tasks_max`, so a group that the program filled never refuses one.
pub const call_tasks_max: u32 = (2 * (@as(u32, loops_max) - 1) + services_max) * calls_per_pair_max;

/// The most tasks one queue of one group can hold: the program's `tasks_queued_max`, and the tasks
/// of calls above them (decision 32, ruling item 11). Each bound of a queue's length reads it.
pub const task_queue_length_max: u32 = tasks_queued_max + call_tasks_max;

comptime {
    std.debug.assert(services_max >= 1);
    std.debug.assert(services_max <= std.math.maxInt(u8));
    std.debug.assert(call_tasks_max == 16_832);
    std.debug.assert(@as(u64, tasks_queued_max) + call_tasks_max <= std.math.maxInt(u32));
}

comptime {
    // The most callbacks one turn holds: one `end` and one `begin` (`core.Heartbeat.Turn`).
    const turn_callbacks_max = pollers_max + batch_max + tasks_per_tick_max;
    std.debug.assert(turn_callbacks_max < std.math.maxInt(u32));
    // The two fields of `Turn.ended` above the records hold the tasks of one run each (decision
    // 30).
    const Turn = core.Heartbeat.Turn;
    const task_bits = Turn.group_task_shift - Turn.task_shift;
    std.debug.assert(tasks_per_tick_max < @as(u64, 1) << task_bits);
}
