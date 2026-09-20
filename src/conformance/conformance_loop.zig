//! Loop scenarios: timers, deadlines, cancellation, close, and what a tick does with more work
//! than it has room for. None of them is about one kind of descriptor; where one needs a
//! connected pair, it gets a TCP pair over loopback.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const tcp = @import("conformance_tcp.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Handle = core.Handle;
const Operation = core.Operation;
const sync = backend.sync;

const ms = core.constants.ns_per_ms;

fn timer(user_data: u64, after_ns: u64) Operation {
    return .{ .user_data = user_data, .kind = .{ .timer = .{ .after_ns = after_ns } } };
}

fn receive(user_data: u64, socket: core.Descriptor, buffer: []u8, timeout_ns: u64) Operation {
    return .{ .user_data = user_data, .timeout_ns = timeout_ns, .kind = .{ .receive = .{
        .socket = socket,
        .target = .{ .buffer = .{ .bytes = buffer } },
    } } };
}

test "timers fire in deadline order, and equal deadlines in the order they were submitted" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    try harness.submit(&.{
        timer(30, 3 * ms), timer(10, 1 * ms), timer(20, 2 * ms), timer(21, 2 * ms),
    }, &.{});
    try testing.expectEqual(@as(u32, 4), harness.loop.in_flight());
    var events: [4]Event = undefined;
    try harness.collect(&events);
    const order = [_]u64{ 10, 20, 21, 30 };
    for (events, order) |event, user_data| {
        try testing.expectEqual(user_data, event.user_data);
        try testing.expectEqual(@as(u32, 0), try event.outcome());
    }
    try testing.expectEqual(@as(u32, 0), harness.loop.in_flight());
}

test "a timer does not fire before its delay, and a waiting tick wakes for it and not later" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const delay_ns = 20 * ms;
    try harness.submit(&.{timer(1, delay_ns)}, &.{});
    var events: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&events, 0));
    try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&events, ms));
    // The wait asked for is a second. The tick must come back for the deadline, long before.
    const before = backend.testing.monotonic_ns();
    try testing.expectEqual(@as(u32, 1), try harness.loop.tick(&events, core.constants.ns_per_s));
    const waited = backend.testing.monotonic_ns() - before;
    try testing.expect(waited < core.constants.ns_per_s / 2);
    try testing.expectEqual(@as(u32, 0), try events[0].outcome());
}

test "a cancelled timer ends with canceled at the next tick, never inside cancel" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var handles: [1]Handle = undefined;
    try harness.submit(&.{timer(5, core.constants.ns_per_s)}, &handles);
    var events: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&events, 0));
    harness.loop.cancel(handles[0]);
    try testing.expectEqual(@as(u32, 1), harness.loop.in_flight());
    try testing.expectEqual(@as(u32, 1), try harness.loop.tick(&events, 0));
    try testing.expectError(error.Canceled, events[0].outcome());
    // The handle names nothing now, and cancelling it again is legal.
    harness.loop.cancel(handles[0]);
    try testing.expectEqual(@as(u32, 0), harness.loop.in_flight());
}

test "a receive whose deadline passes ends with timeout, and a cancelled one with canceled" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const listener = try tcp.Listener.open();
    defer sync.close_now(listener.descriptor);
    const pair = try tcp.connected_pair(&harness, &listener);
    defer for (pair) |descriptor| sync.close_now(descriptor);

    var first: [8]u8 = undefined;
    var second: [8]u8 = undefined;
    var handles: [2]Handle = undefined;
    try harness.submit(&.{
        receive(1, pair[0], &first, 2 * ms),
        receive(2, pair[1], &second, 0),
    }, &handles);
    var events: [1]Event = undefined;
    try harness.collect(&events);
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectError(error.Timeout, events[0].outcome());

    harness.loop.cancel(handles[1]);
    try harness.collect(&events);
    try testing.expectEqual(@as(u64, 2), events[0].user_data);
    try testing.expectError(error.Canceled, events[0].outcome());
    try testing.expectEqual(@as(u32, 0), harness.loop.in_flight());
}

test "a close ends the receive in flight for its descriptor with canceled, then closes" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const listener = try tcp.Listener.open();
    defer sync.close_now(listener.descriptor);
    const pair = try tcp.connected_pair(&harness, &listener);
    defer sync.close_now(pair[1]);

    var buffer: [8]u8 = undefined;
    try harness.submit(&.{receive(1, pair[0], &buffer, 0)}, &.{});
    var events: [2]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&events, 0));
    const close: Operation = .{ .user_data = 2, .kind = .{ .close = .{ .descriptor = pair[0] } } };
    try harness.submit(&.{close}, &.{});
    try harness.collect(&events);
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectError(error.Canceled, events[0].outcome());
    try testing.expectEqual(@as(u64, 2), events[1].user_data);
    try testing.expectEqual(@as(u32, 0), try events[1].outcome());
}

test "two receives waiting on one socket both complete, and between them get every byte once" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const listener = try tcp.Listener.open();
    defer sync.close_now(listener.descriptor);
    const pair = try tcp.connected_pair(&harness, &listener);
    defer for (pair) |descriptor| sync.close_now(descriptor);

    var first: [4]u8 = undefined;
    var second: [4]u8 = undefined;
    try harness.submit(&.{ receive(1, pair[1], &first, 0), receive(2, pair[1], &second, 0) }, &.{});
    var none: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&none, 0));
    // Eight bytes fill both buffers. Which receive gets which half is not promised
    // (`Operation.Receive`): io_uring wakes two receives on one socket in an order of its own.
    try harness.submit(&.{tcp.send(3, pair[0], "onetwo!!")}, &.{});
    var events: [3]Event = undefined;
    try harness.collect(&events);
    try testing.expectEqual(@as(u32, 4), try (try Harness.find(&events, 1)).outcome());
    try testing.expectEqual(@as(u32, 4), try (try Harness.find(&events, 2)).outcome());
    const in_order = std.mem.eql(u8, &first, "onet") and std.mem.eql(u8, &second, "wo!!");
    const swapped = std.mem.eql(u8, &first, "wo!!") and std.mem.eql(u8, &second, "onet");
    try testing.expect(in_order or swapped);
}

test "an operation cancelled before any tick ends with canceled and leaves nothing behind" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const listener = try tcp.Listener.open();
    defer sync.close_now(listener.descriptor);
    const pair = try tcp.connected_pair(&harness, &listener);
    defer for (pair) |descriptor| sync.close_now(descriptor);

    var buffer: [8]u8 = undefined;
    var handles: [1]Handle = undefined;
    try harness.submit(&.{receive(1, pair[1], &buffer, 0)}, &handles);
    harness.loop.cancel(handles[0]);
    var events: [1]Event = undefined;
    try harness.collect(&events);
    try testing.expectError(error.Canceled, events[0].outcome());
    try testing.expectEqual(@as(u32, 0), harness.loop.in_flight());
    // The socket is as it was: a receive after the cancelled one gets the next bytes.
    try harness.submit(&.{ receive(2, pair[1], &buffer, 0), tcp.send(3, pair[0], "after") }, &.{});
    var two: [2]Event = undefined;
    try harness.collect(&two);
    try testing.expectEqual(@as(u32, 5), try (try Harness.find(&two, 2)).outcome());
}

/// Longer than a drain can take, so an operation that `cancel_all` missed fails the drain and
/// does not pass by ending on its own.
const outlasts_drain_ns = 2 * core.constants.drain_rounds_max * core.constants.drain_wait_ns;

test "cancel_all and drain leave the loop empty, whatever was in flight" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const listener = try tcp.Listener.open();
    defer sync.close_now(listener.descriptor);
    const pair = try tcp.connected_pair(&harness, &listener);
    defer for (pair) |descriptor| sync.close_now(descriptor);

    var first: [8]u8 = undefined;
    var second: [8]u8 = undefined;
    try harness.submit(&.{
        receive(1, pair[0], &first, 0),
        receive(2, pair[1], &second, outlasts_drain_ns),
        timer(3, outlasts_drain_ns),
        tcp.accept(4, listener.descriptor, true),
    }, &.{});
    var scratch: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&scratch, 0));
    // One more is still queued when the cancel comes: it never reaches the kernel.
    try harness.submit(&.{timer(5, outlasts_drain_ns)}, &.{});
    try testing.expectEqual(@as(u32, 5), harness.loop.in_flight());
    harness.loop.cancel_all();
    try harness.loop.drain(&scratch);
    try testing.expectEqual(@as(u32, 0), harness.loop.in_flight());
    harness.loop.assert_empty();
}

const batch_operations = 2 * conformance.entries;

test "more operations than a tick has room for all complete, and each no-op keeps its user data" {
    if (conformance.unsupported()) return error.SkipZigTest;
    comptime std.debug.assert(batch_operations <= conformance.operations);
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var batch: [batch_operations]Operation = undefined;
    for (&batch, 0..) |*operation, index| operation.* = .{ .user_data = index, .kind = .nop };
    try harness.submit(&batch, &.{});
    var events: [batch_operations]Event = undefined;
    try harness.collect(&events);
    var seen: [batch_operations]bool = @splat(false);
    for (events) |event| {
        try testing.expectEqual(@as(u32, 0), try event.outcome());
        try testing.expect(!seen[event.user_data]);
        seen[event.user_data] = true;
    }
    try testing.expectEqual(@as(u32, 0), harness.loop.in_flight());
}

test "submit takes as many operations as the table has slots and no more" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var batch: [conformance.operations + 2]Operation = undefined;
    for (&batch, 0..) |*operation, index| operation.* = timer(index, 0);
    const slots = conformance.operations;
    try testing.expectEqual(@as(u32, slots), harness.loop.submit(batch[0..slots], &.{}));
    try testing.expectEqual(@as(u32, 0), harness.loop.submit(batch[slots..], &.{}));
    var events: [slots]Event = undefined;
    try harness.collect(&events);
    try testing.expectEqual(@as(u32, 2), harness.loop.submit(batch[slots..], &.{}));
    try harness.collect(events[0..2]);
}

/// Ticks without waiting, at most `poll_rounds_max` times, until one event arrives.
const poll_rounds_max = 1_000_000;

fn poll_one(harness: *Harness) !Event {
    var events: [1]Event = undefined;
    var round: u32 = 0;
    while (round < poll_rounds_max) : (round += 1) {
        if (try harness.loop.tick(&events, 0) == 1) return events[0];
    }
    return error.EventsMissing;
}

test "a loop that polls and never waits still sees bytes that arrive later" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var sender: Harness = undefined;
    try sender.init(1, null);
    defer sender.deinit();
    const listener = try tcp.Listener.open();
    defer sync.close_now(listener.descriptor);
    const pair = try tcp.connected_pair(&harness, &listener);
    defer for (pair) |descriptor| sync.close_now(descriptor);

    var buffer: [8]u8 = undefined;
    try harness.submit(&.{receive(1, pair[1], &buffer, 0)}, &.{});
    var none: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&none, 0));
    // The bytes are sent by another loop, so nothing tells the polling loop they are coming.
    try sender.submit(&.{tcp.send(9, pair[0], "hi")}, &.{});
    var sent: [1]Event = undefined;
    try sender.collect(&sent);
    const received = try poll_one(&harness);
    try testing.expectEqual(@as(u32, 2), try received.outcome());
}
