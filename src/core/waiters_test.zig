//! `Waiters` under test: unit tests for each call, and a seeded property test against a model
//! that keeps, for every descriptor and filter, the slots that wait in the order they joined.
const std = @import("std");
const testing = std.testing;
const random_module = @import("random.zig");
const slot_module = @import("slot.zig");
const waiters_module = @import("waiters.zig");

const Descriptor = @import("operation.zig").Descriptor;
const Slot = slot_module.Slot;
const Waiters = waiters_module.Waiters;
const Filter = waiters_module.Filter;
const Entry = waiters_module.Entry;

const slots_count = 16;
const entries_count = 32;

const Fixture = struct {
    slots: [slots_count]Slot,
    entries: [entries_count]Entry,
    waiters: Waiters,

    fn init(fixture: *Fixture) void {
        for (&fixture.slots) |*slot| {
            slot.* = std.mem.zeroes(Slot);
            slot.next = slot_module.next_none;
        }
        fixture.waiters.init(&fixture.entries);
    }
};

test "the first waiter of a descriptor and filter asks for a registration, and later ones do not" {
    var fixture: Fixture = undefined;
    fixture.init();
    const waiters = &fixture.waiters;
    try testing.expect(waiters.add(&fixture.slots, 7, .read, 0));
    try testing.expect(!waiters.add(&fixture.slots, 7, .read, 1));
    try testing.expect(waiters.add(&fixture.slots, 7, .write, 2));
    try testing.expect(waiters.add(&fixture.slots, 9, .read, 3));
    try testing.expectEqual(@as(u32, 2), waiters.count(7, .read));
    try testing.expectEqual(@as(u32, 1), waiters.count(7, .write));
    try testing.expectEqual(@as(u32, 0), waiters.count(8, .read));
    try testing.expectEqual(@as(u32, 2), waiters.used);
}

test "waiters leave in the order they joined, and the entry goes when its lists are empty" {
    var fixture: Fixture = undefined;
    fixture.init();
    const waiters = &fixture.waiters;
    for (0..3) |index| _ = waiters.add(&fixture.slots, 5, .read, @intCast(index));
    try testing.expectEqual(@as(?u32, 0), waiters.first(5, .read));
    try testing.expectEqual(@as(?u32, 0), waiters.pop(&fixture.slots, 5, .read));
    try testing.expectEqual(@as(?u32, 1), waiters.pop(&fixture.slots, 5, .read));
    try testing.expectEqual(@as(u32, 1), waiters.used);
    try testing.expectEqual(@as(?u32, 2), waiters.pop(&fixture.slots, 5, .read));
    try testing.expectEqual(@as(?u32, null), waiters.pop(&fixture.slots, 5, .read));
    try testing.expectEqual(@as(u32, 0), waiters.used);
    try testing.expectEqual(@as(?u32, null), waiters.first(5, .read));
}

test "a cancel takes a slot from the head, the middle or the tail, and a stranger is refused" {
    var fixture: Fixture = undefined;
    fixture.init();
    const waiters = &fixture.waiters;
    for (0..4) |index| _ = waiters.add(&fixture.slots, 5, .write, @intCast(index));
    try testing.expect(waiters.remove(&fixture.slots, 5, .write, 2));
    try testing.expect(waiters.remove(&fixture.slots, 5, .write, 0));
    try testing.expect(!waiters.remove(&fixture.slots, 5, .write, 0));
    try testing.expect(!waiters.remove(&fixture.slots, 5, .read, 1));
    try testing.expect(!waiters.remove(&fixture.slots, 6, .write, 1));
    try testing.expect(waiters.remove(&fixture.slots, 5, .write, 3));
    // The tail moved back to slot 1, so a new waiter joins behind it.
    _ = waiters.add(&fixture.slots, 5, .write, 0);
    try testing.expectEqual(@as(?u32, 1), waiters.pop(&fixture.slots, 5, .write));
    try testing.expectEqual(@as(?u32, 0), waiters.pop(&fixture.slots, 5, .write));
    try testing.expectEqual(@as(u32, 0), waiters.used);
}

test "a close takes every waiter of its descriptor, reads first, and no other descriptor's" {
    var fixture: Fixture = undefined;
    fixture.init();
    const waiters = &fixture.waiters;
    _ = waiters.add(&fixture.slots, 4, .write, 0);
    _ = waiters.add(&fixture.slots, 4, .read, 1);
    _ = waiters.add(&fixture.slots, 6, .read, 2);
    _ = waiters.add(&fixture.slots, 4, .read, 3);
    try testing.expectEqual(@as(?u32, 1), waiters.pop_any(&fixture.slots, 4));
    try testing.expectEqual(@as(?u32, 3), waiters.pop_any(&fixture.slots, 4));
    try testing.expectEqual(@as(?u32, 0), waiters.pop_any(&fixture.slots, 4));
    try testing.expectEqual(@as(?u32, null), waiters.pop_any(&fixture.slots, 4));
    try testing.expectEqual(@as(u32, 1), waiters.count(6, .read));
}

test "an entry removed from a run of collisions leaves the ones behind it findable" {
    var fixture: Fixture = undefined;
    fixture.init();
    const waiters = &fixture.waiters;
    // One slot per descriptor, as many descriptors as the table may hold: probes run long.
    for (0..slots_count) |index| {
        const descriptor: Descriptor = @intCast(index * 32);
        try testing.expect(waiters.add(&fixture.slots, descriptor, .read, @intCast(index)));
    }
    try testing.expectEqual(@as(u32, slots_count), waiters.used);
    for (0..slots_count) |round| {
        // Remove them in an order that is not the order they joined.
        const index = (round * 5) % slots_count;
        const descriptor: Descriptor = @intCast(index * 32);
        const popped = waiters.pop(&fixture.slots, descriptor, .read);
        try testing.expectEqual(@as(?u32, @intCast(index)), popped);
        for (0..slots_count) |other| {
            const expected: u32 = if (still_waits(other, round)) 1 else 0;
            try testing.expectEqual(expected, waiters.count(@intCast(other * 32), .read));
        }
    }
    try testing.expectEqual(@as(u32, 0), waiters.used);
}

/// True when the descriptor of slot `index` has not been removed by round `round` of the test
/// above.
fn still_waits(index: usize, round: usize) bool {
    for (0..round + 1) |done| {
        if ((done * 5) % slots_count == index) return false;
    }
    return true;
}

const seeds = 64;
const steps_per_seed = 512;
const descriptors = 6;

/// For each descriptor and filter, the slots that wait, oldest first. -1 ends a list.
const Model = struct {
    lists: [descriptors][2][slots_count]i32,
    lengths: [descriptors][2]u32,
    waiting: [slots_count]bool,

    fn init() Model {
        return .{
            .lists = @splat(@splat(@splat(-1))),
            .lengths = @splat(@splat(0)),
            .waiting = @splat(false),
        };
    }

    fn push(model: *Model, descriptor: usize, filter: usize, index: u32) void {
        model.lists[descriptor][filter][model.lengths[descriptor][filter]] = @intCast(index);
        model.lengths[descriptor][filter] += 1;
        model.waiting[index] = true;
    }

    fn take(model: *Model, descriptor: usize, filter: usize, position: u32) u32 {
        const list = &model.lists[descriptor][filter];
        const length = model.lengths[descriptor][filter];
        const index: u32 = @intCast(list[position]);
        for (position..length - 1) |at| list[at] = list[at + 1];
        model.lengths[descriptor][filter] = length - 1;
        model.waiting[index] = false;
        return index;
    }
};

fn one_step(fixture: *Fixture, model: *Model, random: *random_module.Random) !void {
    const descriptor = random.below(descriptors);
    const filter = random.below(2);
    const kernel_descriptor: Descriptor = @intCast(descriptor * 7 + 3);
    const kernel_filter: Filter = @enumFromInt(filter);
    const length = model.lengths[descriptor][filter];
    switch (random.below(3)) {
        0 => {
            const index: u32 = @intCast(random.below(slots_count));
            if (model.waiting[index]) return;
            const slots = &fixture.slots;
            const first = fixture.waiters.add(slots, kernel_descriptor, kernel_filter, index);
            try testing.expectEqual(length == 0, first);
            model.push(descriptor, filter, index);
        },
        1 => {
            const popped = fixture.waiters.pop(&fixture.slots, kernel_descriptor, kernel_filter);
            const expected: ?u32 = if (length == 0) null else model.take(descriptor, filter, 0);
            try testing.expectEqual(expected, popped);
        },
        else => {
            if (length == 0) return;
            const position: u32 = @intCast(random.below(length));
            const index = model.take(descriptor, filter, position);
            const slots = &fixture.slots;
            const removed = fixture.waiters.remove(slots, kernel_descriptor, kernel_filter, index);
            try testing.expect(removed);
        },
    }
    const counted = fixture.waiters.count(kernel_descriptor, kernel_filter);
    try testing.expectEqual(model.lengths[descriptor][filter], counted);
}

test "a seeded run of adds, pops and removes agrees with a model at every step" {
    for (0..seeds) |seed| {
        var fixture: Fixture = undefined;
        fixture.init();
        var model = Model.init();
        var random = random_module.Random.init(seed);
        for (0..steps_per_seed) |at| {
            one_step(&fixture, &model, &random) catch |err| {
                std.debug.print("waiters property test: seed {d}, step {d}\n", .{ seed, at });
                return err;
            };
        }
    }
}
