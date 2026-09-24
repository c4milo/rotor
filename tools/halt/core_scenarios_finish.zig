//! Halt scenarios for how `core.Tables` ends an operation the loop answered itself. A single-shot
//! receive from a group that succeeded took a buffer, and only `finish_local_buffer` records it,
//! so its event names the buffer. Split from `core_scenarios.zig` for the 500-line limit.
//!
//! Each scenario reaches its assertion through the function's own parameters. With the assertion
//! deleted, each call finishes the slot and returns.
const std = @import("std");
const core = @import("core");
const scenario = @import("scenario.zig");

const Slot = core.Slot;
const TimerHeap = core.timer_heap.TimerHeap;

const slots_count = 4;

var slots: [slots_count]Slot align(@alignOf(Slot)) = undefined;
var entries: [slots_count]TimerHeap.Entry align(@alignOf(TimerHeap.Entry)) = undefined;
var starts: [slots_count]u64 = undefined;
var bytes: [slots_count]u8 = undefined;

const socket = 3;
const group_id = 1;
const buffer_id = 2;
const received_bytes = 5;

/// Submits `operation` and takes it off the pending list, as a backend's flush does before it
/// makes the call. Answers its index.
fn flushed(tables: *core.Tables, operation: core.Operation) u32 {
    tables.init(&slots, &entries, &starts, .{});
    const taken = tables.submit(&.{operation}, &.{});
    std.debug.assert(taken == 1);
    const index = tables.next_pending().?;
    tables.take_pending(index);
    return index;
}

fn single_shot_from_group() core.Operation {
    return .{ .user_data = 1, .kind = .{ .receive = .{
        .socket = socket,
        .target = .{ .group = group_id },
    } } };
}

/// Its event would name no buffer, and the buffer would never go back to its group.
fn finish_a_receive_from_a_group_without_its_buffer() void {
    var tables: core.Tables = undefined;
    const index = flushed(&tables, single_shot_from_group());
    scenario.reached_violation();
    tables.finish_local(index, received_bytes);
}

/// Its event would name a group's buffer the caller never received into.
fn finish_a_receive_into_its_own_buffer_with_a_buffer() void {
    var tables: core.Tables = undefined;
    const index = flushed(&tables, core.Operation.receive(1, socket, &bytes));
    scenario.reached_violation();
    tables.finish_local_buffer(index, received_bytes, buffer_id);
}

/// A receive that failed gave its buffer back, so it has none to name.
fn finish_a_failed_receive_from_a_group_with_a_buffer() void {
    var tables: core.Tables = undefined;
    const index = flushed(&tables, single_shot_from_group());
    scenario.reached_violation();
    tables.finish_local_buffer(index, core.event.result_of(.connection_reset), buffer_id);
}

pub const scenarios = [_]scenario.Scenario{
    .{
        .name = "tables: finish a receive from a group without its buffer",
        .run = finish_a_receive_from_a_group_without_its_buffer,
    },
    .{
        .name = "tables: finish a receive into its own buffer with a buffer",
        .run = finish_a_receive_into_its_own_buffer_with_a_buffer,
    },
    .{
        .name = "tables: finish a failed receive from a group with a buffer",
        .run = finish_a_failed_receive_from_a_group_with_a_buffer,
    },
};
