//! The loop against the real kernel (decision 10, point 2). Every test here enters io_uring, so
//! each runs under Linux alone: `tools/linux_test.sh` runs them in Docker. The sockets are a
//! connected pair from `socketpair(2)`, so these tests need nothing the module's other files
//! provide; TCP, O_DIRECT files and both backends' agreement are the conformance suite's.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const linux = std.os.linux;
const core = @import("core");
const constants = @import("constants.zig");
const uring = @import("uring.zig");

const Loop = uring.Loop;
const Event = core.Event;
const Handle = core.Handle;
const Operation = core.Operation;

const operations = 16;
const memory_alignment = core.layout.memory_alignment;
const memory_bytes = Loop.memory_bytes(.{ .operations = operations, .entries = 8 });

/// The most rounds `Fixture.collect` ticks before it gives up: with a 10 ms wait each, a second.
const collect_rounds_max = 100;
const collect_wait_ns = 10 * core.constants.ns_per_ms;

const Fixture = struct {
    memory: [memory_bytes]u8 align(core.layout.memory_alignment),
    loop: Loop,

    fn init(fixture: *Fixture, options: Loop.Options) !void {
        try fixture.loop.init(&fixture.memory, options);
    }

    /// Ticks until `events` is full, and fails when it is not full within a second.
    fn collect(fixture: *Fixture, events: []Event) !void {
        var filled: usize = 0;
        var round: u32 = 0;
        while (filled < events.len and round < collect_rounds_max) : (round += 1) {
            filled += try fixture.loop.tick(events[filled..], collect_wait_ns);
        }
        if (filled < events.len) return error.EventsMissing;
    }
};

fn socket_pair() ![2]i32 {
    var descriptors: [2]i32 = undefined;
    const kind = linux.SOCK.STREAM | linux.SOCK.CLOEXEC;
    const rc = linux.socketpair(linux.AF.UNIX, kind, 0, &descriptors);
    if (linux.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    return descriptors;
}

fn close_pair(descriptors: [2]i32) void {
    for (descriptors) |descriptor| _ = linux.close(descriptor);
}

fn timer(user_data: u64, after_ns: u64) Operation {
    return .{ .user_data = user_data, .kind = .{ .timer = .{ .after_ns = after_ns } } };
}

fn receive(user_data: u64, socket: i32, buffer: []u8, timeout_ns: u64) Operation {
    return .{ .user_data = user_data, .timeout_ns = timeout_ns, .kind = .{ .receive = .{
        .socket = socket,
        .target = .{ .buffer = .{ .bytes = buffer } },
    } } };
}

fn send(user_data: u64, socket: i32, bytes: []const u8) Operation {
    return .{ .user_data = user_data, .kind = .{ .send = .{
        .socket = socket,
        .buffer = .{ .bytes = bytes },
    } } };
}

test "timers fire in deadline order, and equal deadlines in the order they were submitted" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(.{ .operations = operations, .entries = 8 });
    defer fixture.loop.deinit();
    const ms = core.constants.ns_per_ms;
    const taken = fixture.loop.submit(&.{
        timer(30, 3 * ms), timer(10, 1 * ms), timer(20, 2 * ms), timer(21, 2 * ms),
    }, &.{});
    try testing.expectEqual(@as(u32, 4), taken);
    try testing.expectEqual(@as(u32, 4), fixture.loop.in_flight());
    var events: [4]Event = undefined;
    try fixture.collect(&events);
    const order = [_]u64{ 10, 20, 21, 30 };
    for (events, order) |event, user_data| {
        try testing.expectEqual(user_data, event.user_data);
        try testing.expectEqual(@as(u32, 0), try event.outcome());
    }
    try testing.expectEqual(@as(u32, 0), fixture.loop.in_flight());
}

test "a timer does not fire before its delay" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(.{ .operations = operations, .entries = 8 });
    defer fixture.loop.deinit();
    _ = fixture.loop.submit(&.{timer(1, 20 * core.constants.ns_per_ms)}, &.{});
    var events: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try fixture.loop.tick(&events, 0));
    try testing.expectEqual(@as(u32, 0), try fixture.loop.tick(&events, core.constants.ns_per_ms));
    try fixture.collect(&events);
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * core.constants.ns_per_s + @as(u64, @intCast(now.nsec));
}

test "a tick that waits wakes for the nearest deadline, long before its own wait is over" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(.{ .operations = operations, .entries = 8 });
    defer fixture.loop.deinit();
    const delay_ns = 5 * core.constants.ns_per_ms;
    _ = fixture.loop.submit(&.{timer(1, delay_ns)}, &.{});
    var events: [1]Event = undefined;
    const before = monotonic_ns();
    try testing.expectEqual(@as(u32, 1), try fixture.loop.tick(&events, core.constants.ns_per_s));
    const waited = monotonic_ns() - before;
    try testing.expect(waited >= delay_ns);
    try testing.expect(waited < core.constants.ns_per_s / 2);
    try testing.expectEqual(@as(u32, 0), try events[0].outcome());
}

test "a cancelled timer ends with canceled at the next tick, never inside cancel" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(.{ .operations = operations, .entries = 8 });
    defer fixture.loop.deinit();
    var handles: [1]Handle = undefined;
    _ = fixture.loop.submit(&.{timer(5, core.constants.ns_per_s)}, &handles);
    var events: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try fixture.loop.tick(&events, 0));
    fixture.loop.cancel(handles[0]);
    try testing.expectEqual(@as(u32, 1), fixture.loop.in_flight());
    try testing.expectEqual(@as(u32, 1), try fixture.loop.tick(&events, 0));
    try testing.expectError(error.Canceled, events[0].outcome());
    // The handle names nothing now, and cancelling it again is legal.
    fixture.loop.cancel(handles[0]);
    try testing.expectEqual(@as(u32, 0), fixture.loop.in_flight());
}

test "a receive gets the bytes a send wrote" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(.{ .operations = operations, .entries = 8 });
    defer fixture.loop.deinit();
    const pair = try socket_pair();
    defer close_pair(pair);
    var buffer: [16]u8 = @splat(0);
    _ = fixture.loop.submit(&.{ receive(1, pair[0], &buffer, 0), send(2, pair[1], "rotor") }, &.{});
    var events: [2]Event = undefined;
    try fixture.collect(&events);
    for (events) |event| try testing.expectEqual(@as(u32, 5), try event.outcome());
    try testing.expectEqualStrings("rotor", buffer[0..5]);
}

test "a receive whose deadline passes ends with timeout, and a cancelled one with canceled" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(.{ .operations = operations, .entries = 8 });
    defer fixture.loop.deinit();
    const pair = try socket_pair();
    defer close_pair(pair);
    var first: [8]u8 = undefined;
    var second: [8]u8 = undefined;
    var handles: [2]Handle = undefined;
    _ = fixture.loop.submit(&.{
        receive(1, pair[0], &first, 2 * core.constants.ns_per_ms),
        receive(2, pair[1], &second, 0),
    }, &handles);
    var events: [1]Event = undefined;
    try fixture.collect(&events);
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectError(error.Timeout, events[0].outcome());

    fixture.loop.cancel(handles[1]);
    try fixture.collect(&events);
    try testing.expectEqual(@as(u64, 2), events[0].user_data);
    try testing.expectError(error.Canceled, events[0].outcome());
    try testing.expectEqual(@as(u32, 0), fixture.loop.in_flight());
}

test "more operations than submission entries all complete, a ring's worth per tick" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(.{ .operations = operations, .entries = 2 });
    defer fixture.loop.deinit();
    const pair = try socket_pair();
    defer close_pair(pair);
    var batch: [8]Operation = undefined;
    for (&batch, 0..) |*operation, index| operation.* = send(index, pair[1], "x");
    try testing.expectEqual(@as(u32, 8), fixture.loop.submit(&batch, &.{}));
    var events: [8]Event = undefined;
    try fixture.collect(&events);
    for (events) |event| try testing.expectEqual(@as(u32, 1), try event.outcome());
}

/// Ticks without waiting, at most `poll_rounds_max` times, until one event arrives.
const poll_rounds_max = 100_000;

fn poll_one(fixture: *Fixture) !Event {
    var events: [1]Event = undefined;
    var round: u32 = 0;
    while (round < poll_rounds_max) : (round += 1) {
        if (try fixture.loop.tick(&events, 0) == 1) return events[0];
    }
    return error.EventsMissing;
}

test "a loop that polls and never waits still sees a completion and a posted message" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var registry: uring.Registry = undefined;
    var registry_memory: [uring.Registry.memory_bytes(2)]u8 align(memory_alignment) = undefined;
    registry.init(&registry_memory, 2);
    var sender: Fixture = undefined;
    try sender.init(.{ .operations = operations, .entries = 8, .id = 0, .registry = &registry });
    defer sender.loop.deinit();
    var poller: Fixture = undefined;
    try poller.init(.{ .operations = operations, .entries = 8, .id = 1, .registry = &registry });
    defer poller.loop.deinit();
    const pair = try socket_pair();
    defer close_pair(pair);

    // A receive whose bytes arrive later, written outside any loop: the kernel defers the
    // completion until the polling loop enters it, and nothing else tells the loop to.
    var buffer: [8]u8 = undefined;
    _ = poller.loop.submit(&.{receive(1, pair[0], &buffer, 0)}, &.{});
    var none: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try poller.loop.tick(&none, 0));
    try testing.expectEqual(@as(usize, 2), linux.write(pair[1], "hi", 2));
    const received = try poll_one(&poller);
    try testing.expectEqual(@as(u32, 2), try received.outcome());

    _ = sender.loop.submit(&.{.{ .user_data = 9, .kind = .{ .post = .{
        .target = 1,
        .message = .{ .payload = 5, .tag = 6 },
    } } }}, &.{});
    var sent: [1]Event = undefined;
    try sender.collect(&sent);
    const message = try poll_one(&poller);
    try testing.expect(message.flags.message);
    try testing.expectEqual(@as(u64, 5), message.user_data);
}

test "a batch of no-ops completes in one tick, each with its own user data" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(.{ .operations = operations, .entries = 8 });
    defer fixture.loop.deinit();
    var batch: [8]Operation = undefined;
    for (&batch, 0..) |*operation, index| operation.* = .{ .user_data = index, .kind = .nop };
    try testing.expectEqual(@as(u32, 8), fixture.loop.submit(&batch, &.{}));
    var events: [8]Event = undefined;
    const produced = try fixture.loop.tick(&events, core.constants.ns_per_s);
    try testing.expectEqual(@as(u32, 8), produced);
    var seen: u64 = 0;
    for (events) |event| {
        try testing.expectEqual(@as(u32, 0), try event.outcome());
        seen |= @as(u64, 1) << @intCast(event.user_data);
    }
    try testing.expectEqual(@as(u64, 0xFF), seen);
}

test "submit takes as many operations as the table has slots and no more" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(.{ .operations = 4, .entries = 8 });
    defer fixture.loop.deinit();
    var batch: [6]Operation = undefined;
    for (&batch, 0..) |*operation, index| operation.* = timer(index, 0);
    try testing.expectEqual(@as(u32, 4), fixture.loop.submit(&batch, &.{}));
    try testing.expectEqual(@as(u32, 0), fixture.loop.submit(batch[4..], &.{}));
    var events: [4]Event = undefined;
    try fixture.collect(&events);
    try testing.expectEqual(@as(u32, 2), fixture.loop.submit(batch[4..], &.{}));
    try fixture.collect(events[0..2]);
}

test "a close cancels the receive in flight for its descriptor, then closes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(.{ .operations = operations, .entries = 8 });
    defer fixture.loop.deinit();
    const pair = try socket_pair();
    defer _ = linux.close(pair[1]);
    var buffer: [8]u8 = undefined;
    _ = fixture.loop.submit(&.{receive(1, pair[0], &buffer, 0)}, &.{});
    var events: [2]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try fixture.loop.tick(&events, 0));
    const close: Operation = .{ .user_data = 2, .kind = .{ .close = .{ .descriptor = pair[0] } } };
    _ = fixture.loop.submit(&.{close}, &.{});
    try fixture.collect(&events);
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectError(error.Canceled, events[0].outcome());
    try testing.expectEqual(@as(u64, 2), events[1].user_data);
    try testing.expectEqual(@as(u32, 0), try events[1].outcome());
}

test "a post reaches the other loop with its payload and tag, and a missing loop is an error" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var registry: uring.Registry = undefined;
    var registry_memory: [uring.Registry.memory_bytes(2)]u8 align(memory_alignment) = undefined;
    registry.init(&registry_memory, 2);
    var sender: Fixture = undefined;
    try sender.init(.{ .operations = operations, .entries = 8, .id = 0, .registry = &registry });
    defer sender.loop.deinit();
    var receiver: Fixture = undefined;
    try receiver.init(.{ .operations = operations, .entries = 8, .id = 1, .registry = &registry });
    defer receiver.loop.deinit();

    const message: core.Message = .{ .payload = 0xFEED_FACE_CAFE_BEEF, .tag = 77 };
    _ = sender.loop.submit(&.{
        .{ .user_data = 1, .kind = .{ .post = .{ .target = 1, .message = message } } },
        .{ .user_data = 2, .kind = .{ .post = .{ .target = 9, .message = message } } },
    }, &.{});
    var sent: [2]Event = undefined;
    try sender.collect(&sent);
    for (sent) |event| {
        if (event.user_data == 1) try testing.expectEqual(@as(u32, 0), try event.outcome());
        if (event.user_data == 2) try testing.expectError(error.LoopNotFound, event.outcome());
    }

    var received: [1]Event = undefined;
    try receiver.collect(&received);
    try testing.expect(received[0].flags.message);
    try testing.expectEqual(message.payload, received[0].user_data);
    try testing.expectEqual(@as(i32, 77), received[0].result);
    try testing.expectEqual(@as(u32, 0), receiver.loop.in_flight());
}

const group_buffers = 2;
const group_buffer_bytes = 8;

test "a multishot receive names the provided buffer of each event and ends when they run out" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(.{ .operations = operations, .entries = 8 });
    defer fixture.loop.deinit();
    const pair = try socket_pair();
    defer close_pair(pair);
    const ring_alignment = constants.buffer_ring_alignment;
    var ring_memory: [uring.buffers.ring_bytes(group_buffers)]u8 align(ring_alignment) = undefined;
    var memory: [group_buffers * group_buffer_bytes]u8 = undefined;
    try fixture.loop.provide_buffers(3, &ring_memory, &memory, group_buffer_bytes);

    _ = fixture.loop.submit(&.{.{ .user_data = 1, .kind = .{ .receive = .{
        .socket = pair[0],
        .target = .{ .group = 3 },
        .multishot = true,
    } } }}, &.{});
    var events: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try fixture.loop.tick(&events, 0));

    _ = fixture.loop.submit(&.{send(2, pair[1], "first")}, &.{});
    var pair_of_events: [2]Event = undefined;
    try fixture.collect(&pair_of_events);
    for (pair_of_events) |event| {
        if (event.user_data != 1) continue;
        try testing.expect(event.flags.more and event.flags.buffer);
        const bytes = fixture.loop.provided_buffer(3, event.flags.buffer_id);
        try testing.expectEqualStrings("first", bytes[0..try event.outcome()]);
    }
    try testing.expectEqual(@as(u32, 1), fixture.loop.in_flight());

    // One buffer is left and none is given back: the second message takes it, and the third
    // finds the group empty, which ends the operation.
    _ = fixture.loop.submit(&.{send(3, pair[1], "second")}, &.{});
    try fixture.collect(&pair_of_events);
    _ = fixture.loop.submit(&.{send(4, pair[1], "third")}, &.{});
    try fixture.collect(&pair_of_events);
    var ended = false;
    for (pair_of_events) |event| {
        if (event.user_data != 1) continue;
        try testing.expect(event.is_final());
        try testing.expectError(error.BuffersExhausted, event.outcome());
        ended = true;
    }
    try testing.expect(ended);
    try testing.expectEqual(@as(u32, 0), fixture.loop.in_flight());
}
