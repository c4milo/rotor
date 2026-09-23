//! The loop against the real kernel (decision 10, point 2). Every test here enters io_uring, so
//! each runs under Linux alone: `tools/linux_test.sh` runs them in Docker. The sockets are a
//! connected pair from `socketpair(2)`, so these tests need nothing the module's other files
//! provide; TCP, O_DIRECT files and both backends' agreement are the conformance suite's. A
//! scenario that suite runs on every backend is not repeated here: what is left is what only a
//! ring has, such as more operations than it has submission entries.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const linux = std.os.linux;
const core = @import("core");
const uring = @import("uring.zig");

const Loop = uring.Loop;
const sync_module = uring.sync;
const buffers_module = uring.buffers;
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

/// Datagram operations sent, which must exceed the ring's `entries` so that the per-entry
/// message scratch has to be reused. Three times over is enough to catch a counter that only
/// rises.
const datagram_rounds = 3 * 8;

const datagram_group = 0;
const datagram_buffers = 4;
const datagram_buffer_bytes = core.datagram.prefix_bytes(.{}) + 64;

test "more datagrams than the ring has entries reuse the message scratch" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(.{ .operations = operations, .entries = 8 });
    defer fixture.loop.deinit();

    const group_bytes = comptime buffers_module.group_bytes(datagram_buffers, datagram_buffer_bytes);
    var group_memory: [group_bytes]u8 align(buffers_module.group_alignment) = undefined;
    try fixture.loop.provide_datagram_buffers(
        datagram_group,
        &group_memory,
        datagram_buffers,
        datagram_buffer_bytes,
        .{},
    );

    const any_port = core.Address.ipv4(.{ 127, 0, 0, 1 }, 0);
    const receiver = try sync_module.open_datagram(.ipv4, &any_port, .{});
    defer sync_module.close_now(receiver);
    const sender = try sync_module.open_datagram(.ipv4, null, .{});
    defer sync_module.close_now(sender);
    var out: core.datagram.Outbound = .{
        .peer = try sync_module.local_address(receiver),
        .local = undefined,
        .segment_bytes = 0,
        .ecn = .not_ect,
        .flags = .{ .peer = true },
    };

    var handles: [1]core.Handle = undefined;
    _ = fixture.loop.submit(&.{.{ .user_data = 1, .kind = .{ .receive_from = .{
        .socket = receiver,
        .group = datagram_group,
    } } }}, &handles);

    // One send per round, each taking one entry and one message scratch. The scratch is one per
    // entry and is reused from the start each tick, so a counter that only rose would stop the
    // loop on the ninth round here.
    var events: [8]Event = undefined;
    var round: u32 = 0;
    while (round < datagram_rounds) : (round += 1) {
        _ = fixture.loop.submit(&.{.{ .user_data = 2, .kind = .{ .send_to = .{
            .socket = sender,
            .buffer = .{ .bytes = "scratch" },
            .to = &out,
        } } }}, &.{});
        const count = try fixture.loop.tick(&events, collect_wait_ns);
        for (events[0..count]) |event| {
            if (event.user_data == 1) fixture.loop.give_back_buffer(
                datagram_group,
                event.flags.buffer_id,
            );
        }
    }

    fixture.loop.cancel_all();
    try fixture.loop.drain(&events);
}
