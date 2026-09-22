//! rotor_echo: a TCP echo server on 127.0.0.1, the rotor side of the echo comparison.
//!
//! Run:  rotor_echo PORT        Stop it by closing every connection, or with SIGTERM.
//!
//! It is written the way that is fastest for rotor, as `bench/alternatives/libxev_echo.zig` is
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
const placement = @import("harness").placement;

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

/// How the server reads (decision 3, and the question `bench/alternatives/README.md` names as the
/// first thing to settle before any 64 KiB claim).
///
///   - `group`: one multishot receive per connection from a provided-buffer group. Every
///     completion takes a whole buffer, and TCP delivers a large message in several pieces, so
///     each piece is echoed with a send of its own.
///   - `accumulate`: a receive into this connection's own buffer, re-armed into what is left
///     until a whole message has arrived, then one send.
///
/// The pair is the experiment. It needs no kernel above decision 2's floor and no record
/// amended: the surface already offers a receive into a buffer the caller names.
const Shape = enum { group, accumulate };
var shape: Shape = .group;

/// The core this server pins to, from `--cpu`, or null to let the scheduler place it.
var cpu: ?usize = null;

/// In `accumulate`, one buffer per connection carved from the same memory the group would use,
/// so the two shapes hold the same bytes in total and the comparison is not of sizing.
var accumulated: [connections_max]u32 = undefined;

/// Connections the accumulate shape can track: the pool divided by a whole message.
fn accumulate_connections() u32 {
    return @intCast(group_bytes / buffer_bytes);
}

fn accumulator_of(descriptor: core.Descriptor) []u8 {
    const index: usize = @intCast(descriptor);
    return group_memory[index * buffer_bytes ..][0..buffer_bytes];
}

/// Loops this server may run, one per thread and one per core: decision 4's `listener_per_core`.
/// Each has its own listener on the shared port, its own ring and its own slice of the pool, and
/// shares nothing with the others but the per-connection arrays, which a descriptor makes
/// private: a descriptor belongs to exactly one loop, because that loop accepted it.
const loops_max = 16;
var loops: u32 = 1;

var loop_memory: [loops_max][
    Loop.memory_bytes(.{
        .operations = operations,
        .entries = entries,
    })
]u8 align(core.layout.memory_alignment) = undefined;

const group_alignment = backend.buffers.group_alignment;

var group_memory: [group_bytes]u8 align(group_alignment) = undefined;

/// The pool one loop gets: the whole of it divided between them, each share a whole number of
/// the group alignment, so a share can hold a group with its bookkeeping in front.
fn pool_of(index: u32) []align(group_alignment) u8 {
    return @alignCast(group_memory[index * share_bytes() ..][0..share_bytes()]);
}

fn share_bytes() usize {
    return (group_bytes / loops) & ~(@as(usize, group_alignment) - 1);
}

/// Buffers one loop's group holds: the largest power of two whose group, bookkeeping included,
/// fits its share of the pool.
fn buffers_of() u16 {
    const per_buffer = buffer_bytes + backend.buffers.ring_bytes(1);
    const fit = @min(share_bytes() / per_buffer, core.constants.buffers_per_group_max);
    const count = std.math.floorPowerOfTwo(u16, @intCast(fit));
    std.debug.assert(backend.buffers.group_bytes(count, buffer_bytes) <= share_bytes());
    return count;
}

pub fn main(init: std.process.Init) !void {
    const port = try parse(init);
    open = @splat(false);
    accumulated = @splat(0);
    group_buffers = buffers_of();

    // One listener per loop, all bound before any of them serves, so a client that connects on
    // the ready line cannot reach a port only half the loops are listening on.
    var listeners: [loops_max]core.Descriptor = undefined;
    const address = core.Address.ipv4(.{ 127, 0, 0, 1 }, port);
    // Registered above the loop and counting with the variable the loop advances, which is
    // `src/conformance/conformance_reuse_port.zig`'s shape. Below the loop this defer was never
    // reached when a `listen` failed part way through, so a third listener refused left the first
    // two open; written against `loops` it would close descriptors nothing opened.
    var opened: u32 = 0;
    defer for (listeners[0..opened]) |listener| sync.close_now(listener);
    while (opened < loops) : (opened += 1) {
        const share = loops > 1;
        listeners[opened] = try sync.listen(&address, .{
            .backlog = backlog,
            .reuse_port = share,
        });
    }

    var threads: [loops_max]std.Thread = undefined;
    var started: u32 = 1;
    while (started < loops) : (started += 1) {
        threads[started] = try std.Thread.spawn(.{}, serve, .{ started, listeners[started] });
    }
    defer for (threads[1..loops]) |thread| thread.join();

    // The first loop is this thread's: rotor starts no thread of its own, and a caller that
    // wants N runs N (decision 4).
    const placed = placement.place(core_of(0));
    try announce(init, port, placed);
    serve(0, listeners[0]);
}

/// The core loop `index` takes: consecutive from `--cpu`, so N loops land on N cores.
fn core_of(index: u32) ?usize {
    return if (cpu) |first| first + index else null;
}

/// One loop, on this thread, until the process ends. Every failure here is a configuration
/// fault rather than a result, so it halts instead of reporting a number that hides it.
fn serve(index: u32, listener: core.Descriptor) void {
    if (index != 0) _ = placement.place(core_of(index));
    var loop: Loop = undefined;
    loop.init(&loop_memory[index], .{ .operations = operations, .entries = entries }) catch
        @panic("the loop refused its memory");
    defer loop.deinit();

    loop.provide_buffers(group_id, pool_of(index), group_buffers, buffer_bytes) catch
        @panic("the buffer group was refused");

    submit_one(&loop, .{
        .user_data = user_data_of(.accept, listener),
        .kind = .{ .accept = .{ .listener = listener, .multishot = true } },
    });

    var events: [events_max]Event = undefined;
    while (true) {
        const count = loop.tick(&events, core.constants.ns_per_s) catch @panic("the tick failed");
        for (events[0..count]) |event| handle(&loop, event);
    }
}

/// The line the harness waits for before it connects, as it does for the alternatives'.
fn announce(init: std.process.Init, port: u16, placed: placement.Placement) !void {
    var out_buffer: [160]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buffer);
    try out.interface.print(
        "rotor_echo: rotor {s}, {d} loops, {d} buffers of {d} bytes each, {t}, {t}, " ++
            "listening on 127.0.0.1:{d}\n",
        .{ @tagName(builtin.os.tag), loops, group_buffers, buffer_bytes, shape, placed, port },
    );
    try out.interface.flush();
}

/// Reads the port and `--buffer-bytes`, which sets how many buffers the group holds.
fn parse(init: std.process.Init) !u16 {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len < 2) return error.MissingPort;
    const port = try std.fmt.parseInt(u16, arguments[1], 10);
    var index: usize = 2;
    while (index < arguments.len) : (index += 2) {
        if (index + 1 >= arguments.len) return error.MissingValue;
        try apply(arguments[index], arguments[index + 1]);
    }
    return port;
}

/// One `--name value` pair. Split from `parse` so each stays inside the complexity limit.
fn apply(name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, "--cpu")) {
        cpu = try std.fmt.parseInt(usize, value, 10);
    } else if (std.mem.eql(u8, name, "--shape")) {
        shape = std.meta.stringToEnum(Shape, value) orelse return error.UnknownShape;
    } else if (std.mem.eql(u8, name, "--loops")) {
        loops = try std.fmt.parseInt(u32, value, 10);
        if (loops == 0 or loops > loops_max) return error.LoopsOutOfRange;
    } else if (std.mem.eql(u8, name, "--buffer-bytes")) {
        try set_buffer_bytes(try std.fmt.parseInt(u32, value, 10));
    } else {
        return error.UnknownArgument;
    }
}

/// The group's buffers are cut from fixed memory, so a larger buffer means fewer of them.
fn set_buffer_bytes(wanted: u32) !void {
    if (wanted < buffer_bytes_min or wanted > buffer_bytes_max) return error.BufferOutOfRange;
    if (!std.math.isPowerOfTwo(wanted)) return error.BufferNotPowerOfTwo;
    buffer_bytes = wanted;
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
    // The accumulate shape gives each connection a whole message of the pool, so it tracks
    // fewer of them than the group shape does.
    if (shape == .accumulate and descriptor >= accumulate_connections()) {
        return sync.close_now(descriptor);
    }
    // Nagle off, because every other candidate of the comparison turns it off and a row that
    // does not match is measuring the socket option and not the loop. A connection this fails
    // on is refused rather than served, so a run cannot quietly mix the two shapes.
    sync.set_no_delay(descriptor, true) catch return sync.close_now(descriptor);
    open[@intCast(descriptor)] = true;
    arm_receive(loop, descriptor);
}

/// One multishot receive for this connection, which serves it until it ends or the group empties.
fn arm_receive(loop: *Loop, descriptor: core.Descriptor) void {
    if (shape == .accumulate) return arm_accumulating_receive(loop, descriptor);
    submit_one(loop, .{
        .user_data = user_data_of(.receive, descriptor),
        .kind = .{ .receive = .{
            .socket = descriptor,
            .target = .{ .group = group_id },
            .multishot = true,
        } },
    });
}

/// One receive into what is left of this connection's buffer. Single-shot: the next one is armed
/// when this completes, because where it lands depends on how much arrived.
fn arm_accumulating_receive(loop: *Loop, descriptor: core.Descriptor) void {
    const have = accumulated[@intCast(descriptor)];
    std.debug.assert(have < buffer_bytes);
    submit_one(loop, .{
        .user_data = user_data_of(.receive, descriptor),
        .kind = .{ .receive = .{
            .socket = descriptor,
            .target = .{ .buffer = .{ .bytes = accumulator_of(descriptor)[have..] } },
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
    if (shape == .accumulate) return accumulate_received(loop, descriptor, received);
    sending[@intCast(descriptor)] = .{
        .buffer_id = event.flags.buffer_id,
        .sent = 0,
        .len = received,
    };
    send_rest(loop, descriptor);
}

/// Bytes arrived into this connection's own buffer. A whole message is echoed with one send;
/// anything short arms another receive into what is left, which is the point of the shape.
fn accumulate_received(loop: *Loop, descriptor: core.Descriptor, received: u32) void {
    const have = &accumulated[@intCast(descriptor)];
    have.* += received;
    std.debug.assert(have.* <= buffer_bytes);
    if (have.* < buffer_bytes) return arm_accumulating_receive(loop, descriptor);
    sending[@intCast(descriptor)] = .{ .buffer_id = 0, .sent = 0, .len = have.* };
    have.* = 0;
    send_rest(loop, descriptor);
}

/// Submits what is left of this descriptor's echo.
fn send_rest(loop: *Loop, descriptor: core.Descriptor) void {
    const state = &sending[@intCast(descriptor)];
    const buffer = if (shape == .accumulate)
        accumulator_of(descriptor)
    else
        loop.provided_buffer(group_id, state.buffer_id);
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
        release(loop, state.buffer_id);
        return close(loop, descriptor);
    };
    state.sent += sent;
    if (state.sent < state.len) return send_rest(loop, descriptor);
    release(loop, state.buffer_id);
    // The accumulate shape reads again itself: its receive is single-shot, so nothing is armed
    // for this connection until the echo is out.
    if (shape == .accumulate) arm_receive(loop, descriptor);
}

/// Gives a provided buffer back, which the accumulate shape has none of: its buffer is the
/// connection's own and belongs to no group.
fn release(loop: *Loop, buffer_id: u16) void {
    if (shape == .accumulate) return;
    loop.give_back_buffer(group_id, buffer_id);
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
