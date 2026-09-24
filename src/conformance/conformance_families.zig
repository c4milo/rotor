//! Scenarios over both address families. The surface names IPv4 and IPv6 (`core.Address`), and
//! every backend converts both, but until 2026-09-23 no scenario drove a loop over IPv6, so a
//! backend could have broken it unseen (decision 10). The TCP scenario here is the IPv6 twin of
//! `conformance_tcp.zig`'s first one.
//!
//! The datagram scenarios run over both families, because no other scenario checks what a
//! datagram's control messages carry: the local address it was sent to, and its ECN codepoint.
//! The IPv4 one found that kqueue marked a datagram with option 1, Linux's `IP_TOS`, where macOS
//! numbers it 3 (decision 15, "macOS").
//!
//! These do not skip on a host without IPv6: a scenario that skips where nobody reads the count is
//! how two backends drift apart. The Linux gates start their containers with IPv6 switched on.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const tcp = @import("conformance_tcp.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Operation = core.Operation;
const Address = core.Address;
const Outbound = core.datagram.Outbound;
const Received = core.datagram.Received;
const sync = backend.sync;

/// `::1`, port 0 so the kernel chooses one.
const loopback6: Address = blk: {
    var octets: [Address.ipv6_bytes]u8 = @splat(0);
    octets[Address.ipv6_bytes - 1] = 1;
    break :blk Address.ipv6(octets, 0, 0);
};
const loopback4 = Address.ipv4(.{ 127, 0, 0, 1 }, 0);

test "accept, connect, and bytes both ways over IPv6 loopback" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const listener = try tcp.Listener.open_on(&loopback6);
    defer sync.close_now(listener.descriptor);
    try testing.expectEqual(Address.Family.ipv6, listener.address.family);
    const pair = try tcp.connected_pair(&harness, &listener);
    defer for (pair) |descriptor| sync.close_now(descriptor);
    // Both ends are IPv6, and the accepted one is bound where the listener is.
    try testing.expectEqual(Address.Family.ipv6, (try sync.local_address(pair[0])).family);
    const accepted = try sync.local_address(pair[1]);
    try testing.expectEqualSlices(u8, &loopback6.bytes, &accepted.bytes);
    try testing.expectEqual(listener.address.port, accepted.port);

    var to_server: [16]u8 = @splat(0);
    var to_client: [16]u8 = @splat(0);
    try harness.submit(&.{
        Operation.receive(1, pair[1], &to_server), Operation.send(2, pair[0], "ping"),
        Operation.receive(3, pair[0], &to_client), Operation.send(4, pair[1], "pong!"),
    }, &.{});
    var events: [4]Event = undefined;
    try harness.collect(&events);
    try testing.expectEqual(@as(u32, 4), try (try Harness.find(&events, 1)).outcome());
    try testing.expectEqual(@as(u32, 5), try (try Harness.find(&events, 3)).outcome());
    try testing.expectEqualStrings("ping", to_server[0..4]);
    try testing.expectEqualStrings("pong!", to_client[0..5]);
}

/// One group per socket, because a group serves one socket's receives and both sockets receive.
const receiver_group = 1;
const sender_group = 2;
const group_buffers = 4;
const buffer_bytes = 512;
const group_bytes = backend.buffers.group_bytes(group_buffers, buffer_bytes);
var receiver_memory: [group_bytes]u8 align(backend.buffers.group_alignment) = undefined;
var sender_memory: [group_bytes]u8 align(backend.buffers.group_alignment) = undefined;

const question = "which address?";
const answer = "this one";

const user_data_receiver = 1;
const user_data_sender = 2;
const user_data_question = 3;
const user_data_answer = 4;

/// A bound receiver and a sender of one family, each with a multishot receive armed.
const Pair = struct {
    receiver: core.Descriptor,
    sender: core.Descriptor,
    address: Address,
    receives: [2]core.Handle = undefined,

    fn open(harness: *Harness, loopback: *const Address) !Pair {
        const receiver = try sync.open_datagram(loopback.family, loopback, .{});
        errdefer sync.close_now(receiver);
        const sender = try sync.open_datagram(loopback.family, loopback, .{});
        errdefer sync.close_now(sender);
        var pair: Pair = .{
            .receiver = receiver,
            .sender = sender,
            .address = try sync.local_address(receiver),
        };
        try harness.submit(&.{
            Operation.receive_from(user_data_receiver, receiver, receiver_group),
            Operation.receive_from(user_data_sender, sender, sender_group),
        }, &pair.receives);
        return pair;
    }

    /// Ends both receives, empties the loop, and closes both sockets.
    fn close(pair: *const Pair, harness: *Harness) !void {
        for (pair.receives) |handle| harness.loop.cancel(handle);
        var events: [8]Event = undefined;
        try harness.loop.drain(&events);
        sync.close_now(pair.receiver);
        sync.close_now(pair.sender);
    }
};

/// Sends `bytes` from `socket` with `out`, and hands back the datagram `receive_user_data` took,
/// copied out of its buffer, which goes back to `group`.
fn cross(
    harness: *Harness,
    socket: core.Descriptor,
    bytes: []const u8,
    out: *const Outbound,
    send_user_data: u64,
    receive_user_data: u64,
    group: u16,
) !Received {
    try harness.submit(&.{Operation.send_to(send_user_data, socket, bytes, out)}, &.{});
    var events: [2]Event = undefined;
    try harness.collect(&events);
    try testing.expectEqual(@as(u32, @intCast(bytes.len)), try (try Harness.find(
        &events,
        send_user_data,
    )).outcome());
    const got = try Harness.find(&events, receive_user_data);
    try testing.expect(got.flags.more);
    const delivery = harness.loop.datagram(group, got);
    try testing.expectEqualStrings(bytes, delivery.bytes);
    harness.loop.give_back_buffer(group, got.flags.buffer_id);
    return delivery.from;
}

/// What a received datagram must carry: its peer, the loopback address it was sent to, and the
/// codepoint it was sent with.
fn expect_received(from: *const Received, peer: *const Address, loopback: *const Address) !void {
    try testing.expectEqual(loopback.family, from.peer.family);
    try testing.expectEqual(peer.port, from.peer.port);
    try testing.expectEqualSlices(u8, &peer.bytes, &from.peer.bytes);
    try testing.expect(from.flags.local);
    try testing.expectEqual(loopback.family, from.local.family);
    try testing.expectEqualSlices(u8, &loopback.bytes, &from.local.bytes);
}

/// A question with an ECN codepoint, then the reply `Outbound.reply_to` makes from what it carried.
fn question_and_answer(loopback: *const Address) !void {
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    try harness.loop.provide_datagram_buffers(receiver_group, &receiver_memory, group_buffers, buffer_bytes, .{});
    try harness.loop.provide_datagram_buffers(sender_group, &sender_memory, group_buffers, buffer_bytes, .{});
    const pair = try Pair.open(&harness, loopback);
    const sender_address = try sync.local_address(pair.sender);

    const asked: Outbound = .{
        .peer = pair.address,
        .local = undefined,
        .segment_bytes = 0,
        .ecn = .ect0,
        .flags = .{ .peer = true, .ecn = true },
    };
    const heard = try cross(&harness, pair.sender, question, &asked, user_data_question, user_data_receiver, receiver_group);
    try expect_received(&heard, &sender_address, loopback);
    try testing.expect(heard.flags.ecn);
    try testing.expectEqual(core.datagram.Ecn.ect0, heard.ecn);

    // The answer goes back from the address the question was sent to, unmarked.
    const reply = Outbound.reply_to(&heard);
    const answered = try cross(&harness, pair.receiver, answer, &reply, user_data_answer, user_data_sender, sender_group);
    try expect_received(&answered, &pair.address, loopback);
    try testing.expectEqual(core.datagram.Ecn.not_ect, answered.ecn);
    try pair.close(&harness);
}

test "an IPv6 datagram carries its peer, its local address and its codepoint, and a reply returns" {
    if (conformance.unsupported()) return error.SkipZigTest;
    try question_and_answer(&loopback6);
}

test "an IPv4 datagram carries its peer, its local address and its codepoint, and a reply returns" {
    if (conformance.unsupported()) return error.SkipZigTest;
    try question_and_answer(&loopback4);
}
