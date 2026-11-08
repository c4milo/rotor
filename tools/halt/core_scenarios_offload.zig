//! Halt scenarios for the offload's count of operations out, for the file operations it holds, and
//! for the closes it keeps (decision 18, amendment of 2026-11-06). Only rotor's own code can break
//! these checks, and each scenario reaches its check through the function's own parameters: the
//! count, the inbox that holds it, a slot, the tables, or a descriptor.
//!
//! With each check deleted, the scenario returns: the out array loses an entry, or the inbox
//! answers with the wait it was given, or a list goes on with a slot it must not hold.
const std = @import("std");
const core = @import("core");
const scenario = @import("scenario.zig");

const InFlight = core.offload.InFlight;
const Slot = core.Slot;
const TimerHeap = core.timer_heap.TimerHeap;

const slots_count = 4;

var slots: [slots_count]Slot align(@alignOf(Slot)) = undefined;
var entries: [slots_count]TimerHeap.Entry align(@alignOf(TimerHeap.Entry)) = undefined;
var starts: [slots_count]u64 = undefined;
var heartbeat: core.Heartbeat align(@alignOf(core.Heartbeat)) = undefined;
var groups: core.scheduling.Groups align(@alignOf(core.scheduling.Groups)) = undefined;
var read_bytes: [16]u8 = undefined;
var out: core.offload.OutArray align(@alignOf(core.offload.OutArray)) = undefined;

/// The file the read of `queued_read` names. No read is performed.
const read_descriptor: core.Descriptor = 3;

/// A hand-out at the limit. The backend asks for room first, so this is rotor's own mistake, and
/// a worker's ring could then overflow. The bounds check of the out array halts, and a mutation
/// that wraps the position into the array returns.
fn hand_out_past_the_limit() void {
    var in_flight: InFlight = .init(&out);
    in_flight.count = core.constants.offload_in_flight_max;
    scenario.reached_violation();
    in_flight.note_handed_out(0, read_descriptor);
}

/// A result for an operation the out array does not name. With the check deleted, the count falls
/// by one and the array keeps its one entry.
fn take_back_an_operation_that_is_not_out() void {
    var in_flight: InFlight = .init(&out);
    in_flight.note_handed_out(2, read_descriptor);
    scenario.reached_violation();
    in_flight.note_back(1);
}

/// A loop about to sleep with an operation held and none out: no worker would wake it, and the
/// held operation would wait with nothing to end the wait. The held list names a slot it never
/// links, which the check reads only by its count.
fn sleep_with_an_operation_held_and_none_out() void {
    var inbox = core.inbox.Inbox.init(null, &.{}, null);
    inbox.offload_in_flight.held = .{ .head = 0, .tail = 0, .count = 1 };
    scenario.reached_violation();
    _ = inbox.settle_to_sleep(0, core.constants.ns_per_ms);
}

/// Tables with one read submitted and taken off the pending list, as a backend's flush takes it
/// before it tries the read. Returns the read's slot index.
fn queued_read(tables: *core.Tables) u32 {
    tables.init(&slots, &entries, &starts, &heartbeat, &groups, .{});
    const read = core.Operation.read(1, read_descriptor, &read_bytes, 0);
    _ = tables.submit(&.{read}, &.{});
    const index = tables.next_pending().?;
    tables.take_pending(index);
    return index;
}

/// What a backend's `hand_out` does in the scenario below: nothing.
fn hand_out_nowhere(tables: *core.Tables, index: u32, slot: *Slot) void {
    _ = tables;
    _ = index;
    _ = slot;
}

/// A hold with room. The flush holds an operation only at the limit, and `may_sleep` depends on it.
fn hold_an_operation_while_there_is_room() void {
    var tables: core.Tables = undefined;
    const index = queued_read(&tables);
    var in_flight: InFlight = .empty;
    scenario.reached_violation();
    in_flight.hold(&tables, index);
}

/// A cancel noted for a slot that no cancel marked. The slot is a queued read, so with the check
/// deleted the count reads only its own held list, which is empty.
fn note_a_cancel_that_marked_nothing() void {
    var tables: core.Tables = undefined;
    const index = queued_read(&tables);
    var in_flight: InFlight = .empty;
    scenario.reached_violation();
    in_flight.note_cancel(&tables, index, tables.table.at(index));
}

/// A held operation whose cancel no one noted: the flush would hand it out. The read is held at
/// room, which only the push into the list allows here.
fn hand_out_a_held_operation_whose_cancel_was_not_noted() void {
    var tables: core.Tables = undefined;
    const index = queued_read(&tables);
    var in_flight: InFlight = .empty;
    in_flight.held.push(tables.table.slots, index);
    tables.table.at(index).flags.cancel_requested = true;
    scenario.reached_violation();
    in_flight.flush(&tables, &tables, hand_out_nowhere);
}

/// A close of a descriptor that cannot be open.
fn end_the_held_operations_of_a_negative_descriptor() void {
    var tables: core.Tables = undefined;
    tables.init(&slots, &entries, &starts, &heartbeat, &groups, .{});
    var in_flight: InFlight = .empty;
    scenario.reached_violation();
    in_flight.end_descriptor(&tables, -1);
}

/// A held list with an operation already handed out. With the check deleted, the close ends it,
/// which the tables allow for a `submitted` slot.
fn end_a_held_operation_that_is_not_queued() void {
    var tables: core.Tables = undefined;
    const index = queued_read(&tables);
    var in_flight: InFlight = .empty;
    in_flight.held.push(tables.table.slots, index);
    tables.table.at(index).state = .submitted;
    scenario.reached_violation();
    in_flight.end_descriptor(&tables, read_descriptor);
}

/// A read handed to the close's keep. With the check deleted, nothing is out, and the read is not
/// kept.
fn keep_an_operation_that_is_not_a_close() void {
    var tables: core.Tables = undefined;
    const index = queued_read(&tables);
    var in_flight: InFlight = .init(&out);
    scenario.reached_violation();
    _ = in_flight.keep_close(&tables, index);
}

/// What a backend's close does in the scenario below: nothing.
fn close_nowhere(tables: *core.Tables, index: u32, slot: *Slot) void {
    _ = tables;
    _ = index;
    _ = slot;
}

/// A kept close whose cancel came, on the closing list at a drain. The cancel ends a kept close at
/// once, so the drain must find none marked. With the check deleted, the backend's close runs.
fn settle_a_kept_close_whose_cancel_came() void {
    var tables: core.Tables = undefined;
    tables.init(&slots, &entries, &starts, &heartbeat, &groups, .{});
    _ = tables.submit(&.{core.Operation.close(1, read_descriptor)}, &.{});
    const index = tables.next_pending().?;
    tables.take_pending(index);
    var in_flight: InFlight = .init(&out);
    in_flight.closing.push(tables.table.slots, index);
    tables.table.at(index).flags.cancel_requested = true;
    scenario.reached_violation();
    in_flight.settle_closes(&tables, &tables, close_nowhere);
}

/// What a backend's close does in the scenario below: keeps the close again, whatever is out.
fn close_kept_again(in_flight: *InFlight, index: u32, slot: *Slot) void {
    _ = slot;
    in_flight.closing.push(&slots, index);
}

/// A drain that leaves a close kept with nothing out. No worker would wake a loop that sleeps, and
/// the close would wait with nothing to end the wait. With the check deleted, the close stays on
/// the list.
fn settle_a_close_kept_with_nothing_out() void {
    var tables: core.Tables = undefined;
    tables.init(&slots, &entries, &starts, &heartbeat, &groups, .{});
    _ = tables.submit(&.{core.Operation.close(1, read_descriptor)}, &.{});
    const index = tables.next_pending().?;
    tables.take_pending(index);
    var in_flight: InFlight = .init(&out);
    in_flight.closing.push(tables.table.slots, index);
    scenario.reached_violation();
    in_flight.settle_closes(&tables, &in_flight, close_kept_again);
}

pub const scenarios = [_]scenario.Scenario{
    .{ .name = "offload: hand out past the limit", .run = hand_out_past_the_limit },
    .{
        .name = "offload: take back an operation that is not out",
        .run = take_back_an_operation_that_is_not_out,
    },
    .{
        .name = "offload: sleep with an operation held and none out",
        .run = sleep_with_an_operation_held_and_none_out,
    },
    .{
        .name = "offload: hold an operation while there is room",
        .run = hold_an_operation_while_there_is_room,
    },
    .{
        .name = "offload: note a cancel that marked nothing",
        .run = note_a_cancel_that_marked_nothing,
    },
    .{
        .name = "offload: hand out a held operation whose cancel was not noted",
        .run = hand_out_a_held_operation_whose_cancel_was_not_noted,
    },
    .{
        .name = "offload: end the held operations of a negative descriptor",
        .run = end_the_held_operations_of_a_negative_descriptor,
    },
    .{
        .name = "offload: end a held operation that is not queued",
        .run = end_a_held_operation_that_is_not_queued,
    },
    .{
        .name = "offload: keep an operation that is not a close",
        .run = keep_an_operation_that_is_not_a_close,
    },
    .{
        .name = "offload: settle a kept close whose cancel came",
        .run = settle_a_kept_close_whose_cancel_came,
    },
    .{
        .name = "offload: settle a close kept with nothing out",
        .run = settle_a_close_kept_with_nothing_out,
    },
};
