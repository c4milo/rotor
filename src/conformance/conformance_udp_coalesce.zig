//! Datagrams the kernel coalesces (decision 15): a socket opened with `DatagramOptions.coalesce`,
//! the default, which turns UDP_GRO on under Linux, and the largest segmented send. Split from
//! `conformance_udp.zig` for the 500-line limit. A small segmented send on loopback reaches a
//! coalescing socket as the one datagram it was sent as, so on Linux these scenarios require
//! coalescence instead of only tolerating it. The loop splits a coalesced datagram into one event
//! per datagram (the amendment of 2026-11-05), and the scenarios hold it to that. macOS has neither GSO nor GRO, and each scenario asserts what it
//! does there in an arm of its own (decision 10).
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

const shape: core.datagram.GroupOptions = .{};
const group_buffers = 4;

/// Room for a coalesced datagram of up to 64 KiB, after the group's prefix.
const large_buffer_bytes = 64 * 1024 + 1024;
const large_group_bytes = backend.buffers.group_bytes(group_buffers, large_buffer_bytes);
var large_memory: [large_group_bytes]u8 align(backend.buffers.group_alignment) = undefined;

/// Room for one segment of the truncation scenario and not for three.
const small_buffer_bytes = 512;
const small_group_bytes = backend.buffers.group_bytes(group_buffers, small_buffer_bytes);
var small_memory: [small_group_bytes]u8 align(backend.buffers.group_alignment) = undefined;

/// The largest UDP payload over IPv4: 65,535 bytes less 20 of IP header and 8 of UDP header.
const ipv4_payload_bytes_max = std.math.maxInt(u16) - 20 - 8;

const loopback = Address.ipv4(.{ 127, 0, 0, 1 }, 0);
const linux = builtin.os.tag == .linux;

const Pair = struct {
    receiver: core.Descriptor,
    sender: core.Descriptor,
    address: Address,
    sender_port: u16,

    fn open(coalesce: bool) !Pair {
        return open_with(.{ .coalesce = coalesce });
    }

    /// A receiver with every option at its default, which coalesces.
    fn open_default() !Pair {
        return open_with(.{});
    }

    fn open_with(options: sync.DatagramOptions) !Pair {
        const receiver = try sync.open_datagram(.ipv4, &loopback, options);
        errdefer sync.close_now(receiver);
        // Bound, so the receiver can name the sender's port.
        const sender = try sync.open_datagram(.ipv4, &loopback, .{});
        errdefer sync.close_now(sender);
        return .{
            .receiver = receiver,
            .sender = sender,
            .address = try sync.local_address(receiver),
            .sender_port = (try sync.local_address(sender)).port,
        };
    }

    fn close(pair: Pair) void {
        sync.close_now(pair.receiver);
        sync.close_now(pair.sender);
    }
};

fn outbound(pair: Pair, segment_bytes: u16) Outbound {
    return .{
        .peer = pair.address,
        .local = undefined,
        .segment_bytes = segment_bytes,
        .ecn = .not_ect,
        .flags = .{ .peer = true },
    };
}

fn end(harness: *Harness, handle: core.Handle) !void {
    harness.loop.cancel(handle);
    var events: [8]Event = undefined;
    try harness.loop.drain(&events);
}

/// Submits a multishot receive on the pair's receiver and one send of `payload`, cut into
/// `segment_bytes` when it is not 0, and collects `events.len` events.
fn exchange(
    harness: *Harness,
    group: core.BufferGroup,
    pair: Pair,
    payload: []const u8,
    segment_bytes: u16,
    events: []Event,
) !core.Handle {
    var handles: [1]core.Handle = undefined;
    try harness.submit(&.{Operation.receive_from(1, pair.receiver, group)}, &handles);
    var out = outbound(pair, segment_bytes);
    try harness.submit(&.{Operation.send_to(2, pair.sender, payload, &out)}, &.{});
    try harness.collect(events);
    return handles[0];
}

test "a socket that coalesces hands each datagram of a segmented send over as an event of its own" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const group = try harness.loop.reserve_buffer_group();
    try harness.loop.provide_datagram_buffers(
        group,
        &large_memory,
        group_buffers,
        large_buffer_bytes,
        shape,
    );
    // Coalescing is the default.
    const pair = try Pair.open_default();
    defer pair.close();

    var payload: [24]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @intCast(index);
    if (!linux) {
        // macOS has no GRO: the option opens the socket and changes nothing, so a datagram
        // arrives whole and names no segment size.
        var events: [2]Event = undefined;
        const handle = try exchange(&harness, group, pair, &payload, 0, &events);
        const got = try Harness.find(&events, 1);
        const delivery = harness.loop.datagram(group, got);
        try testing.expectEqualSlices(u8, &payload, delivery.bytes);
        try testing.expectEqual(@as(u16, 0), delivery.from.segment_bytes);
        harness.loop.give_back_buffer(group, got.flags.buffer_id);
        return end(&harness, handle);
    }
    // The send's event and one event for each of the three datagrams.
    var events: [4]Event = undefined;
    const handle = try exchange(&harness, group, pair, &payload, 8, &events);
    try testing.expectEqual(@as(u32, payload.len), try (try Harness.find(&events, 2)).outcome());
    var received: u32 = 0;
    var buffer_id: ?u16 = null;
    for (events) |event| {
        if (event.user_data != 1) continue;
        try testing.expect(event.flags.more);
        const delivery = harness.loop.datagram(group, event);
        try testing.expectEqualSlices(u8, payload[received * 8 ..][0..8], delivery.bytes);
        try testing.expectEqual(@as(u16, 0), delivery.from.segment_bytes);
        try testing.expectEqual(pair.sender_port, delivery.from.peer.port);
        // The kernel coalesced the three, so all three name the buffer it filled.
        if (buffer_id) |id| try testing.expectEqual(id, event.flags.buffer_id);
        buffer_id = event.flags.buffer_id;
        received += 1;
    }
    try testing.expectEqual(@as(u32, 3), received);
    for (0..received) |_| harness.loop.give_back_buffer(group, buffer_id.?);
    try end(&harness, handle);
}

test "the datagrams of a coalesced one that do not fit a tick's events come in the next ticks" {
    if (conformance.unsupported()) return error.SkipZigTest;
    if (!linux) return;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const group = try harness.loop.reserve_buffer_group();
    try harness.loop.provide_datagram_buffers(group, &large_memory, group_buffers, large_buffer_bytes, shape);
    const pair = try Pair.open_default();
    defer pair.close();
    var handles: [1]core.Handle = undefined;
    try harness.submit(&.{Operation.receive_from(1, pair.receiver, group)}, &handles);
    const payload: [40]u8 = @splat('s');
    var out = outbound(pair, 10);
    try harness.submit(&.{Operation.send_to(2, pair.sender, &payload, &out)}, &.{});
    // One event a tick: the send's, and four datagrams of ten bytes, in order.
    var segments: u32 = 0;
    var round: u32 = 0;
    while (segments < 4 and round < 100) : (round += 1) {
        var one: [1]Event = undefined;
        if (try harness.loop.tick(&one, 10 * core.constants.ns_per_ms) == 0) continue;
        if (one[0].user_data != 1) continue;
        try testing.expectEqual(@as(u6, @intCast(segments)), one[0].flags.segment);
        try testing.expectEqual(@as(usize, 10), harness.loop.datagram(group, one[0]).bytes.len);
        harness.loop.give_back_buffer(group, one[0].flags.buffer_id);
        segments += 1;
    }
    try testing.expectEqual(@as(u32, 4), segments);
    try end(&harness, handles[0]);
}

/// The wait of each tick while a split is pending. A tick that blocks takes all of it, and a tick
/// that does not block takes a small part of it.
const split_wait_ns = core.constants.ns_per_s;

/// Receives one datagram of a coalesced one into a single event, so the rest of it is pending.
fn first_segment(harness: *Harness, group: core.BufferGroup, pair: Pair) !core.Handle {
    // The send ends first, so no event of it is left for a later tick.
    const payload: [40]u8 = @splat('w');
    var out = outbound(pair, 10);
    try harness.submit(&.{Operation.send_to(2, pair.sender, &payload, &out)}, &.{});
    var sent: [1]Event = undefined;
    try harness.collect(&sent);
    try testing.expectEqual(@as(u32, payload.len), try sent[0].outcome());
    var handles: [1]core.Handle = undefined;
    try harness.submit(&.{Operation.receive_from(1, pair.receiver, group)}, &handles);
    for (0..100) |_| {
        var one: [1]Event = undefined;
        if (try harness.loop.tick(&one, 10 * core.constants.ns_per_ms) == 0) continue;
        try testing.expectEqual(@as(u64, 1), one[0].user_data);
        try testing.expectEqual(@as(u6, 0), one[0].flags.segment);
        harness.loop.give_back_buffer(group, one[0].flags.buffer_id);
        return handles[0];
    }
    return error.EventsMissing;
}

test "a tick does not block while datagrams of a coalesced one wait to be handed over" {
    if (conformance.unsupported()) return error.SkipZigTest;
    // macOS has no GRO, so a kqueue loop never holds a split.
    if (!linux) return;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const group = try harness.loop.reserve_buffer_group();
    try harness.loop.provide_datagram_buffers(group, &large_memory, group_buffers, large_buffer_bytes, shape);
    const pair = try Pair.open_default();
    defer pair.close();
    const handle = try first_segment(&harness, group, pair);
    // A failure ends the receive too, so the loop's `deinit` finds every operation ended.
    errdefer end(&harness, handle) catch {};
    // Nothing else is due and the socket holds nothing more. Each tick hands over the next
    // datagram of the split at once, and does not wait for the kernel (decision 15).
    for (1..4) |segment| {
        var one: [1]Event = undefined;
        const before_ns = harness.loop.now_ns();
        try testing.expectEqual(@as(u32, 1), try harness.loop.tick(&one, split_wait_ns));
        const waited_ns = harness.loop.now_ns() - before_ns;
        if (waited_ns >= split_wait_ns / 2) {
            std.debug.print("the tick waited {d} ms with a split pending\n", .{waited_ns / core.constants.ns_per_ms});
            return error.TestUnexpectedResult;
        }
        try testing.expectEqual(@as(u6, @intCast(segment)), one[0].flags.segment);
        harness.loop.give_back_buffer(group, one[0].flags.buffer_id);
    }
    try end(&harness, handle);
}

test "a socket that does not coalesce takes a segmented send as one datagram per segment" {
    if (conformance.unsupported()) return error.SkipZigTest;
    // macOS refuses the segmented send, which `conformance_udp.zig` asserts.
    if (!linux) return;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const group = try harness.loop.reserve_buffer_group();
    try harness.loop.provide_datagram_buffers(
        group,
        &large_memory,
        group_buffers,
        large_buffer_bytes,
        shape,
    );
    const pair = try Pair.open(false);
    defer pair.close();

    const payload: [24]u8 = @splat('d');
    var events: [4]Event = undefined;
    const handle = try exchange(&harness, group, pair, &payload, 8, &events);
    var received: u32 = 0;
    for (events) |event| {
        if (event.user_data != 1) continue;
        const delivery = harness.loop.datagram(group, event);
        try testing.expectEqual(@as(usize, 8), delivery.bytes.len);
        try testing.expectEqual(@as(u16, 0), delivery.from.segment_bytes);
        harness.loop.give_back_buffer(group, event.flags.buffer_id);
        received += 1;
    }
    try testing.expectEqual(@as(u32, 3), received);
    try end(&harness, handle);
}

/// A buffer for each segment of the largest send, and room in each for one segment.
const segment_buffers = 128;
const segment_buffer_bytes = 2048;
const segment_group_bytes = backend.buffers.group_bytes(segment_buffers, segment_buffer_bytes);
var segment_memory: [segment_group_bytes]u8 align(backend.buffers.group_alignment) = undefined;

/// Ticks of up to `segment_wait_ns` each that the largest send's segments get to arrive.
const segment_rounds_max = 100;
const segment_wait_ns = 10 * core.constants.ns_per_ms;

/// What the receiver of the largest send took.
const Taken = struct { datagrams: u32 = 0, bytes: usize = 0 };

/// Receives datagrams until `bytes` have arrived. A multishot receive can end with a success: on
/// io_uring on 2026-10-26 the kernel ended it after 32 datagrams, with the 32nd as its final event,
/// and the rest waited in the socket. So a final event that carries bytes submits the receive again.
fn take(harness: *Harness, group: core.BufferGroup, receiver: core.Descriptor, bytes: usize) !Taken {
    var taken: Taken = .{};
    var handles: [1]core.Handle = undefined;
    try harness.submit(&.{Operation.receive_from(1, receiver, group)}, &handles);
    var events: [segment_buffers]Event = undefined;
    var round: u32 = 0;
    while (taken.bytes < bytes and round < segment_rounds_max) : (round += 1) {
        const count = try harness.loop.tick(&events, segment_wait_ns);
        for (events[0..count]) |event| {
            if (event.user_data != 1) continue;
            _ = try event.outcome();
            const delivery = harness.loop.datagram(group, event);
            taken.datagrams += 1;
            taken.bytes += delivery.bytes.len;
            harness.loop.give_back_buffer(group, event.flags.buffer_id);
            if (event.flags.more) continue;
            try harness.submit(&.{Operation.receive_from(1, receiver, group)}, &handles);
        }
    }
    try end(harness, handles[0]);
    return taken;
}

test "the largest segmented send is the largest IPv4 datagram in 64 segments, and all of it arrives" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const group = try harness.loop.reserve_buffer_group();
    try harness.loop.provide_datagram_buffers(
        group,
        &segment_memory,
        segment_buffers,
        segment_buffer_bytes,
        shape,
    );
    // A socket that does not coalesce, so each segment arrives as a datagram of its own. On
    // loopback a coalescing socket took this send as separate datagrams too, on 2026-10-26.
    const pair = try Pair.open(false);
    defer pair.close();

    // 1,024-byte segments cut the largest payload into exactly `segments_max` of them.
    const segment_bytes = 1024;
    const segments = core.constants.segments_max;
    comptime std.debug.assert((ipv4_payload_bytes_max + segment_bytes - 1) / segment_bytes == segments);
    const payload = struct {
        var bytes: [ipv4_payload_bytes_max + 1]u8 = @splat('g');
    };
    const largest = payload.bytes[0..ipv4_payload_bytes_max];
    var out = outbound(pair, segment_bytes);
    try harness.submit(&.{Operation.send_to(2, pair.sender, largest, &out)}, &.{});
    var sent: [1]Event = undefined;
    try harness.collect(&sent);
    if (!linux) return testing.expectError(error.Unsupported, sent[0].outcome());
    try testing.expectEqual(@as(u32, ipv4_payload_bytes_max), try sent[0].outcome());
    const taken = try take(&harness, group, pair.receiver, ipv4_payload_bytes_max);
    try testing.expectEqual(@as(usize, ipv4_payload_bytes_max), taken.bytes);
    try testing.expectEqual(segments, taken.datagrams);

    // One byte more is more than one IPv4 datagram carries, and the kernel refuses it.
    var over = outbound(pair, segment_bytes);
    try harness.submit(&.{Operation.send_to(3, pair.sender, &payload.bytes, &over)}, &.{});
    var refused: [1]Event = undefined;
    try harness.collect(&refused);
    try testing.expectError(error.MessageTooLong, refused[0].outcome());
}

test "a socket whose group cannot hold a coalesced datagram does not coalesce, so none is cut" {
    if (conformance.unsupported()) return error.SkipZigTest;
    if (!linux) return;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const group = try harness.loop.reserve_buffer_group();
    try harness.loop.provide_datagram_buffers(
        group,
        &small_memory,
        group_buffers,
        small_buffer_bytes,
        shape,
    );
    const pair = try Pair.open_default();
    defer pair.close();

    // Three datagrams of 300 bytes: one fits a buffer, and the three coalesced would not.
    const segment_bytes = 300;
    try testing.expect(core.datagram.payload_capacity(small_buffer_bytes, shape) >= segment_bytes);
    var payload: [3 * segment_bytes]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @truncate(index);
    var events: [4]Event = undefined;
    const handle = try exchange(&harness, group, pair, &payload, segment_bytes, &events);
    var received: u32 = 0;
    for (events) |event| {
        if (event.user_data != 1) continue;
        const delivery = harness.loop.datagram(group, event);
        try testing.expect(!delivery.from.flags.truncated);
        try testing.expectEqualSlices(u8, payload[received * segment_bytes ..][0..segment_bytes], delivery.bytes);
        // Each datagram has a buffer of its own: the receive turned coalescing off.
        try testing.expectEqual(@as(u6, 0), event.flags.segment);
        harness.loop.give_back_buffer(group, event.flags.buffer_id);
        received += 1;
    }
    try testing.expectEqual(@as(u32, 3), received);
    try end(&harness, handle);
}
