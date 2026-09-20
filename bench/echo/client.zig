//! `client`: the load generator of the echo workload, and the only thing that measures it.
//! `echo_client` runs it once from the command line; `echo_runner` calls `run` many times, once
//! per candidate per round, which is how a comparison gets its spread (`harness.series`).
//!
//! It opens `connections` sockets to 127.0.0.1:PORT and keeps one message in flight on each: send
//! the payload, read it back whole, record the round trip, send again. It reports the throughput
//! of the measured span and the p50, p99 and p999 of the round trips, through `bench/harness`.
//!
//! One client serves every candidate, so a comparison is made with one instrument: `rotor_echo`,
//! `libuv_echo` and `libxev_echo` are told apart by nothing but the `--candidate` name in the
//! row, and by which process was listening.
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
pub const connections_max = 512;

/// The largest payload, which is the 64 KiB the harness names.
pub const payload_bytes_max = 64 * 1024;

/// Slots: a connect, a send and a receive in flight per connection, with room to spare.
const operations = 4 * connections_max + 64;
const entries = 4096;
const events_max = 1024;

pub const Defaults = struct {
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

pub const Options = struct {
    port: u16,
    connections: u32 = Defaults.connections,
    payload_bytes: u32 = Defaults.payload_bytes,
    seconds: u64 = Defaults.seconds,
    warmup_seconds: u64 = Defaults.warmup_seconds,
    candidate: []const u8 = "rotor",
    version: []const u8 = "this tree",
    /// The core to pin this client to, or null to let the scheduler place it. A row that says
    /// how many cores it used is only true when both ends were pinned, which Linux does and
    /// macOS cannot (`bench/harness/placement.zig`).
    cpu: ?usize = null,
    /// The cores the run is meant to be using, which the report carries. The runner sets it from
    /// where it placed the two ends; it is not discovered here.
    cores: u32 = 1,
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

/// Runs one measurement against a server already listening on `options.port`, and returns the
/// row it measured. The warm-up span runs first and nothing of it is kept.
///
/// Everything this touches is static and reused between calls, so a runner may call it once per
/// candidate per round without allocating.
/// What the last run's placement was, so `echo_client` can print it beside the row. A row that
/// claims a core count without a pin is the failure this exists to make visible.
pub var last_placement: harness.Placement = .scheduler_default;

pub fn run(options: Options) !Result {
    // Placed before the loop is built: `Loop.init` asks to run on the thread that will own it,
    // after that thread is pinned, because the ring binds to it (decision 4).
    last_placement = harness.placement.place(options.cpu);
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

    return Result.init(.{
        .workload = "echo",
        .candidate = options.candidate,
        .candidate_version = options.version,
        .configuration = .{
            // A row names a core count only when the thread was really pinned. macOS refuses a
            // pin, so a run there reports 0 rather than claiming a placement nobody made — which
            // is the whole reason `names_a_core` exists.
            .cores = if (last_placement.names_a_core()) options.cores else 0,
            .connections = options.connections,
            .payload_bytes = options.payload_bytes,
            .load = .even,
        },
        .duration_ns = measured_ns,
        .operations = client.rounds,
    }, &latencies);
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
