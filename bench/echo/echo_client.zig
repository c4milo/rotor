//! echo_client: the load generator of the echo workload, and the only thing that measures it.
//!
//! Run:  echo_client PORT [--connections N] [--payload BYTES] [--seconds S] [--warmup S]
//!                        [--candidate NAME] [--version TEXT]
//!
//! It opens `connections` sockets to 127.0.0.1:PORT and keeps one message in flight on each: send
//! the payload, read it back whole, record the round trip, send again. It reports the throughput
//! of the measured span and the p50, p99 and p999 of the round trips, through `bench/harness`.
//!
//! One client serves every candidate, so a comparison is made with one instrument. That is the
//! point of it being its own program: `rotor_echo`, `libuv_echo` and `libxev_echo` are told apart
//! by nothing but the `--candidate` name printed in the row.
//!
//! The client is written on rotor. Two consequences, and the first is why that is allowed:
//!
//! - **A comparison stays fair**, because the same client cost is on both sides of every row.
//! - **An absolute number is not the server's alone.** It holds the client's send and receive as
//!   well, so a row here is a comparison and never a figure for what rotor's loop costs. The
//!   cost probes of `bench/costs` are where that figure comes from.
//!
//! A warm-up span runs first and is thrown away: the first messages of a connection pay for the
//! kernel's buffers growing and for pages this process has not touched.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const backend = @import("backend");
const harness = @import("harness");

const Loop = backend.Loop;
const Event = core.Event;
const Histogram = harness.histogram.Histogram;
const Operation = core.Operation;
const Result = harness.report.Result;
const Run = harness.report.Run;
const sync = backend.sync;

/// Connections this client opens at most.
const connections_max = 512;

/// The largest payload, which is the 64 KiB the harness names.
const payload_bytes_max = 64 * 1024;

/// Slots: a connect, a send and a receive in flight per connection, with room to spare.
const operations = 4 * connections_max + 64;
const entries = 4096;
const events_max = 1024;

const Defaults = struct {
    const connections: u32 = 64;
    const payload_bytes: u32 = 4096;
    const seconds: u64 = 5;
    const warmup_seconds: u64 = 1;
};

/// What a completion's `user_data` says: the kind in the high half, the connection in the low.
const Kind = enum(u32) { connect, send, receive };
const kind_shift = 32;

fn user_data_of(kind: Kind, index: u32) u64 {
    return (@as(u64, @intFromEnum(kind)) << kind_shift) | index;
}

fn kind_of(user_data: u64) Kind {
    return @enumFromInt(@as(u32, @truncate(user_data >> kind_shift)));
}

fn index_of(user_data: u64) u32 {
    return @truncate(user_data);
}

/// One connection and the round trip it has in flight.
const Connection = struct {
    descriptor: core.Descriptor,
    /// Bytes of this round trip already sent, and already read back.
    sent: u32,
    received: u32,
    /// The clock when this round trip's first send was submitted.
    started_ns: u64,
    /// False once the peer closed or the socket failed: the connection stops working.
    live: bool,
};

const Options = struct {
    port: u16,
    connections: u32 = Defaults.connections,
    payload_bytes: u32 = Defaults.payload_bytes,
    seconds: u64 = Defaults.seconds,
    warmup_seconds: u64 = Defaults.warmup_seconds,
    candidate: []const u8 = "rotor",
    version: []const u8 = "this tree",
};

var loop_memory: [
    Loop.memory_bytes(.{
        .operations = operations,
        .entries = entries,
    })
]u8 align(core.layout.memory_alignment) = undefined;

var connections: [connections_max]Connection = undefined;
var payload: [payload_bytes_max]u8 = undefined;
var received_bytes: [connections_max * payload_bytes_max]u8 = undefined;
var latencies: Histogram = Histogram.empty;

/// The state the event handlers share, so a handler takes one pointer and not eight.
const Client = struct {
    loop: *Loop,
    options: Options,
    /// Round trips completed since the last `reset`.
    rounds: u64 = 0,
    /// When the current span ends.
    deadline_ns: u64 = 0,
};

pub fn main(init: std.process.Init) !void {
    const options = try parse(init);
    if (options.connections > connections_max) return error.TooManyConnections;
    if (options.payload_bytes > payload_bytes_max) return error.PayloadTooLarge;
    for (&payload, 0..) |*byte, index| byte.* = @truncate(index);

    var loop: Loop = undefined;
    try loop.init(&loop_memory, .{ .operations = operations, .entries = entries });
    defer loop.deinit();
    var client: Client = .{ .loop = &loop, .options = options };
    try connect_all(&client);
    defer close_all();

    _ = try run_span(&client, options.warmup_seconds);
    // The warm-up's round trips and latencies are not this run's.
    client.rounds = 0;
    latencies = Histogram.empty;
    const measured_ns = try run_span(&client, options.seconds);

    try report(init, options, measured_ns, client.rounds);
}

/// Opens every connection and waits for all of them, before any timing starts.
fn connect_all(client: *Client) !void {
    const options = client.options;
    const address = core.Address.ipv4(.{ 127, 0, 0, 1 }, options.port);
    var index: u32 = 0;
    while (index < options.connections) : (index += 1) {
        const descriptor = try sync.open_socket(.ipv4);
        connections[index] = .{
            .descriptor = descriptor,
            .sent = 0,
            .received = 0,
            .started_ns = 0,
            .live = true,
        };
        _ = client.loop.submit(&.{.{
            .user_data = user_data_of(.connect, index),
            .kind = .{ .connect = .{ .socket = descriptor, .address = &address } },
        }}, &.{});
    }

    var events: [events_max]Event = undefined;
    var connected: u32 = 0;
    while (connected < options.connections) {
        const count = try client.loop.tick(&events, core.constants.ns_per_s);
        for (events[0..count]) |event| {
            _ = event.outcome() catch return error.ConnectFailed;
            connected += 1;
        }
    }
}

fn close_all() void {
    for (&connections) |*connection| {
        if (connection.live) sync.close_now(connection.descriptor);
        connection.live = false;
    }
}

/// How long after the deadline a span waits for the operations still in flight before it calls
/// the server stalled. A round trip that has not come back in this long is not a slow one.
const stall_grace_ns = 5 * core.constants.ns_per_s;

/// Runs for `seconds` and returns the span it actually measured. Every connection starts a round
/// trip at the top and keeps one in flight until the deadline passes.
///
/// A span that reaches its deadline with operations still in flight ends anyway and fails: a
/// candidate that stops answering must not hang the harness, and must never be reported as a
/// number. `cancel_all` and `drain` then leave the loop empty, as decision 5, rule 7 requires.
fn run_span(client: *Client, seconds: u64) !u64 {
    const started_ns = now_ns();
    client.deadline_ns = started_ns + seconds * core.constants.ns_per_s;

    var index: u32 = 0;
    while (index < client.options.connections) : (index += 1) start_round(client, index);

    var events: [events_max]Event = undefined;
    var in_flight = client.options.connections;
    const stall_ns = client.deadline_ns + stall_grace_ns;
    while (in_flight != 0 and now_ns() < stall_ns) {
        const count = try client.loop.tick(&events, core.constants.ns_per_ms);
        for (events[0..count]) |event| {
            if (!handle(client, event)) in_flight -= 1;
        }
    }
    const span_ns = now_ns() - started_ns;
    if (in_flight != 0) {
        client.loop.cancel_all();
        try client.loop.drain(&events);
        return error.CandidateStalled;
    }
    return span_ns;
}

/// Sends the payload. The round trip's clock starts here.
fn start_round(client: *Client, index: u32) void {
    const connection = &connections[index];
    connection.sent = 0;
    connection.received = 0;
    connection.started_ns = now_ns();
    submit_send(client, index);
}

fn submit_send(client: *Client, index: u32) void {
    const connection = &connections[index];
    const bytes = payload[connection.sent..client.options.payload_bytes];
    _ = client.loop.submit(&.{.{
        .user_data = user_data_of(.send, index),
        .kind = .{ .send = .{
            .socket = connection.descriptor,
            .buffer = .{ .bytes = bytes },
        } },
    }}, &.{});
}

fn submit_receive(client: *Client, index: u32) void {
    const connection = &connections[index];
    const start = index * payload_bytes_max + connection.received;
    const wanted = client.options.payload_bytes - connection.received;
    _ = client.loop.submit(&.{.{
        .user_data = user_data_of(.receive, index),
        .kind = .{ .receive = .{
            .socket = connection.descriptor,
            .target = .{ .buffer = .{ .bytes = received_bytes[start..][0..wanted] } },
        } },
    }}, &.{});
}

/// True while this connection still has an operation in flight.
fn handle(client: *Client, event: Event) bool {
    const index = index_of(event.user_data);
    return switch (kind_of(event.user_data)) {
        .send => handle_send(client, index, event),
        .receive => handle_receive(client, index, event),
        .connect => false,
    };
}

fn handle_send(client: *Client, index: u32, event: Event) bool {
    const connection = &connections[index];
    const sent = event.outcome() catch return stop(index);
    connection.sent += sent;
    // A send may be short, and the rest of the payload has to follow it.
    if (connection.sent < client.options.payload_bytes) {
        submit_send(client, index);
        return true;
    }
    submit_receive(client, index);
    return true;
}

fn handle_receive(client: *Client, index: u32, event: Event) bool {
    const connection = &connections[index];
    const received = event.outcome() catch return stop(index);
    if (received == 0) return stop(index);
    connection.received += received;
    if (connection.received < client.options.payload_bytes) {
        submit_receive(client, index);
        return true;
    }
    finish_round(client, index);
    if (now_ns() >= client.deadline_ns) return false;
    start_round(client, index);
    return true;
}

fn finish_round(client: *Client, index: u32) void {
    const connection = &connections[index];
    latencies.record(now_ns() - connection.started_ns);
    client.rounds += 1;
}

fn stop(index: u32) bool {
    connections[index].live = false;
    return false;
}

/// The monotonic clock, as the backends' ticks read it. A round trip is thousands of
/// nanoseconds, so one read at each end of it costs C20 against C14 and does not show.
fn now_ns() u64 {
    var value: if (builtin.os.tag == .linux) std.os.linux.timespec else std.c.timespec = undefined;
    if (builtin.os.tag == .linux) {
        std.debug.assert(std.os.linux.clock_gettime(.MONOTONIC, &value) == 0);
    } else {
        std.debug.assert(std.c.clock_gettime(.MONOTONIC, &value) == 0);
    }
    const seconds: u64 = @intCast(value.sec);
    return seconds * core.constants.ns_per_s + @as(u64, @intCast(value.nsec));
}

const output_buffer_bytes = 4096;

fn report(init: std.process.Init, options: Options, duration_ns: u64, rounds: u64) !void {
    const result = Result.init(.{
        .workload = "echo",
        .candidate = options.candidate,
        .candidate_version = options.version,
        .configuration = .{
            .cores = 1,
            .connections = options.connections,
            .payload_bytes = options.payload_bytes,
            .load = .even,
        },
        .duration_ns = duration_ns,
        .operations = rounds,
    }, &latencies);

    var buffer: [output_buffer_bytes]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const writer = &output.interface;
    try writer.writeAll(harness.report.markdown_header);
    try result.render_markdown_row(writer);
    try writer.writeByte('\n');
    try result.render_json_line(writer);
    try writer.writeByte('\n');
    try writer.flush();
}

fn parse(init: std.process.Init) !Options {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len < 2) return error.MissingPort;
    var options: Options = .{ .port = try std.fmt.parseInt(u16, arguments[1], 10) };
    var index: usize = 2;
    while (index < arguments.len) : (index += 2) {
        if (index + 1 >= arguments.len) return error.MissingValue;
        const name = arguments[index];
        const value = arguments[index + 1];
        if (std.mem.eql(u8, name, "--connections")) {
            options.connections = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, name, "--payload")) {
            options.payload_bytes = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, name, "--seconds")) {
            options.seconds = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, name, "--warmup")) {
            options.warmup_seconds = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, name, "--candidate")) {
            options.candidate = value;
        } else if (std.mem.eql(u8, name, "--version")) {
            options.version = value;
        } else {
            return error.UnknownArgument;
        }
    }
    if (options.connections == 0 or options.payload_bytes == 0) return error.EmptyConfiguration;
    return options;
}
