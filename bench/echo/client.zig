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
//!
//! A span fails, and gives no row, when a connection ends for any reason but the deadline: the
//! server closed it, a send or receive failed, or the bytes that came back were not the bytes
//! sent. Until 2026-09-24 it did not. A dead server gave a row of 0 operations, and a server that
//! echoed wrong bytes on io_uring at 64 KiB gave rows that entered `bench/baseline/echo.txt`.
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
    /// Round trips this connection finished before the one in flight, counted from its connect
    /// and across both spans. It picks the bytes a round sends and whether they are compared.
    round: u64,
    /// True while this slot holds an open socket, which `close_all` closes.
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

var connections: [connections_max]Connection align(@alignOf(Connection)) = undefined;
var received_bytes: [connections_max * payload_bytes_max]u8 = undefined;
var latencies: Histogram align(@alignOf(Histogram)) = Histogram.empty;

/// What a round sends: `payload_bytes` of `pattern`, from an offset that `window_of` picks. The
/// pattern is random bytes, so a piece that lands at the wrong offset does not match. Each
/// connection has its own windows, and a connection's next rounds move to the next window. So a
/// piece from another connection, or from this connection's recent rounds, does not match either.
/// A buffer the server let two receives share gives exactly those pieces. The bytes before
/// 2026-09-24 were `index mod 256` on every connection and every round. They hid every piece from
/// another connection or an earlier round, and every piece moved by a multiple of 256 bytes.
pub var pattern: [payload_bytes_max + windows * window_step_bytes]u8 = undefined;

/// The seed `pattern` is drawn from. Fixed, so every run sends the same bytes.
const pattern_seed: u64 = 0x5EED_EC40;

/// Rounds of one connection that use different windows, before the windows repeat.
pub const rounds_apart = 4;
pub const windows = connections_max * rounds_apart;

/// How far apart two windows start. Any step changes every byte of a random pattern; this one
/// keeps the extra bytes at 32 KiB, beside the 64 KiB a round sends at most.
pub const window_step_bytes = 16;

/// A connection compares one round in this many with what it sent, starting with its first.
/// Which rounds is a function of the round's number, never of the clock (decision 9). The estimate
/// for a compare of 64 KiB is C23, a copy of 64 KiB: 1,587 ns on `github`. A round trip there
/// costs at least two C22, 22,408 ns. So a compare of every round adds 7 percent, and one round
/// in 64 adds 0.1 percent. The compare runs after the round's latency is recorded.
pub const compare_every = 64;

pub fn fill_pattern() void {
    var random = core.random.Random.init(pattern_seed);
    for (&pattern) |*byte| byte.* = @truncate(random.next());
}

/// Where in `pattern` round `round` of connection `index` starts.
pub fn window_of(index: u32, round: u64) usize {
    const phase: usize = @intCast(round % rounds_apart);
    return (@as(usize, index) * rounds_apart + phase) * window_step_bytes;
}

pub fn compared(round: u64) bool {
    return round % compare_every == 0;
}

/// The bytes the round in flight on connection `index` sends, and has to get back.
fn round_bytes(client: *const Client, index: u32) []const u8 {
    const start = window_of(index, connections[index].round);
    return pattern[start..][0..client.options.payload_bytes];
}

/// False when this round is one `compared` picks and the bytes that came back are not the bytes
/// it sent.
fn echo_intact(client: *const Client, index: u32) bool {
    if (!compared(connections[index].round)) return true;
    const echoed = received_bytes[index * payload_bytes_max ..][0..client.options.payload_bytes];
    return std.mem.eql(u8, echoed, round_bytes(client, index));
}

/// Why a span fails. Each names a candidate that must not be reported as a number.
const SpanError = error{
    /// A connection ended before its last round came back: the server closed it, or a send or a
    /// receive on it failed.
    CandidateClosed,
    /// A round that `compared` picked came back with bytes other than the bytes it sent.
    CandidateCorrupted,
    /// Operations were still in flight `stall_grace_ns` after the deadline.
    CandidateStalled,
};

/// The state the event handlers share, so a handler takes one pointer and not eight.
const Client = struct {
    loop: *Loop,
    options: Options,
    /// Round trips completed since the last `reset`.
    rounds: u64 = 0,
    /// When the current span ends.
    deadline_ns: u64 = 0,
    /// Why the current span fails, set by the first connection that ended any way but by the
    /// deadline.
    failure: ?SpanError = null,
};

/// Runs one measurement against a server already listening on `options.port`, and returns the
/// row it measured. The warm-up span runs first and nothing of it is kept.
///
/// Everything this touches is static and reused between calls, so a runner may call it once per
/// candidate per round without allocating.
/// What the last run's placement was, so `echo_client` can print it beside the row. A row that
/// claims a core count without a pin is the failure this exists to make visible.
pub var last_placement: harness.Placement align(@alignOf(harness.Placement)) = .scheduler_default;

pub fn run(options: Options) !Result {
    // Placed before the loop is built: `Loop.init` asks to run on the thread that will own it,
    // after that thread is pinned, because the ring binds to it (decision 4).
    last_placement = harness.placement.place(options.cpu);
    if (options.connections > connections_max) return error.TooManyConnections;
    if (options.payload_bytes > payload_bytes_max) return error.PayloadTooLarge;
    fill_pattern();

    var loop: Loop = undefined;
    try loop.init(&loop_memory, .{ .operations = operations, .entries = entries });
    defer loop.deinit();
    var client: Client = .{ .loop = &loop, .options = options };
    // These three run in reverse: the loop is emptied, then the sockets close, then the loop is
    // torn down. All of them are above `connect_all` and not below it, because that call opens a
    // socket per connection and submits a connect for each, and returns on the first that fails.
    // A `defer` below it would leak every socket already opened and leave every other connect in
    // flight, which `deinit` halts on (decision 5, rule 7). A server that never started made both
    // visible on 2026-09-22: three failed rounds of 16 connections and then 64, and the run ended
    // out of descriptors.
    defer close_all();
    defer drain_loop(&loop);
    try connect_all(&client);

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
    // Every caller already defers `close_all`, and this makes the function safe without one:
    // `close_all` clears `live` as it goes, so the caller's deferred call after this one closes
    // nothing twice. A caller that forgot is what cost a comparison run on 2026-09-22.
    errdefer close_all();
    const options = client.options;
    const address = core.Address.ipv4(.{ 127, 0, 0, 1 }, options.port);
    var index: u32 = 0;
    while (index < options.connections) : (index += 1) {
        // Opened into the entry that owns it, so no statement stands between the socket existing
        // and `close_all` being able to close it. A `const` above the entry left a window that
        // only stayed safe because nothing fallible sat in it.
        connections[index] = .{
            .descriptor = try sync.open_socket(.ipv4),
            .sent = 0,
            .received = 0,
            .started_ns = 0,
            .round = 0,
            .live = true,
        };
        _ = client.loop.submit(&.{.{
            .user_data = user_data_of(.connect, index),
            .kind = .{ .connect = .{ .socket = connections[index].descriptor, .address = &address } },
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

/// Ends every operation the loop still holds, so `deinit` finds it empty whatever failed above.
/// A loop that is already empty pays one tick for this.
fn drain_loop(loop: *Loop) void {
    var events: [events_max]Event = undefined;
    loop.cancel_all();
    loop.drain(&events) catch {};
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
/// A span fails, and returns no number, when a connection ended any way but by the deadline, which
/// `Client.failure` names. It also fails when operations are still in flight `stall_grace_ns` after
/// the deadline: a candidate that stops answering must not hang the harness. Then `cancel_all` and
/// `drain` leave the loop empty, as decision 5, rule 7 requires.
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
    }
    // A failure is named before a stall: a connection that failed is why the others stalled.
    if (client.failure) |failure| return failure;
    if (in_flight != 0) return error.CandidateStalled;
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
    const bytes = round_bytes(client, index)[connection.sent..];
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
    const sent = event.outcome() catch return stop(client, error.CandidateClosed);
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
    const received = event.outcome() catch return stop(client, error.CandidateClosed);
    // The server closed the connection with this round still owed.
    if (received == 0) return stop(client, error.CandidateClosed);
    connection.received += received;
    if (connection.received < client.options.payload_bytes) {
        submit_receive(client, index);
        return true;
    }
    finish_round(client, index);
    // After the round's latency is recorded, so a comparison never lands in a percentile.
    if (!echo_intact(client, index)) return stop(client, error.CandidateCorrupted);
    connection.round += 1;
    if (now_ns() >= client.deadline_ns) return false;
    start_round(client, index);
    return true;
}

fn finish_round(client: *Client, index: u32) void {
    const connection = &connections[index];
    latencies.record(now_ns() - connection.started_ns);
    client.rounds += 1;
}

/// Ends this connection's part of the span and records why the span fails. The first failure is
/// the one reported. The socket stays open until `close_all`.
fn stop(client: *Client, failure: SpanError) bool {
    if (client.failure == null) client.failure = failure;
    return false;
}

/// The monotonic clock, as the backends' ticks read it. A round trip is thousands of
/// nanoseconds, so one read at each end of it costs C20 against C14 and does not show.
const now_ns = harness.clock.now_ns;

const testing = std.testing;

test {
    _ = @import("client_test.zig");
}

/// A client for the tests that hand `handle` a made-up event (decision 10). No such event reaches
/// the loop: each one ends its connection before anything is submitted.
fn client_for_test() Client {
    return .{ .loop = undefined, .options = .{ .port = 0 } };
}

test "a send or a receive that fails, or a receive of 0 bytes, fails the span as closed" {
    // A server that dies can end a connection any of these three ways, and which one depends on
    // timing, so the kernel will not produce each on demand.
    const ended = [_]Event{
        Event.failure(user_data_of(.send, 0), .broken_pipe),
        Event.failure(user_data_of(.receive, 0), .connection_reset),
        Event.success(user_data_of(.receive, 0), 0),
    };
    for (ended) |event| {
        var client = client_for_test();
        connections[0].received = 0;
        try testing.expect(!handle(&client, event));
        try testing.expectEqual(@as(?SpanError, error.CandidateClosed), client.failure);
    }
}

test "a round that comes back whole moves its connection to its next round" {
    var client = client_for_test();
    // Past its deadline, so the connection starts no round after this one. Round 1 is one that
    // `compared` skips, so the bytes in `received_bytes` do not matter.
    client.deadline_ns = 0;
    connections[0].received = 0;
    connections[0].round = 1;
    const payload_bytes = client.options.payload_bytes;
    try testing.expect(!handle(&client, Event.success(user_data_of(.receive, 0), payload_bytes)));
    try testing.expectEqual(@as(?SpanError, null), client.failure);
    try testing.expectEqual(@as(u64, 2), connections[0].round);
    try testing.expectEqual(@as(u64, 1), client.rounds);
}

test "the first failure of a span is the one it reports" {
    var client = client_for_test();
    client.failure = error.CandidateCorrupted;
    try testing.expect(!handle(&client, Event.failure(user_data_of(.send, 0), .broken_pipe)));
    try testing.expectEqual(@as(?SpanError, error.CandidateCorrupted), client.failure);
}
