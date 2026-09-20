//! Datagrams (decision 15), on whichever kernel the build gives this suite. One suite runs on
//! both backends (decision 10), so every scenario here asserts what both must do, and the one
//! thing they differ on — segmentation, which macOS has no option for — is asserted in two arms
//! rather than compiled away on one side.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Operation = core.Operation;
const Address = core.Address;
const Outbound = core.datagram.Outbound;
const sync = backend.sync;

/// The group's reserve. The default, because that is what a caller gets who says nothing.
const group: core.datagram.GroupOptions = .{};

/// Buffers in the group, and what each holds: the prefix plus room for the datagrams below.
const group_buffers = 8;
const buffer_bytes = 512;
const group_id = 0;

const ring_alignment = backend.buffers.ring_alignment;
var group_memory: [group_buffers * buffer_bytes]u8 align(ring_alignment) = undefined;
var ring_memory: [backend.buffers.ring_bytes(group_buffers)]u8 align(ring_alignment) = undefined;

const loopback = Address.ipv4(.{ 127, 0, 0, 1 }, 0);

/// A bound receiver and an unbound sender, with the receiver's real address.
const Pair = struct {
    receiver: core.Descriptor,
    sender: core.Descriptor,
    address: Address,

    fn open() !Pair {
        const receiver = try sync.open_datagram(.ipv4, &loopback, .{});
        errdefer sync.close_now(receiver);
        const sender = try sync.open_datagram(.ipv4, null, .{});
        return .{
            .receiver = receiver,
            .sender = sender,
            .address = try sync.local_address(receiver),
        };
    }

    fn close(pair: Pair) void {
        sync.close_now(pair.receiver);
        sync.close_now(pair.sender);
    }
};

fn receive_from(user_data: u64, socket: core.Descriptor) Operation {
    return .{ .user_data = user_data, .kind = .{ .receive_from = .{
        .socket = socket,
        .group = group_id,
    } } };
}

fn send_to(user_data: u64, socket: core.Descriptor, bytes: []const u8, to: *const Outbound) Operation {
    return .{ .user_data = user_data, .kind = .{ .send_to = .{
        .socket = socket,
        .buffer = .{ .bytes = bytes },
        .to = to,
    } } };
}

fn provide(harness: *Harness) !void {
    try harness.loop.provide_datagram_buffers(
        group_id,
        &ring_memory,
        &group_memory,
        buffer_bytes,
        group,
    );
}

const message = "a datagram crosses";

/// Ends a multishot receive and empties the loop, which `deinit` requires (decision 5, rule 7).
fn end(harness: *Harness, handle: core.Handle) !void {
    harness.loop.cancel(handle);
    var events: [8]Event = undefined;
    try harness.loop.drain(&events);
}

test "a datagram crosses, and the receiver is told which peer sent it" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    try provide(&harness);

    const pair = try Pair.open();
    defer pair.close();

    var handles: [1]core.Handle = undefined;
    try harness.submit(&.{receive_from(1, pair.receiver)}, &handles);
    var out: Outbound = .{
        .peer = pair.address,
        .local = undefined,
        .segment_bytes = 0,
        .ecn = .not_ect,
        .flags = .{ .peer = true },
    };
    try harness.submit(&.{send_to(2, pair.sender, message, &out)}, &.{});

    var events: [2]Event = undefined;
    try harness.collect(&events);
    const sent = try Harness.find(&events, 2);
    try testing.expectEqual(@as(u32, message.len), try sent.outcome());

    // Read after the send, not before: an unbound datagram socket has no port until it sends,
    // and the first version of this scenario compared the received peer against a port of 0.
    const sender_address = try sync.local_address(pair.sender);
    try testing.expect(sender_address.port != 0);

    const got = try Harness.find(&events, 1);
    // The result is the datagram's own bytes: never the prefix in front of them (decision 15).
    try testing.expectEqual(@as(u32, message.len), try got.outcome());
    const buffer = harness.loop.provided_buffer(group_id, got.flags.buffer_id);
    const delivery = harness.loop.datagram(buffer, got);
    try testing.expectEqualStrings(message, delivery.bytes);
    try testing.expectEqual(sender_address.port, delivery.from.peer.port);
    try testing.expectEqualSlices(u8, &loopback.bytes, &delivery.from.peer.bytes);
    harness.loop.give_back_buffer(group_id, got.flags.buffer_id);
    try end(&harness, handles[0]);
}

test "a datagram's bytes are read through the loop and not from the front of its buffer" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    try provide(&harness);

    const pair = try Pair.open();
    defer pair.close();
    var handles: [1]core.Handle = undefined;
    try harness.submit(&.{receive_from(1, pair.receiver)}, &handles);
    var out: Outbound = .{
        .peer = pair.address,
        .local = undefined,
        .segment_bytes = 0,
        .ecn = .not_ect,
        .flags = .{ .peer = true },
    };
    try harness.submit(&.{send_to(2, pair.sender, message, &out)}, &.{});
    var events: [2]Event = undefined;
    try harness.collect(&events);

    const got = try Harness.find(&events, 1);
    const buffer = harness.loop.provided_buffer(group_id, got.flags.buffer_id);
    // The whole point of the prefix: the datagram does not start where its buffer does. A
    // caller that read `buffer[0..count]` would get the head and the address instead, which is
    // the mistake the accessor exists to prevent.
    const prefix = core.datagram.prefix_bytes(group);
    try testing.expect(!std.mem.eql(u8, buffer[0..message.len], message));
    try testing.expectEqualStrings(message, buffer[prefix..][0..message.len]);
    harness.loop.give_back_buffer(group_id, got.flags.buffer_id);
    try end(&harness, handles[0]);
}

test "a multishot receive takes datagram after datagram from one submission" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    try provide(&harness);

    const pair = try Pair.open();
    defer pair.close();
    var handles: [1]core.Handle = undefined;
    try harness.submit(&.{receive_from(1, pair.receiver)}, &handles);

    var out: Outbound = .{
        .peer = pair.address,
        .local = undefined,
        .segment_bytes = 0,
        .ecn = .not_ect,
        .flags = .{ .peer = true },
    };
    const datagrams = 3;
    var sent: u32 = 0;
    while (sent < datagrams) : (sent += 1) {
        try harness.submit(&.{send_to(2, pair.sender, message, &out)}, &.{});
    }

    var received: u32 = 0;
    var rounds: u32 = 0;
    var events: [8]Event = undefined;
    while (received < datagrams and rounds < conformance.collect_rounds_max) : (rounds += 1) {
        const count = try harness.loop.tick(&events, 10 * core.constants.ns_per_ms);
        for (events[0..count]) |event| {
            if (event.user_data != 1) continue;
            try testing.expectEqual(@as(u32, message.len), try event.outcome());
            // Every datagram but the last says there is more to come (decision 5, rule 1).
            try testing.expect(event.flags.more);
            harness.loop.give_back_buffer(group_id, event.flags.buffer_id);
            received += 1;
        }
    }
    try testing.expectEqual(@as(u32, datagrams), received);

    harness.loop.cancel(handles[0]);
    try harness.loop.drain(&events);
}

test "a datagram larger than the buffer's room is reported, not silently cut" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    try provide(&harness);

    const pair = try Pair.open();
    defer pair.close();
    var handles: [1]core.Handle = undefined;
    try harness.submit(&.{receive_from(1, pair.receiver)}, &handles);

    // One byte more than a buffer can hold past its prefix.
    const capacity = core.datagram.payload_capacity(buffer_bytes, group);
    var large: [buffer_bytes]u8 = @splat('x');
    var out: Outbound = .{
        .peer = pair.address,
        .local = undefined,
        .segment_bytes = 0,
        .ecn = .not_ect,
        .flags = .{ .peer = true },
    };
    try harness.submit(&.{send_to(2, pair.sender, large[0 .. capacity + 1], &out)}, &.{});

    var events: [2]Event = undefined;
    try harness.collect(&events);
    const got = try Harness.find(&events, 1);
    const count = try got.outcome();
    const buffer = harness.loop.provided_buffer(group_id, got.flags.buffer_id);
    const delivery = harness.loop.datagram(buffer, got);
    // The kernel keeps what fits and says the rest is gone. Both kernels must say so.
    try testing.expect(delivery.from.flags.truncated);
    try testing.expect(count <= capacity);
    harness.loop.give_back_buffer(group_id, got.flags.buffer_id);
    try end(&harness, handles[0]);
}

test "a cancelled datagram receive ends with one final event and leaves nothing behind" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    try provide(&harness);

    const pair = try Pair.open();
    defer pair.close();
    var handles: [1]core.Handle = undefined;
    try harness.submit(&.{receive_from(7, pair.receiver)}, &handles);
    var events: [4]Event = undefined;
    _ = try harness.loop.tick(&events, 0);

    harness.loop.cancel(handles[0]);
    var last: [1]Event = undefined;
    try harness.collect(&last);
    try testing.expectEqual(@as(u64, 7), last[0].user_data);
    try testing.expectError(error.Canceled, last[0].outcome());
    try testing.expect(!last[0].flags.more);
    try testing.expectEqual(@as(u32, 0), harness.loop.in_flight());
}

test "a segmented send is carried where the kernel segments and refused where it cannot" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    try provide(&harness);

    const pair = try Pair.open();
    defer pair.close();
    const segment_bytes = 8;
    const segments = 3;
    var payload: [segment_bytes * segments]u8 = @splat('s');
    var out: Outbound = .{
        .peer = pair.address,
        .local = undefined,
        .segment_bytes = segment_bytes,
        .ecn = .not_ect,
        .flags = .{ .peer = true },
    };
    try harness.submit(&.{send_to(2, pair.sender, &payload, &out)}, &.{});
    var events: [1]Event = undefined;
    try harness.collect(&events);

    // Both arms assert. macOS has no UDP segmentation and answers `unsupported`; Linux carries
    // it. A scenario that compiled away on one side would let the two backends drift unseen,
    // which is what decision 10's one suite exists to prevent.
    if (builtin.os.tag == .linux) {
        try testing.expectEqual(@as(u32, payload.len), try events[0].outcome());
    } else {
        try testing.expectError(error.Unsupported, events[0].outcome());
    }
}
