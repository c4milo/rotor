//! `TimerHeap`, the 4-ary min-heap of deadlines, indexed by slot (decision 5, rule 5). Every
//! operation deadline and every standalone timer of a loop is one entry. The loop passes
//! `earliest_ns` to its one syscall per tick as the wait bound, then calls `pop_due` until it
//! answers null. The order is ascending (`deadline_ns`, `sequence`): entries with one deadline
//! come out in the order they were armed, so timer order is the same on every backend.
//!
//! The memory is the caller's. `entries` is the capacity, and `slots` are the slot table's: the
//! heap keeps the `heap_position` of every armed slot current, so `disarm` finds an entry without
//! a search. A sift keeps the entry it is placing in a local and moves each entry on its path one
//! level. Every write goes through `place`, which also points the entry's slot at the position.
//!
//! One of the six hot files decision 7 names, and this is its plain version: no `inline`, no
//! many-item pointer, no `@setRuntimeSafety`, no ledger row. Decision 8: `arm`, `disarm` and
//! `pop_due` carry class A assertions only, which read what the function loads anyway. The O(n)
//! check is `assert_heap`, class D, which the tests call after every step.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const slot_module = @import("slot.zig");

const Slot = slot_module.Slot;
const heap_position_none = slot_module.heap_position_none;
const arity = constants.timer_heap_arity;

/// The most levels a heap of `constants.operations_max` entries has below its root: 10 for 2^20
/// entries of arity 4. One sift moves at most that many entries, and asserts its trip count.
const depth_max: u32 = depth_of(constants.operations_max - 1);

pub const TimerHeap = struct {
    /// The capacity. `entries[0..count]` is the heap.
    entries: []Entry,
    /// The slot table's slots. The heap keeps `slots[entry.slot].heap_position` current.
    slots: []Slot,
    count: u32,
    /// What the next `arm` stamps on its entry. Rises by one per arm, wrapping.
    sequence: u32,

    /// 16 bytes, aligned to 8, held there by a comptime assert. `deadline_ns` comes first: every
    /// comparison reads it, and most read nothing else.
    pub const Entry = extern struct {
        deadline_ns: u64,
        /// The heap's `sequence` when the entry was armed: the order among equal deadlines.
        sequence: u32,
        /// The index of the slot the entry belongs to.
        slot: u32,
    };

    /// `entries.len` is in [1, `constants.operations_max`] and at most `slots.len`. `init` leaves
    /// the slots alone: `Slot.fill` sets `heap_position` to none on every claim.
    pub fn init(heap: *TimerHeap, entries: []Entry, slots: []Slot) void {
        assert(entries.len >= 1);
        assert(entries.len <= constants.operations_max);
        assert(entries.len <= slots.len);
        heap.* = .{ .entries = entries, .slots = slots, .count = 0, .sequence = 0 };
    }

    /// The slot must not be armed and the heap must have room. Both are asserted, and neither is
    /// an error value, because the loop's accounting guarantees them.
    pub fn arm(heap: *TimerHeap, slot_index: u32, deadline_ns: u64) void {
        assert(heap.count < heap.entries.len);
        assert(heap.slots[slot_index].heap_position == heap_position_none);
        const entry: Entry = .{
            .deadline_ns = deadline_ns,
            .sequence = heap.sequence,
            .slot = slot_index,
        };
        heap.sequence +%= 1;
        heap.count += 1;
        heap.sift_up(heap.count - 1, entry);
    }

    /// The slot must be armed. Removes its entry in O(log n) through `heap_position`, which is none
    /// afterwards. None is above every count, so the first assertion refuses an unarmed slot.
    pub fn disarm(heap: *TimerHeap, slot_index: u32) void {
        const position = heap.slots[slot_index].heap_position;
        assert(position < heap.count);
        assert(heap.entries[position].slot == slot_index);
        heap.remove(position);
    }

    pub fn is_armed(heap: *const TimerHeap, slot_index: u32) bool {
        const position = heap.slots[slot_index].heap_position;
        assert(position < heap.count or position == heap_position_none);
        return position != heap_position_none;
    }

    /// The earliest deadline, or null when the heap is empty. The loop passes it to its one
    /// syscall per tick as the wait bound.
    pub fn earliest_ns(heap: *const TimerHeap) ?u64 {
        assert(heap.count <= heap.entries.len);
        if (heap.count == 0) return null;
        return heap.entries[0].deadline_ns;
    }

    /// When the earliest deadline is at or before `now_ns`, removes that entry and returns its
    /// slot index, with the slot's `heap_position` back at `heap_position_none`. Null otherwise.
    pub fn pop_due(heap: *TimerHeap, now_ns: u64) ?u32 {
        if (heap.count == 0) return null;
        const root = heap.entries[0];
        if (root.deadline_ns > now_ns) return null;
        assert(heap.slots[root.slot].heap_position == 0);
        heap.remove(0);
        return root.slot;
    }

    /// Decision 8 class D, O(n): every child orders at or after its parent, and every entry's slot
    /// points back at the entry's position. Tests call it after each step; no production path does.
    pub fn assert_heap(heap: *const TimerHeap) void {
        assert(heap.count <= heap.entries.len);
        assert(heap.first_violation() == null);
    }

    /// The position of the first entry that orders before its parent, or whose slot points
    /// elsewhere, or null. It is a value so that a test can show the check works and name a seed.
    fn first_violation(heap: *const TimerHeap) ?u32 {
        for (heap.entries[0..heap.count], 0..) |entry, index| {
            const position: u32 = @intCast(index);
            if (heap.slots[entry.slot].heap_position != position) return position;
            if (position == 0) continue;
            if (before(entry, heap.entries[parent_of(position)])) return position;
        }
        return null;
    }

    /// Removes the entry at `position` and puts the last entry in its place. The last entry came
    /// from anywhere in the heap, so it may order before its new parent, and then it moves up.
    fn remove(heap: *TimerHeap, position: u32) void {
        assert(position < heap.count);
        heap.slots[heap.entries[position].slot].heap_position = heap_position_none;
        heap.count -= 1;
        if (position == heap.count) return;
        const last = heap.entries[heap.count];
        if (position > 0 and before(last, heap.entries[parent_of(position)])) {
            heap.sift_up(position, last);
        } else {
            heap.sift_down(position, last);
        }
    }

    /// Places `entry` at `start` or above it: every parent that orders after it moves down a level.
    fn sift_up(heap: *TimerHeap, start: u32, entry: Entry) void {
        var position = start;
        var moves: u32 = 0;
        while (position > 0) : (moves += 1) {
            assert(moves < depth_max);
            const parent = parent_of(position);
            if (!before(entry, heap.entries[parent])) break;
            heap.place(position, heap.entries[parent]);
            position = parent;
        }
        heap.place(position, entry);
    }

    /// Places `entry` at `start` or below it: at each level the earliest child moves up a level
    /// when it orders before `entry`.
    fn sift_down(heap: *TimerHeap, start: u32, entry: Entry) void {
        var position = start;
        var moves: u32 = 0;
        while (first_child_of(position) < heap.count) : (moves += 1) {
            assert(moves < depth_max);
            const child = heap.earliest_child_of(position);
            if (!before(heap.entries[child], entry)) break;
            heap.place(position, heap.entries[child]);
            position = child;
        }
        heap.place(position, entry);
    }

    /// The position of the child of `position` that orders first. `position` has a child.
    fn earliest_child_of(heap: *const TimerHeap, position: u32) u32 {
        const first = first_child_of(position);
        assert(first < heap.count);
        var earliest = first;
        var sibling: u32 = 1;
        while (sibling < arity) : (sibling += 1) {
            const child = first + sibling;
            if (child >= heap.count) break;
            if (before(heap.entries[child], heap.entries[earliest])) earliest = child;
        }
        assert(earliest >= first and earliest < heap.count);
        return earliest;
    }

    /// Writes `entry` at `position` and points its slot there. No entry moves any other way.
    fn place(heap: *TimerHeap, position: u32, entry: Entry) void {
        assert(position < heap.count);
        heap.entries[position] = entry;
        heap.slots[entry.slot].heap_position = position;
    }

    /// True when `a` comes out before `b`: the earlier deadline, and among equal deadlines the
    /// earlier arm. `sequence` wraps, so two sequences compare by their wrapping difference read as
    /// a signed 32-bit value. That holds while the live entries span fewer than 2^31 arms. Past
    /// that span only the order among equal deadlines is affected, never the order of deadlines.
    fn before(a: Entry, b: Entry) bool {
        if (a.deadline_ns != b.deadline_ns) return a.deadline_ns < b.deadline_ns;
        const difference: i32 = @bitCast(a.sequence -% b.sequence);
        return difference < 0;
    }
};

fn parent_of(position: u32) u32 {
    assert(position >= 1);
    return (position - 1) / arity;
}

/// The children of `position` are `first_child_of(position)` and the `arity - 1` after it.
fn first_child_of(position: u32) u32 {
    assert(position < constants.operations_max);
    return position * arity + 1;
}

/// The level of `position`: 0 for the root, and one more than its parent's for every other.
fn depth_of(position: u32) u32 {
    var depth: u32 = 0;
    var ancestor = position;
    while (ancestor > 0) : (depth += 1) {
        assert(depth < @bitSizeOf(u32)); // Each step at least halves the position.
        ancestor = parent_of(ancestor);
    }
    return depth;
}

comptime {
    assert(@sizeOf(TimerHeap.Entry) == 16);
    assert(@alignOf(TimerHeap.Entry) == 8);
    assert(@offsetOf(TimerHeap.Entry, "deadline_ns") == 0);
    // `first_child_of` and the siblings after it fit 32 bits for every position a heap can hold.
    assert(constants.operations_max <= (std.math.maxInt(u32) - arity) / arity);
    // No position equals `heap_position_none`, so `position < count` refuses an unarmed slot.
    assert(constants.operations_max < heap_position_none);
}

const testing = std.testing;
const Random = @import("random.zig").Random;

/// More slots than entries, so a slot index is not a position.
const test_slots = 64;
const test_entries = 48;
/// Coprime with `test_entries`, so `scattered` visits every value below `test_entries` once.
const test_stride = 29;
/// A `now_ns` at which every entry is due.
const now_ns_last: u64 = std.math.maxInt(u64);

/// `index` moved out of order, so a test arms slots in an order that is not their indices'.
fn scattered(index: usize) u32 {
    comptime assert(std.math.gcd(test_stride, test_entries) == 1);
    return @intCast(index * test_stride % test_entries);
}

/// The caller's memory and the heap over it. `init` runs in place, because the heap keeps slices
/// of the two arrays. The entries stay undefined: the heap reads no entry it did not write.
const Fixture = struct {
    slots: [test_slots]Slot,
    entries: [test_entries]TimerHeap.Entry,
    heap: TimerHeap,

    fn init(fixture: *Fixture) void {
        for (&fixture.slots) |*slot| {
            slot.* = std.mem.zeroes(Slot);
            slot.heap_position = heap_position_none;
        }
        fixture.heap.init(&fixture.entries, &fixture.slots);
    }
};

test "pop_due returns null before the deadline and the slot at the deadline" {
    var fixture: Fixture = undefined;
    fixture.init();
    const heap = &fixture.heap;
    try testing.expectEqual(null, heap.earliest_ns());
    try testing.expectEqual(null, heap.pop_due(now_ns_last));
    heap.arm(7, 1000);
    heap.assert_heap();
    try testing.expect(heap.is_armed(7) and !heap.is_armed(6));
    try testing.expectEqual(1000, heap.earliest_ns());
    try testing.expectEqual(null, heap.pop_due(999));
    try testing.expect(heap.is_armed(7));
    try testing.expectEqual(7, heap.pop_due(1000));
    heap.assert_heap();
    try testing.expect(!heap.is_armed(7));
    try testing.expectEqual(heap_position_none, fixture.slots[7].heap_position);
    try testing.expectEqual(null, heap.pop_due(1000));
    heap.arm(7, 50); // The slot arms again, and an entry past its deadline is due too.
    try testing.expectEqual(7, heap.pop_due(51));
    try testing.expectEqual(0, heap.count);
}

/// Arms every entry, arm `index` on slot `scattered(index)` with deadline `slot % deadlines`, so
/// neither slots nor deadlines rise with arm order. Expects them back by deadline, then by arm.
fn expect_order(deadlines: u32, sequence_first: u32) !void {
    var fixture: Fixture = undefined;
    fixture.init();
    const heap = &fixture.heap;
    heap.sequence = sequence_first;
    for (0..test_entries) |index| {
        heap.arm(scattered(index), scattered(index) % deadlines);
        heap.assert_heap();
    }
    try testing.expectEqual(test_entries, heap.count);
    for (0..deadlines) |deadline| {
        const deadline_ns: u64 = deadline;
        try testing.expectEqual(deadline_ns, heap.earliest_ns());
        for (0..test_entries) |index| {
            if (scattered(index) % deadlines != deadline_ns) continue;
            try testing.expectEqual(scattered(index), heap.pop_due(deadline_ns));
            heap.assert_heap();
        }
        try testing.expectEqual(null, heap.pop_due(deadline_ns));
    }
    try testing.expectEqual(0, heap.count);
}

test "entries come out in deadline order" {
    try expect_order(test_entries, 0);
}

test "equal deadlines come out in arm order" {
    try expect_order(3, 0);
}

test "the sequence comparison survives a wrap" {
    // The arms stamp maxInt - 20 to maxInt and then 0 to 26, 16 of them at each deadline.
    try expect_order(3, std.math.maxInt(u32) - 20);
}

/// Arms slot i with `deadlines[i]`, disarms `disarmed`, drains the heap, and arms the slot again.
fn expect_disarm(deadlines: []const u64, disarmed: u32) !void {
    var fixture: Fixture = undefined;
    fixture.init();
    const heap = &fixture.heap;
    for (deadlines, 0..) |deadline_ns, slot| heap.arm(@intCast(slot), deadline_ns);
    // The case is the one its comment names only while slot i sits at position i.
    for (0..deadlines.len) |slot| try testing.expectEqual(slot, fixture.slots[slot].heap_position);
    heap.disarm(disarmed);
    heap.assert_heap();
    try testing.expect(!heap.is_armed(disarmed));
    try testing.expectEqual(heap_position_none, fixture.slots[disarmed].heap_position);
    try testing.expectEqual(deadlines.len - 1, heap.count);
    var previous_ns: u64 = 0;
    for (1..deadlines.len) |_| {
        const slot = heap.pop_due(now_ns_last).?;
        heap.assert_heap();
        try testing.expect(slot != disarmed);
        try testing.expect(deadlines[slot] >= previous_ns);
        previous_ns = deadlines[slot];
    }
    try testing.expectEqual(null, heap.pop_due(now_ns_last));
    heap.arm(disarmed, 1);
    try testing.expectEqual(disarmed, heap.pop_due(1));
}

test "disarm of the root, of a leaf and of a middle entry keeps the heap valid" {
    comptime assert(arity == 4);
    // Deadlines by position. Armed in this order no entry moves, so slot i sits at position i:
    // position 1 is the parent of 5 to 8, position 2 of 9 to 12, and position 3 of 13 to 15.
    const deadlines = [_]u64{ 10, 100, 20, 30, 40, 110, 120, 130, 140, 21, 22, 23, 24, 31, 32, 33 };
    try expect_disarm(&deadlines, 0); // The root: the last entry, 33, goes down from the top.
    try expect_disarm(&deadlines, 15); // The last leaf: nothing moves.
    try expect_disarm(&deadlines, 5); // A leaf under 100: the last entry, 33, goes up past it.
    try expect_disarm(&deadlines, 2); // Over 21 to 24: the last entry, 33, goes down below them.
    try expect_disarm(&deadlines, 1); // Over 110 to 140: the last entry, 33, stays where it lands.
}

test "first_violation names an entry before its parent and a slot that points elsewhere" {
    var fixture: Fixture = undefined;
    fixture.init();
    const heap = &fixture.heap;
    for (0..6) |slot| heap.arm(@intCast(slot), 10 * (slot + 1));
    try testing.expectEqual(null, heap.first_violation());
    // Position 5 is a child of position 1, which holds deadline 20 and sequence 1.
    fixture.entries[5].deadline_ns = 19;
    try testing.expectEqual(5, heap.first_violation());
    fixture.entries[5] = .{ .deadline_ns = 20, .sequence = 0, .slot = 5 };
    try testing.expectEqual(5, heap.first_violation());
    fixture.entries[5].sequence = 5;
    try testing.expectEqual(null, heap.first_violation());
    fixture.slots[2].heap_position = 3;
    try testing.expectEqual(2, heap.first_violation());
}

test "depth_max is the level of the last position a full heap holds" {
    comptime assert(arity == 4);
    // Level 1 is positions 1 to 4, level 2 is 5 to 20, level 3 is 21 to 84.
    const positions = [_]u32{ 0, 1, 4, 5, 20, 21, 84, 85 };
    const depths = [_]u32{ 0, 1, 1, 2, 2, 3, 3, 4 };
    for (positions, depths) |position, depth| try testing.expectEqual(depth, depth_of(position));
    try testing.expectEqual(10, depth_max);
}

/// A property run draws its deadlines below this: few, so that most arms tie with a live entry.
const property_deadlines = 12;
const property_steps = 1024;
/// A run arms on 3 steps in `arm_odds` for this many steps, then on 1 step for as many, and so
/// on, so the heap fills to its capacity and drains to nothing several times.
const property_phase_steps = 128;
const arm_odds = 4;

/// What the heap must agree with: each armed slot's deadline and the number of its arm, which
/// never wraps, scanned for the minimum.
const Model = struct {
    /// Null for a slot that is not armed.
    deadline_ns: [test_slots]?u64 = [_]?u64{null} ** test_slots,
    arm: [test_slots]u64 = [_]u64{0} ** test_slots,
    arms: u64 = 0,
    count: u32 = 0,

    fn earliest(model: *const Model) ?u32 {
        var best: ?u32 = null;
        for (0..test_slots) |slot| {
            if (model.deadline_ns[slot] == null) continue;
            if (best == null or model.before(slot, best.?)) best = @intCast(slot);
        }
        return best;
    }

    fn before(model: *const Model, a: usize, b: usize) bool {
        const a_ns = model.deadline_ns[a].?;
        const b_ns = model.deadline_ns[b].?;
        return if (a_ns != b_ns) a_ns < b_ns else model.arm[a] < model.arm[b];
    }

    /// A slot that is armed, or one that is not, scanning from a random slot. One must exist.
    fn pick(model: *const Model, random: *Random, armed: bool) u32 {
        const start = random.below(test_slots);
        for (0..test_slots) |offset| {
            const slot = (start + offset) % test_slots;
            if ((model.deadline_ns[slot] != null) == armed) return @intCast(slot);
        }
        unreachable;
    }
};

fn property_step(heap: *TimerHeap, model: *Model, random: *Random, filling: bool) !void {
    // One draw in `arm_odds` is 0. A draining phase arms on it, a filling phase on the others.
    if ((random.below(arm_odds) == 0) != filling) {
        if (model.count == test_entries) return;
        const slot = model.pick(random, false);
        model.deadline_ns[slot] = random.below(property_deadlines);
        model.arm[slot] = model.arms;
        model.arms += 1;
        model.count += 1;
        heap.arm(slot, model.deadline_ns[slot].?);
    } else if (random.next() & 1 == 0) {
        if (model.count == 0) return;
        const slot = model.pick(random, true);
        model.deadline_ns[slot] = null;
        model.count -= 1;
        heap.disarm(slot);
    } else {
        try expect_pop(heap, model, random.below(property_deadlines + 1));
    }
}

/// One `pop_due`, which must answer what the model's scan answers.
fn expect_pop(heap: *TimerHeap, model: *Model, now_ns: u64) !void {
    var due = model.earliest();
    if (due != null and model.deadline_ns[due.?].? > now_ns) due = null;
    try testing.expectEqual(due, heap.pop_due(now_ns));
    const slot = due orelse return;
    model.deadline_ns[slot] = null;
    model.count -= 1;
}

/// The heap holds, and its count, its earliest deadline and every slot's state are the model's.
fn expect_agreement(heap: *const TimerHeap, model: *const Model) !void {
    try testing.expectEqual(null, heap.first_violation());
    heap.assert_heap();
    try testing.expectEqual(model.count, heap.count);
    const earliest_ns = if (model.earliest()) |slot| model.deadline_ns[slot] else null;
    try testing.expectEqual(earliest_ns, heap.earliest_ns());
    for (model.deadline_ns, 0..) |deadline_ns, slot| {
        try testing.expectEqual(deadline_ns != null, heap.is_armed(@intCast(slot)));
    }
}

fn property_run(seed: u64) !void {
    errdefer std.debug.print("timer heap property failed: seed {d}\n", .{seed});
    var fixture: Fixture = undefined;
    fixture.init();
    var model: Model = .{};
    var random = Random.init(seed);
    // The sequence wraps early in the run, while entries stamped before the wrap are live.
    fixture.heap.sequence -%= @intCast(random.between(1, test_entries));
    for (0..property_steps) |step| {
        const filling = (step / property_phase_steps) & 1 == 0;
        try property_step(&fixture.heap, &model, &random, filling);
        try expect_agreement(&fixture.heap, &model);
    }
    // What is left comes out in the model's order, and then nothing does.
    for (0..test_entries + 1) |_| try expect_pop(&fixture.heap, &model, now_ns_last);
    try testing.expectEqual(0, fixture.heap.count);
}

test "property: random arms, disarms and pops agree with a model that scans for the minimum" {
    const seeds = 128;
    for (0..seeds) |seed| try property_run(seed);
}
