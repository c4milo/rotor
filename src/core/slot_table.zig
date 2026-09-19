//! `SlotTable`: the loop's table of `Slot`s, its free list, and the mapping between a `Handle` and
//! a slot (decision 1). The caller owns the memory: `init` takes the slice, and the table
//! allocates nothing.
//!
//! The loop claims a slot when it takes an operation and releases it when the operation's final
//! event is reaped, and at no other moment (decision 5, rule 1). `release` raises the slot's
//! generation, so a `Handle` kept past the final event no longer matches. Such a stale handle is
//! legal (decision 5, rule 2), so `lookup` answers null for it and does not halt.
//!
//! The free list is a stack threaded through `Slot.next`. `release` pushes and `claim` pops, so a
//! claim takes the slot released last, which is the line the table wrote most recently.
//!
//! This is one of the six hot files decision 7 names, and this is its plain version: slices,
//! ordinary calls, every safety check on, and no row in the hot-path ledger. Decision 8 sorts the
//! assertions. `claim`, `release`, `lookup` and `at` run per operation and carry class A
//! assertions only: each reads what the function has already loaded. The walk over the whole
//! table is class D and runs in `assert_accounting` alone, which the tests call after every step.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const handle_module = @import("handle.zig");
const slot_module = @import("slot.zig");

const Handle = handle_module.Handle;
const Slot = slot_module.Slot;
const next_none = slot_module.next_none;
const heap_position_none = slot_module.heap_position_none;

/// A slice and two 32-bit integers with no padding: 24 bytes aligned to 8 on a 64-bit target.
pub const SlotTable = struct {
    /// The caller's memory: one `Slot` per operation the loop may hold in flight.
    slots: []Slot,
    /// The slot the next `claim` takes, or `slot.next_none` when the table is full.
    free_head: u32,
    /// How many slots are on the free list. `in_use` is the rest.
    free_count: u32,

    /// `slots.len` is in `[1, constants.operations_max]`. Every slot becomes free with generation
    /// `constants.generation_first`, linked so that the first claim returns index 0, the second
    /// index 1, and so on. Writes every byte of every slot, so nothing later reads memory the
    /// caller left undefined.
    pub fn init(table: *SlotTable, slots: []Slot) void {
        assert(slots.len >= 1);
        assert(slots.len <= constants.operations_max);
        const count: u32 = @intCast(slots.len);
        for (slots, 0..) |*slot, position| {
            const following: u32 = @intCast(position + 1);
            slot.* = std.mem.zeroes(Slot);
            slot.state = .free;
            slot.generation = constants.generation_first;
            slot.next = if (following < count) following else next_none;
            slot.heap_position = heap_position_none;
        }
        table.* = .{ .slots = slots, .free_head = 0, .free_count = count };
        assert(table.in_use() == 0);
    }

    /// Pops the free list, so the slot released last is claimed first. The slot goes from `free`
    /// to `queued` and ends its list. Its generation stays: `release` is what raises it. Null
    /// when no slot is free.
    pub fn claim(table: *SlotTable) ?u32 {
        const index = table.free_head;
        if (index == next_none) {
            assert(table.free_count == 0);
            return null;
        }
        const slot = table.at(index);
        assert(slot.state == .free);
        assert(slot.generation >= constants.generation_first);
        assert(table.free_count >= 1);
        table.free_head = slot.next;
        table.free_count -= 1;
        slot.state = .queued;
        slot.next = next_none;
        return index;
    }

    /// Frees the slot at `index`, which must not be free, and pushes it on the free list. Raises
    /// the generation, so every handle to the operation that held the slot stops matching
    /// (decision 5, rule 1). The slot's deadline must have left the timer heap already.
    pub fn release(table: *SlotTable, index: u32) void {
        const slot = table.at(index);
        assert(slot.state != .free);
        assert(slot.heap_position == heap_position_none);
        assert(table.free_count < table.slots.len);
        slot.generation = Handle.next_generation(slot.generation);
        slot.state = .free;
        slot.next = table.free_head;
        table.free_head = index;
        table.free_count += 1;
    }

    /// The handle that names the operation holding the slot at `index`, which must not be free.
    pub fn handle_of(table: *const SlotTable, index: u32) Handle {
        assert(index < table.slots.len);
        const slot = &table.slots[index];
        assert(slot.state != .free);
        assert(slot.generation >= constants.generation_first);
        return .{ .index = index, .generation = slot.generation };
    }

    /// The slot `handle` names. Null when the slot is free or its generation differs: a stale
    /// handle, which decision 5, rule 2 makes legal. Null for `Handle.none` too, by the same
    /// comparison, because no slot carries generation 0. Halts on an index outside the table: no
    /// handle rotor ever issued names one.
    pub fn lookup(table: *SlotTable, handle: Handle) ?*Slot {
        const slot = table.at(handle.index);
        assert(slot.generation >= constants.generation_first);
        if (slot.state == .free) return null;
        if (slot.generation != handle.generation) return null;
        return slot;
    }

    /// The slot at `index`, claimed or free. Halts on an index outside the table.
    pub fn at(table: *SlotTable, index: u32) *Slot {
        assert(index < table.slots.len);
        return &table.slots[index];
    }

    /// The index of `slot`, which must be one of this table's slots: the inverse of `at`. The
    /// distance between two addresses inside the table does not depend on where the table sits.
    pub fn index_of(table: *const SlotTable, slot: *const Slot) u32 {
        const base = @intFromPtr(table.slots.ptr);
        const address = @intFromPtr(slot);
        assert(address >= base);
        const index = (address - base) / constants.slot_bytes;
        assert(index < table.slots.len);
        return @intCast(index);
    }

    /// How many slots the table holds: the most operations the loop may hold in flight.
    pub fn capacity(table: *const SlotTable) u32 {
        assert(table.slots.len >= 1);
        assert(table.slots.len <= constants.operations_max);
        return @intCast(table.slots.len);
    }

    /// How many slots are claimed, in any state but `free`.
    pub fn in_use(table: *const SlotTable) u32 {
        const total = table.capacity();
        assert(table.free_count <= total);
        return total - table.free_count;
    }

    /// Decision 8, class D: O(n), so no per-operation function calls it. Halts on a broken table.
    pub fn assert_accounting(table: *const SlotTable) void {
        assert(table.accounting_holds());
    }

    /// Walks the free list for at most `slots.len` steps. True when the list ends, every node on
    /// it is a free slot of the table, its length is `free_count`, and `free_count` plus the
    /// slots that are not free is `slots.len`. Together those say that every free slot is on the
    /// list exactly once. It answers and does not halt, so a test can hand it a broken table.
    fn accounting_holds(table: *const SlotTable) bool {
        const total = table.capacity();
        var index = table.free_head;
        var walked: u32 = 0;
        for (0..total) |_| {
            if (index == next_none) break;
            if (index >= total or table.slots[index].state != .free) return false;
            index = table.slots[index].next;
            walked += 1;
        }
        // A list that has not ended after `total` nodes holds a cycle.
        if (index != next_none or walked != table.free_count) return false;
        var claimed: u32 = 0;
        for (table.slots) |*slot| {
            if (slot.state != .free) claimed += 1;
        }
        return table.free_count + claimed == total;
    }
};

comptime {
    assert(@sizeOf(SlotTable) == @sizeOf([]Slot) + @sizeOf(u32) + @sizeOf(u32));
    assert(@alignOf(SlotTable) == @alignOf([]Slot));
    // `index_of` divides by the size of a slot.
    assert(@sizeOf(Slot) == constants.slot_bytes);
    // `next_none` ends a list, so it must never be the index of a slot.
    assert(constants.operations_max <= next_none);
}

const testing = std.testing;
const Random = @import("random.zig").Random;

/// Slots in the fixed array a unit test hands `init`. No test allocates (tools/lint heap).
const test_slots = 8;

fn table_over(slots: []Slot) SlotTable {
    var table: SlotTable = undefined;
    table.init(slots);
    table.assert_accounting();
    return table;
}

test "init defines every byte of every slot, whatever the caller's memory held" {
    var slots: [test_slots]Slot = undefined;
    @memset(std.mem.asBytes(&slots), 0xFF);
    const table = table_over(&slots);
    for (&slots, 0..) |*slot, index| {
        var expected = std.mem.zeroes(Slot);
        expected.state = .free;
        expected.generation = constants.generation_first;
        expected.heap_position = heap_position_none;
        expected.next = if (index + 1 < test_slots) @intCast(index + 1) else next_none;
        try testing.expectEqualSlices(u8, std.mem.asBytes(&expected), std.mem.asBytes(slot));
    }
    try testing.expectEqual(@as(u32, 0), table.free_head);
    try testing.expectEqual(@as(u32, test_slots), table.free_count);
    try testing.expectEqual(@as(u32, test_slots), table.capacity());
    try testing.expectEqual(@as(u32, 0), table.in_use());
}

test "claims after init run 0, 1, 2, and a full table claims null until a release makes room" {
    var slots: [test_slots]Slot = undefined;
    var table = table_over(&slots);
    for (0..test_slots) |position| {
        const expected: u32 = @intCast(position);
        try testing.expectEqual(@as(?u32, expected), table.claim());
        try testing.expectEqual(expected + 1, table.in_use());
        table.assert_accounting();
    }
    try testing.expectEqual(next_none, table.free_head);
    try testing.expectEqual(@as(?u32, null), table.claim());
    try testing.expectEqual(@as(?u32, null), table.claim());
    try testing.expectEqual(table.capacity(), table.in_use());
    table.release(5);
    try testing.expectEqual(@as(?u32, 5), table.claim());
    try testing.expectEqual(@as(?u32, null), table.claim());
    table.assert_accounting();
}

test "claim hands out a queued slot that ends its list and keeps its generation" {
    var slots: [test_slots]Slot = undefined;
    var table = table_over(&slots);
    const index = table.claim().?;
    const slot = table.at(index);
    try testing.expectEqual(Slot.State.queued, slot.state);
    try testing.expectEqual(next_none, slot.next);
    try testing.expectEqual(constants.generation_first, slot.generation);
    try testing.expectEqual(@as(u32, 1), table.in_use());
    try testing.expectEqual(@as(u32, test_slots - 1), table.free_count);
    try testing.expectEqual(@as(u32, 1), table.free_head);
    table.assert_accounting();
}

test "each release raises the generation by one and the old handle stops matching" {
    var slots: [test_slots]Slot = undefined;
    var table = table_over(&slots);
    var stale = Handle.none;
    for (0..4) |round| {
        const index = table.claim().?;
        const handle = table.handle_of(index);
        const generation = constants.generation_first + @as(u32, @intCast(round));
        try testing.expectEqual(Handle{ .index = 0, .generation = generation }, handle);
        try testing.expectEqual(@as(?*Slot, &slots[0]), table.lookup(handle));
        // The slot is claimed again, and the handle of the operation before still misses.
        try testing.expectEqual(@as(?*Slot, null), table.lookup(stale));
        table.release(index);
        try testing.expectEqual(Slot.State.free, slots[0].state);
        try testing.expectEqual(generation + 1, slots[0].generation);
        try testing.expectEqual(@as(?*Slot, null), table.lookup(handle));
        stale = handle;
        table.assert_accounting();
    }
}

test "release pushes on the head, so the slot released last is claimed first" {
    var slots: [test_slots]Slot = undefined;
    var table = table_over(&slots);
    for (0..4) |_| _ = table.claim().?;
    table.release(1);
    table.release(3);
    table.release(0);
    table.assert_accounting();
    try testing.expectEqual(@as(u32, 1), table.in_use());
    for ([_]u32{ 0, 3, 1, 4 }) |expected| {
        try testing.expectEqual(@as(?u32, expected), table.claim());
    }
    table.assert_accounting();
}

test "release takes a slot in every claimed state" {
    var slots: [test_slots]Slot = undefined;
    var table = table_over(&slots);
    for ([_]Slot.State{ .queued, .submitted, .finishing }) |state| {
        const index = table.claim().?;
        slots[index].state = state;
        const handle = table.handle_of(index);
        try testing.expectEqual(@as(?*Slot, &slots[index]), table.lookup(handle));
        table.release(index);
        try testing.expectEqual(@as(?*Slot, null), table.lookup(handle));
        table.assert_accounting();
    }
}

test "release wraps a generation past 32 bits to the first one and never to 0" {
    var slots: [test_slots]Slot = undefined;
    var table = table_over(&slots);
    const index = table.claim().?;
    slots[index].generation = std.math.maxInt(u32);
    const last = table.handle_of(index);
    table.release(index);
    try testing.expectEqual(constants.generation_first, slots[index].generation);
    try testing.expectEqual(@as(?*Slot, null), table.lookup(last));
}

test "lookup refuses the none handle, a free slot and a generation that differs" {
    var slots: [test_slots]Slot = undefined;
    var table = table_over(&slots);
    const third: Handle = .{ .index = 2, .generation = constants.generation_first };
    // Slot 0 is free, then claimed: the none handle names index 0 and misses both times.
    try testing.expectEqual(@as(?*Slot, null), table.lookup(Handle.none));
    // The generation matches, and the slot is free: no operation holds it.
    try testing.expectEqual(@as(?*Slot, null), table.lookup(third));
    for (0..3) |_| _ = table.claim().?;
    try testing.expectEqual(@as(?*Slot, null), table.lookup(Handle.none));
    try testing.expectEqual(third, table.handle_of(2));
    try testing.expectEqual(@as(?*Slot, &slots[2]), table.lookup(third));
    const ahead: Handle = .{ .index = 2, .generation = third.generation + 1 };
    try testing.expectEqual(@as(?*Slot, null), table.lookup(ahead));
}

test "index_of inverts at for every slot" {
    var slots: [test_slots]Slot = undefined;
    var table = table_over(&slots);
    for (0..test_slots) |position| {
        const index: u32 = @intCast(position);
        try testing.expectEqual(&slots[position], table.at(index));
        try testing.expectEqual(index, table.index_of(table.at(index)));
    }
}

test "the accounting check refuses a cycle, a node outside, a lost node and a claimed node" {
    var slots: [test_slots]Slot = undefined;
    var table = table_over(&slots);
    const last = test_slots - 1;
    // Each break leaves every other condition true, so each one proves one condition.
    slots[last].next = 0; // The list never ends.
    try testing.expect(!table.accounting_holds());
    slots[last].next = next_none;
    slots[0].next = test_slots; // A node outside the table, met before the walk's bound.
    try testing.expect(!table.accounting_holds());
    slots[0].next = 1;
    slots[last - 1].next = next_none; // The last slot is free and counted, and off the list.
    try testing.expect(!table.accounting_holds());
    table.free_count -= 1;
    slots[0].state = .queued; // The counts agree again, and a claimed slot is on the list.
    try testing.expect(!table.accounting_holds());
    slots[0].state = .free;
    table.free_count += 1;
    slots[last - 1].next = last;
    try testing.expect(table.accounting_holds());
    try testing.expectEqual(@as(?u32, 0), table.claim());
    slots[0].state = .free; // Free, and on no list.
    try testing.expect(!table.accounting_holds());
    slots[0].state = .queued;
    try testing.expect(table.accounting_holds());
}

/// The property test's tables hold 1 to this many slots, a size per seed in turn. Small, so a
/// run fills and empties its table many times.
const model_slots_max = 16;
/// Claims and releases one seed draws.
const model_steps = 512;
/// A seed claims on 1, 2 or 3 draws in this many, so some seeds sit near full and some near empty.
const claim_draws = 4;

/// How often the seeds reached each end of a table: a claim refused, a table released to empty.
const Reach = struct { refused: u32 = 0, emptied: u32 = 0 };

/// What the table must hold, kept the simple way: flags, generations, and the free slots as a
/// stack whose top is the next slot to claim.
const Model = struct {
    capacity: u32,
    reach: *Reach,
    step: u32 = 0,
    free: [model_slots_max]u32 = @splat(next_none),
    free_count: u32 = 0,
    in_use: [model_slots_max]bool = @splat(false),
    generations: [model_slots_max]u32 = @splat(constants.generation_first),
    /// The handle each slot's last release left stale, or none.
    stale: [model_slots_max]Handle = @splat(Handle.none),

    fn init(capacity: u32, reach: *Reach) Model {
        var model: Model = .{ .capacity = capacity, .reach = reach };
        // `SlotTable.init` links the list so that claims run 0, 1, 2: slot 0 is on top.
        for (0..capacity) |depth| model.free[depth] = capacity - 1 - @as(u32, @intCast(depth));
        model.free_count = capacity;
        return model;
    }

    /// Fails the run and names the step. The test names the seed.
    fn expect(model: *const Model, holds: bool, what: []const u8) !void {
        if (holds) return;
        std.debug.print("slot_table property: step {d}: {s}\n", .{ model.step, what });
        return error.ModelMismatch;
    }

    fn claim(model: *Model, table: *SlotTable) !void {
        var expected: ?u32 = null;
        if (model.free_count >= 1) {
            model.free_count -= 1;
            expected = model.free[model.free_count];
            model.in_use[expected.?] = true;
        } else {
            model.reach.refused += 1;
        }
        const claimed = table.claim();
        try model.expect(std.meta.eql(claimed, expected), "claim differs from the model");
    }

    fn release(model: *Model, table: *SlotTable, random: *Random) !void {
        const in_use_count = model.capacity - model.free_count;
        assert(in_use_count >= 1);
        const index = model.nth_in_use(@intCast(random.below(in_use_count)));
        model.stale[index] = table.handle_of(index);
        table.release(index);
        model.in_use[index] = false;
        model.generations[index] += 1;
        model.free[model.free_count] = index;
        model.free_count += 1;
        if (model.free_count == model.capacity) model.reach.emptied += 1;
    }

    fn nth_in_use(model: *const Model, nth: u32) u32 {
        var seen: u32 = 0;
        for (model.in_use[0..model.capacity], 0..) |in_use, index| {
            if (!in_use) continue;
            if (seen == nth) return @intCast(index);
            seen += 1;
        }
        unreachable;
    }

    fn verify(model: *const Model, table: *SlotTable) !void {
        try model.expect(table.capacity() == model.capacity, "the capacity changed");
        try model.expect(table.free_count == model.free_count, "free_count differs");
        try model.expect(table.in_use() == model.capacity - model.free_count, "in_use differs");
        var index = table.free_head;
        for (0..model.free_count) |depth| {
            const expected = model.free[model.free_count - 1 - depth];
            try model.expect(index == expected, "the free list is out of order");
            index = table.slots[index].next;
        }
        try model.expect(index == next_none, "the free list runs past the model's");
        for (0..model.capacity) |position| try model.verify_slot(table, @intCast(position));
    }

    fn verify_slot(model: *const Model, table: *SlotTable, index: u32) !void {
        const slot = table.at(index);
        const current: Handle = .{ .index = index, .generation = model.generations[index] };
        try model.expect(slot.generation == current.generation, "a generation differs");
        try model.expect(table.index_of(slot) == index, "index_of does not invert at");
        try model.expect(table.lookup(model.stale[index]) == null, "a stale handle matched");
        if (model.in_use[index]) {
            try model.expect(slot.state == .queued, "a claimed slot is not queued");
            try model.expect(slot.next == next_none, "a claimed slot does not end its list");
            try model.expect(std.meta.eql(table.handle_of(index), current), "handle_of differs");
            try model.expect(table.lookup(current) == slot, "a live handle missed its slot");
        } else {
            try model.expect(slot.state == .free, "a released slot is not free");
            try model.expect(table.lookup(current) == null, "a free slot was looked up");
        }
    }
};

fn run_seed(seed: u64, reach: *Reach) !void {
    var random = Random.init(seed);
    var slots: [model_slots_max]Slot = undefined;
    const capacity: u32 = @intCast(seed % model_slots_max + 1);
    const claim_chance = random.between(1, claim_draws - 1);
    var table = table_over(slots[0..capacity]);
    var model = Model.init(capacity, reach);
    try model.verify(&table);
    for (0..model_steps) |step| {
        model.step = @intCast(step);
        // Nothing to release: claim. Otherwise the seed decides, and a full table must refuse.
        const claims = model.free_count == capacity or random.chance(claim_chance, claim_draws);
        if (claims) try model.claim(&table) else try model.release(&table, &random);
        // The model first, because its failure names the seed and a failed assertion cannot.
        try model.verify(&table);
        table.assert_accounting();
    }
}

test "property: seeded claims and releases match the model and the accounting holds" {
    const seeds = 256;
    var reach: Reach = .{};
    for (0..seeds) |seed| {
        run_seed(seed, &reach) catch |err| {
            std.debug.print("slot_table property: seed {d} replays it\n", .{seed});
            return err;
        };
    }
    // A test that never filled a table or never emptied one proved less than it says.
    try testing.expect(reach.refused >= seeds and reach.emptied >= seeds);
}
