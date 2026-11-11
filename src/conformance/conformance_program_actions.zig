//! The actions of the seeded library program (`conformance_program.zig`), and the check of each
//! operation's result against its cause. Where the program can force a result, the check asks for
//! that result. Where a real kernel races, for example a deadline against a transfer or a cancel
//! against a timer, the check accepts either outcome.
const std = @import("std");
const core = @import("core");
const reactor_module = @import("reactor");
const program_module = @import("conformance_program.zig");
const ledger_module = @import("conformance_program_ledger.zig");

const Event = core.Event;
const Operation = core.Operation;
const Program = program_module.Program;
const Entry = ledger_module.Entry;
const Kind = ledger_module.Kind;

const us = core.constants.ns_per_us;
const ms = core.constants.ns_per_ms;

/// The buffers of the provided-buffer group of the datagram receive.
pub const group_buffers = 32;
pub const buffer_bytes = 2048;

/// The tag of every message the program posts.
const post_tag = 5;
/// The id of the loop that echoes the program's messages.
pub const peer_id = 1;

/// The most datagrams and the most posts in one run of a seed.
pub const ids_max = 1024;
/// The most messages posted that have not come back. It keeps both mailboxes far from full, so a
/// post must succeed.
const posts_outstanding_max = 64;
/// The most datagram sends in flight, and the most that one action submits. A burst leaves
/// datagrams in the socket for several reaps, so epoll's reap takes them in a batch (decision 20).
const datagram_sends_max = 16;
const datagram_burst_max = 8;

/// The largest send and the largest receive on the TCP connection.
const stream_bytes_max = 512;
/// The most bytes sent and not yet received. The socket buffers hold that much, so a send
/// completes.
const unread_bytes_max = 8 * 1024;

const timer_after_ns_max = 2 * ms;
const timer_repeat_ns_min = 200 * us;
const timer_repeat_ns_max = ms;
const deadline_ns_min = 100 * us;
const deadline_ns_max = 2 * ms;

/// The waits a tick draws from, and the wait of a tick that must not block.
const waits_ns = [_]u64{ 0, 100 * us, ms, 2 * ms };
pub const long_wait_ns = 2 * core.constants.ns_per_s;
/// The room for events that a tick draws: from 1 to `events_small_max`, or all of `events_max`.
/// epoll takes datagrams in a batch only when the room holds two coalesced datagrams.
pub const events_max = 2 * core.constants.coalesced_segments_max;
const events_small_max = 16;

/// The byte at `offset` of the TCP stream, so a receive checks that its bytes continue the stream.
fn stream_byte(offset: u64) u8 {
    return @intCast(offset % 251);
}

/// One TCP connection over loopback: one send and one receive in flight at most.
pub const Stream = struct {
    client: core.Descriptor,
    server: core.Descriptor,
    sent: u64 = 0,
    received: u64 = 0,
    send_entry: ?*Entry = null,
    receive_entry: ?*Entry = null,
    send_buffer: [stream_bytes_max]u8 = @splat(0),
    receive_buffer: [stream_bytes_max]u8 = @splat(0),

    /// The bytes sent and not yet received. A send that ended at the flush waits on the finished
    /// list, and since W3 the receive of its bytes can reach the caller first (decision 11, point
    /// 4, amended 2026-11-07). The send is then still in flight, and none of its bytes is unread.
    fn unread(stream: *const Stream) u64 {
        return stream.sent -| stream.received;
    }
};

/// A datagram receiver and sender over loopback, and the ids each side saw.
pub const Datagrams = struct {
    /// The provided-buffer group of the datagram receive, which the program reserved.
    group: core.BufferGroup,
    receiver: core.Descriptor,
    sender: core.Descriptor,
    out: core.datagram.Outbound,
    next_id: u64 = 0,
    sends_in_flight: u32 = 0,
    receive_entry: ?*Entry = null,
    sent: std.StaticBitSet(ids_max) = .initEmpty(),
    received: std.StaticBitSet(ids_max) = .initEmpty(),
};

/// The messages the program posts to the peer loop, which posts each one back.
pub const Posts = struct {
    next_id: u64 = 0,
    outstanding: u32 = 0,
    posted: std.StaticBitSet(ids_max) = .initEmpty(),
    returned: std.StaticBitSet(ids_max) = .initEmpty(),
};

/// A library's poller. It may queue a task, and may say that work is left.
pub const Library = struct {
    poller: reactor_module.Poller = .init(Library, "poller", polled),
    program: *Program,
    added: bool = false,
    polls: u32 = 0,

    fn polled(library: *Library) core.WaitLimit {
        const program = library.program;
        library.polls += 1;
        if (program.stopping) return .none;
        if (program.random.chance(1, 3)) program.jobs.schedule_any(program, .poller) catch |err| program.fail(err);
        return if (program.random.chance(1, 4)) .now else .none;
    }
};

pub const Action = enum {
    timer,
    tcp_receive,
    tcp_send,
    udp_receive,
    udp_send,
    post_operation,
    post_now,
    cancel,
    poller,
    schedule,
    discard,
    tick,
};

/// The weight of each action, in the order of `Action`.
const weights = [_]u8{ 4, 2, 2, 1, 2, 1, 1, 2, 1, 2, 1, 7 };

comptime {
    std.debug.assert(weights.len == @typeInfo(Action).@"enum".fields.len);
}

pub fn draw(random: *core.random.Random) Action {
    comptime var total: u64 = 0;
    inline for (weights) |weight| total += weight;
    var left = random.below(total);
    for (weights, 0..) |weight, index| {
        if (left < weight) return @enumFromInt(index);
        left -= weight;
    }
    unreachable;
}

pub fn perform(program: *Program, action: Action) !void {
    switch (action) {
        .timer => try submit_timer(program),
        .tcp_receive => try submit_tcp_receive(program),
        .tcp_send => try submit_tcp_send(program),
        .udp_receive => try submit_udp_receive(program),
        .udp_send => try submit_udp_burst(program),
        .post_operation => try submit_post(program),
        .post_now => try post_now(program),
        .cancel => cancel(program),
        .poller => try toggle_poller(program),
        .schedule => try program.jobs.schedule_any(program, .program),
        .discard => if (program.random.chance(1, 4)) try program.jobs.discard(program),
        .tick => try program.tick(),
    }
}

/// Submits `operation` for `entry`, with a record on two draws in three.
fn submit(program: *Program, entry: *Entry, operation: Operation, kind: Kind) !void {
    entry.kind = kind;
    entry.cancel_requested = false;
    entry.record = program.random.chance(2, 3);
    const named = if (entry.record) reactor_module.Completion.mark(&entry.completion, operation) else with_user_data(operation, entry);
    var handles: [1]core.Handle = undefined;
    if (program.main.reactor.submit(&.{named}, &handles) != 1) return error.SubmitRefused;
    program.ledger.started(entry, handles[0]);
}

fn with_user_data(operation: Operation, entry: *const Entry) Operation {
    var plain = operation;
    plain.user_data = entry.user_data();
    return plain;
}

fn submit_timer(program: *Program) !void {
    const entry = program.ledger.claim(&program.random) orelse return;
    const after_ns = program.random.below(timer_after_ns_max);
    if (program.random.chance(1, 4)) {
        const repeat_ns = program.random.between(timer_repeat_ns_min, timer_repeat_ns_max);
        return submit(program, entry, Operation.timer(0, after_ns, repeat_ns), .timer_repeat);
    }
    try submit(program, entry, Operation.timer(0, after_ns, 0), .timer);
}

fn submit_tcp_receive(program: *Program) !void {
    const stream = &program.stream;
    if (stream.receive_entry != null) return;
    const entry = program.ledger.claim(&program.random) orelse return;
    entry.bytes = @intCast(program.random.between(1, stream_bytes_max));
    var operation = Operation.receive(0, stream.server, stream.receive_buffer[0..entry.bytes]);
    entry.timeout_set = program.random.chance(1, 3);
    if (entry.timeout_set) operation.timeout_ns = program.random.between(deadline_ns_min, deadline_ns_max);
    // No byte can arrive before the deadline when none is unread and no send is in flight.
    entry.timeout_forced = entry.timeout_set and stream.unread() == 0 and stream.send_entry == null;
    try submit(program, entry, operation, .tcp_receive);
    stream.receive_entry = entry;
}

fn submit_tcp_send(program: *Program) !void {
    const stream = &program.stream;
    if (stream.send_entry != null) return;
    if (stream.unread() + stream_bytes_max > unread_bytes_max) return;
    const entry = program.ledger.claim(&program.random) orelse return;
    entry.bytes = @intCast(program.random.between(1, stream_bytes_max));
    for (stream.send_buffer[0..entry.bytes], 0..) |*byte, offset| byte.* = stream_byte(stream.sent + offset);
    entry.timeout_set = false;
    try submit(program, entry, Operation.send(0, stream.client, stream.send_buffer[0..entry.bytes]), .tcp_send);
    stream.send_entry = entry;
    // Bytes may now reach the receive in flight, so its deadline no longer must win.
    if (stream.receive_entry) |receive| receive.timeout_forced = false;
}

fn submit_udp_receive(program: *Program) !void {
    const datagrams = &program.datagrams;
    if (datagrams.receive_entry != null) return;
    const entry = program.ledger.claim(&program.random) orelse return;
    entry.timeout_set = false;
    try submit(program, entry, Operation.receive_from(0, datagrams.receiver, datagrams.group), .udp_receive);
    datagrams.receive_entry = entry;
}

/// A burst of datagram sends, each an operation of its own.
fn submit_udp_burst(program: *Program) !void {
    const burst = program.random.between(1, datagram_burst_max);
    for (0..burst) |_| try submit_udp_send(program);
}

fn submit_udp_send(program: *Program) !void {
    const datagrams = &program.datagrams;
    if (datagrams.sends_in_flight == datagram_sends_max or datagrams.next_id == ids_max) return;
    const entry = program.ledger.claim(&program.random) orelse return;
    entry.id = datagrams.next_id;
    entry.timeout_set = false;
    std.mem.writeInt(u64, &entry.payload, entry.id, .little);
    try submit(program, entry, Operation.send_to(0, datagrams.sender, &entry.payload, &datagrams.out), .udp_send);
    datagrams.next_id += 1;
    datagrams.sends_in_flight += 1;
}

fn submit_post(program: *Program) !void {
    const posts = &program.posts;
    if (posts.outstanding == posts_outstanding_max or posts.next_id == ids_max) return;
    const entry = program.ledger.claim(&program.random) orelse return;
    entry.id = posts.next_id;
    entry.timeout_set = false;
    const message: core.Message = .{ .payload = entry.id, .tag = post_tag };
    try submit(program, entry, Operation.post(0, peer_id, message), .post);
    posts.next_id += 1;
    posts.outstanding += 1;
}

/// `Loop.post`, which takes no slot and makes no event.
fn post_now(program: *Program) !void {
    const posts = &program.posts;
    if (posts.outstanding == posts_outstanding_max or posts.next_id == ids_max) return;
    try program.main.reactor.post(peer_id, .{ .payload = posts.next_id, .tag = post_tag });
    posts.posted.set(posts.next_id);
    posts.next_id += 1;
    posts.outstanding += 1;
}

fn cancel(program: *Program) void {
    const entry = program.ledger.pick_in_flight(&program.random) orelse return;
    entry.cancel_requested = true;
    program.main.reactor.cancel(entry.handle);
}

fn toggle_poller(program: *Program) !void {
    const library = &program.libraries[program.random.below(program.libraries.len)];
    if (library.added) {
        program.main.reactor.remove_poller(&library.poller);
    } else {
        try program.main.reactor.add_poller(&library.poller);
    }
    library.added = !library.added;
}

/// The wait of the next tick. A tick with a task queued draws a long wait on one draw in two, and
/// must not take it.
pub fn draw_wait(program: *Program) u64 {
    if (program.jobs.queued != 0 and program.random.chance(1, 2)) return long_wait_ns;
    return waits_ns[program.random.below(waits_ns.len)];
}

/// The room for events of the next tick.
pub fn draw_room(program: *Program) u32 {
    if (program.random.chance(1, 2)) return events_max;
    return @intCast(program.random.between(1, events_small_max));
}

/// What a record does after its event, as a library would: queue a task, or submit a timer.
pub fn after_record(program: *Program) void {
    if (program.stopping) return;
    if (program.random.chance(1, 4)) program.jobs.schedule_any(program, .record) catch |err| program.fail(err);
    if (program.random.chance(1, 8)) submit_timer(program) catch |err| program.fail(err);
}

/// What a task does after it runs: queue another task now and then, itself included.
pub fn after_task(program: *Program) void {
    if (program.stopping) return;
    if (program.random.chance(1, 3)) program.jobs.schedule_any(program, .task) catch |err| program.fail(err);
}

/// A `more` event: a fire of a repeating timer, or a datagram.
pub fn on_more(program: *Program, entry: *Entry, event: Event) !void {
    if (entry.kind == .udp_receive) return on_datagram(program, event);
    if (event.result != 0) return error.RepeatFireNotZero;
}

fn on_datagram(program: *Program, event: Event) !void {
    if (!event.flags.buffer) return error.DatagramWithoutBuffer;
    const datagrams = &program.datagrams;
    defer program.main.reactor.give_back_buffer(datagrams.group, event.flags.buffer_id);
    const delivery = program.main.reactor.datagram(datagrams.group, event);
    if (delivery.bytes.len != @sizeOf(u64)) return error.DatagramLengthWrong;
    const id = std.mem.readInt(u64, delivery.bytes[0..@sizeOf(u64)], .little);
    if (id >= datagrams.next_id) return error.DatagramNeverSent;
    if (datagrams.received.isSet(id)) return error.DatagramReceivedTwice;
    datagrams.received.set(id);
}

/// The outcome of a final event that an asked cancel or a deadline may explain.
fn allowed_failure(entry: *const Entry, err: core.Error) !void {
    switch (err) {
        error.Canceled => if (!entry.cancel_requested) return error.CanceledWithoutCancel,
        error.Timeout => if (!entry.timeout_set) return error.TimeoutWithoutDeadline,
        else => return err,
    }
}

pub fn on_final(program: *Program, entry: *Entry, event: Event) !void {
    switch (entry.kind) {
        .timer, .timer_repeat => {
            const result = event.outcome() catch |err| return allowed_failure(entry, err);
            if (result != 0) return error.TimerResultNotZero;
            // A repeating timer ends only at a cancel.
            if (entry.kind == .timer_repeat and !entry.cancel_requested) return error.RepeatEndedAlone;
        },
        .tcp_receive => try on_tcp_receive(program, entry, event),
        .tcp_send => try on_tcp_send(program, entry, event),
        .udp_receive => try on_udp_receive_end(program, entry, event),
        .udp_send => try on_udp_send(program, entry, event),
        .post => try on_post(program, entry, event),
    }
}

fn on_tcp_receive(program: *Program, entry: *Entry, event: Event) !void {
    const stream = &program.stream;
    stream.receive_entry = null;
    const result = event.outcome() catch |err| return allowed_failure(entry, err);
    if (result == 0) return error.StreamEndedEarly;
    if (result > entry.bytes) return error.ReceiveOverran;
    if (entry.timeout_forced) return error.DeadlineDidNotWin;
    for (stream.receive_buffer[0..result], 0..) |byte, offset| {
        if (byte != stream_byte(stream.received + offset)) return error.StreamBytesWrong;
    }
    stream.received += result;
}

fn on_tcp_send(program: *Program, entry: *Entry, event: Event) !void {
    const stream = &program.stream;
    stream.send_entry = null;
    const result = event.outcome() catch |err| return allowed_failure(entry, err);
    if (result == 0 or result > entry.bytes) return error.SendCountWrong;
    stream.sent += result;
}

fn on_udp_receive_end(program: *Program, entry: *Entry, event: Event) !void {
    program.datagrams.receive_entry = null;
    if (event.flags.buffer) return on_datagram(program, event);
    _ = event.outcome() catch |err| switch (err) {
        // The group ran out of buffers between two ticks: the receive ends, and the datagrams stay
        // in the socket for the next receive.
        error.BuffersExhausted => return,
        else => return allowed_failure(entry, err),
    };
    return error.ReceiveEndedAlone;
}

fn on_udp_send(program: *Program, entry: *Entry, event: Event) !void {
    program.datagrams.sends_in_flight -= 1;
    const result = event.outcome() catch |err| return allowed_failure(entry, err);
    if (result != @sizeOf(u64)) return error.DatagramSendShort;
    program.datagrams.sent.set(entry.id);
}

fn on_post(program: *Program, entry: *Entry, event: Event) !void {
    const result = event.outcome() catch |err| {
        // A cancel that won took the message back, so it never comes home.
        program.posts.outstanding -= 1;
        return allowed_failure(entry, err);
    };
    if (result != 0) return error.PostResultNotZero;
    program.posts.posted.set(entry.id);
}

/// An entry whose final event `drain` discarded. Its outcome is not known, so a datagram or a
/// message it may have sent counts as sent.
pub fn on_drained(program: *Program, entry: *Entry) void {
    switch (entry.kind) {
        .tcp_receive => program.stream.receive_entry = null,
        .tcp_send => program.stream.send_entry = null,
        .udp_receive => program.datagrams.receive_entry = null,
        .udp_send => {
            program.datagrams.sends_in_flight -= 1;
            program.datagrams.sent.set(entry.id);
        },
        .post => program.posts.posted.set(entry.id),
        .timer, .timer_repeat => {},
    }
}

/// A message the peer loop posted back. It reaches the caller of `tick`, never a record.
pub fn on_message(program: *Program, event: Event) !void {
    if (event.flags.dispatched) return error.MessageDispatched;
    if (event.result != post_tag) return error.MessageTagWrong;
    const posts = &program.posts;
    const id = event.user_data;
    if (id >= posts.next_id) return error.MessageNeverPosted;
    if (posts.returned.isSet(id)) return error.MessageReturnedTwice;
    posts.returned.set(id);
    posts.outstanding -= 1;
}

/// The peer loop: it takes the program's messages and posts each one back.
pub fn tick_peer(program: *Program) !void {
    var events: [events_max]Event = undefined;
    const count = try program.peer.reactor.tick(&events, 0);
    for (events[0..count]) |event| {
        if (!event.flags.message or event.result != post_tag) return error.PeerGotOtherEvent;
        try program.peer.reactor.post(0, .{ .payload = event.user_data, .tag = post_tag });
    }
}

/// The checks at the end of a seed, once the loop is empty.
pub fn check_end(program: *Program) !void {
    const datagrams = &program.datagrams;
    // A datagram that arrived was sent: a send that a cancel ended moved no byte.
    var received = datagrams.received.iterator(.{});
    while (received.next()) |id| {
        if (!datagrams.sent.isSet(id)) return error.DatagramOfAFailedSend;
    }
    var returned = program.posts.returned.iterator(.{});
    while (returned.next()) |id| {
        if (!program.posts.posted.isSet(id)) return error.MessageOfAFailedPost;
    }
}
