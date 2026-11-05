//! The adapter's datagram receive and batches, through `std.Io.net` (decision 22, step 3).
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const net = std.Io.net;
const adapter_module = @import("adapter.zig");
const fixtures = @import("adapter_test.zig");
const Fixture = fixtures.Fixture;
const millisecond_ns = fixtures.millisecond_ns;

fn bind(io: Io) !net.Socket {
    const address: net.IpAddress = .{ .ip4 = .loopback(0) };
    return address.bind(io, .{ .mode = .dgram });
}

fn close(io: Io, sockets: []const net.Socket) void {
    for (sockets) |socket| io.vtable.netClose(io.userdata, &.{socket.handle});
}

fn expect_released(fixture: *Fixture) !void {
    for (fixture.adapter.datagrams) |entry| try testing.expectEqual(.free, entry.state);
    try testing.expectEqual(0, fixture.loop.in_flight());
}

/// Arms the receiver's standing receive with one datagram, so what is sent next waits on its queue.
fn arm(io: Io, sender: net.Socket, receiver: net.Socket) !void {
    try sender.send(io, &receiver.address, "x");
    var bytes: [8]u8 = undefined;
    const message = try receiver.receive(io, &bytes);
    try testing.expectEqualStrings("x", message.data);
}

test "a datagram is received with its bytes and its sender's address" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    const sender = try bind(io);
    const receiver = try bind(io);
    try sender.send(io, &receiver.address, "ping");
    var bytes: [64]u8 = undefined;
    const message = try receiver.receive(io, &bytes);
    try testing.expectEqualStrings("ping", message.data);
    try testing.expectEqual(sender.address.getPort(), message.from.getPort());
    try testing.expect(!message.flags.trunc);
    close(io, &.{ sender, receiver });
    try expect_released(&fixture);
}

test "datagrams that came before the call wait on the queue, and one call takes them in order" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    const sender = try bind(io);
    const receiver = try bind(io);
    defer close(io, &.{ sender, receiver });
    try arm(io, sender, receiver);
    for ([_][]const u8{ "a", "bb", "ccc" }) |text| try sender.send(io, &receiver.address, text);
    try io.sleep(.fromMilliseconds(5), .awake);
    var messages: [4]net.IncomingMessage = @splat(.init);
    var bytes: [64]u8 = undefined;
    const failure, const count = receiver.receiveManyTimeout(io, &messages, &bytes, .{}, .none);
    try testing.expectEqual(null, failure);
    try testing.expectEqual(3, count);
    try testing.expectEqualStrings("a", messages[0].data);
    try testing.expectEqualStrings("bb", messages[1].data);
    try testing.expectEqualStrings("ccc", messages[2].data);
}

test "a datagram that finds the queue full goes back to its group, and those queued stay in order" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init_with(.{ .queue = 2 });
    defer fixture.deinit();
    const io = fixture.io();
    const sender = try bind(io);
    const receiver = try bind(io);
    defer close(io, &.{ sender, receiver });
    try arm(io, sender, receiver);
    for ([_][]const u8{ "a", "b", "c", "d" }) |text| try sender.send(io, &receiver.address, text);
    try io.sleep(.fromMilliseconds(5), .awake);
    var messages: [4]net.IncomingMessage = @splat(.init);
    var bytes: [64]u8 = undefined;
    _, const count = receiver.receiveManyTimeout(io, &messages, &bytes, .{}, .none);
    try testing.expectEqual(2, count);
    try testing.expectEqualStrings("a", messages[0].data);
    try testing.expectEqualStrings("b", messages[1].data);
    try testing.expectEqual(2, fixture.adapter.datagrams[0].dropped);
}

test "a receive with nothing to take times out" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    const receiver = try bind(io);
    defer close(io, &.{receiver});
    var bytes: [8]u8 = undefined;
    const before = Io.Clock.awake.now(io);
    try testing.expectError(error.Timeout, receiver.receiveTimeout(io, &bytes, .{ .duration = .{
        .raw = .fromMilliseconds(5),
        .clock = .awake,
    } }));
    try testing.expect(Io.Clock.awake.now(io).nanoseconds - before.nanoseconds >= 5 * millisecond_ns);
}

fn receive_one(io: Io, socket: net.Socket) net.Socket.ReceiveError!void {
    var bytes: [8]u8 = undefined;
    _ = try socket.receive(io, &bytes);
}

test "a cancel ends a receive that waits" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    const receiver = try bind(io);
    var future = io.async(receive_one, .{ io, receiver });
    try io.sleep(.fromMilliseconds(1), .awake);
    try testing.expectError(error.Canceled, future.cancel(io));
    close(io, &.{receiver});
    try expect_released(&fixture);
}

test "a receive that waits while another task closes the socket ends with SocketUnconnected" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    const receiver = try bind(io);
    var future = io.async(receive_one, .{ io, receiver });
    try io.sleep(.fromMilliseconds(1), .awake);
    close(io, &.{receiver});
    try testing.expectError(error.SocketUnconnected, future.await(io));
    try expect_released(&fixture);
}

test "a close gives the queued buffers back to the group" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    const sender = try bind(io);
    defer close(io, &.{sender});
    const first = try bind(io);
    try arm(io, sender, first);
    for (0..3) |_| try sender.send(io, &first.address, "q");
    try io.sleep(.fromMilliseconds(5), .awake);
    close(io, &.{first});
    try expect_released(&fixture);
    // Every buffer of the group is back: a new socket receives as many datagrams as it has.
    const second = try bind(io);
    defer close(io, &.{second});
    try arm(io, sender, second);
    for (0..fixtures.group_buffers) |_| try sender.send(io, &second.address, "r");
    var received: usize = 0;
    var round: u32 = 0;
    while (received < fixtures.group_buffers and round < 100) : (round += 1) {
        var messages: [fixtures.group_buffers]net.IncomingMessage = @splat(.init);
        var bytes: [64]u8 = undefined;
        const failure, const count = second.receiveManyTimeout(io, &messages, &bytes, .{}, .none);
        try testing.expectEqual(null, failure);
        received += count;
    }
    try testing.expectEqual(fixtures.group_buffers, received);
}

test "a datagram longer than the buffer is cut and marked" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    const sender = try bind(io);
    const receiver = try bind(io);
    defer close(io, &.{ sender, receiver });
    try sender.send(io, &receiver.address, "0123456789");
    var bytes: [4]u8 = undefined;
    const message = try receiver.receive(io, &bytes);
    try testing.expectEqualStrings("0123", message.data);
    try testing.expect(message.flags.trunc);
}

test "a batch of two receives completes the one whose socket has a datagram" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    const sender = try bind(io);
    const quiet = try bind(io);
    const busy = try bind(io);
    defer close(io, &.{ sender, quiet, busy });
    var storage: [2]Io.Operation.Storage = undefined;
    var batch: Io.Batch = .init(&storage);
    var quiet_message: [1]net.IncomingMessage = @splat(.init);
    var busy_message: [1]net.IncomingMessage = @splat(.init);
    var quiet_bytes: [8]u8 = undefined;
    var busy_bytes: [8]u8 = undefined;
    batch.addAt(0, .{ .net_receive = .{ .socket_handle = quiet.handle, .message_buffer = &quiet_message, .data_buffer = &quiet_bytes, .flags = .{} } });
    batch.addAt(1, .{ .net_receive = .{ .socket_handle = busy.handle, .message_buffer = &busy_message, .data_buffer = &busy_bytes, .flags = .{} } });
    try sender.send(io, &busy.address, "hi");
    try batch.awaitConcurrent(io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
    const completion = batch.next().?;
    try testing.expectEqual(1, completion.index);
    try testing.expectEqual(1, completion.result.net_receive[1]);
    try testing.expectEqualStrings("hi", busy_message[0].data);
    try testing.expectEqual(null, batch.next());
    // The slot that completed takes a receive again, behind the one still waiting.
    batch.addAt(1, .{ .net_receive = .{ .socket_handle = busy.handle, .message_buffer = &busy_message, .data_buffer = &busy_bytes, .flags = .{} } });
    try sender.send(io, &busy.address, "again");
    try batch.awaitConcurrent(io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
    try testing.expectEqual(1, batch.next().?.index);
    try testing.expectEqualStrings("again", busy_message[0].data);
    batch.cancel(io);
}

test "a group with no free buffer ends the receive, a call reports it once, and the next starts again" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    const sender = try bind(io);
    const receiver = try bind(io);
    defer close(io, &.{ sender, receiver });
    try arm(io, sender, receiver);
    // One datagram more than the group has buffers, while nothing takes them.
    const sent = fixtures.group_buffers + 1;
    for (0..sent) |_| try sender.send(io, &receiver.address, "z");
    try io.sleep(.fromMilliseconds(5), .awake);
    var received: usize = 0;
    var failures: usize = 0;
    var round: u32 = 0;
    while (received < sent and round < 100) : (round += 1) {
        var messages: [sent]net.IncomingMessage = @splat(.init);
        var bytes: [64]u8 = undefined;
        const failure, const count = receiver.receiveManyTimeout(io, &messages, &bytes, .{}, .none);
        if (failure) |reported| {
            try testing.expectEqual(error.SystemResources, reported);
            failures += 1;
        }
        received += count;
    }
    try testing.expectEqual(sent, received);
    // Each backend ends a multishot receive whose group is empty, with `buffers_exhausted`. The
    // datagram it had no buffer for stays in the socket, and the receive the next call starts takes
    // it.
    try testing.expectEqual(1, failures);
}
