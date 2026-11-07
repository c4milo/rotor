//! Halt scenarios for a registry of loops in several processes (decision 21): what a caller hands
//! `init_group`, `attach` and `release`. Split from `core_scenarios.zig` for the 500-line limit.
//! Since 2026-11-06 also the wakes a registry keeps (decision 4, amendment of that day): what a
//! backend hands `wake`, `keep_wake` and `close_kept_wakes`.
//!
//! With its assertion deleted, each scenario returns: `init_group` stores what it was handed,
//! `attach` finds no header where it looks and answers an error, `release` clears the entry,
//! `wake` and `keep_wake` read or write the table, and `close_kept_wakes` closes nothing real.
const std = @import("std");
const core = @import("core");
const scenario = @import("scenario.zig");

const Registry = core.mailbox.Registry;
const Wake = core.mailbox.Wake;

const loops = 2;
const registry_bytes = Registry.memory_bytes(loops);
/// A group's memory is aligned to 128, as a mapping is. The scenarios that need memory aligned to
/// 64 only take it 64 bytes in, and the buffer has room for that.
const misalignment_bytes = core.layout.memory_alignment;

var memory: [registry_bytes + misalignment_bytes]u8 align(128) = undefined;
var registry: Registry align(@alignOf(Registry)) = undefined;

/// Made-up descriptors: no scenario reaches a call into the kernel with them.
const wakes = [loops + 1]Wake{
    .{ .send = 10, .watch = 11 },
    .{ .send = 12, .watch = 13 },
    .{ .send = 14, .watch = 15 },
};

fn make_a_group_in_memory_aligned_to_64_only() void {
    scenario.reached_violation();
    registry.init_group(memory[misalignment_bytes..][0..registry_bytes], loops, wakes[0..loops]);
}

fn hand_a_group_more_wakes_than_loops() void {
    scenario.reached_violation();
    registry.init_group(memory[0..registry_bytes], loops, &wakes);
}

fn hand_a_group_a_wake_with_no_descriptor() void {
    const broken = [loops]Wake{ wakes[0], Wake.none };
    scenario.reached_violation();
    registry.init_group(memory[0..registry_bytes], loops, &broken);
}

fn attach_to_memory_aligned_to_64_only() void {
    registry.init_group(memory[0..registry_bytes], loops, wakes[0..loops]);
    scenario.reached_violation();
    registry.attach(memory[misalignment_bytes..][0..registry_bytes]) catch return;
}

fn release_a_loop_of_a_registry_of_one_process() void {
    registry.init(memory[0..registry_bytes], loops);
    registry.set(1, wakes[1].send);
    scenario.reached_violation();
    registry.release(1);
}

fn release_a_loop_nobody_claimed() void {
    registry.init_group(memory[0..registry_bytes], loops, wakes[0..loops]);
    scenario.reached_violation();
    registry.release(1);
}

/// A close that closes nothing: the scenarios hand the registry made-up descriptors.
fn close_nothing(descriptor: core.Descriptor) void {
    _ = descriptor;
}

fn read_the_wake_of_an_id_a_loop_holds() void {
    registry.init(memory[0..registry_bytes], loops);
    registry.keep_wake(1, .{ .send = wakes[1].send, .watch = wakes[1].send });
    registry.set(1, wakes[1].send);
    scenario.reached_violation();
    _ = registry.wake(1);
}

fn keep_a_second_wake_for_one_id() void {
    registry.init(memory[0..registry_bytes], loops);
    registry.keep_wake(1, .{ .send = wakes[1].send, .watch = wakes[1].send });
    scenario.reached_violation();
    registry.keep_wake(1, .{ .send = wakes[2].send, .watch = wakes[2].send });
}

fn keep_a_wake_whose_ends_differ() void {
    registry.init(memory[0..registry_bytes], loops);
    scenario.reached_violation();
    registry.keep_wake(1, wakes[1]);
}

fn close_the_kept_wakes_of_a_group() void {
    registry.init_group(memory[0..registry_bytes], loops, wakes[0..loops]);
    scenario.reached_violation();
    registry.close_kept_wakes(close_nothing);
}

fn close_the_kept_wakes_while_a_loop_holds_an_id() void {
    registry.init(memory[0..registry_bytes], loops);
    registry.keep_wake(1, .{ .send = wakes[1].send, .watch = wakes[1].send });
    registry.set(1, wakes[1].send);
    scenario.reached_violation();
    registry.close_kept_wakes(close_nothing);
}

pub const scenarios = [_]scenario.Scenario{
    .{
        .name = "registry: make a group in memory aligned to 64 only",
        .run = make_a_group_in_memory_aligned_to_64_only,
    },
    .{ .name = "registry: hand a group more wakes than loops", .run = hand_a_group_more_wakes_than_loops },
    .{
        .name = "registry: hand a group a wake with no descriptor",
        .run = hand_a_group_a_wake_with_no_descriptor,
    },
    .{ .name = "registry: attach to memory aligned to 64 only", .run = attach_to_memory_aligned_to_64_only },
    .{
        .name = "registry: release a loop of a registry of one process",
        .run = release_a_loop_of_a_registry_of_one_process,
    },
    .{ .name = "registry: release a loop nobody claimed", .run = release_a_loop_nobody_claimed },
    .{
        .name = "registry: read the wake of an id a loop holds",
        .run = read_the_wake_of_an_id_a_loop_holds,
    },
    .{ .name = "registry: keep a second wake for one id", .run = keep_a_second_wake_for_one_id },
    .{ .name = "registry: keep a wake whose ends differ", .run = keep_a_wake_whose_ends_differ },
    .{ .name = "registry: close the kept wakes of a group", .run = close_the_kept_wakes_of_a_group },
    .{
        .name = "registry: close the kept wakes while a loop holds an id",
        .run = close_the_kept_wakes_while_a_loop_holds_an_id,
    },
};
