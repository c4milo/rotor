//! A buffer group taken back with `release_buffers` and provided again under the same id (rotor
//! issue 13). A library that stops and starts on a loop that lives on uses the one group id it
//! reserved, and does not use up `buffer_groups_max` (decision 29).
const std = @import("std");
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
const buffer_bytes = 2048;
const group_bytes = backend.buffers.group_bytes(group_buffers, buffer_bytes);
var first_memory: [group_bytes]u8 align(backend.buffers.group_alignment) = undefined;
var second_memory: [group_bytes]u8 align(backend.buffers.group_alignment) = undefined;

/// Ticks of up to `wait_ns` each that a datagram gets to arrive.
const rounds_max = 100;
const wait_ns = 10 * core.constants.ns_per_ms;

const loopback = Address.ipv4(.{ 127, 0, 0, 1 }, 0);

/// Sends `byte` to `to` from a loop of its own, and waits until the send ends.
fn send(harness: *Harness, sender: core.Descriptor, to: Address, byte: *const [1]u8) !void {
    var out: Outbound = .{ .peer = to, .local = undefined, .segment_bytes = 0, .ecn = .not_ect, .flags = .{ .peer = true } };
    try harness.submit(&.{Operation.send_to(2, sender, byte, &out)}, &.{});
    var sent: [1]Event = undefined;
    try harness.collect(&sent);
    try testing.expectEqual(@as(u32, 1), try sent[0].outcome());
}

/// Receives one datagram into the group, checks that it holds `byte` and lies inside `memory`,
/// gives its buffer back, then cancels the receive and ticks until its final event.
fn receive_one(
    harness: *Harness,
    group: core.BufferGroup,
    receiver: core.Descriptor,
    memory: []const u8,
    byte: u8,
) !void {
    var handles: [1]core.Handle = undefined;
    try harness.submit(&.{Operation.receive_from(1, receiver, group)}, &handles);
    var events: [8]Event = undefined;
    var received = false;
    var round: u32 = 0;
    while (!received and round < rounds_max) : (round += 1) {
        const count = try harness.loop.tick(&events, wait_ns);
        for (events[0..count]) |event| {
            try testing.expect(event.flags.buffer);
            const delivery = harness.loop.datagram(group, event);
            try testing.expectEqualSlices(u8, &.{byte}, delivery.bytes);
            const start = @intFromPtr(memory.ptr);
            const at = @intFromPtr(delivery.bytes.ptr);
            try testing.expect(at >= start and at < start + memory.len);
            harness.loop.give_back_buffer(group, event.flags.buffer_id);
            received = true;
        }
    }
    try testing.expect(received);
    harness.loop.cancel(handles[0]);
    try harness.loop.drain(&events);
}

test "a group taken back can be provided again under its id, from other memory" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var sending: Harness = undefined;
    try sending.init(1, null);
    defer sending.deinit();
    const receiver = try sync.open_datagram(.ipv4, &loopback, .{ .coalesce = false });
    defer sync.close_now(receiver);
    const sender = try sync.open_datagram(.ipv4, &loopback, .{});
    defer sync.close_now(sender);
    const to = try sync.local_address(receiver);

    const group = try harness.loop.reserve_buffer_group();
    try harness.loop.provide_datagram_buffers(group, &first_memory, group_buffers, buffer_bytes, shape);
    try send(&sending, sender, to, &.{1});
    try receive_one(&harness, group, receiver, &first_memory, 1);
    harness.loop.release_buffers(group);
    // The first memory is the caller's again. A loop that still received into it would deliver
    // the next datagram from it, and the check of where the datagram lies would fail.
    @memset(&first_memory, 0xaa);

    try harness.loop.provide_datagram_buffers(group, &second_memory, group_buffers, buffer_bytes, shape);
    try send(&sending, sender, to, &.{2});
    try receive_one(&harness, group, receiver, &second_memory, 2);
    harness.loop.release_buffers(group);
    // The release kept the id: the next reservation is another one.
    try testing.expect(try harness.loop.reserve_buffer_group() != group);
}

/// The view of the loop a library holds (decision 28).
const SharedLoop = core.shared_loop.SharedLoop(backend.Loop);

/// One library of the two-library scenario: a group it reserved, and a socket it receives on.
const Library = struct {
    group: core.BufferGroup,
    socket: core.Descriptor,

    /// Reserves a group on the loop the library shares, and provides it from `memory`.
    fn start(shared: *SharedLoop, memory: []align(backend.buffers.group_alignment) u8) !Library {
        const group = try shared.reserve_buffer_group();
        try shared.provide_datagram_buffers(group, memory, group_buffers, buffer_bytes, shape);
        const socket = try sync.open_datagram(.ipv4, &loopback, .{ .coalesce = false });
        return .{ .group = group, .socket = socket };
    }

    fn stop(library: *const Library, shared: *SharedLoop) void {
        shared.release_buffers(library.group);
        sync.close_now(library.socket);
    }
};

test "two libraries on one loop reserve two groups, and each receives into its own" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var sending: Harness = undefined;
    try sending.init(1, null);
    defer sending.deinit();
    const sender = try sync.open_datagram(.ipv4, &loopback, .{});
    defer sync.close_now(sender);
    const shared = harness.loop.shared();
    const first = try Library.start(shared, &first_memory);
    defer first.stop(shared);
    const second = try Library.start(shared, &second_memory);
    defer second.stop(shared);
    try testing.expect(first.group != second.group);

    try send(&sending, sender, try sync.local_address(first.socket), &.{1});
    try receive_one(&harness, first.group, first.socket, &first_memory, 1);
    try send(&sending, sender, try sync.local_address(second.socket), &.{2});
    try receive_one(&harness, second.group, second.socket, &second_memory, 2);
}
