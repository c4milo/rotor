//! Halt scenarios of `kqueue_wake.zig`: the descriptor a registry of one process keeps for a loop
//! (decision 4, amendment of 2026-11-06). Split from `kqueue_scenarios.zig` for the 500-line limit.
//!
//! With its assertion deleted, each scenario returns. `claim` in a group is handed a kqueue no
//! process has open, so libc answers `EBADF` and `claim` returns the error. `release` in a group
//! points a pipe's read end at a real kqueue, which libc allows. `release` with a stand-in that is
//! not open closes that number, which libc refuses, and returns.
const std = @import("std");
const core = @import("core");
const kqueue = @import("kqueue");
const scenario = @import("scenario.zig");

const Registry = core.mailbox.Registry;
const Wake = core.mailbox.Wake;
const wake_module = kqueue.wake_module;

const loops = 2;
/// A group's memory is aligned to 128, as a mapping is.
var memory: [Registry.memory_bytes(loops)]u8 align(128) = undefined;
var registry: Registry align(@alignOf(Registry)) = undefined;

/// A descriptor no process has open. It is high rather than 0 so that a call made with it answers
/// `EBADF` at once.
const closed_descriptor: core.Descriptor = 4096;

/// A pipe has a read end and a write end.
const pipe_ends = 2;

/// A group whose wakes are the read end of one real pipe, so a `dup2` onto them succeeds. A
/// scenario that cannot make the pipe returns without the marker, and the check counts that as a
/// failure.
fn a_group_of_one_pipe() ?Wake {
    var ends: [pipe_ends]std.c.fd_t = undefined;
    if (std.c.pipe(&ends) != 0) return null;
    const wake: Wake = .{ .send = ends[0], .watch = ends[0] };
    const wakes = [loops]Wake{ wake, wake };
    registry.init_group(&memory, loops, &wakes);
    return wake;
}

fn claim_a_wake_in_a_group() void {
    _ = a_group_of_one_pipe() orelse return;
    scenario.reached_violation();
    _ = wake_module.claim(&registry, 0, closed_descriptor) catch return;
}

fn release_a_wake_in_a_group() void {
    const wake = a_group_of_one_pipe() orelse return;
    registry.set(0, wake.send);
    const stand_in = std.c.kqueue();
    if (stand_in < 0) return;
    scenario.reached_violation();
    wake_module.release(&registry, 0, stand_in);
}

fn release_a_wake_to_a_stand_in_that_is_not_open() void {
    var ends: [pipe_ends]std.c.fd_t = undefined;
    if (std.c.pipe(&ends) != 0) return;
    registry.init(&memory, loops);
    registry.set(0, ends[0]);
    scenario.reached_violation();
    wake_module.release(&registry, 0, closed_descriptor);
}

pub const scenarios = [_]scenario.Scenario{
    .{ .name = "wake: claim a wake in a group", .run = claim_a_wake_in_a_group },
    .{ .name = "wake: release a wake in a group", .run = release_a_wake_in_a_group },
    .{
        .name = "wake: release a wake to a stand-in that is not open",
        .run = release_a_wake_to_a_stand_in_that_is_not_open,
    },
};
