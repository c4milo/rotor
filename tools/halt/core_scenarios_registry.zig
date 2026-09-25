//! Halt scenarios for a registry of loops in several processes (decision 21): what a caller hands
//! `init_group`, `attach` and `release`. Split from `core_scenarios.zig` for the 500-line limit.
//!
//! With its assertion deleted, each scenario returns: `init_group` stores what it was handed,
//! `attach` finds no header where it looks and answers an error, and `release` clears the entry.
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
};
