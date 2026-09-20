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
//! It also sets `TCP_NODELAY` on every accepted connection, which is not a rotor source at all:
//! it is what the other candidates set, and a comparison whose candidates disagree about Nagle
//! measures Nagle. The first version of this file left it off while libuv and libxev set it.
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

/// The group's memory, cut into `--buffer-bytes` pieces. Fixed, so a larger buffer means fewer
/// of them: a provided-buffer pool trades the size of a buffer against how many are free at once.
const group_bytes = 64 * 1024 * 1024;

/// The largest and smallest buffer `--buffer-bytes` takes. The largest is the biggest payload
/// the harness sends, because a buffer that holds a whole message costs one send to echo it.
const buffer_bytes_max = 64 * 1024;
/// The smallest is what keeps the count inside `core.constants.buffers_per_group_max`, which is
/// 32,768: 64 MiB of pool cut into 2 KiB pieces is exactly that many.
const buffer_bytes_min = 2048;

/// Buffers in the group when every one is `buffer_bytes_min`: the most there can be.
const group_buffers_max = group_bytes / buffer_bytes_min;

/// Bytes per provided buffer, from `--buffer-bytes`. A message larger than this arrives in
/// pieces, and each piece is a send, which is what the 64 KiB rows of the comparison measure.
var buffer_bytes: u32 = 8192;
var group_buffers: u16 = group_bytes / 8192;

/// The listener's backlog.
const backlog = 1024;

/// What a completion's `user_data` says: the kind in the high half, the descriptor in the low.
/// A close has a kind of its own: it used to borrow the send's, so its completion ran the send's
/// handler and gave a provided buffer back a second time, which corrupts the group's free stack.
const Kind = enum(u32) { accept, receive, send, close };

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

/// The send in flight for a descriptor: which provided buffer it is echoing out of, how much of
/// it has gone, and how much there is. A send may be short, so the rest has to follow it before
/// the buffer goes back to the group; sending less than arrived would silently drop bytes out of
/// the middle of the stream.
const Sending = struct {
    buffer_id: u16,
    sent: u32,
    len: u32,
};

var sending: [connections_max]Sending = undefined;

/// True while the descriptor is one this server accepted.
var open: [connections_max]bool = undefined;

var loop_memory: [
    Loop.memory_bytes(.{
        .operations = operations,
        .entries = entries,
    })
]u8 align(core.layout.memory_alignment) = undefined;

const ring_alignment = backend.buffers.ring_alignment;

var group_memory: [group_bytes]u8 align(ring_alignment) = undefined;
const ring_bytes_max = backend.buffers.ring_bytes(group_buffers_max);
var ring_memory: [ring_bytes_max]u8 align(ring_alignment) = undefined;

pub fn main(init: std.process.Init) !void {
    const port = try parse(init);
    var loop: Loop = undefined;
    try loop.init(&loop_memory, .{ .operations = operations, .entries = entries });
    defer loop.deinit();

    const address = core.Address.ipv4(.{ 127, 0, 0, 1 }, port);
    const listener = try sync.listen(&address, .{ .backlog = backlog, .reuse_port = false });
    defer sync.close_now(listener);

    const used = @as(usize, group_buffers) * buffer_bytes;
    const ring_used = ring_memory[0..backend.buffers.ring_bytes(group_buffers)];
    try loop.provide_buffers(group_id, @alignCast(ring_used), group_memory[0..used], buffer_bytes);
    open = @splat(false);

    submit_one(&loop, .{
        .user_data = user_data_of(.accept, listener),
        .kind = .{ .accept = .{ .listener = listener, .multishot = true } },
    });

    // The harness waits for this line before it connects, as it does for the competitors'.
    var out_buffer: [128]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buffer);
    try out.interface.print(
        "rotor_echo: rotor {s}, {d} buffers of {d} bytes, listening on 127.0.0.1:{d}\n",
        .{ @tagName(builtin.os.tag), group_buffers, buffer_bytes, port },
    );
    try out.interface.flush();

    var events: [events_max]Event = undefined;
    while (true) {
        const count = try loop.tick(&events, core.constants.ns_per_s);
        for (events[0..count]) |event| handle(&loop, event);
    }
}

/// Reads the port and `--buffer-bytes`, which sets how many buffers the group holds.
fn parse(init: std.process.Init) !u16 {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len < 2) return error.MissingPort;
    const port = try std.fmt.parseInt(u16, arguments[1], 10);
    var index: usize = 2;
    while (index < arguments.len) : (index += 2) {
        if (index + 1 >= arguments.len) return error.MissingValue;
        if (!std.mem.eql(u8, arguments[index], "--buffer-bytes")) return error.UnknownArgument;
        const wanted = try std.fmt.parseInt(u32, arguments[index + 1], 10);
        if (wanted < buffer_bytes_min or wanted > buffer_bytes_max) return error.BufferOutOfRange;
        if (!std.math.isPowerOfTwo(wanted)) return error.BufferNotPowerOfTwo;
        buffer_bytes = wanted;
        group_buffers = @intCast(group_bytes / wanted);
    }
    return port;
}

fn handle(loop: *Loop, event: Event) void {
    switch (kind_of(event.user_data)) {
        .accept => handle_accept(loop, event),
        .receive => handle_receive(loop, event),
        .send => handle_send(loop, event),
        .close => handle_close(event),
    }
}

fn handle_accept(loop: *Loop, event: Event) void {
    const accepted = event.outcome() catch return;
    const descriptor: core.Descriptor = @intCast(accepted);
    if (descriptor >= connections_max) return sync.close_now(descriptor);
    // Nagle off, because every other candidate of the comparison turns it off and a row that
    // does not match is measuring the socket option and not the loop. A connection this fails
    // on is refused rather than served, so a run cannot quietly mix the two shapes.
    sync.set_no_delay(descriptor, true) catch return sync.close_now(descriptor);
    open[@intCast(descriptor)] = true;
    arm_receive(loop, descriptor);
}

/// One multishot receive for this connection, which serves it until it ends or the group empties.
fn arm_receive(loop: *Loop, descriptor: core.Descriptor) void {
    submit_one(loop, .{
        .user_data = user_data_of(.receive, descriptor),
        .kind = .{ .receive = .{
            .socket = descriptor,
            .target = .{ .group = group_id },
            .multishot = true,
        } },
    });
}

/// Submits one operation and halts when the loop refuses it. A refusal means the slot table is
/// too small for the connections this run was given, and a benchmark that swallowed it would
/// stall that connection and report the stall as throughput. The four call sites all discarded
/// this count before.
fn submit_one(loop: *Loop, operation: Operation) void {
    const taken = loop.submit(&.{operation}, &.{});
    std.debug.assert(taken == 1);
}

/// Bytes arrived: echo them straight back out of the buffer the loop picked, and hold that
/// buffer until the send says it is done with it.
fn handle_receive(loop: *Loop, event: Event) void {
    const descriptor = descriptor_of(event.user_data);
    const received = event.outcome() catch |failure| {
        // The group emptied. That ends the multishot receive and is transient back-pressure, not
        // the connection's fault: another receive is armed rather than a client dropped because
        // the pool was momentarily empty. Closing here reads as throughput at connection counts
        // above the buffer count, which is exactly where the harness is asked to go.
        if (failure == error.BuffersExhausted) return arm_receive(loop, descriptor);
        return close(loop, descriptor);
    };
    if (received == 0) return close(loop, descriptor);
    sending[@intCast(descriptor)] = .{
        .buffer_id = event.flags.buffer_id,
        .sent = 0,
        .len = received,
    };
    send_rest(loop, descriptor);
}

/// Submits what is left of this descriptor's echo.
fn send_rest(loop: *Loop, descriptor: core.Descriptor) void {
    const state = &sending[@intCast(descriptor)];
    const buffer = loop.provided_buffer(group_id, state.buffer_id);
    submit_one(loop, .{
        .user_data = user_data_of(.send, descriptor),
        .kind = .{ .send = .{
            .socket = descriptor,
            .buffer = .{ .bytes = buffer[state.sent..state.len] },
        } },
    });
}

/// A send ended. It may have sent less than it was given, and the rest has to follow before the
/// buffer is anyone else's: a short send that was ignored would drop those bytes and leave the
/// caller's stream missing a piece in the middle, which no test that sends small messages sees.
fn handle_send(loop: *Loop, event: Event) void {
    const descriptor = descriptor_of(event.user_data);
    const state = &sending[@intCast(descriptor)];
    const sent = event.outcome() catch {
        loop.give_back_buffer(group_id, state.buffer_id);
        return close(loop, descriptor);
    };
    state.sent += sent;
    if (state.sent < state.len) return send_rest(loop, descriptor);
    loop.give_back_buffer(group_id, state.buffer_id);
}

/// The close's own completion. It carries no buffer and there is nothing to give back: the send
/// that was in flight, if any, gave its buffer back when it failed.
fn handle_close(event: Event) void {
    _ = event.outcome() catch {};
}

fn close(loop: *Loop, descriptor: core.Descriptor) void {
    if (descriptor < 0 or descriptor >= connections_max) return;
    if (!open[@intCast(descriptor)]) return;
    open[@intCast(descriptor)] = false;
    submit_one(loop, .{
        .user_data = user_data_of(.close, descriptor),
        .kind = .{ .close = .{ .descriptor = descriptor } },
    });
}

comptime {
    std.debug.assert(std.math.isPowerOfTwo(group_buffers_max));
    std.debug.assert(group_buffers_max <= core.constants.buffers_per_group_max);
    std.debug.assert(group_bytes % buffer_bytes_max == 0);
    std.debug.assert(connections_max < operations);
}
