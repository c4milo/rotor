//! `rotor_echo` under test: its own event handlers, on a real loop and a real loopback connection,
//! with this test as the client. The tests live beside the program because `rotor_echo.zig` is at
//! its 500 lines.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const server = @import("rotor_echo.zig");
const pieces_module = @import("rotor_echo_pieces.zig");

const Loop = backend.Loop;
const Event = core.Event;
const Operation = core.Operation;
const sync = backend.sync;

test "a group gets the count asked for, or the most the pool holds, and nothing else" {
    const most = 512;
    try testing.expectEqual(@as(u16, most), try server.group_buffers_from(null, most));
    try testing.expectEqual(@as(u16, 32), try server.group_buffers_from(32, most));
    try testing.expectEqual(@as(u16, most), try server.group_buffers_from(most, most));
    try testing.expectEqual(@as(u16, 1), try server.group_buffers_from(1, most));
    try testing.expectError(
        error.GroupBuffersBeyondPool,
        server.group_buffers_from(most * 2, most),
    );
    try testing.expectError(error.GroupBuffersNotPowerOfTwo, server.group_buffers_from(48, most));
    try testing.expectError(error.GroupBuffersNotPowerOfTwo, server.group_buffers_from(0, most));
}

/// The server's group in a test, and the message: one message fills every buffer of the group, so
/// it arrives in at least `count` pieces.
const Group = struct {
    count: u16,
    buffer_bytes: u32,

    fn message_bytes(group: Group) u32 {
        return group.count * group.buffer_bytes;
    }
};

/// Few buffers, so the pieces of one message overlap the sends of the pieces before them.
const overlapping: Group = .{ .count = 8, .buffer_bytes = 2048 };

/// More buffers than a connection may hold pieces, so one message passes `pieces_max`.
const overflowing: Group = .{ .count = 2 * pieces_module.pieces_max, .buffer_bytes = 16 };

/// The most bytes any group or message here takes.
const group_bytes_max = @max(
    backend.buffers.group_bytes(overlapping.count, overlapping.buffer_bytes),
    backend.buffers.group_bytes(overflowing.count, overflowing.buffer_bytes),
);
const message_bytes_max = @max(overlapping.message_bytes(), overflowing.message_bytes());

/// Messages echoed. The server before 2026-09-24 echoed the first one whole: each send's bytes were
/// fixed when it was submitted. But the first message gave its last buffer back once per piece and
/// the others never, so every piece of the second landed in that one buffer.
const rounds = 4;

/// Ticks one step may take before the test calls it stalled. A round takes a few dozen.
const ticks_max = 10_000;

/// Room for every piece of the overflowing message in one tick, and more.
const events_max = 4 * pieces_module.pieces_max;

const server_options: Loop.Options = .{ .operations = 16, .entries = 16 };
const client_options: Loop.Options = .{ .operations = 4, .entries = 4 };

const memory_alignment = core.layout.memory_alignment;
const group_alignment = backend.buffers.group_alignment;

var server_memory: [Loop.memory_bytes(server_options)]u8 align(memory_alignment) = undefined;
var client_memory: [Loop.memory_bytes(client_options)]u8 align(memory_alignment) = undefined;
var group_memory: [group_bytes_max]u8 align(group_alignment) = undefined;

var message: [message_bytes_max]u8 = undefined;
var echoed: [message_bytes_max]u8 = undefined;

/// A client descriptor once the test has closed it.
const closed: core.Descriptor = -1;

/// The client's two operations, told apart by their `user_data`.
const client_send = 1;
const client_receive = 2;

/// Both loops and the connection between them. The server loop runs the server's handlers; the
/// client loop is this test's.
const Fixture = struct {
    server_loop: Loop,
    client_loop: Loop,
    listener: core.Descriptor,
    /// The client's end, and the end the server accepted.
    client: core.Descriptor,
    accepted: core.Descriptor,
    /// Buffers in the server's group, and so the fewest pieces a message arrives in.
    group_count: u16,
    message_bytes: u32,
    /// Bytes of the current message sent, and echoed back.
    sent: u32,
    received: u32,

    fn init(fixture: *Fixture, group: Group) !void {
        server.forget_connections();
        fixture.group_count = group.count;
        fixture.message_bytes = group.message_bytes();
        try fixture.server_loop.init(&server_memory, server_options);
        errdefer fixture.server_loop.deinit();
        try fixture.client_loop.init(&client_memory, client_options);
        errdefer fixture.client_loop.deinit();
        const bytes = backend.buffers.group_bytes(group.count, group.buffer_bytes);
        try fixture.server_loop.provide_buffers(
            server.group_id,
            group_memory[0..bytes],
            group.count,
            group.buffer_bytes,
        );
        const any_port = core.Address.ipv4(.{ 127, 0, 0, 1 }, 0);
        fixture.listener = try sync.listen(&any_port, .{ .backlog = 1, .reuse_port = false });
        errdefer sync.close_now(fixture.listener);
        fixture.client = try sync.open_socket(.ipv4);
        errdefer sync.close_now(fixture.client);
        try fixture.connect();
    }

    /// The server accepts through its own handler, which arms its multishot receive.
    fn connect(fixture: *Fixture) !void {
        const address = try sync.local_address(fixture.listener);
        const accept_user_data = server.user_data_of(.accept, fixture.listener);
        submit(&fixture.server_loop, Operation.accept(accept_user_data, fixture.listener, false));
        submit(&fixture.client_loop, Operation.connect(0, fixture.client, &address));
        fixture.accepted = -1;
        var connected = false;
        var events: [events_max]Event = undefined;
        for (0..ticks_max) |_| {
            if (connected and fixture.accepted >= 0) return;
            for (try serve(fixture, &events)) |event| {
                if (event.user_data != accept_user_data) continue;
                fixture.accepted = @intCast(try event.outcome());
            }
            const count = try fixture.client_loop.tick(&events, 0);
            if (count == 1) connected = (try events[0].outcome()) == 0;
        }
        return error.ConnectStalled;
    }

    /// A new client, connected as the first one was.
    fn reconnect(fixture: *Fixture) !void {
        std.debug.assert(fixture.client == closed);
        fixture.client = try sync.open_socket(.ipv4);
        errdefer fixture.close_client();
        try fixture.connect();
    }

    /// Sends one message and reads its echo back, and holds the echo to the message. The server
    /// holds every piece before it handles the first, so on every backend each piece arrives
    /// while the sends of the pieces before it are still to come, and every buffer of the group
    /// has to be free for the message to arrive.
    fn echo_round(fixture: *Fixture, round: u32) !void {
        try fixture.send_whole(round);
        var events: [events_max]Event = undefined;
        const arrived = try fixture.arrive(&events, fixture.group_count);
        for (arrived) |event| server.handle(&fixture.server_loop, event);
        echoed = @splat(0);
        fixture.received = 0;
        fixture.receive_rest();
        for (0..ticks_max) |_| {
            if (fixture.received == fixture.message_bytes) break;
            _ = try serve(fixture, &events);
            const count = try fixture.client_loop.tick(&events, 0);
            for (events[0..count]) |event| try fixture.client_event(event);
        } else return error.EchoStalled;
        const length = fixture.message_bytes;
        try testing.expectEqualSlices(u8, message[0..length], echoed[0..length]);
    }

    /// The message of round `round`. Every byte of a piece differs from its neighbours, and from
    /// the bytes at the same place in the other pieces and rounds, so an echo that repeats, drops
    /// or swaps a piece differs from its message.
    fn fill(fixture: *const Fixture, round: u32) void {
        const piece_bytes = fixture.message_bytes / fixture.group_count;
        for (message[0..fixture.message_bytes], 0..) |*byte, index| {
            byte.* = @truncate(index *% 7 + index / piece_bytes * 31 + round * 13);
        }
    }

    /// Sends round `round`'s whole message, and returns once the client has handed all of it to
    /// the kernel.
    fn send_whole(fixture: *Fixture, round: u32) !void {
        fixture.fill(round);
        fixture.sent = 0;
        fixture.send_rest();
        var events: [events_max]Event = undefined;
        for (0..ticks_max) |_| {
            if (fixture.sent == fixture.message_bytes) return;
            const count = try fixture.client_loop.tick(&events, 0);
            for (events[0..count]) |event| try fixture.client_event(event);
        }
        return error.SendStalled;
    }

    /// The server's events until at least `wanted` have arrived, not yet handed to the server.
    /// Nothing is handed over, so no buffer comes back and the pieces pile up whatever the backend.
    /// Each of the first `wanted` has to hold a piece: a group short of a buffer it lent answers
    /// `buffers_exhausted` sooner.
    fn arrive(fixture: *Fixture, events: *[events_max]Event, wanted: usize) ![]const Event {
        var arrived: usize = 0;
        for (0..ticks_max) |_| {
            if (arrived >= wanted) break;
            arrived += try fixture.server_loop.tick(events[arrived..], 0);
        } else return error.ReceiveStalled;
        for (events[0..wanted]) |event| _ = try event.outcome();
        return events[0..arrived];
    }

    /// Closes the server's end while the pieces of a message arrive: after the server has handled
    /// `handled_first` of them and before the rest. Then the server hears that its receive ran out
    /// of buffers, which io_uring can report after a close was submitted.
    fn close_during(fixture: *Fixture, handled_first: u32) !void {
        try fixture.send_whole(0);
        var events: [events_max]Event = undefined;
        const arrived = try fixture.arrive(&events, @max(handled_first, 1));
        for (arrived[0..handled_first]) |event| server.handle(&fixture.server_loop, event);
        server.close(&fixture.server_loop, fixture.accepted);
        for (arrived[handled_first..]) |event| server.handle(&fixture.server_loop, event);
        const receive_user_data = server.user_data_of(.receive, fixture.accepted);
        server.handle(&fixture.server_loop, Event.failure(receive_user_data, .buffers_exhausted));
        try fixture.settle_close();
        fixture.close_client();
    }

    /// Runs the server until its loop is empty. No event may name the closed descriptor after the
    /// close's own event: an operation submitted after a close can reach the next connection the
    /// kernel gives the same number.
    fn settle_close(fixture: *Fixture) !void {
        const close_user_data = server.user_data_of(.close, fixture.accepted);
        var close_seen = false;
        var events: [events_max]Event = undefined;
        for (0..ticks_max) |_| {
            if (fixture.server_loop.in_flight() == 0) break;
            for (try serve(fixture, &events)) |event| {
                if (close_seen and names(event, fixture.accepted)) return error.EventAfterClose;
                close_seen = close_seen or event.user_data == close_user_data;
            }
        } else return error.CloseStalled;
        if (!close_seen) return error.CloseMissing;
    }

    /// Reads until the server's end is gone: the end of the stream, or a reset.
    fn read_to_end(fixture: *Fixture) !void {
        var events: [events_max]Event = undefined;
        for (0..ticks_max) |_| {
            fixture.received = 0;
            fixture.receive_rest();
            const event = try fixture.client_wait(&events);
            const bytes = event.outcome() catch return;
            if (bytes == 0) return;
        }
        return error.ServerStillOpen;
    }

    fn client_wait(fixture: *Fixture, events: *[events_max]Event) !Event {
        for (0..ticks_max) |_| {
            if (try fixture.client_loop.tick(events, 0) == 1) return events[0];
        }
        return error.ClientStalled;
    }

    fn close_client(fixture: *Fixture) void {
        sync.close_now(fixture.client);
        fixture.client = closed;
    }

    fn client_event(fixture: *Fixture, event: Event) !void {
        const bytes = try event.outcome();
        if (event.user_data == client_send) {
            fixture.sent += bytes;
            if (fixture.sent < fixture.message_bytes) fixture.send_rest();
        } else {
            try testing.expectEqual(@as(u64, client_receive), event.user_data);
            try testing.expect(bytes > 0);
            fixture.received += bytes;
            if (fixture.received < fixture.message_bytes) fixture.receive_rest();
        }
    }

    fn send_rest(fixture: *Fixture) void {
        const rest = message[fixture.sent..fixture.message_bytes];
        submit(&fixture.client_loop, Operation.send(client_send, fixture.client, rest));
    }

    fn receive_rest(fixture: *Fixture) void {
        const rest = echoed[fixture.received..fixture.message_bytes];
        submit(&fixture.client_loop, Operation.receive(client_receive, fixture.client, rest));
    }

    /// The server closes the connection through its own handlers, which hold every buffer to have
    /// come back by the time the close's event arrives.
    fn deinit(fixture: *Fixture) void {
        server.close(&fixture.server_loop, fixture.accepted);
        var events: [events_max]Event = undefined;
        for (0..ticks_max) |_| {
            if (fixture.server_loop.in_flight() == 0) break;
            _ = serve(fixture, &events) catch break;
        }
        if (fixture.client != closed) sync.close_now(fixture.client);
        sync.close_now(fixture.listener);
        fixture.client_loop.cancel_all();
        fixture.client_loop.drain(&events) catch {};
        fixture.server_loop.cancel_all();
        fixture.server_loop.drain(&events) catch {};
        fixture.client_loop.deinit();
        fixture.server_loop.deinit();
    }
};

/// True when `event` is about `descriptor`: every `user_data` the server makes names one in its
/// low half.
fn names(event: Event, descriptor: core.Descriptor) bool {
    return @as(u32, @truncate(event.user_data)) == @as(u32, @bitCast(descriptor));
}

/// One tick of the server loop, every event handed to the server as `serve` hands them, and the
/// events returned for the caller to read.
fn serve(fixture: *Fixture, events: *[events_max]Event) ![]const Event {
    const count = try fixture.server_loop.tick(events, 0);
    for (events[0..count]) |event| server.handle(&fixture.server_loop, event);
    return events[0..count];
}

fn submit(loop: *Loop, operation: Operation) void {
    const taken = loop.submit(&.{operation}, &.{});
    std.debug.assert(taken == 1);
}

test "a message in more pieces than the group has spare comes back byte for byte, every round" {
    if (!backend.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(overlapping);
    defer fixture.deinit();
    for (0..rounds) |round| try fixture.echo_round(@intCast(round));
}

test "a close while pieces arrive gives every buffer back once, and nothing follows it" {
    if (!backend.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(overlapping);
    defer fixture.deinit();
    // Closed before the server handled any piece: each piece goes straight back to the group, and
    // a receive that ran out of buffers is not armed again.
    try fixture.close_during(0);
    try fixture.reconnect();
    // Closed with the first piece's send in flight and the second waiting behind it: that send's
    // event gives back both, and the waiting piece is never sent.
    try fixture.close_during(2);
    try fixture.reconnect();
    // A buffer never given back leaves a message short of one; a buffer given back twice lands two
    // pieces in it, and the echo's bytes differ.
    for (0..rounds) |round| try fixture.echo_round(@intCast(round));
}

test "a connection holding more pieces than the harness's client makes is closed" {
    if (!backend.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(overflowing);
    defer fixture.deinit();
    try fixture.send_whole(0);
    var events: [events_max]Event = undefined;
    const arrived = try fixture.arrive(&events, pieces_module.pieces_max + 1);
    for (arrived) |event| server.handle(&fixture.server_loop, event);
    try fixture.settle_close();
    try fixture.read_to_end();
}
