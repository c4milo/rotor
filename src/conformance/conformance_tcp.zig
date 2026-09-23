//! TCP scenarios: what decision 2's TCP row promises, over loopback.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Handle = core.Handle;
const Operation = core.Operation;
const sync = backend.sync;

const loopback = core.Address.ipv4(.{ 127, 0, 0, 1 }, 0);
const backlog = 16;

/// A listener on a port the kernel chose, and the address a client connects to.
pub const Listener = struct {
    descriptor: core.Descriptor,
    address: core.Address,

    pub fn open() !Listener {
        const descriptor = try sync.listen(&loopback, .{ .backlog = backlog, .reuse_port = false });
        errdefer sync.close_now(descriptor);
        const address = try sync.local_address(descriptor);
        if (address.port == 0) return error.PortNotAssigned;
        return .{ .descriptor = descriptor, .address = address };
    }
};

/// Connects one client to `listener` through the loop, and returns both ends.
pub fn connected_pair(harness: *Harness, listener: *const Listener) ![2]core.Descriptor {
    const client = try sync.open_socket(.ipv4);
    errdefer sync.close_now(client);
    try harness.submit(&.{
        Operation.accept(100, listener.descriptor, false),
        Operation.connect(101, client, &listener.address),
    }, &.{});
    var events: [2]Event = undefined;
    try harness.collect(&events);
    const accepted = try (try Harness.find(&events, 100)).outcome();
    try testing.expectEqual(@as(u32, 0), try (try Harness.find(&events, 101)).outcome());
    return .{ client, @intCast(accepted) };
}

test "accept, connect, and bytes both ways over loopback" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const listener = try Listener.open();
    defer sync.close_now(listener.descriptor);
    const pair = try connected_pair(&harness, &listener);
    defer for (pair) |descriptor| sync.close_now(descriptor);
    // A socket the loop accepted does not leak into a process the application starts.
    try testing.expect(backend.testing.closes_on_exec(pair[1]));

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
    try testing.expectEqual(@as(u32, 0), harness.loop.in_flight());
}

test "a connect to a port nobody listens on is refused" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    // A listener's port, freed by closing the listener, is a port nobody listens on.
    const listener = try Listener.open();
    sync.close_now(listener.descriptor);
    const client = try sync.open_socket(.ipv4);
    defer sync.close_now(client);
    try harness.submit(&.{Operation.connect(1, client, &listener.address)}, &.{});
    var events: [1]Event = undefined;
    try harness.collect(&events);
    try testing.expectError(error.ConnectionRefused, events[0].outcome());
}

test "a receive returns 0 when the peer shut its sending side" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const listener = try Listener.open();
    defer sync.close_now(listener.descriptor);
    const pair = try connected_pair(&harness, &listener);
    defer for (pair) |descriptor| sync.close_now(descriptor);

    var buffer: [8]u8 = undefined;
    try harness.submit(&.{
        Operation.receive(1, pair[1], &buffer),
        .{ .user_data = 2, .kind = .{ .shutdown = .{ .socket = pair[0], .how = .send } } },
    }, &.{});
    var events: [2]Event = undefined;
    try harness.collect(&events);
    try testing.expectEqual(@as(u32, 0), try (try Harness.find(&events, 1)).outcome());
    try testing.expectEqual(@as(u32, 0), try (try Harness.find(&events, 2)).outcome());
}

/// Connections per wave. Two waves make more connects than the loop has submission entries, so
/// the storage a connect's address is converted into is reused across ticks (decision 11,
/// point 6).
const storm_connections = 12;
const storm_waves = 2;
/// How long the scenario's last tick waits, with a connection pending that nobody accepts.
const quiet_wait_ns = 40 * core.constants.ns_per_ms;

/// Opens `storm_connections` clients, connects them all in one batch, and closes every accepted
/// socket and every client. Returns how many accepts the multishot operation `accept_user_data`
/// produced.
fn storm_wave(harness: *Harness, listener: *const Listener, accept_user_data: u64) !u32 {
    var clients: [storm_connections]core.Descriptor = undefined;
    var connects: [storm_connections]Operation = undefined;
    for (&clients, &connects, 0..) |*client, *operation, index| {
        client.* = try sync.open_socket(.ipv4);
        operation.* = Operation.connect(10 + index, client.*, &listener.address);
    }
    defer for (clients) |client| sync.close_now(client);
    try harness.submit(&connects, &.{});

    var events: [2 * storm_connections]Event = undefined;
    try harness.collect(&events);
    var accepted: u32 = 0;
    for (events) |event| {
        if (event.user_data != accept_user_data) {
            try testing.expectEqual(@as(u32, 0), try event.outcome());
            continue;
        }
        try testing.expect(event.flags.more);
        sync.close_now(@intCast(try event.outcome()));
        accepted += 1;
    }
    return accepted;
}

test "one multishot accept takes every connection, and a cancel ends it with one final event" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const listener = try Listener.open();
    defer sync.close_now(listener.descriptor);

    var handles: [1]Handle = undefined;
    try harness.submit(&.{Operation.accept(1, listener.descriptor, true)}, &handles);
    comptime std.debug.assert(storm_waves * storm_connections > conformance.entries);
    for (0..storm_waves) |_| {
        const accepted = try storm_wave(&harness, &listener, 1);
        try testing.expectEqual(@as(u32, storm_connections), accepted);
    }
    try testing.expectEqual(@as(u32, 1), harness.loop.in_flight());

    harness.loop.cancel(handles[0]);
    var last: [1]Event = undefined;
    try harness.collect(&last);
    try testing.expect(last[0].is_final());
    try testing.expectError(error.Canceled, last[0].outcome());
    try testing.expectEqual(@as(u32, 0), harness.loop.in_flight());

    // Nobody accepts any more. A connection that arrives now yields no event, and it must not
    // keep the loop from sleeping: a tick that waits takes its whole wait. A second loop makes the
    // connection, so this one does not tick between the cancel and the tick that is measured: a
    // tick of its own in between could tidy up what the cancel left behind and hide it.
    var other: Harness = undefined;
    try other.init(1, null);
    defer other.deinit();
    const late = try sync.open_socket(.ipv4);
    defer sync.close_now(late);
    try other.submit(&.{Operation.connect(99, late, &listener.address)}, &.{});
    try other.collect(&last);
    try testing.expectEqual(@as(u32, 0), try last[0].outcome());
    const before = backend.testing.monotonic_ns();
    try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&last, quiet_wait_ns));
    const waited = backend.testing.monotonic_ns() - before;
    try testing.expect(waited >= quiet_wait_ns / 2);
}

test "a one-shot accept behind a cancelled multishot accept still takes the next connection" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const listener = try Listener.open();
    defer sync.close_now(listener.descriptor);

    // Both wait on the one listener: the multishot accept first, the one-shot accept behind it.
    var handles: [2]Handle = undefined;
    try harness.submit(&.{
        Operation.accept(1, listener.descriptor, true),
        Operation.accept(2, listener.descriptor, false),
    }, &handles);
    var ended: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&ended, 0));
    harness.loop.cancel(handles[0]);
    try harness.collect(&ended);
    try testing.expectEqual(@as(u64, 1), ended[0].user_data);
    try testing.expectError(error.Canceled, ended[0].outcome());

    // The next connection is the one-shot accept's, although the filter it waited on was the
    // multishot accept's.
    const client = try sync.open_socket(.ipv4);
    defer sync.close_now(client);
    try harness.submit(&.{Operation.connect(3, client, &listener.address)}, &.{});
    var answers: [2]Event = undefined;
    try harness.collect(&answers);
    const accepted = try (try Harness.find(&answers, 2)).outcome();
    sync.close_now(@intCast(accepted));
    try testing.expectEqual(@as(u32, 0), try (try Harness.find(&answers, 3)).outcome());
}

test "bytes that arrive while nobody receives do not keep the loop from sleeping" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const listener = try Listener.open();
    defer sync.close_now(listener.descriptor);
    const pair = try connected_pair(&harness, &listener);
    defer for (pair) |descriptor| sync.close_now(descriptor);

    // One receive that waits and completes. After it, nobody receives on this socket.
    var buffer: [8]u8 = undefined;
    const batch = [_]Operation{
        Operation.receive(1, pair[1], &buffer),
        Operation.send(2, pair[0], "one"),
    };
    try harness.submit(&batch, &.{});
    var events: [2]Event = undefined;
    try harness.collect(&events);
    try testing.expectEqual(@as(u32, 3), try (try Harness.find(&events, 1)).outcome());

    // More bytes arrive and nobody asks for them. A backend may wake once for them, but not on
    // every wait: of two waiting ticks, the second takes its whole wait.
    try harness.submit(&.{Operation.send(3, pair[0], "two")}, &.{});
    try harness.collect(events[0..1]);
    _ = try harness.loop.tick(events[0..1], quiet_wait_ns);
    const before = backend.testing.monotonic_ns();
    try testing.expectEqual(@as(u32, 0), try harness.loop.tick(events[0..1], quiet_wait_ns));
    try testing.expect(backend.testing.monotonic_ns() - before >= quiet_wait_ns / 2);
}

/// Sends a scenario makes to a peer that closed before it gives up. The first is taken and answered
/// with a reset, and the kernel refuses one of the next few; this many is far beyond that.
const sends_to_a_closed_peer_max = 64;

/// SIGPIPEs this process received while the scenario below counted them.
var broken_pipe_signals = std.atomic.Value(u32).init(0);

fn count_broken_pipe_signal(signal: std.posix.SIG) callconv(.c) void {
    _ = signal;
    _ = broken_pipe_signals.fetchAdd(1, .monotonic);
}

test "a send to a peer that closed ends with broken_pipe, and raises no signal" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const listener = try Listener.open();
    defer sync.close_now(listener.descriptor);
    const pair = try connected_pair(&harness, &listener);
    defer sync.close_now(pair[0]);

    // The peer closes. The first send after it is still taken, and the peer answers it with a
    // reset; a send after that is refused, and the kernel raises SIGPIPE with the refusal unless the
    // backend asked it not to. Unasked, that signal ends a C program, or any that keeps the default
    // action. A Zig test cannot see that: `std.Io.Threaded` installs a handler that does nothing for
    // SIGPIPE, so this process would live either way. So the scenario counts the signal instead,
    // with a handler of its own for the length of the sends.
    const counting: std.posix.Sigaction = .{
        .handler = .{ .handler = count_broken_pipe_signal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(.PIPE, &counting, &previous);
    defer std.posix.sigaction(.PIPE, &previous, null);
    const signals_before = broken_pipe_signals.load(.monotonic);
    sync.close_now(pair[1]);
    var events: [1]Event = undefined;
    var refused: anyerror = error.SendNeverRefused;
    var sent: u32 = 0;
    while (sent < sends_to_a_closed_peer_max) : (sent += 1) {
        try harness.submit(&.{Operation.send(1, pair[0], "x")}, &.{});
        try harness.collect(&events);
        // A reset reported on one send is consumed by it, and the next send meets the closed pipe.
        if (events[0].outcome()) |_| {} else |err| switch (err) {
            error.ConnectionReset => {},
            else => {
                refused = err;
                break;
            },
        }
    }
    try testing.expectEqual(@as(anyerror, error.BrokenPipe), refused);
    try testing.expectEqual(signals_before, broken_pipe_signals.load(.monotonic));
}

const group_id = 3;
const group_buffers = 2;
const group_buffer_bytes = 16;

test "a multishot receive names the provided buffer of each event and ends when they run out" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const listener = try Listener.open();
    defer sync.close_now(listener.descriptor);
    const pair = try connected_pair(&harness, &listener);
    defer for (pair) |descriptor| sync.close_now(descriptor);

    const group_bytes = comptime backend.buffers.group_bytes(group_buffers, group_buffer_bytes);
    var group_memory: [group_bytes]u8 align(backend.buffers.group_alignment) = undefined;
    try harness.loop.provide_buffers(group_id, &group_memory, group_buffers, group_buffer_bytes);
    try harness.submit(&.{.{ .user_data = 1, .kind = .{ .receive = .{
        .socket = pair[1],
        .target = .{ .group = group_id },
        .multishot = true,
    } } }}, &.{});

    // Two messages take the two buffers, and none is given back, so the third finds the group
    // empty, which ends the operation. Each message is received before the next is sent, so
    // each arrives as its own event.
    const messages = [_][]const u8{ "first", "second" };
    for (messages, 0..) |message, round| {
        try harness.submit(&.{Operation.send(10 + round, pair[0], message)}, &.{});
        var events: [2]Event = undefined;
        try harness.collect(&events);
        const received = try Harness.find(&events, 1);
        try testing.expect(received.flags.more and received.flags.buffer);
        const bytes = harness.loop.provided_buffer(group_id, received.flags.buffer_id);
        try testing.expectEqualStrings(message, bytes[0..try received.outcome()]);
    }
    try testing.expectEqual(@as(u32, 1), harness.loop.in_flight());

    try harness.submit(&.{Operation.send(12, pair[0], "third")}, &.{});
    var events: [2]Event = undefined;
    try harness.collect(&events);
    const last = try Harness.find(&events, 1);
    try testing.expect(last.is_final());
    try testing.expectError(error.BuffersExhausted, last.outcome());
    try testing.expectEqual(@as(u32, 0), harness.loop.in_flight());
}
