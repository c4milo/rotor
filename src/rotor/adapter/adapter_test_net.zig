//! The adapter's network calls, through `std.Io.net` as code written against `std.Io` makes them
//! (decision 22, check 3). Every socket is on loopback.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const net = std.Io.net;
const posix = std.posix;
const rotor = @import("../rotor.zig");
const adapter_module = @import("adapter.zig");
const network = @import("adapter_net.zig");
const fixtures = @import("adapter_test.zig");
const Fixture = fixtures.Fixture;

const rounds_max = 100;

fn loopback() net.IpAddress {
    return .{ .ip4 = .loopback(0) };
}

/// Accepts one connection and echoes it until the peer stops sending.
fn serve_one(io: Io, server: *net.Server, peer: *net.IpAddress) anyerror!void {
    const stream = try server.accept(io);
    defer stream.close(io);
    peer.* = stream.socket.address;
    var read_buffer: [64]u8 = undefined;
    var write_buffer: [64]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var round: u32 = 0;
    while (round < rounds_max) : (round += 1) {
        const bytes = reader.interface.peekGreedy(1) catch |failure| switch (failure) {
            error.EndOfStream => return,
            else => return failure,
        };
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
        reader.interface.toss(bytes.len);
    }
    return error.TooManyRounds;
}

test "a task accepts and echoes, and the client reads its bytes back and then the end" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    const listen_at = loopback();
    var server = try listen_at.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    try testing.expect(server.socket.address.getPort() != 0);
    var peer: net.IpAddress = undefined;
    var served = io.async(serve_one, .{ io, &server, &peer });

    const stream = try server.socket.address.connect(io, .{ .mode = .stream });
    const local = try rotor.sync.local_address(stream.socket.handle);
    var read_buffer: [64]u8 = undefined;
    var write_buffer: [64]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    const message = "hello, rotor";
    try writer.interface.writeAll(message);
    try writer.interface.flush();
    var echoed: [message.len]u8 = undefined;
    try reader.interface.readSliceAll(&echoed);
    try testing.expectEqualStrings(message, &echoed);
    // The server sees the end of the stream from the shutdown alone, and returns.
    try stream.shutdown(io, .send);
    try served.await(io);
    try testing.expectError(error.EndOfStream, reader.interface.takeByte());
    stream.close(io);
    // The server saw the client's own address.
    try testing.expectEqual(local.port, peer.getPort());
    try testing.expectEqual(0, fixture.loop.in_flight());
}

fn accept_one(io: Io, server: *net.Server) net.Server.AcceptError!void {
    const stream = try server.accept(io);
    stream.close(io);
}

test "a cancel ends an accept that waits, with Canceled" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    const listen_at = loopback();
    var server = try listen_at.listen(io, .{});
    defer server.deinit(io);
    var future = io.async(accept_one, .{ io, &server });
    try io.sleep(.fromMilliseconds(1), .awake);
    try testing.expectError(error.Canceled, future.cancel(io));
    try testing.expectEqual(0, fixture.loop.in_flight());
}

test "a connect to a port where nothing listens is refused" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    const listen_at = loopback();
    var server = try listen_at.listen(io, .{});
    const closed = server.socket.address;
    server.deinit(io);
    try testing.expectError(error.ConnectionRefused, closed.connect(io, .{ .mode = .stream }));
}

test "a datagram goes from one bound socket to another" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    const bind_at = loopback();
    const sender = try bind_at.bind(io, .{ .mode = .dgram });
    const receiver = try bind_at.bind(io, .{ .mode = .dgram });
    // std 0.16.0's `Socket.closeMany` does not compile: it hands the table sockets where the
    // table takes handles. So the test closes both through the table itself.
    defer io.vtable.netClose(io.userdata, &.{ sender.handle, receiver.handle });
    try sender.send(io, &receiver.address, "ping");
    // The receiver's socket may not block, so the test reads it until the datagram is there.
    var bytes: [16]u8 = undefined;
    var round: u32 = 0;
    const count = while (round < rounds_max) : (round += 1) {
        const rc = posix.system.recvfrom(receiver.handle, &bytes, bytes.len, 0, null, null);
        if (posix.errno(rc) == .SUCCESS) break @as(usize, @intCast(rc));
        try io.sleep(.fromMilliseconds(1), .awake);
    } else return error.NoDatagram;
    try testing.expectEqualStrings("ping", bytes[0..count]);
}

test "a bind refuses a stream socket and a listen refuses a datagram one" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    const address = loopback();
    try testing.expectError(error.SocketModeUnsupported, address.bind(io, .{ .mode = .stream }));
    try testing.expectError(error.SocketModeUnsupported, address.listen(io, .{ .mode = .dgram }));
}

test "a write sends the header first, then each buffer, then the repeated buffer once" {
    try testing.expectEqualStrings("head", network.first_bytes("head", &.{ "a", "b" }, 1));
    try testing.expectEqualStrings("a", network.first_bytes("", &.{ "", "a", "b" }, 1));
    try testing.expectEqualStrings("b", network.first_bytes("", &.{ "", "b" }, 3));
    try testing.expectEqualStrings("", network.first_bytes("", &.{"b"}, 0));
}

test "an address keeps its family, its bytes and its port through rotor's form" {
    const four: net.IpAddress = .{ .ip4 = .{ .bytes = .{ 10, 0, 0, 7 }, .port = 4433 } };
    const back_four = network.from_rotor(network.to_rotor(&four));
    try testing.expectEqualSlices(u8, &four.ip4.bytes, &back_four.ip4.bytes);
    try testing.expectEqual(4433, back_four.ip4.port);
    const six: net.IpAddress = .{ .ip6 = .{ .bytes = @splat(9), .port = 443, .interface = .{ .index = 3 } } };
    const back_six = network.from_rotor(network.to_rotor(&six));
    try testing.expectEqualSlices(u8, &six.ip6.bytes, &back_six.ip6.bytes);
    try testing.expectEqual(443, back_six.ip6.port);
    try testing.expectEqual(3, back_six.ip6.interface.index);
}

test "a task canceled before it runs gets Canceled from its first call, and submits nothing" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    const listen_at = loopback();
    var server = try listen_at.listen(io, .{});
    defer server.deinit(io);
    var future = io.async(accept_one, .{ io, &server });
    try testing.expectError(error.Canceled, future.cancel(io));
    try testing.expectEqual(0, fixture.loop.in_flight());
}

fn send_one(io: Io, server: *net.Server, bytes: []const u8) anyerror!void {
    const stream = try server.accept(io);
    defer stream.close(io);
    var writer = stream.writer(io, &.{});
    try writer.interface.writeAll(bytes);
}

test "a read skips an empty buffer and receives into the first one with room" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    const listen_at = loopback();
    var server = try listen_at.listen(io, .{});
    defer server.deinit(io);
    var sent = io.async(send_one, .{ io, &server, "abc" });
    const stream = try server.socket.address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    try sent.await(io);
    var bytes: [8]u8 = undefined;
    var empty: [0]u8 = .{};
    var data = [_][]u8{ &empty, &bytes };
    const count = try io.vtable.netRead(io.userdata, stream.socket.handle, &data);
    try testing.expect(count >= 1);
    try testing.expectEqualStrings("abc"[0..count], bytes[0..count]);
}
