//! The calls of the public `Loop` that name its scheduling groups (decision 30), and the program's
//! named groups. Each call makes the call of the same name on the backend this process runs. Split
//! from `rotor_loop.zig` for the 500-line limit. `Loop` declares each one, so a caller writes
//! `loop.schedule_in(group, &task)`.
//!
//! The program declares its named groups once, in its root source file, as
//! `pub const rotor_scheduling_groups = .{ .quic = 400, .dns = 100 };`. This file reads that
//! declaration through `@import("root")`, as std reads `std_options`, and every loop of the program
//! reserves the same names at init (decision 30, ruling item 5). Core reads no root file.
const core = @import("core");
const loop_module = @import("rotor_loop.zig");

const Loop = loop_module.Loop;
const SchedulingGroup = core.SchedulingGroup;

const root = @import("root");

/// The program's declaration, or none when its root file declares no `rotor_scheduling_groups`.
const declaration = if (@hasDecl(root, "rotor_scheduling_groups")) root.rotor_scheduling_groups else .{};

/// The program's named groups, which `Named` checks at compile time.
pub const root_groups = core.scheduling.Named(declaration);

/// The group of the program's name `name`: ids 1 to n, in the order of the declaration. The same
/// id names the same group on every loop of the program. An undeclared name fails to compile.
pub fn named_scheduling_group(comptime name: root_groups.Name) core.NamedSchedulingGroup {
    return root_groups.group(name);
}

/// Queues `task` in `group`, a group of this loop (decision 30). Returns `TasksFull` when that
/// group holds `constants.tasks_queued_max` tasks. `schedule_in(.default, task)` is
/// `schedule(task)`. A library names its group in each call: the program hands it the group at
/// init.
pub fn schedule_in(loop: *Loop, group: SchedulingGroup, task: *core.Task) Loop.ScheduleError!void {
    return switch (loop.inner) {
        inline else => |*inner| inner.schedule_in(group, task),
    };
}

/// Inside a task's call only: adds `units`, less than `constants.task_charge_max`, to the cost of
/// the task that runs now. Its static cost, 1 for `Task.init`, pays for its first slices. A task
/// whose work varies does at most `@max(cost, task_budget_left() + 1)` slices, calls this with the
/// slices less its cost when they are more, and schedules itself again when work is left. One run
/// costs at most `task_charge_max` units. Halts outside a task's call.
pub fn charge_task(loop: *Loop, units: u16) void {
    switch (loop.inner) {
        inline else => |*inner| inner.charge_task(units),
    }
}

/// Reserves the lowest free group id with `shares`, in 1 to `constants.scheduling_shares_max`. The
/// named groups hold ids 1 to n from init, so the first reserve returns n + 1. The id belongs to
/// this loop only, until `deinit`: no call gives it back. Only the program calls it, between
/// ticks: inside a tick it halts.
pub fn reserve_scheduling_group(loop: *Loop, shares: u16) Loop.ReserveSchedulingGroupError!SchedulingGroup {
    return switch (loop.inner) {
        inline else => |*inner| inner.reserve_scheduling_group(shares),
    };
}

/// Sets the shares of `.default` or of a reserved group of this loop, in 1 to
/// `constants.scheduling_shares_max`. It counts from the group's next visit. A named group's shares
/// change on this loop only. Only the program calls it.
pub fn set_scheduling_group_shares(loop: *Loop, group: SchedulingGroup, shares: u16) void {
    switch (loop.inner) {
        inline else => |*inner| inner.set_scheduling_group_shares(group, shares),
    }
}
