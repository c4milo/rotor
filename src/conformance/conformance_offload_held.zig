//! A file operation held for the offload's room is the loop's alone, so the loop ends it as it
//! ends a queued one (decision 18, amendment of 2026-11-06). A close of its descriptor ends it
//! before the close, its deadline ends it while it waits, and a cancel ends it wherever it sits.
//!
//! Each scenario first fills the offload: one worker that holds, and `offload_in_flight_max` reads
//! handed out to it. The operation under test is then held, and gets exactly one final event with
//! the right result while the worker still holds. Last, the worker answers, and every read that
//! went out gets exactly one event.
//!
//! It runs where a file operation blocks the loop: on kqueue and epoll. On io_uring the scenarios
//! skip, as `conformance_offload_limit.zig` does.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const limit = @import("conformance_offload_limit.zig");

const Event = core.Event;
const Handle = core.Handle;
const Operation = core.Operation;
const Fixture = limit.Fixture;
const sync = backend.sync;

/// The reads that fill the offload, one for each operation it lets out.
const filling = core.constants.offload_in_flight_max;
/// The user data of the first operation a scenario holds. Every user data is below
/// `limit.operations`, the length of `Fixture.seen`.
const first_held = filling;
/// The operations a scenario holds at most.
const held_max = 2;
/// The deadline of the held read that times out. It is short, so the scenario waits little.
const held_timeout_ns = core.constants.ns_per_ms;
/// The wait of each tick while a scenario waits for a deadline or for the worker.
const tick_wait_ns = 10 * core.constants.ns_per_ms;

comptime {
    std.debug.assert(first_held + held_max <= limit.operations);
}

// Restates its type's alignment, as every static of the suite does: Zig 0.16's own x86-64 backend
// places a static without it unless the static declares it.
var held_fixture: Fixture align(@alignOf(Fixture)) = undefined;

/// Starts the fixture, and hands out `filling` reads to the worker, which holds them all.
fn fill(fixture: *Fixture) !void {
    try fixture.init();
    errdefer fixture.deinit();
    const batch = fixture.batch[0..filling];
    for (batch, fixture.buffers[0..filling], 0..) |*operation, *buffer, index| {
        operation.* = Operation.read(index, fixture.file, buffer, index * limit.read_bytes);
    }
    try testing.expectEqual(@as(u32, filling), fixture.loop.submit(batch, &.{}));
    var events: [limit.events_per_tick]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try fixture.loop.tick(&events, 0));
    try testing.expectEqual(filling, fixture.pool.submitted());
}

/// A read of the file into the buffer of `user_data`, which the worker can answer in full.
fn read(fixture: *Fixture, user_data: u32) Operation {
    const offset = user_data * limit.read_bytes;
    return Operation.read(user_data, fixture.file, &fixture.buffers[user_data], offset);
}

/// Submits `operation`, and runs one tick that hands over no event and hands out nothing: the
/// operation is held. Returns its handle.
fn hold(fixture: *Fixture, operation: Operation) !Handle {
    var handles: [1]Handle = undefined;
    try testing.expectEqual(@as(u32, 1), fixture.loop.submit(&.{operation}, &handles));
    var events: [limit.events_per_tick]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try fixture.loop.tick(&events, 0));
    try testing.expectEqual(filling, fixture.pool.submitted());
    return handles[0];
}

/// Records the event of `event.user_data`, which must be its first.
fn see(fixture: *Fixture, event: Event) !void {
    try testing.expect(event.user_data < limit.operations);
    try testing.expect(!fixture.seen[event.user_data]);
    fixture.seen[event.user_data] = true;
}

/// Lets the worker answer, and requires exactly one event of `limit.read_bytes` for each of the
/// `reads` reads that go out to it. The worker answers the `filling` reads it holds before the loop
/// ticks, as in `conformance_offload_limit.zig`. A loop that ticks while the worker answers can
/// take one result a tick, and the scenario would then need hundreds of ticks.
fn answer(fixture: *Fixture, reads: u32) !void {
    fixture.pool.holding.store(false, .release);
    try fixture.pool.wait_for_served(filling);
    var events: [limit.events_per_tick]Event = undefined;
    var collected: u32 = 0;
    var round: u32 = 0;
    while (collected < reads and round < conformance.collect_rounds_max) : (round += 1) {
        const produced = try fixture.loop.tick(&events, tick_wait_ns);
        for (events[0..produced]) |event| {
            try see(fixture, event);
            try testing.expectEqual(@as(u32, limit.read_bytes), try event.outcome());
        }
        collected += produced;
    }
    try testing.expectEqual(reads, collected);
    try testing.expectEqual(@as(u32, 0), fixture.loop.in_flight());
    // Nothing more comes: each operation had one final event and no second one.
    try testing.expectEqual(@as(u32, 0), try fixture.loop.tick(&events, 0));
    fixture.pool.stop();
    try testing.expectEqual(reads, fixture.pool.served.load(.acquire));
}

test "a close ends a held write on its descriptor with canceled, before the close's own event" {
    if (conformance.unsupported()) return error.SkipZigTest;
    if (!backend.files_block) return error.SkipZigTest;
    const fixture = &held_fixture;
    try fill(fixture);
    defer fixture.deinit();
    // A second descriptor of the file, which the close closes.
    const closing = try sync.open_file(fixture.path, .{ .create = false, .direct = false });
    const bytes: [limit.read_bytes]u8 = @splat('w');
    _ = try hold(fixture, Operation.write(first_held, closing, &bytes, 0));

    const close = Operation.close(first_held + 1, closing);
    try testing.expectEqual(@as(u32, 1), fixture.loop.submit(&.{close}, &.{}));
    var events: [limit.events_per_tick]Event = undefined;
    try testing.expectEqual(@as(u32, 2), try fixture.loop.tick(&events, 0));
    for (events[0..2]) |event| try see(fixture, event);
    // The write ends first, and never went out to the worker.
    try testing.expectEqual(@as(u64, first_held), events[0].user_data);
    try testing.expectError(error.Canceled, events[0].outcome());
    try testing.expectEqual(@as(u64, first_held + 1), events[1].user_data);
    try testing.expectEqual(@as(u32, 0), try events[1].outcome());
    try testing.expectEqual(filling, fixture.pool.submitted());
    try answer(fixture, filling);
}

test "a held read with a short deadline ends with timeout while it waits for room" {
    if (conformance.unsupported()) return error.SkipZigTest;
    if (!backend.files_block) return error.SkipZigTest;
    const fixture = &held_fixture;
    try fill(fixture);
    defer fixture.deinit();
    var timed = read(fixture, first_held);
    timed.timeout_ns = held_timeout_ns;
    _ = try hold(fixture, timed);

    var events: [limit.events_per_tick]Event = undefined;
    var produced: u32 = 0;
    var round: u32 = 0;
    while (produced == 0 and round < conformance.collect_rounds_max) : (round += 1) {
        produced = try fixture.loop.tick(&events, tick_wait_ns);
    }
    try testing.expectEqual(@as(u32, 1), produced);
    try see(fixture, events[0]);
    try testing.expectEqual(@as(u64, first_held), events[0].user_data);
    try testing.expectError(error.Timeout, events[0].outcome());
    // It ended where it waited: the worker was never given it.
    try testing.expectEqual(filling, fixture.pool.submitted());
    try answer(fixture, filling);
}

test "a cancel ends a held read behind another held one, and the first still goes out" {
    if (conformance.unsupported()) return error.SkipZigTest;
    if (!backend.files_block) return error.SkipZigTest;
    const fixture = &held_fixture;
    try fill(fixture);
    defer fixture.deinit();
    _ = try hold(fixture, read(fixture, first_held));
    const behind = try hold(fixture, read(fixture, first_held + 1));

    fixture.loop.cancel(behind);
    var events: [limit.events_per_tick]Event = undefined;
    try testing.expectEqual(@as(u32, 1), try fixture.loop.tick(&events, 0));
    try see(fixture, events[0]);
    try testing.expectEqual(@as(u64, first_held + 1), events[0].user_data);
    try testing.expectError(error.Canceled, events[0].outcome());
    try testing.expectEqual(filling, fixture.pool.submitted());
    // The fillers, and the first held read once room comes back.
    try answer(fixture, filling + 1);
}
