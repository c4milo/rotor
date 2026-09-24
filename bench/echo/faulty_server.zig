//! `faulty_server`: an echo server for the tests of `client.zig` and `storm.zig` that does one
//! thing wrong on purpose, or nothing. It runs a rotor loop on a thread of its own and serves
//! every connection it accepts until the test stops it.
//!
//! A measurement must fail when its server fails. A test cannot make `rotor_echo`, libuv or libxev
//! fail on demand, so the tests start this server instead.
const std = @import("std");
const core = @import("core");
const backend = @import("backend");

const Loop = backend.Loop;
const Event = core.Event;
const Operation = core.Operation;
const sync = backend.sync;

/// What the server does wrong.
pub const Fault = enum {
    /// Nothing: every piece goes back as it came.
    none,
    /// Closes each connection as soon as it has accepted it.
    close,
    /// Changes the first byte of every piece before it sends the piece back.
    corrupt,
    /// Sends each piece back on the other connection of its pair: connection 0's bytes go to 1,
    /// 1's go to 0, 2's go to 3, and so on. A count of bytes cannot tell this from an echo.
    crossed,
};

/// Connections the server accepts at most, over its whole life.
pub const connections_max = 16;

/// The most bytes one receive takes.
const piece_bytes_max = 4096;

/// Slots: a receive and a send per connection, and the accept.
const loop_options: Loop.Options = .{ .operations = 2 * connections_max + 1, .entries = 64 };

var loop_memory: [Loop.memory_bytes(loop_options)]u8 align(core.layout.memory_alignment) = undefined;
var pieces: [connections_max][piece_bytes_max]u8 = undefined;

/// What a completion's `user_data` says: the kind in the high half, the connection in the low. A
/// send names the connection whose piece it carries, which for `crossed` is not the one it goes to.
const Kind = enum(u32) { accept, receive, send };
const kind_shift = 32;

fn user_data_of(kind: Kind, index: u32) u64 {
    return (@as(u64, @intFromEnum(kind)) << kind_shift) | index;
}

/// How long the server waits in one tick before it looks at `stopping` again.
const tick_wait_ns = core.constants.ns_per_ms;

/// The byte `corrupt` changes the first byte of a piece with.
const corrupt_mask: u8 = 0xFF;

const Connection = struct {
    descriptor: core.Descriptor,
    /// Bytes of the piece in `pieces[index]`, and how many of them are sent.
    piece_bytes: u32,
    sent: u32,
    /// True until the server closes the socket.
    open: bool,
};

pub const Server = struct {
    fault: Fault,
    listener: core.Descriptor,
    /// The port the listener got, which the test hands its client.
    port: u16,
    stopping: std.atomic.Value(bool),
    thread: std.Thread,
    /// What `serve` returned, which `stop` returns.
    outcome: anyerror!void,
    accepted: u32,
    connections: [connections_max]Connection,
    loop: *Loop,

    /// Listens on a port the kernel picks and starts the server's thread.
    pub fn start(server: *Server, fault: Fault) !void {
        const any_port = core.Address.ipv4(.{ 127, 0, 0, 1 }, 0);
        const listener = try sync.listen(&any_port, .{
            .backlog = connections_max,
            .reuse_port = false,
        });
        errdefer sync.close_now(listener);
        const address = try sync.local_address(listener);
        server.* = .{
            .fault = fault,
            .listener = listener,
            .port = address.port,
            .stopping = .init(false),
            .thread = undefined,
            .outcome = {},
            .accepted = 0,
            .connections = undefined,
            .loop = undefined,
        };
        server.thread = try std.Thread.spawn(.{}, run, .{server});
    }

    /// Stops the thread, closes every socket the server holds, and returns what `serve` returned.
    pub fn stop(server: *Server) !void {
        server.stopping.store(true, .release);
        server.thread.join();
        sync.close_now(server.listener);
        return server.outcome;
    }
};

fn run(server: *Server) void {
    server.outcome = serve(server);
}

/// The loop is built here and not in `start`, because a loop belongs to the thread that runs it.
fn serve(server: *Server) !void {
    var loop: Loop = undefined;
    try loop.init(&loop_memory, loop_options);
    // In reverse: the loop is emptied, then the sockets close, then the loop is torn down.
    defer loop.deinit();
    server.loop = &loop;
    defer close_connections(server);
    defer empty(&loop);
    submit(server, Operation.accept(user_data_of(.accept, 0), server.listener, false));

    var events: [events_max]Event = undefined;
    while (!server.stopping.load(.acquire)) {
        const count = try loop.tick(&events, tick_wait_ns);
        for (events[0..count]) |event| try handle(server, event);
    }
}

const events_max = loop_options.operations;

/// Cancels and reaps every operation still in flight, so `deinit` finds the loop empty.
fn empty(loop: *Loop) void {
    var events: [events_max]Event = undefined;
    loop.cancel_all();
    loop.drain(&events) catch {};
}

fn close_connections(server: *Server) void {
    for (server.connections[0..server.accepted]) |*connection| {
        if (connection.open) sync.close_now(connection.descriptor);
        connection.open = false;
    }
}

fn submit(server: *Server, operation: Operation) void {
    const submitted = server.loop.submit(&.{operation}, &.{});
    std.debug.assert(submitted == 1);
}

fn handle(server: *Server, event: Event) !void {
    const index: u32 = @truncate(event.user_data);
    switch (@as(Kind, @enumFromInt(@as(u32, @truncate(event.user_data >> kind_shift))))) {
        .accept => try accepted(server, event),
        .receive => received(server, index, event),
        .send => sent(server, index, event),
    }
}

fn accepted(server: *Server, event: Event) !void {
    // A cancel at the end of the test ends the accept, and nothing is wrong.
    const descriptor: core.Descriptor = @intCast(event.outcome() catch return);
    if (server.accepted == connections_max) {
        sync.close_now(descriptor);
        return error.TooManyConnections;
    }
    const index = server.accepted;
    server.connections[index] = .{
        .descriptor = descriptor,
        .piece_bytes = 0,
        .sent = 0,
        .open = true,
    };
    server.accepted += 1;
    submit(server, Operation.accept(user_data_of(.accept, 0), server.listener, false));
    switch (server.fault) {
        .close => {
            sync.close_now(descriptor);
            server.connections[index].open = false;
        },
        .none, .corrupt => submit_receive(server, index),
        // A pair starts receiving once both of its connections are there, so every piece has
        // somewhere to go.
        .crossed => if (index % 2 == 1) {
            submit_receive(server, index - 1);
            submit_receive(server, index);
        },
    }
}

fn submit_receive(server: *Server, index: u32) void {
    const descriptor = server.connections[index].descriptor;
    submit(server, Operation.receive(user_data_of(.receive, index), descriptor, &pieces[index]));
}

/// A piece arrived on connection `index`. A close by the client, or a cancel, ends the connection's
/// work, and its socket stays open until the server stops.
fn received(server: *Server, index: u32, event: Event) void {
    const count = event.outcome() catch return;
    if (count == 0) return;
    if (server.fault == .corrupt) pieces[index][0] ^= corrupt_mask;
    server.connections[index].piece_bytes = count;
    server.connections[index].sent = 0;
    submit_send(server, index);
}

/// Sends the rest of connection `index`'s piece, to the connection the fault names.
fn submit_send(server: *Server, index: u32) void {
    const connection = &server.connections[index];
    const to = if (server.fault == .crossed) index ^ 1 else index;
    const bytes = pieces[index][connection.sent..connection.piece_bytes];
    const descriptor = server.connections[to].descriptor;
    submit(server, Operation.send(user_data_of(.send, index), descriptor, bytes));
}

fn sent(server: *Server, index: u32, event: Event) void {
    const count = event.outcome() catch return;
    const connection = &server.connections[index];
    connection.sent += count;
    if (connection.sent < connection.piece_bytes) return submit_send(server, index);
    submit_receive(server, index);
}
