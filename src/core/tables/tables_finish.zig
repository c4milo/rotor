//! How the tables hand over the final events the loop produced itself: a slot that the loop ends
//! waits on `finished`, and the next `drain_finished` hands its event over and releases the slot
//! (decision 5, rules 1 and 2). Split from `tables.zig` for the 500-line limit. `Tables` declares
//! the public ones, so a caller writes `tables.finish_local(...)`.
const std = @import("std");
const assert = std.debug.assert;
const assert_class_a = @import("../assertion_class.zig").assert_class_a;
const event_module = @import("../event.zig");
const slot_module = @import("../slot.zig");
const deadline = @import("tables_deadline.zig");
const tables_module = @import("tables.zig");

const Event = event_module.Event;
const Slot = slot_module.Slot;
const Tables = tables_module.Tables;

/// The loop produced the operation's final result itself. The slot waits on `finished`, and
/// the next `drain_finished` hands its event over and releases it: never the call that
/// produced the result (decision 5, rule 2).
pub fn finish_local(tables: *Tables, index: u32, result: i32) void {
    // A receive from a group that succeeded took a buffer, which `finish_local_buffer` records.
    assert_class_a(result < 0 or !names_buffer(tables.table.at(index)));
    finish_now(tables, index, result);
}

/// `finish_local` for a single-shot receive from a group that the flush completed: its event
/// names the buffer the call took. The slot holds the id in `len` until the event is handed
/// over, because a receive from a group names no buffer of its own and leaves `len` unused.
pub fn finish_local_buffer(tables: *Tables, index: u32, result: i32, buffer_id: u16) void {
    const slot = tables.table.at(index);
    assert(names_buffer(slot));
    assert(result >= 0);
    slot.len = buffer_id;
    finish_now(tables, index, result);
}

fn finish_now(tables: *Tables, index: u32, result: i32) void {
    const slot = tables.table.at(index);
    assert_class_a(slot.state == .queued or slot.state == .submitted);
    if (slot.heap_position != slot_module.heap_position_none) tables.timers.disarm(index);
    slot.state = .finishing;
    slot.result = result;
    tables.finished.push(tables.table.slots, index);
}

/// Hands the caller the final events the loop produced itself, oldest first, and releases
/// their slots: the moment decision 5, rule 1 names.
pub fn drain_finished(tables: *Tables, events: []Event) u32 {
    var produced: u32 = 0;
    while (produced < events.len) : (produced += 1) {
        const index = tables.finished.pop(tables.table.slots) orelse break;
        const slot = tables.table.at(index);
        assert_class_a(slot.state == .finishing);
        // A repeating timer that was not cancelled has more to come: its event says so and
        // its slot stays the loop's (decision 14, rule 2).
        const again = repeats(slot);
        if (slot.flags.sampled and !again) tables.statistics.finished(index, slot, tables.now_ns);
        // The flags are built in a register and stored with the event. A packed literal with two
        // runtime fields compiled to a read of the old event and a second write (decision 26).
        var flags: Event.Flags = .{};
        flags.more = again;
        flags.dispatched = slot.flags.dispatched;
        events[produced] = .{ .user_data = slot.user_data, .result = slot.result, .flags = flags };
        if (names_buffer(slot) and slot.result >= 0) {
            events[produced].flags.buffer = true;
            events[produced].flags.buffer_id = @intCast(slot.len);
        }
        if (again) deadline.rearm(tables, index, slot) else tables.table.release(index);
    }
    assert(produced <= events.len);
    return produced;
}

/// True for a single-shot receive from a group: an event of it that succeeded names the buffer
/// its bytes are in. A multishot one never finishes locally with a success.
fn names_buffer(slot: *const Slot) bool {
    return slot.flags.buffer_group and !slot.flags.multishot;
}

/// True when this slot is a repeating timer whose caller has not cancelled it, so the event
/// being handed over is one of many and not the last (decision 14, rule 2).
pub fn repeats(slot: *const Slot) bool {
    if (slot.code != .timer or !slot.flags.multishot) return false;
    return !slot.flags.cancel_requested;
}
