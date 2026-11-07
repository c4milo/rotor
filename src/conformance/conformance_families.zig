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
const user_data_stranger = 5;

/// The datagram a third socket sends to each receiver before a scenario. Under parallel runs,
/// another process can send to a receiver that is not connected. macOS can give a socket on `::`
/// the port of a socket on 127.0.0.1, and the IPv4 datagrams to that port then reach the 127.0.0.1
/// socket. The scenario must put this datagram aside. Its bytes are not `question` or `answer`, so
/// a scenario that takes it fails its check of the bytes.
const stranger_payload = "from a stranger";
/// The most receivers `send_strangers` sends to.
const strangers_max = 2;

/// One group per socket, because a group serves one socket's receives and both sockets receive.
const Groups = struct {
    receiver: core.BufferGroup,
    sender: core.BufferGroup,

    /// Reserves both groups on the harness's loop and provides each from its memory.
    fn provide(harness: *Harness) !Groups {
        const groups: Groups = .{
            .receiver = try harness.loop.reserve_buffer_group(),
            .sender = try harness.loop.reserve_buffer_group(),
        };
        const loop = &harness.loop;
        try loop.provide_datagram_buffers(groups.receiver, &receiver_memory, group_buffers, buffer_bytes, .{});
        try loop.provide_datagram_buffers(groups.sender, &sender_memory, group_buffers, buffer_bytes, .{});
        return groups;
    }
};

/// A bound receiver and a sender of one family, each with a multishot receive armed.
const Pair = struct {
    receiver: core.Descriptor,
    sender: core.Descriptor,
    address: Address,
    receives: [2]core.Handle = undefined,

    fn open(harness: *Harness, groups: Groups, loopback: *const Address) !Pair {
        const receiver = try sync.open_datagram(loopback.family, loopback, .{});
        errdefer sync.close_now(receiver);
        const sender = try sync.open_datagram(loopback.family, loopback, .{});
        errdefer sync.close_now(sender);
        var pair: Pair = .{
            .receiver = receiver,
            .sender = sender,
            .address = try sync.local_address(receiver),
        };
        try send_strangers(harness, loopback, &.{ pair.address, try sync.local_address(sender) });
        try harness.submit(&.{
            Operation.receive_from(user_data_receiver, receiver, groups.receiver),
            Operation.receive_from(user_data_sender, sender, groups.sender),
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

/// Sends `stranger_payload` to each of `targets` from a third socket bound to `loopback`. The
/// datagrams wait in the receivers' sockets, so a caller sends them before it arms a receive.
fn send_strangers(harness: *Harness, loopback: *const Address, targets: []const Address) !void {
    std.debug.assert(targets.len <= strangers_max);
    const stranger = try sync.open_datagram(loopback.family, loopback, .{});
    defer sync.close_now(stranger);
    var outs: [strangers_max]Outbound = undefined;
    var sends: [strangers_max]Operation = undefined;
    for (targets, 0..) |target, i| {
        outs[i] = .{
            .peer = target,
            .local = undefined,
            .segment_bytes = 0,
            .ecn = .not_ect,
            .flags = .{ .peer = true },
        };
        sends[i] = Operation.send_to(user_data_stranger, stranger, stranger_payload, &outs[i]);
    }
    try harness.submit(sends[0..targets.len], &.{});
    var events: [strangers_max]Event = undefined;
    try harness.collect(events[0..targets.len]);
    for (events[0..targets.len]) |event| {
        try testing.expectEqual(@as(u32, stranger_payload.len), try event.outcome());
    }
}

/// What `cross` waits for: one datagram, from one peer, on one receive.
const Expected = struct {
    bytes: []const u8,
    from: *const Address,
    receive_user_data: u64,
};

/// The most events `cross` takes for one datagram: its send, the datagram, and up to six from other
/// sockets, which it puts aside.
const crossing_events_max = 8;

/// Sends `bytes` from `socket` with `out`, and hands back what the datagram that `expected` names
/// carried. It puts aside a datagram from any other peer, so a datagram from another process cannot
/// fail the scenario. Each buffer goes back to its group.
fn cross(
    harness: *Harness,
    groups: Groups,
    socket: core.Descriptor,
    out: *const Outbound,
    send_user_data: u64,
    expected: *const Expected,
) !Received {
    try harness.submit(&.{Operation.send_to(send_user_data, socket, expected.bytes, out)}, &.{});
    var sent = false;
    var heard: ?Received = null;
    var taken: u32 = 0;
    while (!sent or heard == null) : (taken += 1) {
        if (taken == crossing_events_max) return error.EventsMissing;
        var events: [1]Event = undefined;
        try harness.collect(&events);
        if (events[0].user_data == send_user_data and !events[0].flags.message) {
            const sent_bytes = try events[0].outcome();
            try testing.expectEqual(@as(u32, @intCast(expected.bytes.len)), sent_bytes);
            sent = true;
        } else if (try take(harness, groups, &events[0], expected)) |from| {
            try testing.expect(heard == null);
            heard = from;
        }
    }
    return heard.?;
}

/// Gives back the buffer of a receive's `event`. It hands back what the datagram carried when its
/// peer is the one `expected` names, and null when another socket sent it.
fn take(harness: *Harness, groups: Groups, event: *const Event, expected: *const Expected) !?Received {
    const group = switch (event.user_data) {
        user_data_receiver => groups.receiver,
        user_data_sender => groups.sender,
        else => return error.EventNotFound,
    };
    try testing.expect(!event.flags.message);
    try testing.expect(event.flags.more);
    const delivery = harness.loop.datagram(group, event.*);
    defer harness.loop.give_back_buffer(group, event.flags.buffer_id);
    if (!same_peer(&delivery.from.peer, expected.from)) return null;
    try testing.expectEqual(expected.receive_user_data, event.user_data);
    try testing.expectEqualStrings(expected.bytes, delivery.bytes);
    return delivery.from;
}

/// True when `a` and `b` name one socket: the same family, port and address bytes.
fn same_peer(a: *const Address, b: *const Address) bool {
    if (a.family != b.family or a.port != b.port) return false;
    return std.mem.eql(u8, &a.bytes, &b.bytes);
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
    const groups = try Groups.provide(&harness);
    const pair = try Pair.open(&harness, groups, loopback);
    const sender_address = try sync.local_address(pair.sender);

    const asked: Outbound = .{
        .peer = pair.address,
        .local = undefined,
        .segment_bytes = 0,
        .ecn = .ect0,
        .flags = .{ .peer = true, .ecn = true },
    };
    const heard = try cross(&harness, groups, pair.sender, &asked, user_data_question, &.{
        .bytes = question,
        .from = &sender_address,
        .receive_user_data = user_data_receiver,
    });
    try expect_received(&heard, &sender_address, loopback);
    try testing.expect(heard.flags.ecn);
    try testing.expectEqual(core.datagram.Ecn.ect0, heard.ecn);

    // The answer goes back from the address the question was sent to, unmarked.
    const reply = Outbound.reply_to(&heard);
    const answered = try cross(&harness, groups, pair.receiver, &reply, user_data_answer, &.{
        .bytes = answer,
        .from = &pair.address,
        .receive_user_data = user_data_sender,
    });
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

/// The most ports `open_dual_stack` tries before it gives up.
const dual_stack_attempts_max = 8;

/// A socket bound to `::`, which takes IPv6 datagrams and, unless it is set IPv6-only, IPv4 ones
/// too, which the kernel names by their IPv4-mapped addresses (`::ffff:a.b.c.d`).
///
/// Its port is one that no other socket holds in either family. macOS gives a socket bound to
/// `[::]:0` a port that a socket on 127.0.0.1 can already hold, and that socket then takes the
/// IPv4 datagrams sent to the port. A bind to a named port checks both families, so the port comes
/// from an IPv4 socket that is closed first. When another process takes the port before the bind,
/// the bind fails and the next port is tried.
fn open_dual_stack() !core.Descriptor {
    var attempt: u32 = 0;
    while (attempt < dual_stack_attempts_max) : (attempt += 1) {
        const placeholder = try sync.open_datagram(.ipv4, &loopback4, .{});
        const local = sync.local_address(placeholder);
        sync.close_now(placeholder);
        const any6 = Address.ipv6(@splat(0), (try local).port, 0);
        return sync.open_datagram(.ipv6, &any6, .{}) catch |err| switch (err) {
            error.AddressInUse => continue,
            else => return err,
        };
    }
    return error.AddressInUse;
}

/// The IPv4-mapped form of 127.0.0.1, `::ffff:127.0.0.1`. The server names its IPv4 client so, and
/// `cross` takes the question only from that peer: a server that names it otherwise does not hear
/// the question, and the scenario fails with `EventsMissing`.
const mapped_loopback = [Address.ipv6_bytes]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1 };

test "a socket bound to :: carries an IPv4 peer's codepoint both ways" {
    // A server on `::` answering a client on an IPv4 socket, which is how a QUIC server listens
    // once for both families. Colibri found on 2026-09-24 that on Linux neither direction carried
    // its codepoint: the server marked its datagrams with an IPv6 option that a datagram to an
    // IPv4-mapped peer does not read, and asked only for the IPv6 report of what arrived.
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const groups = try Groups.provide(&harness);
    const server = try open_dual_stack();
    defer sync.close_now(server);
    const client = try sync.open_datagram(.ipv4, &loopback4, .{});
    defer sync.close_now(client);
    const server_port = (try sync.local_address(server)).port;
    const client_port = (try sync.local_address(client)).port;
    try send_strangers(&harness, &loopback4, &.{
        Address.ipv4(.{ 127, 0, 0, 1 }, server_port), Address.ipv4(.{ 127, 0, 0, 1 }, client_port),
    });
    var receives: [2]core.Handle = undefined;
    try harness.submit(&.{
        Operation.receive_from(user_data_receiver, server, groups.receiver),
        Operation.receive_from(user_data_sender, client, groups.sender),
    }, &receives);
    // Ended whatever happens, so a failed check reports itself and not the loop's teardown.
    defer {
        for (receives) |handle| harness.loop.cancel(handle);
        var events: [8]Event = undefined;
        harness.loop.drain(&events) catch {};
    }

    const asked: Outbound = .{
        .peer = Address.ipv4(.{ 127, 0, 0, 1 }, server_port),
        .local = undefined,
        .segment_bytes = 0,
        .ecn = .ect0,
        .flags = .{ .peer = true, .ecn = true },
    };
    const client_mapped = Address.ipv6(mapped_loopback, client_port, 0);
    const heard = try cross(&harness, groups, client, &asked, user_data_question, &.{
        .bytes = question,
        .from = &client_mapped,
        .receive_user_data = user_data_receiver,
    });
    try testing.expect(heard.flags.ecn);
    try testing.expectEqual(core.datagram.Ecn.ect0, heard.ecn);

    // The answer goes to the mapped address, marked too.
    var reply = Outbound.reply_to(&heard);
    reply.ecn = .ect0;
    reply.flags.ecn = true;
    const server4 = Address.ipv4(.{ 127, 0, 0, 1 }, server_port);
    const answered = try cross(&harness, groups, server, &reply, user_data_answer, &.{
        .bytes = answer,
        .from = &server4,
        .receive_user_data = user_data_sender,
    });
    try testing.expectEqual(Address.Family.ipv4, answered.peer.family);
    try testing.expectEqual(server_port, answered.peer.port);
    try testing.expect(answered.flags.ecn);
    try testing.expectEqual(core.datagram.Ecn.ect0, answered.ecn);
}
