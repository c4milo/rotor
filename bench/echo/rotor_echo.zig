//! rotor_echo: a TCP echo server on 127.0.0.1, the rotor side of the echo comparison.
//!
//! Run:  rotor_echo PORT        Stop it by closing every connection, or with SIGTERM.
//!
//! It is written the way that is fastest for rotor, as `bench/competitors/libxev_echo.zig` is
//! written the way that is fastest for libxev, so that no result of the harness comes from a
//! candidate written carelessly. That means every source decision 3 claims:
//!
//! - One multishot accept for the whole run: one submission for every connection there will be.
//! - One multishot receive per connection, from a provided-buffer group: the bytes land in a
//!   buffer the loop picked, and no receive is submitted per message.
//! - The echo is one send of the buffer the receive named. The buffer goes back to its group
//!   when that send completes, which is the one place this file has to be careful: the buffer
//!   belongs to the loop until then (decision 5, rule 3).
//!
//! A connection therefore costs one send entry per message and nothing else. The receive side is
//! free after the first submission, which is what a multishot receive is for.
//!
//! Everything is static. The server holds `connections_max` connections and refuses to track more.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const backend = @import("backend");

const Loop = backend.Loop;
const Event = core.Event;
const Operation = core.Operation;
const sync = backend.sync;

/// Connections this server tracks at once. A descriptor above this many is closed at once.
const connections_max = 4096;

/// Slots: one multishot accept, one multishot receive per connection, and one send in flight per
/// connection, with room to spare.
const operations = 2 * connections_max + 64;

/// Submission entries per tick.
const entries = 4096;

/// Events one tick may hand over.
const events_max = 1024;

/// The provided-buffer group the multishot receives draw from.
const group_id = 0;

/// Buffers in the group: a power of two, and more than one per connection in flight at a time.
const group_buffers = 8192;

/// Bytes per provided buffer. The harness sends 4 KiB and 64 KiB payloads; a buffer this size
/// takes a 4 KiB message whole and a 64 KiB message in pieces, which an echo does not mind:
/// every piece is echoed in the order it arrived, so the stream is the same.
const buffer_bytes = 8192;

/// The listener's backlog.
const backlog = 1024;

/// What a completion's `user_data` says: the kind in the high half, the descriptor in the low.
const Kind = enum(u32) { accept, receive, send };

const kind_shift = 32;

fn user_data_of(kind: Kind, descriptor: core.Descriptor) u64 {
    const low: u32 = @bitCast(descriptor);
    return (@as(u64, @intFromEnum(kind)) << kind_shift) | low;
}

fn kind_of(user_data: u64) Kind {
    return @enumFromInt(@as(u32, @truncate(user_data >> kind_shift)));
}

fn descriptor_of(user_data: u64) core.Descriptor {
    return @bitCast(@as(u32, @truncate(user_data)));
}

/// The buffer a send is echoing, by descriptor: it goes back to the group when the send ends.
var sending: [connections_max]u16 = undefined;

/// True while the descriptor is one this server accepted.
var open: [connections_max]bool = undefined;

var loop_memory: [
    Loop.memory_bytes(.{
        .operations = operations,
        .entries = entries,
    })
]u8 align(core.layout.memory_alignment) = undefined;

const ring_alignment = backend.buffers.ring_alignment;

var group_memory: [group_buffers * buffer_bytes]u8 align(ring_alignment) = undefined;
var ring_memory: [backend.buffers.ring_bytes(group_buffers)]u8 align(ring_alignment) = undefined;

pub fn main(init: std.process.Init) !void {
    const port = try port_of(init);
    var loop: Loop = undefined;
    try loop.init(&loop_memory, .{ .operations = operations, .entries = entries });
    defer loop.deinit();

    const address = core.Address.ipv4(.{ 127, 0, 0, 1 }, port);
    const listener = try sync.listen(&address, .{ .backlog = backlog, .reuse_port = false });
    defer sync.close_now(listener);

    try loop.provide_buffers(group_id, &ring_memory, &group_memory, buffer_bytes);
    open = @splat(false);

    _ = loop.submit(&.{.{
        .user_data = user_data_of(.accept, listener),
        .kind = .{ .accept = .{ .listener = listener, .multishot = true } },
    }}, &.{});

    var events: [events_max]Event = undefined;
    while (true) {
        const count = try loop.tick(&events, core.constants.ns_per_s);
        for (events[0..count]) |event| handle(&loop, event);
    }
}

fn port_of(init: std.process.Init) !u16 {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len < 2) return error.MissingPort;
    return std.fmt.parseInt(u16, arguments[1], 10);
}

fn handle(loop: *Loop, event: Event) void {
    switch (kind_of(event.user_data)) {
        .accept => handle_accept(loop, event),
        .receive => handle_receive(loop, event),
        .send => handle_send(loop, event),
    }
}

fn handle_accept(loop: *Loop, event: Event) void {
    const accepted = event.outcome() catch return;
    const descriptor: core.Descriptor = @intCast(accepted);
    if (descriptor >= connections_max) return sync.close_now(descriptor);
    open[@intCast(descriptor)] = true;
    _ = loop.submit(&.{.{
        .user_data = user_data_of(.receive, descriptor),
        .kind = .{ .receive = .{
            .socket = descriptor,
            .target = .{ .group = group_id },
            .multishot = true,
        } },
    }}, &.{});
}

/// Bytes arrived: echo them straight back out of the buffer the loop picked, and hold that
/// buffer until the send says it is done with it.
fn handle_receive(loop: *Loop, event: Event) void {
    const descriptor = descriptor_of(event.user_data);
    const received = event.outcome() catch return close(loop, descriptor);
    if (received == 0) return close(loop, descriptor);
    const buffer_id = event.flags.buffer_id;
    const bytes = loop.provided_buffer(group_id, buffer_id)[0..received];
    sending[@intCast(descriptor)] = buffer_id;
    _ = loop.submit(&.{.{
        .user_data = user_data_of(.send, descriptor),
        .kind = .{ .send = .{ .socket = descriptor, .buffer = .{ .bytes = bytes } } },
    }}, &.{});
}

fn handle_send(loop: *Loop, event: Event) void {
    const descriptor = descriptor_of(event.user_data);
    loop.give_back_buffer(group_id, sending[@intCast(descriptor)]);
    _ = event.outcome() catch return close(loop, descriptor);
}

fn close(loop: *Loop, descriptor: core.Descriptor) void {
    if (descriptor < 0 or descriptor >= connections_max) return;
    if (!open[@intCast(descriptor)]) return;
    open[@intCast(descriptor)] = false;
    _ = loop.submit(&.{.{
        .user_data = user_data_of(.send, descriptor),
        .kind = .{ .close = .{ .descriptor = descriptor } },
    }}, &.{});
}

comptime {
    std.debug.assert(std.math.isPowerOfTwo(group_buffers));
    std.debug.assert(group_buffers <= core.constants.buffers_per_group_max);
    std.debug.assert(connections_max < operations);
}
