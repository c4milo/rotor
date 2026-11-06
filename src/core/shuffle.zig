//! The seeded shuffle of each reaped batch (decision 10, amendment of 2026-11-06). The kernel
//! promises no order between the completions of two operations in one reaped batch. A test build
//! permutes the events of each reap before the caller or `Dispatch.end` sees them, so a scenario
//! that assumes an order that rotor does not promise fails. `-Dshuffle-seed=N` names the seed.
//!
//! The permutation keeps each order that rotor promises:
//!
//! - The events of one `user_data` keep their order. So the `more` events of an operation stay
//!   before its final event, and the datagrams and the bytes of a multishot receive stay in their
//!   order, each with the provided buffer it names. Two operations with the same `user_data` also
//!   keep their order. That costs the shuffle some orders, and needs no read of the slot.
//! - A barrier keeps its place. On io_uring a close's event is a barrier, because the operations
//!   that the close cancelled end first (decision 5, rule 6).
//! - Only the events of a reap move. The due timers, the finished list, the messages and the
//!   expired deadlines come in an order that rotor decides, and in part promises, so they stay.
//!
//! The switch is off by default. Then `Shuffle` has no bytes, and no call site compiles a call:
//! each one reads `enabled`, which is known at compile time. The draws come from `core.random`,
//! and the seed comes from the build, so one seed replays one order of the same batches.
const std = @import("std");
const assert = std.debug.assert;
const Event = @import("event.zig").Event;
const Random = @import("random.zig").Random;
const LoopId = @import("operation.zig").LoopId;
const constants = @import("constants.zig");

/// The seed of this build, or null when the switch is off. `build/modules.zig` writes it into
/// `assertion_options`, the one module that `core` imports.
pub const seed: ?u64 = @import("assertion_options").shuffle_seed;

/// True in a build that shuffles each reaped batch.
pub const enabled: bool = seed != null;

/// What one loop holds for the shuffle: a `Generator` when the switch is on, and no byte when it
/// is off.
pub const Shuffle = if (enabled) Generator else Off;

/// What a loop holds when the switch is off.
pub const Off = struct {
    pub fn init(id: LoopId) Off {
        _ = id;
        return .{};
    }
};

comptime {
    // Off, the switch adds no byte to `Tables`, so the layout of a loop does not change.
    if (!enabled) assert(@sizeOf(Shuffle) == 0);
}

/// The state of the shuffle of one loop. A call site calls it only when `enabled`. The tests
/// below build one with a seed of their own in every build.
pub const Generator = struct {
    random: Random,
    /// The first event of the reap's batch that the next permutation may move: 0, or the place
    /// after the last barrier.
    start: u32,
    /// True when the event that the reap writes next is a barrier.
    barrier: bool,

    /// The generator of loop `id`. Each loop of a process draws its own values, from the seed and
    /// its id, so the values do not depend on the order in which the loops tick.
    pub fn init(id: LoopId) Generator {
        return .seeded(loop_seed(seed.?, id));
    }

    pub fn seeded(value: u64) Generator {
        return .{ .random = .init(value), .start = 0, .barrier = false };
    }

    /// Notes that the event the reap writes next must stay after every event the reap wrote
    /// before it. On io_uring that is a close's event: the kernel ends the operations that the
    /// close cancelled before it ends the close (decision 5, rule 6, and decision 11, point 5).
    pub fn note_barrier(generator: *Generator) void {
        generator.barrier = true;
    }

    /// A reap calls it after it wrote the last event of `events`. When that event is a barrier,
    /// it permutes the events since the last barrier, and the barrier keeps its place.
    pub fn wrote(generator: *Generator, events: []Event) void {
        if (!generator.barrier) return;
        assert(events.len >= 1 and generator.start < events.len);
        generator.barrier = false;
        permute(&generator.random, events[generator.start .. events.len - 1]);
        generator.start = @intCast(events.len);
    }

    /// Permutes the events of `events`, the batch one reap wrote, that follow its last barrier.
    pub fn reaped(generator: *Generator, events: []Event) void {
        assert(!generator.barrier);
        assert(generator.start <= events.len);
        permute(&generator.random, events[generator.start..]);
        generator.start = 0;
    }
};

/// The seed of loop `id` in a build whose seed is `base`. The id goes into the high bits: with
/// `base +% id`, loop 1 under seed N would draw what loop 0 draws under seed N + 1, so a sweep
/// over seeds would repeat streams.
fn loop_seed(base: u64, id: LoopId) u64 {
    return base ^ (@as(u64, id) << loop_seed_shift);
}

/// The bit where a loop's id starts in its seed. For the small seeds a person passes with
/// `-Dshuffle-seed`, the seed and the id use different bits.
const loop_seed_shift = 48;

comptime {
    assert(constants.loops_max <= 1 << (64 - loop_seed_shift));
}

/// Puts `events` in an order that `random` draws, and keeps the order of the events of each
/// `user_data`. Each step draws one of the events not placed yet. It then places the first event
/// not placed yet with the same `user_data`, and the events between keep their order.
pub fn permute(random: *Random, events: []Event) void {
    const count = events.len;
    for (0..count) |placed| {
        const drawn = placed + random.below(count - placed);
        const first = placed + first_of(events[placed .. drawn + 1]);
        assert(placed <= first and first <= drawn and drawn < count);
        const moved = events[first];
        std.mem.copyBackwards(Event, events[placed + 1 .. first + 1], events[placed..first]);
        events[placed] = moved;
    }
}

/// The index of the first event of `events` with the `user_data` of its last event.
fn first_of(events: []const Event) usize {
    const last = events.len - 1;
    const user_data = events[last].user_data;
    for (events[0..last], 0..) |event, index| {
        if (event.user_data == user_data) return index;
    }
    return last;
}

const testing = std.testing;

/// The largest batch the tests below permute.
const batch_max = 24;

/// A batch of `count` events. Event `i` has `user_data` `i % operations`, and its `result` is `i`,
/// so the `result` names each event and orders the events of one `user_data`. The last event of
/// each `user_data` is its final event, and the others carry `more`.
fn batch(count: usize, operations: u64) [batch_max]Event {
    assert(count <= batch_max);
    var events: [batch_max]Event = undefined;
    for (events[0..count], 0..) |*event, index| {
        const more = index + operations < count;
        event.* = .{
            .user_data = index % operations,
            .result = @intCast(index),
            .flags = .{ .more = more },
        };
    }
    return events;
}

test "a permutation holds each event once" {
    for (0..64) |seed_value| {
        var random = Random.init(seed_value);
        const count = random.between(0, batch_max);
        const operations = random.between(1, 6);
        var events = batch(count, operations);
        permute(&random, events[0..count]);
        var seen: [batch_max]bool = @splat(false);
        for (events[0..count]) |event| {
            const index: usize = @intCast(event.result);
            try testing.expect(!seen[index]);
            seen[index] = true;
            try testing.expectEqual(index % operations, event.user_data);
        }
        for (seen[0..count]) |held| try testing.expect(held);
    }
}

test "the events of one user_data keep their order, and the final event stays last" {
    for (0..64) |seed_value| {
        var random = Random.init(seed_value);
        const count = random.between(1, batch_max);
        const operations = random.between(1, 6);
        var events = batch(count, operations);
        permute(&random, events[0..count]);
        var last: [6]i32 = @splat(-1);
        var finished: [6]bool = @splat(false);
        for (events[0..count]) |event| {
            const operation: usize = @intCast(event.user_data);
            try testing.expect(event.result > last[operation]);
            try testing.expect(!finished[operation]);
            last[operation] = event.result;
            finished[operation] = !event.flags.more;
        }
    }
}

fn same(first: []const Event, second: []const Event) bool {
    return std.mem.eql(u8, std.mem.sliceAsBytes(first), std.mem.sliceAsBytes(second));
}

test "one seed gives one order, and the orders of other seeds differ" {
    const count = 8;
    var first = batch(count, count);
    var again = batch(count, count);
    var random_first = Random.init(7);
    var random_again = Random.init(7);
    permute(&random_first, first[0..count]);
    permute(&random_again, again[0..count]);
    try testing.expectEqualSlices(Event, first[0..count], again[0..count]);

    // Eight events of eight operations have 40320 orders. Of 32 seeds, at most a few may give
    // the order the batch came in, or the order of seed 7.
    var moved: u32 = 0;
    var other: u32 = 0;
    const unmoved = batch(count, count);
    for (0..32) |seed_value| {
        var events = batch(count, count);
        var random = Random.init(seed_value);
        permute(&random, events[0..count]);
        if (!same(events[0..count], unmoved[0..count])) moved += 1;
        if (!same(events[0..count], first[0..count])) other += 1;
    }
    try testing.expect(moved >= 30);
    try testing.expect(other >= 30);
}

test "the events of one operation are never moved" {
    const count = 12;
    const unmoved = batch(count, 1);
    for (0..16) |seed_value| {
        var events = batch(count, 1);
        var random = Random.init(seed_value);
        permute(&random, events[0..count]);
        try testing.expectEqualSlices(Event, unmoved[0..count], events[0..count]);
    }
}

test "a barrier keeps its place, and no event crosses it" {
    for (0..64) |seed_value| {
        var generator: Generator = .seeded(seed_value);
        const count = 12;
        const barrier_at = 5;
        var events = batch(count, count);
        // The reap writes the events one at a time, and the sixth is a barrier.
        for (1..count + 1) |written| {
            if (written == barrier_at + 1) generator.note_barrier();
            generator.wrote(events[0..written]);
        }
        generator.reaped(events[0..count]);
        try testing.expectEqual(@as(u32, 0), generator.start);
        try testing.expectEqual(@as(i32, barrier_at), events[barrier_at].result);
        for (events[0..barrier_at]) |event| try testing.expect(event.result < barrier_at);
        for (events[barrier_at + 1 .. count]) |event| try testing.expect(event.result > barrier_at);
    }
}

test "each loop draws from the seed and its own id" {
    var first: Generator = .seeded(loop_seed(7, 0));
    var second: Generator = .seeded(loop_seed(7, 1));
    var other: Generator = .seeded(loop_seed(8, 0));
    const value = first.random.next();
    try testing.expect(value != second.random.next());
    try testing.expect(value != other.random.next());
    // Loop 1 under seed 7 and loop 0 under seed 8 draw different values too.
    var second_again: Generator = .seeded(loop_seed(7, 1));
    var other_again: Generator = .seeded(loop_seed(8, 0));
    try testing.expect(second_again.random.next() != other_again.random.next());
    if (!enabled) try testing.expectEqual(@as(usize, 0), @sizeOf(Shuffle));
}
