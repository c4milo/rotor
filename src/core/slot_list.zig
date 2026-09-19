//! `SlotList`: a first-in first-out list of slots, linked through `Slot.next`, so it costs no
//! memory beside the table. A slot is on at most one list at a time: the free list while `free`,
//! a backend's pending list while `queued`, its finished list while `finishing`.
const std = @import("std");
const assert = std.debug.assert;
const slot_module = @import("slot.zig");

const Slot = slot_module.Slot;
const next_none = slot_module.next_none;

pub const SlotList = struct {
    head: u32,
    tail: u32,
    count: u32,

    pub const empty: SlotList = .{ .head = next_none, .tail = next_none, .count = 0 };

    /// Appends the slot at `index`, which must be on no list.
    pub fn push(list: *SlotList, slots: []Slot, index: u32) void {
        assert(index < slots.len);
        assert(slots[index].next == next_none);
        if (list.tail == next_none) {
            assert(list.count == 0);
            list.head = index;
        } else {
            slots[list.tail].next = index;
        }
        list.tail = index;
        list.count += 1;
    }

    /// Removes and returns the oldest slot's index, or null when the list is empty.
    pub fn pop(list: *SlotList, slots: []Slot) ?u32 {
        if (list.head == next_none) {
            assert(list.count == 0);
            return null;
        }
        const index = list.head;
        assert(index < slots.len);
        list.head = slots[index].next;
        if (list.head == next_none) list.tail = next_none;
        slots[index].next = next_none;
        list.count -= 1;
        return index;
    }

    /// The oldest slot's index without removing it.
    pub fn peek(list: *const SlotList) ?u32 {
        return if (list.head == next_none) null else list.head;
    }
};

const testing = std.testing;

fn unlinked(comptime count: usize) [count]Slot {
    var slots: [count]Slot = undefined;
    for (&slots) |*slot| {
        slot.* = std.mem.zeroes(Slot);
        slot.next = next_none;
    }
    return slots;
}

test "slots leave the list in the order they joined it" {
    var slots = unlinked(4);
    var list = SlotList.empty;
    try testing.expectEqual(@as(?u32, null), list.pop(&slots));
    list.push(&slots, 2);
    list.push(&slots, 0);
    list.push(&slots, 3);
    try testing.expectEqual(@as(u32, 3), list.count);
    try testing.expectEqual(@as(?u32, 2), list.peek());
    try testing.expectEqual(@as(?u32, 2), list.pop(&slots));
    try testing.expectEqual(@as(?u32, 0), list.pop(&slots));
    try testing.expectEqual(@as(?u32, 3), list.pop(&slots));
    try testing.expectEqual(@as(?u32, null), list.pop(&slots));
    try testing.expectEqual(@as(u32, 0), list.count);
}

test "a popped slot is unlinked and a list that emptied takes new slots" {
    var slots = unlinked(2);
    var list = SlotList.empty;
    list.push(&slots, 1);
    list.push(&slots, 0);
    try testing.expectEqual(@as(?u32, 1), list.pop(&slots));
    try testing.expectEqual(next_none, slots[1].next);
    try testing.expectEqual(@as(?u32, 0), list.pop(&slots));
    try testing.expectEqual(next_none, list.tail);
    list.push(&slots, 1);
    try testing.expectEqual(@as(?u32, 1), list.pop(&slots));
}
