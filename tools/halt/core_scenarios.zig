//! Halt scenarios for the `core` module: one per assertion a caller's mistake can reach. Each
//! name says what the scenario does wrong.
const std = @import("std");
const core = @import("core");
const scenario = @import("scenario.zig");

const Slot = core.Slot;
const SlotTable = core.slot_table.SlotTable;
const TimerHeap = core.timer_heap.TimerHeap;

const slots_count = 4;

var slots: [slots_count]Slot = undefined;
var entries: [slots_count]TimerHeap.Entry = undefined;

fn table() SlotTable {
    var result: SlotTable = undefined;
    result.init(&slots);
    return result;
}

/// A second slot stays claimed, so the table's count of free slots stays below its capacity and
/// the state check is the one assertion that can refuse the second release.
fn release_a_free_slot() void {
    var slot_table = table();
    const index = slot_table.claim().?;
    _ = slot_table.claim().?;
    slot_table.release(index);
    scenario.reached_violation();
    slot_table.release(index);
}

fn release_a_slot_with_a_deadline_armed() void {
    var slot_table = table();
    var heap: TimerHeap = undefined;
    heap.init(&entries, &slots);
    const index = slot_table.claim().?;
    heap.arm(index, 1);
    scenario.reached_violation();
    slot_table.release(index);
}

fn look_up_a_handle_outside_the_table() void {
    var slot_table = table();
    scenario.reached_violation();
    _ = slot_table.lookup(.{ .index = slots_count, .generation = 1 });
}

fn arm_a_slot_twice() void {
    var slot_table = table();
    var heap: TimerHeap = undefined;
    heap.init(&entries, &slots);
    const index = slot_table.claim().?;
    heap.arm(index, 1);
    scenario.reached_violation();
    heap.arm(index, 2);
}

fn disarm_a_slot_that_is_not_armed() void {
    var slot_table = table();
    var heap: TimerHeap = undefined;
    heap.init(&entries, &slots);
    const index = slot_table.claim().?;
    scenario.reached_violation();
    heap.disarm(index);
}

fn submit_a_transfer_of_no_bytes() void {
    const operation: core.Operation = .{ .user_data = 1, .kind = .{ .send = .{
        .socket = 3,
        .buffer = .{ .bytes = &.{} },
    } } };
    scenario.reached_violation();
    operation.assert_valid();
}

fn submit_a_timer_with_a_deadline_of_its_own() void {
    const operation: core.Operation = .{
        .user_data = 1,
        .timeout_ns = 1,
        .kind = .{ .timer = .{ .after_ns = 1 } },
    };
    scenario.reached_violation();
    operation.assert_valid();
}

fn post_a_tag_above_the_limit() void {
    const operation: core.Operation = .{ .user_data = 1, .kind = .{ .post = .{
        .target = 1,
        .message = .{ .payload = 0, .tag = core.constants.message_tag_max + 1 },
    } } };
    scenario.reached_violation();
    operation.assert_valid();
}

/// The operation has left the pending list, as after a backend's flush, so the count of slots
/// in use is the one check that can see it: a scenario whose operation is still queued halts on
/// the lists as well, and would pass with this assertion gone.
fn end_a_loop_whose_operation_the_kernel_holds() void {
    var tables: core.Tables = undefined;
    tables.init(&slots, &entries, 0);
    const timer = [_]core.Operation{
        .{ .user_data = 1, .kind = .{ .timer = .{ .after_ns = 1 } } },
    };
    _ = tables.submit(&timer, &.{});
    const index = tables.pending.pop(tables.table.slots).?;
    const slot = tables.table.at(index);
    slot.state = .submitted;
    tables.arm(index, slot);
    scenario.reached_violation();
    tables.assert_empty();
}

const scenarios = [_]scenario.Scenario{
    .{ .name = "slot_table: release a free slot", .run = release_a_free_slot },
    .{
        .name = "slot_table: release a slot with a deadline armed",
        .run = release_a_slot_with_a_deadline_armed,
    },
    .{
        .name = "slot_table: look up a handle outside the table",
        .run = look_up_a_handle_outside_the_table,
    },
    .{ .name = "timer_heap: arm a slot twice", .run = arm_a_slot_twice },
    .{
        .name = "timer_heap: disarm a slot that is not armed",
        .run = disarm_a_slot_that_is_not_armed,
    },
    .{ .name = "operation: submit a transfer of no bytes", .run = submit_a_transfer_of_no_bytes },
    .{
        .name = "operation: submit a timer with a deadline of its own",
        .run = submit_a_timer_with_a_deadline_of_its_own,
    },
    .{ .name = "operation: post a tag above the limit", .run = post_a_tag_above_the_limit },
    .{
        .name = "tables: end a loop whose operation the kernel holds",
        .run = end_a_loop_whose_operation_the_kernel_holds,
    },
};

pub fn main(init: std.process.Init) !void {
    return scenario.main(init, &scenarios);
}
