//! The reap: what `tick` does with the descriptors the kernel reported ready. For each, the
//! operations waiting on that descriptor and filter are tried again, oldest first, and their events
//! are written straight into the caller's events.
//!
//! One readiness serves as many operations as it can. Each readiness carries in `data` the amount
//! that is ready: the connections a listener has waiting, the bytes a socket can read, or the room
//! it has for bytes to send. The reap stops when a call would block or fails, when the successes
//! have used that amount, or when the events are full. Until 2026-09-23 a readiness served one
//! operation, so a burst of datagrams or connections took one tick each (decision 15, "One
//! correction worth recording"). What is left is reported again, because a multishot operation's
//! filter is level-triggered and every other waiter gets a one-shot filter registered anew
//! (decision 12, point 3).
//!
//! One of the six hot files decision 7 names. This is the plain version.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const perform = @import("kqueue_perform.zig");
const queue_module = @import("kqueue_queue.zig");
const submit_module = @import("kqueue_submit.zig");
const kqueue = @import("kqueue.zig");

const Loop = kqueue.Loop;
const Event = core.Event;
const Operation = core.Operation;
const Filter = core.waiters.Filter;
const Kevent = queue_module.Kevent;

/// Turns readiness into events. The tick asked for no more readiness than `events` has room for,
/// and every readiness keeps room for at least one event: a one-shot filter that fired and was not
/// served would not report again. A readiness uses whatever room the later ones leave.
pub fn reap(loop: *Loop, readiness: []const Kevent, events: []Event) u32 {
    assert(readiness.len <= events.len);
    var produced: u32 = 0;
    for (readiness, 1..) |*ready, position| {
        const filter = filter_of(ready) orelse continue;
        const room = events[produced .. events.len - (readiness.len - position)];
        produced += serve(loop, @intCast(ready.ident), filter, reported_of(ready), room);
    }
    assert(produced <= events.len);
    return produced;
}

/// The filter a readiness names, or null for the wake event, which carries no operation.
fn filter_of(ready: *const Kevent) ?Filter {
    if (ready.filter == std.c.EVFILT.READ) return .read;
    if (ready.filter == std.c.EVFILT.WRITE) return .write;
    assert(ready.filter == std.c.EVFILT.USER);
    return null;
}

/// The amount a readiness reports ready. A change the kernel refused comes back flagged `EV_ERROR`
/// with an errno in `data`. Its one attempt is what reports the refusal, so it gets nothing beyond.
fn reported_of(ready: *const Kevent) u64 {
    if (ready.flags & std.c.EV.ERROR != 0) return 0;
    return if (ready.data > 0) @intCast(ready.data) else 0;
}

/// Serves the waiters of `descriptor` on `filter`, oldest first, until a call would block or fails,
/// the successes have used `reported`, or `events` is full. The first waiter is always tried: a
/// readiness that reports 0, such as the end of a stream, still ends or advances it. Returns how many
/// events it wrote.
fn serve(
    loop: *Loop,
    descriptor: core.Descriptor,
    filter: Filter,
    reported: u64,
    events: []Event,
) u32 {
    assert(events.len >= 1);
    // Null when nobody waits: the waiter was cancelled, and its one-shot filter fired all the same.
    const first = loop.waiters.first(descriptor, filter) orelse return 0;
    // A multishot operation keeps its filter. The filter of any other operation has fired.
    const kept = loop.tables.table.at(first).flags.multishot;
    var left = reported;
    var produced: u32 = 0;
    var departed = false;
    while (produced < events.len) {
        const index = loop.waiters.first(descriptor, filter) orelse break;
        const served = serve_one(loop, descriptor, filter, index) orelse break;
        events[produced] = served.event;
        produced += 1;
        departed = departed or served.departed;
        if (served.event.result < 0 or served.used >= left) break;
        left -= served.used;
    }
    settle(loop, descriptor, filter, kept, departed);
    return produced;
}

/// One waiter's event, what its call used of the readiness, and whether the operation ended.
const Served = struct { event: Event, used: u32, departed: bool };

/// Tries the waiter at `index`, the oldest of `descriptor` on `filter`, again. Null when the call
/// would still block. An operation that ended leaves the list and gives back its slot.
fn serve_one(loop: *Loop, descriptor: core.Descriptor, filter: Filter, index: u32) ?Served {
    const tables = &loop.tables;
    const slot = tables.table.at(index);
    assert(slot.state == .submitted);
    const attempt = perform.attempt(loop, slot);
    if (attempt.outcome != .done) return null;
    var served: Served = .{
        .event = .{ .user_data = slot.user_data, .result = attempt.result, .flags = .{} },
        .used = core.attempt.used(slot.code, attempt.result),
        .departed = true,
    };
    if (attempt.buffer_id) |buffer_id| {
        served.event.flags.buffer = true;
        served.event.flags.buffer_id = buffer_id;
    }
    // A multishot operation goes on after a success, and ends at its first failure or at the end
    // of its stream.
    if (slot.flags.multishot and core.attempt.goes_on(slot.code, attempt.result)) {
        served.event.flags.more = true;
        served.departed = false;
        return served;
    }
    const popped = loop.waiters.pop(tables.table.slots, descriptor, filter);
    assert(popped == index);
    tables.finish(index, slot);
    return served;
}

/// Leaves the filter as the operations still waiting need it, once for the whole readiness. A
/// multishot operation that is still first keeps its filter, which reports again. Otherwise the
/// filter fired or its multishot operation ended, and `after_leaving` gives whoever waits now a
/// one-shot filter.
fn settle(loop: *Loop, descriptor: core.Descriptor, filter: Filter, kept: bool, departed: bool) void {
    if (kept and !departed) return;
    submit_module.after_leaving(loop, descriptor, filter, kept);
}

const testing = std.testing;

const builtin = @import("builtin");
const testing_module = @import("kqueue_testing.zig");

/// A loop with one group of four 8-byte buffers, and a socket pair. The tests receive on the first
/// end and write to the second.
const Fixture = struct {
    const operations = 8;
    const entries = 8;
    const options: Loop.Options = .{ .operations = operations, .entries = entries };
    const group_id = 1;
    const buffer_bytes = 8;
    const buffers = 4;
    const group_bytes = kqueue.buffers.group_bytes(buffers, buffer_bytes);

    memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment),
    group_memory: [group_bytes]u8 align(kqueue.buffers.group_alignment),
    loop: Loop,
    pair: [testing_module.pair_ends]i32,

    fn init(fixture: *Fixture) !void {
        try fixture.loop.init(&fixture.memory, options);
        errdefer fixture.loop.deinit();
        try fixture.loop.provide_buffers(group_id, &fixture.group_memory, buffers, buffer_bytes);
        fixture.pair = try testing_module.nonblocking_pair();
    }

    /// Ends whatever still waits, then closes the pair and the loop.
    fn deinit(fixture: *Fixture) void {
        fixture.loop.cancel_all();
        var events: [operations]Event = undefined;
        // A drain that fails leaves operations in flight, and `Loop.deinit` halts on them.
        fixture.loop.drain(&events) catch {};
        for (fixture.pair) |descriptor| _ = std.c.close(descriptor);
        fixture.loop.deinit();
    }

    /// Writes `count` bytes to the second end, so the first has them to read.
    fn send(fixture: *Fixture, count: usize) !void {
        const bytes: [buffers * buffer_bytes]u8 = @splat('r');
        if (std.c.write(fixture.pair[1], &bytes, count) != count) return error.ShortWrite;
    }

    /// Submits `waiting` and flushes it, so each operation waits on its filter.
    fn wait(fixture: *Fixture, waiting: []const Operation) !void {
        try testing.expectEqual(waiting.len, fixture.loop.submit(waiting, &.{}));
        var events: [1]Event = undefined;
        try testing.expectEqual(@as(u32, 0), try fixture.loop.tick(&events, 0));
    }

    /// The first end reported readable, as the kernel would report it.
    fn readable(fixture: *const Fixture, data: isize, flags: u16) Kevent {
        var ready = queue_module.descriptor_event(fixture.pair[0], std.c.EVFILT.READ, flags);
        ready.data = data;
        return ready;
    }
};

test "one readiness serves a multishot receive until the bytes it reported are read" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.wait(&.{Operation.receive_group(1, fixture.pair[0], Fixture.group_id)});

    // Three buffers' worth arrive before the tick, and one readiness reports all of them.
    const filled = 3;
    try fixture.send(filled * Fixture.buffer_bytes);
    var events: [Fixture.buffers]Event = undefined;
    try testing.expectEqual(@as(u32, filled), try fixture.loop.tick(&events, core.constants.ns_per_s));
    for (events[0..filled]) |event| {
        try testing.expect(event.flags.more);
        try testing.expectEqual(@as(u32, Fixture.buffer_bytes), try event.outcome());
    }
    // The receive goes on and keeps its filter, so the readiness changed no registration.
    try testing.expectEqual(@as(u32, 0), fixture.loop.changes_used);
}

test "a readiness is served no further than the amount it reports" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.wait(&.{Operation.receive_group(1, fixture.pair[0], Fixture.group_id)});
    try fixture.send(3 * Fixture.buffer_bytes);
    var events: [Fixture.buffers]Event = undefined;

    // Reported as one buffer's worth, as when the rest arrived after the kernel looked.
    const one_buffer = [_]Kevent{fixture.readable(Fixture.buffer_bytes, 0)};
    try testing.expectEqual(@as(u32, 1), reap(&fixture.loop, &one_buffer, &events));

    // A refused change carries an errno where the amount goes, and gets its one attempt only.
    const bad_descriptor: isize = @intFromEnum(std.c.E.BADF);
    const refused = [_]Kevent{fixture.readable(bad_descriptor, std.c.EV.ERROR)};
    try testing.expectEqual(@as(u32, 1), reap(&fixture.loop, &refused, &events));
}

test "every readiness keeps room for one event, and the one before it takes what is left" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const other = try testing_module.nonblocking_pair();
    defer for (other) |descriptor| {
        _ = std.c.close(descriptor);
    };
    var own: [1]u8 = undefined;
    try fixture.wait(&.{
        Operation.receive_group(1, fixture.pair[0], Fixture.group_id),
        Operation.receive(2, other[0], &own),
    });
    try fixture.send(3 * Fixture.buffer_bytes);
    try testing.expectEqual(@as(isize, 1), std.c.write(other[1], "o", 1));

    // The multishot receive has three buffers' worth and comes first. The one-shot receive's
    // filter has fired, so it must be served now: it would not report again.
    var other_ready = queue_module.descriptor_event(other[0], std.c.EVFILT.READ, 0);
    other_ready.data = 1;
    const readiness = [_]Kevent{ fixture.readable(3 * Fixture.buffer_bytes, 0), other_ready };
    var events: [3]Event = undefined;
    try testing.expectEqual(@as(u32, 3), reap(&fixture.loop, &readiness, &events));
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectEqual(@as(u64, 1), events[1].user_data);
    try testing.expectEqual(@as(u64, 2), events[2].user_data);
    try testing.expectEqual(@as(u8, 'o'), own[0]);
}

test "one readiness serves one-shot receives in their order, and the one left waits for more" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const receives = 3;
    var own: [receives][Fixture.buffer_bytes]u8 = undefined;
    try fixture.wait(&.{
        Operation.receive(1, fixture.pair[0], &own[0]),
        Operation.receive(2, fixture.pair[0], &own[1]),
        Operation.receive(3, fixture.pair[0], &own[2]),
    });

    // Bytes for two of them: both are served by one readiness, oldest first.
    try fixture.send(2 * Fixture.buffer_bytes);
    var events: [receives]Event = undefined;
    try testing.expectEqual(@as(u32, 2), try fixture.loop.tick(&events, core.constants.ns_per_s));
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectEqual(@as(u64, 2), events[1].user_data);
    // The third gets one one-shot filter, registered once for the readiness.
    try testing.expectEqual(@as(u32, 1), fixture.loop.changes_used);

    try fixture.send(Fixture.buffer_bytes);
    try testing.expectEqual(@as(u32, 1), try fixture.loop.tick(&events, core.constants.ns_per_s));
    try testing.expectEqual(@as(u64, 3), events[0].user_data);
}

test "an operation behind a multishot receive that ran out of buffers is still served" {
    if (!@import("builtin").os.tag.isDarwin()) return error.SkipZigTest;
    const options: Loop.Options = .{ .operations = 4, .entries = 4 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, options);
    defer loop.deinit();
    const group_id = 1;
    const buffer_bytes = 8;
    const group_bytes = comptime kqueue.buffers.group_bytes(1, buffer_bytes);
    var group_memory: [group_bytes]u8 align(kqueue.buffers.group_alignment) = undefined;
    try loop.provide_buffers(group_id, &group_memory, 1, buffer_bytes);
    const pair = try @import("kqueue_testing.zig").nonblocking_pair();
    defer for (pair) |descriptor| {
        _ = std.c.close(descriptor);
    };

    // The multishot receive waits first and keeps the filter; the one-shot receive waits behind.
    var own: [buffer_bytes]u8 = undefined;
    const waiting = [_]Operation{
        Operation.receive_group(1, pair[0], group_id),
        Operation.receive(2, pair[0], &own),
    };
    try testing.expectEqual(@as(u32, 2), loop.submit(&waiting, &.{}));
    var events: [2]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, 0));

    // The first byte takes the group's one buffer, and the caller keeps it.
    try testing.expectEqual(@as(isize, 1), std.c.write(pair[1], "a", 1));
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, core.constants.ns_per_s));
    try testing.expect(events[0].flags.more);

    // The second finds no buffer, so the multishot receive ends and its kept filter goes.
    try testing.expectEqual(@as(isize, 1), std.c.write(pair[1], "b", 1));
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, core.constants.ns_per_s));
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectError(error.BuffersExhausted, events[0].outcome());

    // The receive behind it has a filter of its own, and takes the byte that is waiting.
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, core.constants.ns_per_s));
    try testing.expectEqual(@as(u64, 2), events[0].user_data);
    try testing.expectEqual(@as(u32, 1), try events[0].outcome());
    try testing.expectEqual(@as(u8, 'b'), own[0]);
}
