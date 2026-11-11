//! The seeded shuffle of each reaped batch (decision 10, amendment of 2026-11-06). These scenarios
//! run only in a build that shuffles, and skip in every other build. Each round has four receives
//! on four sockets wait, then makes all four sockets readable at once, so one reap serves all
//! four. Over eight rounds the receives must end in more than one order. That shows the
//! permutation reaches the events of a reap on each backend: the events that go back to the caller
//! of `tick`, and the events that a record takes. The last scenario shows that the shuffle keeps
//! the order of decision 5, rule 6: a close ends after the operations it cancelled.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const tcp = @import("conformance_tcp.zig");

const Harness = conformance.Harness;
const reactor_harness = @import("conformance_reactor.zig");
const Event = core.Event;
const Operation = core.Operation;
const sync = backend.sync;

/// The receives that wait in each round, each on a socket of its own.
const receivers = 4;
/// The rounds of the close scenario.
const rounds = 8;
/// The full rounds an order scenario collects: rounds in which one tick handed over all four
/// receives. Four events have 24 orders, so with a working shuffle four full rounds give one order
/// with a chance of 1 in 24 * 24 * 24.
const full_rounds_wanted = 4;
/// The fewest full rounds an order scenario judges. With fewer, it skips.
const full_rounds_min = 2;
/// The most rounds an order scenario runs to collect its full rounds.
const rounds_max = 64;
/// The `user_data` of the first send. The receives use 0 to `receivers - 1`.
const send_user_data = 100;
const wait_ns = 10 * core.constants.ns_per_ms;

/// The order in which the receives of one round ended.
const Log = struct {
    order: [receivers]u8 = @splat(0),
    len: u32 = 0,
    /// True when one tick handed over all the receives, so the shuffle had all four to move.
    full: bool = false,

    fn note(log: *Log, receiver: u64) void {
        std.debug.assert(receiver < receivers);
        log.order[log.len] = @intCast(receiver);
        log.len += 1;
    }
};

/// A library's record for one receive. It notes its receive in the log.
const Receiver = struct {
    completion: core.Completion = .init(Receiver, "completion", called),
    index: u8,
    log: *Log,

    fn called(receiver: *Receiver, event: Event) void {
        std.debug.assert(event.flags.dispatched);
        receiver.log.note(receiver.index);
    }
};

/// Four connected pairs over loopback. The loop receives on `server` and sends on `client`.
const Pairs = struct {
    client: [receivers]core.Descriptor,
    server: [receivers]core.Descriptor,

    fn open(harness: anytype, listener: *const tcp.Listener) !Pairs {
        var pairs: Pairs = undefined;
        for (0..receivers) |index| {
            const pair = try tcp.connected_pair(harness, listener);
            pairs.client[index] = pair[0];
            pairs.server[index] = pair[1];
        }
        return pairs;
    }

    fn close(pairs: *const Pairs) void {
        for (pairs.client) |descriptor| sync.close_now(descriptor);
        for (pairs.server) |descriptor| sync.close_now(descriptor);
    }
};

/// One round: the receives wait, then four sends make every socket readable in one flush. `log`
/// gets the order in which the receives ended. With `records`, each receive names its record, and
/// `harness` is a `ReactorHarness`.
fn round(harness: anytype, pairs: *const Pairs, records: ?*[receivers]Receiver, log: *Log) !void {
    const driven = reactor_harness.driven(harness);
    var buffers: [receivers][1]u8 = undefined;
    for (0..receivers) |index| {
        var operation = Operation.receive(index, pairs.server[index], &buffers[index]);
        if (records) |named| operation = operation.completion(&named[index].completion);
        try harness.submit(&.{operation}, &.{});
    }
    var events: [2 * receivers]Event = undefined;
    // The receives wait: no socket is readable yet.
    try testing.expectEqual(@as(u32, 0), try driven.tick(&events, 0));
    for (0..receivers) |index| {
        const send = Operation.send(send_user_data + index, pairs.client[index], "x");
        try harness.submit(&.{send}, &.{});
    }
    var tick_count: u32 = 0;
    while (driven.in_flight() != 0 and tick_count < conformance.collect_rounds_max) {
        tick_count += 1;
        const before = log.len;
        const count = try driven.tick(&events, wait_ns);
        for (events[0..count]) |event| {
            if (event.user_data < receivers) log.note(event.user_data);
        }
        if (log.len - before == receivers) log.full = true;
    }
    try testing.expectEqual(@as(u32, 0), driven.in_flight());
    try testing.expectEqual(@as(u32, receivers), log.len);
}

/// What the full rounds of a scenario showed.
const Orders = struct {
    /// The full rounds that ended in another order than the first full round.
    others: u32 = 0,
    /// The rounds in which one tick handed over all the receives.
    full: u32 = 0,
};

/// Runs rounds until `full_rounds_wanted` of them are full, and judges only those. A round whose
/// receives a loaded machine ends over several ticks gave the shuffle less to move, so it does not
/// count. With fewer than `full_rounds_min` full rounds the scenario cannot judge, and it skips.
fn rounds_in_other_orders(comptime records: bool) !u32 {
    const orders = try run_rounds(records);
    if (orders.full < full_rounds_min) return error.SkipZigTest;
    return orders.others;
}

/// The harness of the rounds: a reactor's when the receives name records (decision 33).
fn RoundHarness(comptime records: bool) type {
    return if (records) conformance.ReactorHarness else Harness;
}

fn run_rounds(comptime records: bool) !Orders {
    var harness: RoundHarness(records) = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const listener = try tcp.Listener.open();
    defer sync.close_now(listener.descriptor);
    const pairs = try Pairs.open(&harness, &listener);
    defer pairs.close();

    var first: Log = .{};
    var orders: Orders = .{};
    for (0..rounds_max) |_| {
        if (orders.full == full_rounds_wanted) break;
        var log: Log = .{};
        var named: [receivers]Receiver = undefined;
        for (&named, 0..) |*receiver, receiver_index| {
            receiver.* = .{ .index = @intCast(receiver_index), .log = &log };
        }
        try round(&harness, &pairs, if (records) &named else null, &log);
        if (!log.full) continue;
        if (orders.full == 0) first = log;
        if (!std.mem.eql(u8, &log.order, &first.order)) orders.others += 1;
        orders.full += 1;
    }
    return orders;
}

test "a shuffled build hands the caller the receives of one reap in more than one order" {
    if (conformance.unsupported() or !core.shuffle.enabled) return error.SkipZigTest;
    try testing.expect(try rounds_in_other_orders(false) >= 1);
}

test "a shuffled build calls the records of the receives of one reap in more than one order" {
    if (conformance.unsupported() or !core.shuffle.enabled) return error.SkipZigTest;
    try testing.expect(try rounds_in_other_orders(true) >= 1);
}

test "a shuffled build keeps a close's event after the receive it cancelled, in every round" {
    if (conformance.unsupported() or !core.shuffle.enabled) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const listener = try tcp.Listener.open();
    defer sync.close_now(listener.descriptor);
    // On io_uring the receive's event and the close's come in one reap, which the shuffle permutes.
    // Of eight rounds, a shuffle that moved the close would put it first in about four.
    for (0..rounds) |_| {
        const pair = try tcp.connected_pair(&harness, &listener);
        defer sync.close_now(pair[0]);
        var buffer: [1]u8 = undefined;
        try harness.submit(&.{Operation.receive(1, pair[1], &buffer)}, &.{});
        var events: [2]Event = undefined;
        try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&events, 0));
        try harness.submit(&.{Operation.close(2, pair[1])}, &.{});
        try harness.collect(&events);
        try testing.expectEqual(@as(u64, 1), events[0].user_data);
        try testing.expectError(error.Canceled, events[0].outcome());
        try testing.expectEqual(@as(u64, 2), events[1].user_data);
        try testing.expectEqual(@as(u32, 0), try events[1].outcome());
    }
}
