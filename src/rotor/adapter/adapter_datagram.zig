//! Datagram receive (decision 22, step 3, by Camilo's choice of 2026-11-05): a standing receive
//! for each socket.
//!
//! rotor's `receive_from` is always multishot and reads into a provided buffer group (decision 15),
//! and std's `net_receive` takes the datagrams there are when it is called. So the first receive on
//! a socket starts one `receive_from` that stays in flight. Each datagram it hands over waits, in
//! its group buffer, on the socket's queue, until a receive copies it into the caller's buffer and
//! gives the buffer back. Nothing is lost while the queue has room. A datagram that finds the queue
//! full goes back to its group unread, as a kernel drops one that a full socket buffer cannot hold.
//!
//! The receive ends when the socket closes: `netClose` cancels it, waits for its final event, closes
//! the socket, and frees the socket's entry. A receive that fails, for
//! example when the group has no free buffer, reports its error to the next call, and the call
//! after that starts a new receive.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const net = std.Io.net;
const rotor = @import("../rotor.zig");
const constants = @import("constants.zig");
const adapter_module = @import("adapter.zig");
const scheduler = @import("adapter_scheduler.zig");
const wait = @import("adapter_wait.zig");
const network = @import("adapter_net.zig");
const Adapter = adapter_module.Adapter;

pub const State = enum(u8) {
    free,
    /// The standing receive is in flight.
    armed,
    /// The standing receive had its final event. The next call starts another.
    ended,
};

/// One socket's entry. 48 bytes beside its queue, aligned to 8.
pub const Socket = struct {
    /// The events whose datagrams wait for a call, from `head`, `queued` of them.
    queue: []rotor.Event,
    handle: rotor.Handle,
    socket: rotor.Descriptor,
    /// Moves at every event, so a call that waits sees that one came.
    epoch: u32,
    /// The negative result of a final event no call has reported yet, or 0.
    failure: i32,
    /// Datagrams that found the queue full.
    dropped: u32,
    head: u16,
    queued: u16,
    state: State,
    /// `netClose` ended the standing receive. No call starts another, and each returns
    /// `SocketUnconnected`.
    closing: bool,

    comptime {
        assert(@sizeOf(Socket) == 48);
        assert(@alignOf(Socket) == 8);
    }
};

/// The bytes the table and its queues take, aligned to 8.
pub fn table_bytes(sockets: u16, queue: u16) usize {
    return @as(usize, sockets) * (@sizeOf(Socket) + @as(usize, queue) * @sizeOf(rotor.Event));
}

/// The table, from `memory`, every entry free.
pub fn carve(memory: []u8, options: adapter_module.Options) []Socket {
    assert(memory.len == table_bytes(options.datagram_sockets, options.datagram_queue));
    const entries_end = @as(usize, options.datagram_sockets) * @sizeOf(Socket);
    const entries: []Socket = @ptrCast(@alignCast(memory[0..entries_end]));
    const queues: []rotor.Event = @ptrCast(@alignCast(memory[entries_end..]));
    for (entries, 0..) |*entry, index| {
        entry.* = .{
            .queue = queues[index * options.datagram_queue ..][0..options.datagram_queue],
            .handle = .none,
            .socket = -1,
            .epoch = 0,
            .failure = 0,
            .dropped = 0,
            .head = 0,
            .queued = 0,
            .state = .free,
            .closing = false,
        };
    }
    return entries;
}

fn find(adapter: *Adapter, socket: rotor.Descriptor) ?u16 {
    for (adapter.datagrams, 0..) |entry, index| {
        if (entry.state != .free and entry.socket == socket) return @intCast(index);
    }
    return null;
}

fn claim(adapter: *Adapter, socket: rotor.Descriptor) ?u16 {
    for (adapter.datagrams, 0..) |*entry, index| {
        if (entry.state != .free) continue;
        entry.socket = socket;
        entry.state = .ended;
        return @intCast(index);
    }
    return null;
}

/// Starts the socket's standing receive.
fn arm(adapter: *Adapter, index: u16) void {
    const entry = &adapter.datagrams[index];
    assert(entry.state == .ended);
    entry.handle = scheduler.submit_detached(adapter, .{
        .user_data = constants.user_data_tag | scheduler.datagram_bit | index,
        .kind = .{ .receive_from = .{ .socket = entry.socket, .group = adapter.datagram_group.? } },
    });
    entry.state = .armed;
}

/// An event of the standing receive of entry `index`, from the tick.
pub fn deliver(adapter: *Adapter, index: u16, event: rotor.Event) void {
    const entry = &adapter.datagrams[index];
    assert(entry.state == .armed);
    if (event.flags.buffer) {
        assert(event.result >= 0);
        queue_or_drop(adapter, entry, event);
    } else if (event.result < 0 and event.result != scheduler.canceled_result) {
        entry.failure = event.result;
    }
    if (!event.flags.more) {
        entry.state = .ended;
        entry.handle = .none;
    }
    entry.epoch +%= 1;
    adapter.datagram_epoch +%= 1;
    wait.futex_wake(adapter, &entry.epoch, std.math.maxInt(u32));
    wait.futex_wake(adapter, &adapter.datagram_epoch, std.math.maxInt(u32));
}

fn queue_or_drop(adapter: *Adapter, entry: *Socket, event: rotor.Event) void {
    if (entry.queued == entry.queue.len) {
        adapter.loop.give_back_buffer(adapter.datagram_group.?, event.flags.buffer_id);
        entry.dropped +%= 1;
        return;
    }
    entry.queue[(@as(usize, entry.head) + entry.queued) % entry.queue.len] = event;
    entry.queued += 1;
}

/// Copies the queued datagrams into `receive`'s messages, as many as fit, and gives their buffers
/// back. A datagram longer than the room left is cut and marked `trunc` when it is the first, and
/// left for the next call otherwise.
fn take(adapter: *Adapter, entry: *Socket, operation: Io.Operation.NetReceive) usize {
    const group = adapter.datagram_group.?;
    var used: usize = 0;
    var count: usize = 0;
    while (count < operation.message_buffer.len and entry.queued != 0) : (count += 1) {
        const event = entry.queue[entry.head];
        const delivery = adapter.loop.datagram(group, event);
        const room = operation.data_buffer.len - used;
        if (delivery.bytes.len > room and count != 0) break;
        const length = @min(delivery.bytes.len, room);
        const data = operation.data_buffer[used..][0..length];
        @memcpy(data, delivery.bytes[0..length]);
        const message = &operation.message_buffer[count];
        message.from = network.from_rotor(delivery.from.peer);
        message.data = data;
        message.control = message.control[0..0];
        message.flags = .{
            .eor = false,
            .trunc = delivery.from.flags.truncated or length < delivery.bytes.len,
            .ctrunc = false,
            .oob = false,
            .errqueue = false,
        };
        adapter.loop.give_back_buffer(group, event.flags.buffer_id);
        entry.head = @intCast((@as(usize, entry.head) + 1) % entry.queue.len);
        entry.queued -= 1;
        used += length;
    }
    return count;
}

const ReceiveResult = Io.Operation.NetReceive.Result;

/// What a receive gets now, or null when it must wait: the queued datagrams, else the failure no
/// call has reported. Starts the standing receive when none is in flight.
pub fn try_receive(adapter: *Adapter, operation: Io.Operation.NetReceive) ?ReceiveResult {
    assert(adapter.datagram_group != null);
    const index = find(adapter, operation.socket_handle) orelse
        claim(adapter, operation.socket_handle) orelse
        return .{ error.SystemResources, 0 };
    const entry = &adapter.datagrams[index];
    if (entry.closing) return .{ error.SocketUnconnected, 0 };
    if (entry.queued != 0) return .{ null, take(adapter, entry, operation) };
    if (entry.failure != 0) {
        const failure = entry.failure;
        entry.failure = 0;
        return .{ receive_error(failure), 0 };
    }
    if (entry.state == .ended) arm(adapter, index);
    return null;
}

/// `operate`'s `net_receive`: waits until a datagram or a failure comes, a cancel point.
///
/// Each round waits for an event of the socket. An event that leaves nothing to take and no failure
/// ends a receive that nobody canceled, and the next round starts another. More such rounds in a row
/// than `constants.datagram_queue_max` mean the receive cannot start, and the call reports it.
pub fn receive(adapter: *Adapter, operation: Io.Operation.NetReceive) Io.Cancelable!ReceiveResult {
    var round: u32 = 0;
    while (round <= constants.datagram_queue_max) : (round += 1) {
        if (try_receive(adapter, operation)) |result| return result;
        const entry = &adapter.datagrams[find(adapter, operation.socket_handle).?];
        // A wait ends at an event of the socket. When another task closes the socket, that event is
        // the end of the standing receive, while the entry is still closing, so the next round's
        // `try_receive` returns `SocketUnconnected` before `release` frees the entry.
        try wait.futex_wait(adapter, &entry.epoch, entry.epoch, .none);
    }
    return .{ error.SystemResources, 0 };
}

/// Ends the standing receive of `socket` before its close, and waits for its final event. The
/// close does not wait for it on every backend: kqueue handed the close's event over first.
pub fn stop(adapter: *Adapter, socket: rotor.Descriptor) void {
    const index = find(adapter, socket) orelse return;
    const entry = &adapter.datagrams[index];
    entry.closing = true;
    if (entry.state == .armed) adapter.loop.cancel(entry.handle);
    while (entry.state == .armed) wait.futex_wait_uncancelable(adapter, &entry.epoch, entry.epoch);
}

/// Frees the entry of `socket`, after `stop` and its close. A call that
/// waits on it finds no entry, and returns `SocketUnconnected`.
pub fn release(adapter: *Adapter, socket: rotor.Descriptor) void {
    const index = find(adapter, socket) orelse return;
    const entry = &adapter.datagrams[index];
    assert(entry.state == .ended);
    assert(entry.closing);
    while (entry.queued != 0) : (entry.queued -= 1) {
        adapter.loop.give_back_buffer(adapter.datagram_group.?, entry.queue[entry.head].flags.buffer_id);
        entry.head = @intCast((@as(usize, entry.head) + 1) % entry.queue.len);
    }
    entry.state = .free;
    entry.closing = false;
    entry.head = 0;
    entry.failure = 0;
    entry.epoch +%= 1;
    wait.futex_wake(adapter, &entry.epoch, std.math.maxInt(u32));
}

fn receive_error(result: i32) net.Socket.ReceiveError {
    assert(result < 0);
    const code: rotor.Code = @enumFromInt(@as(u8, @intCast(-result)));
    return switch (code) {
        .system_resources, .buffers_exhausted => error.SystemResources,
        .descriptor_limit => error.ProcessFdQuotaExceeded,
        .connection_refused => error.PortUnreachable,
        .connection_reset => error.ConnectionResetByPeer,
        .not_connected => error.SocketUnconnected,
        .message_too_long => error.MessageOversize,
        .network_unreachable => error.NetworkDown,
        else => error.Unexpected,
    };
}
