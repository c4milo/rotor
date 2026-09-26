//! A TCP echo server on one rotor loop: it sends back every byte a connection sends it.
//!
//! Run:  zig build examples && ./zig-out/bin/echo
//! Then: nc 127.0.0.1 9000
//!
//! It imports the public module `rotor` the way a project that depends on rotor does, and
//! `zig build test` compiles it, so it stays in step with the API. The README shows its `main`.
const std = @import("std");
const rotor = @import("rotor");

const port = 9000;
/// Connections served at once. The server closes any connection beyond this.
const connections_max = 128;
const buffer_bytes = 4096;

/// What an operation's `user_data` carries: its kind in the high 32 bits, its socket in the low.
const Kind = enum(u32) { accept, receive, send, close };

fn tag(kind: Kind, socket: rotor.Descriptor) u64 {
    return @as(u64, @intFromEnum(kind)) << 32 | @as(u32, @bitCast(socket));
}

/// The loop holds the accept and one operation per connection: a connection is receiving, sending
/// or closing, never two at once. rotor allocates nothing, so its memory is declared here.
const options: rotor.Loop.Options = .{ .operations = connections_max + 1 };
var memory: [rotor.Loop.memory_bytes(options)]u8 align(rotor.memory_alignment) = undefined;

/// One buffer per connection, the bytes it last received, and how many of them are sent back.
var buffers: [connections_max][buffer_bytes]u8 = undefined;
var received: [connections_max]u32 = undefined;
var sent: [connections_max]u32 = undefined;

pub fn main() !void {
    var loop: rotor.Loop = undefined;
    try loop.init(&memory, options);
    // The server runs until it is stopped, so it never calls `loop.deinit()`.

    const address = rotor.Address.ipv4(.{ 127, 0, 0, 1 }, port);
    const listener = try rotor.sync.listen(&address, .{ .backlog = 128, .reuse_port = false });
    // One multishot accept delivers every connection.
    try submit(&loop, rotor.Operation.accept(tag(.accept, listener), listener, true));
    std.debug.print("echo on 127.0.0.1:{d}, {t} backend\n", .{ port, rotor.backend() });

    var events: [64]rotor.Event = undefined;
    while (true) {
        const count = try loop.tick(&events, rotor.constants.ns_per_s);
        for (events[0..count]) |event| try handle(&loop, event);
    }
}

fn handle(loop: *rotor.Loop, event: rotor.Event) !void {
    const socket: rotor.Descriptor = @bitCast(@as(u32, @truncate(event.user_data)));
    switch (@as(Kind, @enumFromInt(event.user_data >> 32))) {
        .accept => {
            // An event without `more` ends the multishot accept, so arm another.
            if (!event.flags.more) try submit(loop, rotor.Operation.accept(event.user_data, socket, true));
            const accepted: rotor.Descriptor = @intCast(event.outcome() catch return);
            if (accepted >= connections_max) return rotor.sync.close_now(accepted);
            try receive(loop, accepted);
        },
        .receive => {
            // 0 bytes is the peer closing; an error ends the connection too.
            const count = event.outcome() catch 0;
            if (count == 0) return submit(loop, rotor.Operation.close(tag(.close, socket), socket));
            received[@intCast(socket)] = count;
            sent[@intCast(socket)] = 0;
            try send_rest(loop, socket);
        },
        .send => {
            const count = event.outcome() catch {
                return submit(loop, rotor.Operation.close(tag(.close, socket), socket));
            };
            sent[@intCast(socket)] += count;
            // A send may take fewer bytes than it was given: send the rest before reading again.
            if (sent[@intCast(socket)] < received[@intCast(socket)]) return send_rest(loop, socket);
            try receive(loop, socket);
        },
        .close => {},
    }
}

fn receive(loop: *rotor.Loop, socket: rotor.Descriptor) !void {
    const buffer = &buffers[@intCast(socket)];
    try submit(loop, rotor.Operation.receive(tag(.receive, socket), socket, buffer));
}

fn send_rest(loop: *rotor.Loop, socket: rotor.Descriptor) !void {
    const index: usize = @intCast(socket);
    const rest = buffers[index][sent[index]..received[index]];
    try submit(loop, rotor.Operation.send(tag(.send, socket), socket, rest));
}

/// `submit` takes as many operations as the loop has room for. This loop is sized for every
/// operation the server can have in flight, so a refusal here is a bug in that sizing.
fn submit(loop: *rotor.Loop, operation: rotor.Operation) !void {
    if (loop.submit(&.{operation}, &.{}) != 1) return error.LoopFull;
}
