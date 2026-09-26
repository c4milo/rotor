//! The code of `docs/using.md`, run in order as one program. Every Zig block of the guide is part of
//! this file, line for line, and `tools/readme_examples.zig` holds it to that, so the guide shows
//! code that compiles against the public module and does what the guide says it does. `zig build
//! test` runs it, and the Linux gate runs it on io_uring and on epoll. It exits 0 only when every
//! step did what the guide says.
//!
//! Run:  zig build examples && ./zig-out/bin/guide
const std = @import("std");
const rotor = @import("rotor");

/// The `user_data` of the operations this program adds around the guide's own, which use 1 and 2.
const accept_data = 10;
const connect_data = 11;
const send_data = 12;
const receive_group_data = 13;

/// Ticks a step may take before the program calls it stuck.
const ticks_max = 1000;

/// The provided-buffer group of "Buffers": four buffers of 256 bytes, in memory aligned forward
/// inside a larger static block, which the guide recommends for a caller that builds on every
/// backend.
const buffers = rotor.buffers;
const group_id: u16 = 0;
const group_count: u16 = 4;
const group_buffer_bytes: u32 = 256;
const bytes = buffers.group_bytes(group_count, group_buffer_bytes);
var backing: [bytes + buffers.group_alignment]u8 align(buffers.group_alignment) = undefined;

pub fn main() !void {
    // "A loop"
    const options: rotor.Loop.Options = .{ .operations = 1024 };
    var memory: [rotor.Loop.memory_bytes(options)]u8 align(rotor.memory_alignment) = undefined;
    var loop: rotor.Loop = undefined;
    try loop.init(&memory, options);
    defer loop.deinit();

    // A connected pair on 127.0.0.1 to receive on, made through the loop.
    var address: rotor.Address = undefined;
    const pair = try connected_pair(&loop, &address);
    defer rotor.sync.close_now(pair.client);
    defer rotor.sync.close_now(pair.server);
    const socket = pair.server;
    var buffer: [64]u8 = undefined;

    // "Submit and tick"
    var handles: [2]rotor.Handle = undefined;
    const taken = loop.submit(&.{
        rotor.Operation.receive(1, socket, &buffer),
        rotor.Operation.timer(2, rotor.constants.ns_per_s, 0),
    }, &handles);
    var events: [64]rotor.Event = undefined;
    const count = try loop.tick(&events, rotor.constants.ns_per_ms);

    // Both were taken. Nothing has been sent, so no event can be the receive's, and the timer has
    // a second to go.
    if (taken != 2) return error.NotTaken;
    for (events[0..count]) |event| if (event.user_data == 1 or event.user_data == 2) return error.TooEarly;

    // The peer sends, and the receive ends with those bytes.
    const greeting = "hello from the guide";
    try submit_one(&loop, rotor.Operation.send(send_data, pair.client, greeting));
    const received = try (try next_event(&loop, 1, &events)).outcome();
    if (!std.mem.eql(u8, greeting, buffer[0..received])) return error.WrongBytes;
    _ = try (try next_event(&loop, send_data, &events)).outcome();

    // The timer is cancelled, and its one final event says so.
    loop.cancel(handles[1]);
    try expect_canceled(try next_event(&loop, 2, &events));

    try receive_into_a_group(&loop, pair, &events);
    if (loop.in_flight() != 0) return error.StillInFlight;
    std.debug.print("guide: every step of docs/using.md ran, on the {t} backend\n", .{rotor.backend()});
}

/// "Buffers": a provided-buffer group whose memory is aligned forward, a multishot receive that lets
/// the kernel pick a buffer, the bytes read from that buffer, the buffer given back, and the
/// receive cancelled.
fn receive_into_a_group(loop: *rotor.Loop, pair: Pair, events: []rotor.Event) !void {
    const start = std.mem.alignForward(usize, @intFromPtr(&backing), buffers.group_alignment);
    const memory: []align(buffers.group_alignment) u8 =
        @as([*]align(buffers.group_alignment) u8, @ptrFromInt(start))[0..bytes];
    try loop.provide_buffers(group_id, memory, group_count, group_buffer_bytes);

    var handle: [1]rotor.Handle = undefined;
    const receive = rotor.Operation.receive_group(receive_group_data, pair.server, group_id);
    if (loop.submit(&.{receive}, &handle) != 1) return error.NotTaken;
    const message = "a buffer the kernel picked";
    try submit_one(loop, rotor.Operation.send(send_data, pair.client, message));
    const delivered = try next_event(loop, receive_group_data, events);
    if (!delivered.flags.buffer or !delivered.flags.more) return error.NotFromTheGroup;
    const got = loop.provided_buffer(group_id, delivered.flags.buffer_id)[0..try delivered.outcome()];
    if (!std.mem.eql(u8, message, got)) return error.WrongBytes;
    loop.give_back_buffer(group_id, delivered.flags.buffer_id);
    _ = try (try next_event(loop, send_data, events)).outcome();

    loop.cancel(handle[0]);
    try expect_canceled(try next_event(loop, receive_group_data, events));
}

fn expect_canceled(event: rotor.Event) !void {
    if (!event.is_final()) return error.NotFinal;
    if (event.outcome()) |_| return error.NotCanceled else |err| if (err != error.Canceled) return err;
}

const Pair = struct { client: rotor.Descriptor, server: rotor.Descriptor };

/// A listener on a free port of 127.0.0.1, a connect to it and the accept, both through the loop.
/// `address` holds where the listener is, and outlives the connect, which reads it.
fn connected_pair(loop: *rotor.Loop, address: *rotor.Address) !Pair {
    const any = rotor.Address.ipv4(.{ 127, 0, 0, 1 }, 0);
    const listener = try rotor.sync.listen(&any, .{ .backlog = 1, .reuse_port = false });
    defer rotor.sync.close_now(listener);
    address.* = try rotor.sync.local_address(listener);
    const client = try rotor.sync.open_socket(.ipv4);
    try submit_one(loop, rotor.Operation.accept(accept_data, listener, false));
    try submit_one(loop, rotor.Operation.connect(connect_data, client, address));
    var events: [64]rotor.Event = undefined;
    const server = try (try next_event(loop, accept_data, &events)).outcome();
    _ = try (try next_event(loop, connect_data, &events)).outcome();
    return .{ .client = client, .server = @intCast(server) };
}

fn submit_one(loop: *rotor.Loop, operation: rotor.Operation) !void {
    if (loop.submit(&.{operation}, &.{}) != 1) return error.NotTaken;
}

/// Events a tick handed over for an operation this program was not waiting on yet.
var early: [16]rotor.Event align(@alignOf(rotor.Event)) = undefined;
var early_count: usize = 0;

/// Ticks until the next event of the operation `user_data` names, and returns it. Events of other
/// operations are kept for their own call.
fn next_event(loop: *rotor.Loop, user_data: u64, events: []rotor.Event) !rotor.Event {
    for (0..ticks_max) |_| {
        if (take_early(user_data)) |event| return event;
        const count = try loop.tick(events, rotor.constants.ns_per_ms);
        for (events[0..count]) |event| {
            if (early_count == early.len) return error.TooManyEvents;
            early[early_count] = event;
            early_count += 1;
        }
    }
    return error.Stuck;
}

/// The oldest kept event of `user_data`, taken out of the list.
fn take_early(user_data: u64) ?rotor.Event {
    for (early[0..early_count], 0..) |event, index| {
        if (event.user_data != user_data) continue;
        std.mem.copyForwards(rotor.Event, early[index .. early_count - 1], early[index + 1 .. early_count]);
        early_count -= 1;
        return event;
    }
    return null;
}
