//! `Waiters`: the table from a descriptor to the operations waiting for it to become readable or
//! writable (decision 12, point 2). kqueue knows one registration per descriptor and filter, and
//! its user data is one word, so the loop keeps the lists itself, linked through `Slot.next`.
//!
//! The table is touched when an operation has to wait, when one is cancelled, when readiness
//! arrives, and at close: never on the path of an operation that completes at once.
//!
//! It is an open-addressing table over memory the caller handed in, with linear probing. Its
//! capacity is a power of two with two entries per slot of the slot table, and at most one entry
//! per slot can be in use, so it is never more than half full. An entry whose two lists are
//! empty is removed by shifting the entries after it back, so the table holds no tombstones and
//! a probe ends at the first vacant entry.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const constants = @import("constants.zig");

const Slot = core.Slot;
const SlotList = core.slot_list.SlotList;
const next_none = core.slot.next_none;

pub const Filter = enum(u1) { read, write };

const filter_count = 2;

/// The descriptor of a vacant entry. No open descriptor is negative.
const descriptor_vacant: core.Descriptor = -1;

/// Fibonacci hashing: the multiplier is 2^32 divided by the golden ratio, which spreads
/// consecutive descriptors, the common case, across the table.
const hash_multiplier: u32 = 0x9E37_79B1;
const hash_bits = 32;

pub const Entry = struct {
    descriptor: core.Descriptor,
    lists: [filter_count]SlotList,

    const vacant: Entry = .{
        .descriptor = descriptor_vacant,
        .lists = .{ SlotList.empty, SlotList.empty },
    };

    fn is_idle(entry: *const Entry) bool {
        return entry.lists[0].count == 0 and entry.lists[1].count == 0;
    }
};

pub const Waiters = struct {
    entries: []Entry,
    /// Entries in use, at most half of `entries.len`.
    used: u32,

    /// The entries a slot table of `operations` slots needs.
    pub fn capacity_for(operations: u32) u32 {
        assert(operations >= 1);
        assert(operations <= core.constants.operations_max);
        const wanted = operations * constants.descriptor_entries_per_slot;
        return std.math.ceilPowerOfTwoAssert(u32, wanted);
    }

    pub fn init(waiters: *Waiters, entries: []Entry) void {
        assert(entries.len >= constants.descriptor_entries_per_slot);
        assert(std.math.isPowerOfTwo(entries.len));
        for (entries) |*entry| entry.* = Entry.vacant;
        waiters.* = .{ .entries = entries, .used = 0 };
    }

    /// Appends the slot at `index` to the waiters of `descriptor` on `filter`. True when it is
    /// the first there, and the caller must register the filter with the kernel.
    pub fn add(
        waiters: *Waiters,
        slots: []Slot,
        descriptor: core.Descriptor,
        filter: Filter,
        index: u32,
    ) bool {
        assert(descriptor >= 0);
        const entry = waiters.find(descriptor) orelse waiters.claim(descriptor);
        const list = &entry.lists[@intFromEnum(filter)];
        list.push(slots, index);
        return list.count == 1;
    }

    /// The oldest waiter of `descriptor` on `filter`, which stays on its list.
    pub fn first(waiters: *Waiters, descriptor: core.Descriptor, filter: Filter) ?u32 {
        const entry = waiters.find(descriptor) orelse return null;
        return entry.lists[@intFromEnum(filter)].peek();
    }

    /// Removes and returns the oldest waiter of `descriptor` on `filter`.
    pub fn pop(
        waiters: *Waiters,
        slots: []Slot,
        descriptor: core.Descriptor,
        filter: Filter,
    ) ?u32 {
        const entry = waiters.find(descriptor) orelse return null;
        const index = entry.lists[@intFromEnum(filter)].pop(slots) orelse return null;
        if (entry.is_idle()) waiters.release(entry);
        return index;
    }

    /// Removes and returns the oldest waiter of `descriptor` on either filter, reads first: what
    /// a close calls until it answers null.
    pub fn pop_any(waiters: *Waiters, slots: []Slot, descriptor: core.Descriptor) ?u32 {
        if (waiters.pop(slots, descriptor, .read)) |index| return index;
        return waiters.pop(slots, descriptor, .write);
    }

    /// Removes the slot at `index` from the waiters of `descriptor` on `filter`, wherever it is
    /// on the list: what a cancel calls. True when the slot was there.
    pub fn remove(
        waiters: *Waiters,
        slots: []Slot,
        descriptor: core.Descriptor,
        filter: Filter,
        index: u32,
    ) bool {
        const entry = waiters.find(descriptor) orelse return false;
        const list = &entry.lists[@intFromEnum(filter)];
        if (!unlink(list, slots, index)) return false;
        if (entry.is_idle()) waiters.release(entry);
        return true;
    }

    /// How many operations wait for `descriptor` on `filter`.
    pub fn count(waiters: *Waiters, descriptor: core.Descriptor, filter: Filter) u32 {
        const entry = waiters.find(descriptor) orelse return 0;
        return entry.lists[@intFromEnum(filter)].count;
    }

    fn mask(waiters: *const Waiters) u32 {
        return @intCast(waiters.entries.len - 1);
    }

    fn home(waiters: *const Waiters, descriptor: core.Descriptor) u32 {
        assert(descriptor >= 0);
        const key: u32 = @intCast(descriptor);
        const bits = std.math.log2_int(usize, waiters.entries.len);
        if (bits == 0) return 0;
        return (key *% hash_multiplier) >> @intCast(hash_bits - @as(u32, bits));
    }

    /// The entry of `descriptor`, or null. The probe ends at the first vacant entry, and the
    /// table is at most half full, so it ends.
    fn find(waiters: *Waiters, descriptor: core.Descriptor) ?*Entry {
        var position = waiters.home(descriptor);
        var probed: u32 = 0;
        while (probed < waiters.entries.len) : (probed += 1) {
            const entry = &waiters.entries[position];
            if (entry.descriptor == descriptor) return entry;
            if (entry.descriptor == descriptor_vacant) return null;
            position = (position + 1) & waiters.mask();
        }
        unreachable;
    }

    fn claim(waiters: *Waiters, descriptor: core.Descriptor) *Entry {
        assert(waiters.used * constants.descriptor_entries_per_slot < waiters.entries.len + 1);
        var position = waiters.home(descriptor);
        var probed: u32 = 0;
        while (probed < waiters.entries.len) : (probed += 1) {
            const entry = &waiters.entries[position];
            if (entry.descriptor == descriptor_vacant) {
                entry.descriptor = descriptor;
                waiters.used += 1;
                return entry;
            }
            position = (position + 1) & waiters.mask();
        }
        unreachable;
    }

    /// Vacates `entry` and shifts back every entry after it that its vacancy would cut off from
    /// its home, so a later probe still reaches it.
    fn release(waiters: *Waiters, entry: *Entry) void {
        assert(entry.is_idle());
        assert(waiters.used >= 1);
        const offset_bytes = @intFromPtr(entry) - @intFromPtr(waiters.entries.ptr);
        var hole: u32 = @intCast(offset_bytes / @sizeOf(Entry));
        var position = (hole + 1) & waiters.mask();
        var probed: u32 = 0;
        while (probed < waiters.entries.len) : (probed += 1) {
            const candidate = &waiters.entries[position];
            if (candidate.descriptor == descriptor_vacant) break;
            const candidate_home = waiters.home(candidate.descriptor);
            const distance_from_home = (position -% candidate_home) & waiters.mask();
            const distance_from_hole = (position -% hole) & waiters.mask();
            if (distance_from_home >= distance_from_hole) {
                waiters.entries[hole] = candidate.*;
                hole = position;
            }
            position = (position + 1) & waiters.mask();
        }
        waiters.entries[hole] = Entry.vacant;
        waiters.used -= 1;
    }
};

/// Takes the slot at `index` off `list`, wherever it is. A list is short: the operations waiting
/// on one descriptor and one filter.
fn unlink(list: *SlotList, slots: []Slot, index: u32) bool {
    var previous: u32 = next_none;
    var current = list.head;
    var walked: u32 = 0;
    while (current != next_none and walked < list.count) : (walked += 1) {
        if (current == index) {
            const next = slots[current].next;
            if (previous == next_none) list.head = next else slots[previous].next = next;
            if (list.tail == current) list.tail = previous;
            slots[current].next = next_none;
            list.count -= 1;
            return true;
        }
        previous = current;
        current = slots[current].next;
    }
    return false;
}
