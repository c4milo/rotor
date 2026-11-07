//! Datagrams that wait in a socket before the loop reads them (decision 15). io_uring's multishot
//! receive and kqueue's reap take all of them in one tick. epoll's reap takes a batch with one
//! `recvmmsg` when the reap before also served the receive, so a burst arrives in a few ticks
//! there too (decision 20, amendment of 2026-11-06). Split from `conformance_udp_coalesce.zig` for
//! the 500-line limit.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const assert = std.debug.assert;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const fair = @import("conformance_fair.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Operation = core.Operation;
const Address = core.Address;
const Outbound = core.datagram.Outbound;
const sync = backend.sync;

const shape: core.datagram.GroupOptions = .{};

/// Fewer buffers than one burst has datagrams, so a batch that kept a buffer it did not fill
/// would run the group dry within `bursts` bursts.
const group_buffers = 16;
const buffer_bytes = 2048;
const group_bytes = backend.buffers.group_bytes(group_buffers, buffer_bytes);
var memory: [group_bytes]u8 align(backend.buffers.group_alignment) = undefined;

/// Datagrams each burst leaves waiting in the socket before the loop reads them. Not a multiple of
/// 8, so on epoll the last batch of every burst is only partly filled and gives buffers back.
const burst_datagrams = 25;

/// Bursts the scenario sends, one after the other, through the same receive.
const bursts = 4;

/// The most ticks one burst may take. epoll's reap batches a receive the reap before also served,
/// in batches of 1, 2, 4 and then 8, which is 6 ticks for 25 datagrams; two more is slack. One
/// datagram a tick would take 25.
const burst_ticks_max = 8;

/// Room for every event of `receive_batch_max` coalesced datagrams, so epoll's reap may batch 8.
const events_len = 8 * core.constants.coalesced_segments_max;

/// Ticks of up to `wait_ns` each that a burst gets to arrive.
const rounds_max = 100;
const wait_ns = 10 * core.constants.ns_per_ms;

const loopback = Address.ipv4(.{ 127, 0, 0, 1 }, 0);

fn outbound(to: Address) Outbound {
    return .{ .peer = to, .local = undefined, .segment_bytes = 0, .ecn = .not_ect, .flags = .{ .peer = true } };
}

/// Sends `burst_datagrams` datagrams of one byte each, its index, and waits until each send ends.
/// `harness` is a loop of its own, so a receive armed on the other loop takes none of its ticks.
fn send_burst(harness: *Harness, sender: core.Descriptor, to: Address) !void {
    const bytes = struct {
        var values: [burst_datagrams]u8 = undefined;
    };
    var out = outbound(to);
    for (&bytes.values, 0..) |*byte, index| {
        byte.* = @intCast(index);
        try harness.submit(&.{Operation.send_to(2, sender, byte[0..1], &out)}, &.{});
        var sent: [1]Event = undefined;
        try harness.collect(&sent);
        try testing.expectEqual(@as(u32, 1), try sent[0].outcome());
    }
}

/// The socket option of macOS that reports how many datagrams wait in a socket, from
/// `<sys/socket.h>`. Zig's standard library does not name it.
const so_numrcvpkt = 0x1112;

/// The most times `wait_queued` reads the count before it fails, and the pause between two reads.
const queued_reads_max = 1000;
const queued_pause_ms = 1;

/// Waits until `datagrams` datagrams wait in `receiver`, so the first tick can read the whole
/// burst. On macOS a datagram over loopback can reach its socket after its send returns. Without
/// the wait, a loaded machine took 11 and 12 ticks for one burst (2026-11-07). Linux reports no
/// count of datagrams, so there the wait ends when the socket is readable.
fn wait_queued(receiver: core.Descriptor, datagrams: u32) !void {
    if (builtin.os.tag == .linux) return fair.wait_readable(receiver);
    for (0..queued_reads_max) |_| {
        var count: c_int = 0;
        var length: std.c.socklen_t = @sizeOf(c_int);
        const rc = std.c.getsockopt(receiver, std.c.SOL.SOCKET, so_numrcvpkt, @ptrCast(&count), &length);
        if (rc != 0) return error.Unexpected;
        if (count >= datagrams) return;
        _ = std.c.poll(&.{}, 0, queued_pause_ms);
    }
    return error.NotQueued;
}

/// What one burst's receive took: datagrams, the ticks that handed any over, and the final event
/// of a receive that ended with an error other than an empty group.
const Taken = struct { datagrams: u32 = 0, ticks: u32 = 0, failed: ?Event = null };

/// The multishot receive of the burst scenarios, on `receiver` into the group.
const Receive = struct {
    receiver: core.Descriptor,
    group: core.BufferGroup,
    handle: core.Handle = undefined,

    fn start(receive: *Receive, harness: *Harness) !void {
        var handles: [1]core.Handle = undefined;
        try harness.submit(&.{Operation.receive_from(1, receive.receiver, receive.group)}, &handles);
        receive.handle = handles[0];
    }
};

/// Ticks until `burst_datagrams` datagrams arrive, each with the byte of its index. A burst
/// larger than the group can end the receive: kqueue's reap and io_uring take every datagram that
/// waits, and the group runs dry before the caller gives a buffer back. The receive then starts
/// again, as a caller's would. A group that never gets its buffers back stays dry, and the burst
/// does not arrive. Any other error ends the receive for good, and the taking with it.
fn take_burst(harness: *Harness, receive: *Receive, events: []Event) !Taken {
    var taken: Taken = .{};
    var round: u32 = 0;
    while (taken.datagrams < burst_datagrams and taken.failed == null and round < rounds_max) : (round += 1) {
        const count = try harness.loop.tick(events, wait_ns);
        if (count == 0) continue;
        taken.ticks += 1;
        for (events[0..count]) |event| try take_one(harness, receive, event, &taken);
    }
    return taken;
}

fn take_one(harness: *Harness, receive: *Receive, event: Event, taken: *Taken) !void {
    try testing.expectEqual(@as(u64, 1), event.user_data);
    if (!event.flags.buffer) {
        // A receive's event without a buffer is its final one, and carries why it ended.
        try testing.expect(!event.flags.more);
        if (event.outcome()) |_| {
            return error.TestUnexpectedResult;
        } else |failure| {
            if (failure != error.BuffersExhausted) {
                taken.failed = event;
                return;
            }
        }
        return receive.start(harness);
    }
    // io_uring can end a multishot receive with a success, whose event holds a datagram.
    if (!event.flags.more) try receive.start(harness);
    const delivery = harness.loop.datagram(receive.group, event);
    try testing.expectEqualSlices(u8, &.{@as(u8, @intCast(taken.datagrams))}, delivery.bytes);
    harness.loop.give_back_buffer(receive.group, event.flags.buffer_id);
    taken.datagrams += 1;
}

fn end(harness: *Harness, handle: core.Handle) !void {
    harness.loop.cancel(handle);
    var events: [8]Event = undefined;
    try harness.loop.drain(&events);
}

test "bursts of datagrams waiting in a socket arrive in order, in fewer ticks than datagrams" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const group = try harness.loop.reserve_buffer_group();
    try harness.loop.provide_datagram_buffers(group, &memory, group_buffers, buffer_bytes, shape);
    var sending: Harness = undefined;
    try sending.init(1, null);
    defer sending.deinit();
    const receiver = try sync.open_datagram(.ipv4, &loopback, .{ .coalesce = false });
    defer sync.close_now(receiver);
    const sender = try sync.open_datagram(.ipv4, &loopback, .{});
    defer sync.close_now(sender);
    const to = try sync.local_address(receiver);

    var receive: Receive = .{ .receiver = receiver, .group = group };
    try receive.start(&harness);
    var events: [events_len]Event = undefined;
    for (0..bursts) |_| {
        try send_burst(&sending, sender, to);
        try wait_queued(receiver, burst_datagrams);
        const taken = try take_burst(&harness, &receive, &events);
        try testing.expectEqual(@as(u32, burst_datagrams), taken.datagrams);
        try testing.expect(taken.ticks <= burst_ticks_max);
    }
    try end(&harness, receive.handle);
}

/// A group that holds a whole burst, so io_uring's multishot receive takes it without running dry.
const whole_buffers = 64;
const whole_group_bytes = backend.buffers.group_bytes(whole_buffers, buffer_bytes);
var whole_memory: [whole_group_bytes]u8 align(backend.buffers.group_alignment) = undefined;

test "a receive whose socket meets an error while datagrams wait ends with the error" {
    if (conformance.unsupported()) return error.SkipZigTest;
    // A connected datagram socket learns of an unreachable port through ICMP; this asks Linux's.
    if (builtin.os.tag != .linux) return;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const group = try harness.loop.reserve_buffer_group();
    try harness.loop.provide_datagram_buffers(group, &whole_memory, whole_buffers, buffer_bytes, shape);
    var sending: Harness = undefined;
    try sending.init(1, null);
    defer sending.deinit();
    const receiver = try sync.open_datagram(.ipv4, &loopback, .{ .coalesce = false });
    defer sync.close_now(receiver);
    const sender = try sync.open_datagram(.ipv4, &loopback, .{});
    const sender_address = try sync.local_address(sender);
    // Connected to the sender, so the receiver hears of the sender's port when it closes.
    try sending.submit(&.{Operation.connect(4, receiver, &sender_address)}, &.{});
    var connected: [1]Event = undefined;
    try sending.collect(&connected);
    try testing.expectEqual(@as(u32, 0), try connected[0].outcome());
    try send_burst(&sending, sender, try sync.local_address(receiver));
    sync.close_now(sender);

    var receive: Receive = .{ .receiver = receiver, .group = group };
    try receive.start(&harness);
    var events: [events_len]Event = undefined;
    // One tick that serves the receive. On epoll it takes one datagram, so the next reap batches.
    var taken: Taken = .{};
    var round: u32 = 0;
    while (taken.datagrams == 0 and round < rounds_max) : (round += 1) {
        const count = try harness.loop.tick(&events, wait_ns);
        for (events[0..count]) |event| try take_one(&harness, &receive, event, &taken);
    }
    try testing.expect(taken.datagrams >= 1);
    // The port is closed now, so the kernel answers this datagram with an error for the receiver.
    // It is sent from the other loop, so this loop makes no tick between the two reaps.
    const probe = [_]u8{0};
    var out = outbound(sender_address);
    try sending.submit(&.{Operation.send_to(5, receiver, &probe, &out)}, &.{});
    var probed: [1]Event = undefined;
    try sending.collect(&probed);
    try testing.expectEqual(@as(u32, 1), try probed[0].outcome());
    // Linux reports the error before the datagrams that still wait, and it ends the receive.
    round = 0;
    while (taken.failed == null and round < rounds_max) : (round += 1) {
        const count = try harness.loop.tick(&events, wait_ns);
        for (events[0..count]) |event| try take_one(&harness, &receive, event, &taken);
    }
    const failed = taken.failed orelse return error.TestUnexpectedResult;
    try testing.expect(!failed.flags.more);
    try testing.expectError(error.ConnectionRefused, failed.outcome());
    try testing.expect(taken.datagrams <= burst_datagrams);
    try testing.expectEqual(@as(u32, 0), harness.loop.in_flight());
}

/// Room for a coalesced datagram of up to 64 KiB after the group's prefix, so a socket whose
/// receive takes from this group coalesces.
const coalesced_buffers = 8;
const coalesced_buffer_bytes = 64 * 1024 + 1024;
const coalesced_group_bytes = backend.buffers.group_bytes(coalesced_buffers, coalesced_buffer_bytes);
var coalesced_memory: [coalesced_group_bytes]u8 align(backend.buffers.group_alignment) = undefined;

/// Bytes of each datagram of a segmented send in the coalesced scenarios.
const coalesced_segment_bytes = 10;

/// Sends `sends` segmented sends of `segments` datagrams each, every datagram `coalesced_segment_bytes`
/// long and filled with its index over the whole burst, and waits until each send ends.
fn send_coalesced(harness: *Harness, sender: core.Descriptor, to: Address, sends: u32, segments: u32) !void {
    const bytes = struct {
        var values: [core.constants.segments_max * coalesced_segment_bytes]u8 = undefined;
    };
    assert(segments <= core.constants.segments_max);
    var out = outbound(to);
    out.segment_bytes = coalesced_segment_bytes;
    for (0..sends) |send| {
        const length = segments * coalesced_segment_bytes;
        for (bytes.values[0..length], 0..) |*byte, offset| {
            byte.* = @intCast(send * segments + offset / coalesced_segment_bytes);
        }
        try harness.submit(&.{Operation.send_to(2, sender, bytes.values[0..length], &out)}, &.{});
        var sent: [1]Event = undefined;
        try harness.collect(&sent);
        try testing.expectEqual(@as(u32, length), try sent[0].outcome());
    }
}

/// Sends coalesced datagrams that wait in a socket, then receives them with `events`, and checks
/// that each event hands over one datagram, in order. Linux only: macOS has neither GSO nor GRO.
fn coalesced_burst(events: []Event, sends: u32, segments: u32) !void {
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const group = try harness.loop.reserve_buffer_group();
    try harness.loop.provide_datagram_buffers(group, &coalesced_memory, coalesced_buffers, coalesced_buffer_bytes, shape);
    var sending: Harness = undefined;
    try sending.init(1, null);
    defer sending.deinit();
    const receiver = try sync.open_datagram(.ipv4, &loopback, .{});
    defer sync.close_now(receiver);
    const sender = try sync.open_datagram(.ipv4, &loopback, .{});
    defer sync.close_now(sender);
    try send_coalesced(&sending, sender, try sync.local_address(receiver), sends, segments);

    var receive: Receive = .{ .receiver = receiver, .group = group };
    try receive.start(&harness);
    const total = sends * segments;
    var received: u32 = 0;
    var round: u32 = 0;
    while (received < total and round < rounds_max) : (round += 1) {
        const count = try harness.loop.tick(events, wait_ns);
        for (events[0..count]) |event| {
            try testing.expectEqual(@as(u64, 1), event.user_data);
            if (!event.flags.more) try receive.start(&harness);
            if (!event.flags.buffer) {
                // The group ran dry before this tick gave its buffers back: see `take_burst`.
                try testing.expectError(error.BuffersExhausted, event.outcome());
                continue;
            }
            const delivery = harness.loop.datagram(group, event);
            const expected: [coalesced_segment_bytes]u8 = @splat(@intCast(received));
            try testing.expectEqualSlices(u8, &expected, delivery.bytes);
            harness.loop.give_back_buffer(group, event.flags.buffer_id);
            received += 1;
        }
    }
    try testing.expectEqual(total, received);
    try end(&harness, receive.handle);
}

test "coalesced datagrams that wait in a socket arrive as one event each, in order" {
    if (conformance.unsupported()) return error.SkipZigTest;
    if (builtin.os.tag != .linux) return;
    // Room for epoll's reap to batch 8, and each batched buffer a coalesced datagram to split.
    var events: [events_len]Event = undefined;
    try coalesced_burst(&events, coalesced_buffers, 4);
}

test "coalesced datagrams too many for a tick's events arrive whole in later ticks" {
    if (conformance.unsupported()) return error.SkipZigTest;
    if (builtin.os.tag != .linux) return;
    // Room for one coalesced datagram's events, so epoll's reap takes one datagram a readiness. A
    // batch of 4 coalesced datagrams of 32 would need twice the room.
    var events: [core.constants.coalesced_segments_max]Event = undefined;
    try coalesced_burst(&events, coalesced_buffers, 32);
}
