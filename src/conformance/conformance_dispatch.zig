//! A loop that several libraries share (decision 26). Each library names a `Completion` in its
//! operations, and any of them may tick. Every event reaches the record of its own operation, and
//! an event of an operation without a record reaches the caller of `tick`.
//!
//! `conformance_stall.zig` makes every record and poller here, and the harness ticks the loop, so a
//! callback that holds the loop past its limit fails the scenario.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const conformance = @import("conformance.zig");
const stall = @import("conformance_stall.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Operation = core.Operation;

const ms = core.constants.ns_per_ms;

/// Ticks of up to `wait_ns` each that the scenarios get to see their events.
const rounds_max = 200;
const wait_ns = 10 * ms;

/// One library on the shared loop: a record and what it saw.
const Library = struct {
    /// The events the record received, `more` ones included.
    events: u32 = 0,
    completion: core.Completion = stall.completion(Library, "completion", called),
    /// The final events the record received.
    finals: u32 = 0,
    /// Set by `called` when it should submit a timer without a record from inside its callback.
    submit_into: ?*Harness = null,

    fn called(library: *Library, event: Event) void {
        std.debug.assert(event.flags.dispatched);
        std.debug.assert(event.user_data == @intFromPtr(&library.completion));
        library.events += 1;
        if (!event.flags.more) library.finals += 1;
        const harness = library.submit_into orelse return;
        library.submit_into = null;
        harness.submit(&.{Operation.timer(9, ms, 0)}, &.{}) catch unreachable;
    }
};

/// Room for every event of a full batch of coalesced datagrams. epoll's reap sizes a batch by the
/// room it has, so with less it never takes the batch path the receive scenario tests.
const events_len = core.constants.coalesced_segments_max * 8;

/// Ticks until `done` returns true, and fails if any tick hands an event to its caller.
fn tick_until(harness: *Harness, context: anytype, comptime done: fn (@TypeOf(context)) bool) !void {
    var events: [events_len]Event = undefined;
    var round: u32 = 0;
    while (!done(context) and round < rounds_max) : (round += 1) {
        try testing.expectEqual(@as(u32, 0), try harness.tick(&events, wait_ns));
    }
    try testing.expect(done(context));
}

const Pair = struct { first: *Library, second: *Library };

fn both_finished(pair: Pair) bool {
    return pair.first.finals == 2 and pair.second.finals == 1;
}

test "two libraries on one loop each get their own events, whichever of them ticks" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var first: Library = .{};
    var second: Library = .{};
    // The first library: a repeating timer, cancelled after three fires, and a one-shot timer.
    var handles: [1]core.Handle = undefined;
    try harness.submit(&.{Operation.timer(0, ms, ms).completion(&first.completion)}, &handles);
    try harness.submit(&.{Operation.timer(0, 2 * ms, 0).completion(&first.completion)}, &.{});
    // The second library: one one-shot timer.
    try harness.submit(&.{Operation.timer(0, 3 * ms, 0).completion(&second.completion)}, &.{});
    var events: [8]Event = undefined;
    var round: u32 = 0;
    while (first.events < 3 and round < rounds_max) : (round += 1) {
        try testing.expectEqual(@as(u32, 0), try harness.tick(&events, wait_ns));
    }
    harness.loop.cancel(handles[0]);
    try tick_until(&harness, Pair{ .first = &first, .second = &second }, both_finished);
    try testing.expectEqual(@as(u32, 1), second.events);
    try testing.expectEqual(@as(u32, 0), harness.loop.in_flight());
}

test "an event of an operation without a record reaches the caller, and the other does not" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var library: Library = .{};
    try harness.submit(&.{
        Operation.timer(0, ms, 0).completion(&library.completion),
        Operation.timer(7, ms, 0),
    }, &.{});
    var events: [8]Event = undefined;
    var plain: u32 = 0;
    var round: u32 = 0;
    while ((plain == 0 or library.finals == 0) and round < rounds_max) : (round += 1) {
        const count = try harness.tick(&events, wait_ns);
        for (events[0..count]) |event| {
            try testing.expectEqual(@as(u64, 7), event.user_data);
            try testing.expect(!event.flags.dispatched);
            plain += 1;
        }
    }
    try testing.expectEqual(@as(u32, 1), plain);
    try testing.expectEqual(@as(u32, 1), library.finals);
}

test "a callback may submit, and the next tick serves what it submitted" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var library: Library = .{ .submit_into = &harness };
    try harness.submit(&.{Operation.timer(0, ms, 0).completion(&library.completion)}, &.{});
    var events: [8]Event = undefined;
    var seen: ?Event = null;
    var round: u32 = 0;
    while (seen == null and round < rounds_max) : (round += 1) {
        const count = try harness.tick(&events, wait_ns);
        if (count != 0) seen = events[0];
    }
    try testing.expectEqual(@as(u32, 1), library.finals);
    try testing.expectEqual(@as(u64, 9), seen.?.user_data);
}

const Polling = struct {
    calls: u32 = 0,
    poller: core.Poller = stall.poller(Polling, "poller", polled),
    worked: bool = false,

    fn polled(polling: *Polling) core.WaitLimit {
        polling.calls += 1;
        return if (polling.worked) .now else .none;
    }
};

/// A wait the tick would block for if no poller did work: long enough that a tick which blocked
/// fails the bound below by far.
const long_wait_ns = 2 * core.constants.ns_per_s;

test "each poller runs once a tick, and one that did work keeps the tick from blocking" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var idle: Polling = .{};
    var busy: Polling = .{ .worked = true };
    var events: [8]Event = undefined;
    // `now_ns` is the clock as the last tick read it, so one tick sets it before the first reading.
    _ = try harness.tick(&events, 0);
    try harness.loop.add_poller(&idle.poller);
    try harness.loop.add_poller(&busy.poller);
    const ticks = 3;
    for (0..ticks) |_| {
        const before = harness.loop.now_ns();
        try testing.expectEqual(@as(u32, 0), try harness.tick(&events, long_wait_ns));
        try testing.expect(harness.loop.now_ns() - before < long_wait_ns / 2);
    }
    try testing.expectEqual(@as(u32, ticks), idle.calls);
    try testing.expectEqual(@as(u32, ticks), busy.calls);
    harness.loop.remove_poller(&busy.poller);
    harness.loop.remove_poller(&idle.poller);
    _ = try harness.tick(&events, 0);
    try testing.expectEqual(@as(u32, ticks), idle.calls);
}

const backend = @import("backend");
const sync = backend.sync;

const group_buffers = 32;
const buffer_bytes = 2048;
const group_bytes = backend.buffers.group_bytes(group_buffers, buffer_bytes);
var group_memory: [group_bytes]u8 align(backend.buffers.group_alignment) = undefined;

const loopback = core.Address.ipv4(.{ 127, 0, 0, 1 }, 0);

/// Datagrams the receive scenario sends: enough that epoll's reap grows its batch past one
/// datagram and takes them with `recvmmsg` (decision 20, amendment of 2026-11-06), so the flag of
/// that path is tested too. The group holds all of them.
const datagrams = 25;

/// A library whose record receives datagrams and gives each buffer back.
const Receiver = struct {
    harness: *Harness,
    group: core.BufferGroup,
    completion: core.Completion = stall.completion(Receiver, "completion", received),
    datagrams: u32 = 0,
    finals: u32 = 0,

    fn received(receiver: *Receiver, event: Event) void {
        if (!event.flags.more) receiver.finals += 1;
        if (!event.flags.buffer) return;
        receiver.datagrams += 1;
        receiver.harness.loop.give_back_buffer(receiver.group, event.flags.buffer_id);
    }
};

fn received_all(receiver: *Receiver) bool {
    return receiver.datagrams == datagrams;
}

fn ended(receiver: *Receiver) bool {
    return receiver.finals == 1;
}

/// Sends `datagrams` datagrams of one byte to `socket`, from a loop of its own.
fn send_datagrams(sending: *Harness, sender: core.Descriptor, socket: core.Descriptor) !void {
    var out: core.datagram.Outbound = .{
        .peer = try sync.local_address(socket),
        .local = undefined,
        .segment_bytes = 0,
        .ecn = .not_ect,
        .flags = .{ .peer = true },
    };
    const byte = [1]u8{7};
    for (0..datagrams) |_| {
        try sending.submit(&.{Operation.send_to(2, sender, &byte, &out)}, &.{});
        var sent: [1]Event = undefined;
        try sending.collect(&sent);
    }
}

test "a multishot receive that names a record hands every datagram and its end to the record" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const group = try harness.loop.reserve_buffer_group();
    try harness.loop.provide_datagram_buffers(group, &group_memory, group_buffers, buffer_bytes, .{});
    defer harness.loop.release_buffers(group);
    var sending: Harness = undefined;
    try sending.init(1, null);
    defer sending.deinit();
    const socket = try sync.open_datagram(.ipv4, &loopback, .{ .coalesce = false });
    defer sync.close_now(socket);
    const sender = try sync.open_datagram(.ipv4, &loopback, .{});
    defer sync.close_now(sender);

    var receiver: Receiver = .{ .harness = &harness, .group = group };
    const receive = Operation.receive_from(0, socket, group).completion(&receiver.completion);
    var handles: [1]core.Handle = undefined;
    try harness.submit(&.{receive}, &handles);
    try send_datagrams(&sending, sender, socket);
    try tick_until(&harness, &receiver, received_all);
    // The cancel's final event reaches the record too, through the backend's failure path.
    harness.loop.cancel(handles[0]);
    try tick_until(&harness, &receiver, ended);
}
