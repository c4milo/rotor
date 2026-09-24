//! The accept storm: how fast a candidate takes new connections, which is the workload decision 3
//! says multishot accept should show most in, and the one decision 4's `single_acceptor` question
//! turns on.
//!
//! One connection is: open a socket, connect, send one byte, read it back, close. The byte is
//! what makes the measurement honest. A connect that the kernel completed proves nothing about
//! the server, because a listener's backlog accepts connections whether or not the application
//! ever calls accept: a server that never accepts would score a perfect connect rate. Waiting for
//! the echo proves the server accepted the connection and served it.
//!
//! A run is **one burst**: `connections` sockets opened and connected as fast as the client can
//! submit them, then every one of them served. The latency recorded is per connection, from
//! opening the socket to its byte coming back; the throughput is the burst divided by the time
//! the whole burst took. A burst is what "storm" means, and it is what decision 3 expects
//! multishot accept to show in: one submission taking a queue of waiting connections.
//!
//! It drives the same servers the echo workload does, unchanged, so every candidate is measured
//! without writing one line per candidate.
//!
//! A burst fails, and gives no row, when any of its connections is not served: a connect fails,
//! the server closes the connection before the byte comes back, or the byte that comes back is not
//! the one sent. Until 2026-09-24 a failed connection was left out of the count, and a receive that
//! the server's close ended with 0 bytes was counted as served, so a dead server still gave a row.
//!
//! **Why a burst and not sustained churn.** The first version of this file opened and closed
//! connections continuously for a span. On loopback that cannot be measured:
//!
//!   - Closed politely, each connection leaves a socket in TIME_WAIT for a minute. A second of
//!     churn filled the ephemeral range, 16,314 sockets on the development machine, and every
//!     further connect failed. The rate measured would have been the kernel recycling ports.
//!   - Closed with `SO_LINGER` at zero, which sends a reset and skips TIME_WAIT, the freed port
//!     is reused at once and the next connection collides with the four-tuple the server has not
//!     finished tearing down. Every receive failed with `ConnectionReset`.
//!
//! A burst has neither problem: it costs `connections` ports once, and the runner's rounds and
//! candidates together must stay inside the ephemeral range, which is what `ports_per_run`
//! records.
const std = @import("std");
const core = @import("core");
const backend = @import("backend");
const harness = @import("harness");
const now_ns = harness.clock.now_ns;

const Loop = backend.Loop;
const Event = core.Event;
const Histogram = harness.histogram.Histogram;
const Operation = core.Operation;
const Result = harness.report.Result;
const sync = backend.sync;

/// Connections in one burst, at most. Also the ports one run consumes: a host has some thousands
/// of ephemeral ports and each is held for a minute after the burst, so a runner doing five
/// rounds of four candidates at this size uses 10,240 of them, which fits the 16,384 the
/// development machine has.
pub const connections_max = 512;

/// Slots: a connect, a send and a receive in flight per connection, with room to spare.
const operations = 4 * connections_max + 64;
const entries = 4096;
const events_max = 1024;

/// The one byte a connection carries, which proves the server accepted it.
const probe_byte: u8 = 0xC1;

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

const Connection = struct {
    descriptor: core.Descriptor,
    /// The clock when this connection's socket was opened.
    started_ns: u64,
    /// True while this slot holds an open socket.
    live: bool,
};

pub const Options = struct {
    port: u16,
    /// The burst: connections opened at once, which is also the ports the run consumes.
    connections: u32 = 256,
    candidate: []const u8 = "rotor",
    version: []const u8 = "this tree",
};

var loop_memory: [
    Loop.memory_bytes(.{ .operations = operations, .entries = entries })
]u8 align(core.layout.memory_alignment) = undefined;

var connections: [connections_max]Connection align(@alignOf(Connection)) = undefined;
var bytes: [connections_max]u8 = undefined;
var latencies: Histogram align(@alignOf(Histogram)) = Histogram.empty;

/// Why a burst fails. Each names a candidate that must not be reported as a number.
const BurstError = error{
    /// A connect failed: the server did not take the connection.
    ConnectFailed,
    /// A connection ended before its byte came back: the server closed it, or a send or a receive
    /// on it failed.
    CandidateClosed,
    /// The byte that came back was not `probe_byte`.
    CandidateCorrupted,
    /// Connections were still in flight `burst_stall_ns` after the burst started.
    CandidateStalled,
};

const Storm = struct {
    loop: *Loop,
    options: Options,
    address: core.Address,
    /// Connections that completed in this burst.
    completed: u64 = 0,
    /// Why the current burst fails, set by the first connection that was not served.
    failure: ?BurstError = null,
};

pub fn run(options: Options) !Result {
    if (options.connections > connections_max) return error.TooManyConnections;
    var loop: Loop = undefined;
    try loop.init(&loop_memory, .{ .operations = operations, .entries = entries });
    defer loop.deinit();
    var storm: Storm = .{
        .loop = &loop,
        .options = options,
        .address = core.Address.ipv4(.{ 127, 0, 0, 1 }, options.port),
    };
    for (&connections) |*connection| connection.live = false;
    defer close_all();

    // One burst is thrown away: the first connections of a run pay for pages this process and
    // the server have not touched.
    _ = try run_burst(&storm);
    storm.completed = 0;
    latencies = Histogram.empty;
    const measured_ns = try run_burst(&storm);

    return Result.init(.{
        .workload = "accept storm",
        .candidate = options.candidate,
        .candidate_version = options.version,
        .configuration = configuration_of(options.connections),
        .duration_ns = measured_ns,
        .operations = storm.completed,
    }, &latencies);
}

/// What a storm row says about itself. It is a function so a test can read it: the `cores` field
/// claimed 1 while the storm pinned nothing, and no test noticed (decision 19's rule about a row
/// claiming what the harness did not do, applied to cores as well as load).
fn configuration_of(count: u32) harness.report.Configuration {
    return .{
        // The storm pins no thread, so it claims no core.
        .cores = 0,
        .connections = count,
        // One byte: the probe, not a payload this workload is about.
        .payload_bytes = 1,
        .load = .even,
    };
}

fn close_all() void {
    for (&connections) |*connection| {
        if (connection.live) sync.close_now(connection.descriptor);
        connection.live = false;
    }
}

/// How long a burst waits for the connections still in flight before it calls the server
/// stalled. A burst of `connections_max` that has not finished in this long is not a slow one.
const burst_stall_ns = 20 * core.constants.ns_per_s;

/// One burst: every connection opened and submitted, then all of them served. Returns how long
/// the burst took, which is what the throughput divides. A burst in which a connection was not
/// served, or that is still in flight after `burst_stall_ns`, fails instead, and `cancel_all` and
/// `drain` leave the loop empty (decision 5, rule 7).
fn run_burst(storm: *Storm) !u64 {
    const started_ns = now_ns();
    var index: u32 = 0;
    while (index < storm.options.connections) : (index += 1) try start_one(storm, index);

    var events: [events_max]Event = undefined;
    var in_flight = storm.options.connections;
    const stall_ns = started_ns + burst_stall_ns;
    while (in_flight != 0 and now_ns() < stall_ns) {
        const count = try storm.loop.tick(&events, core.constants.ns_per_ms);
        for (events[0..count]) |event| {
            if (!handle(storm, event)) in_flight -= 1;
        }
    }
    const span_ns = now_ns() - started_ns;
    if (in_flight != 0) {
        storm.loop.cancel_all();
        try storm.loop.drain(&events);
    }
    // A failure is named before a stall: a connection that failed is why the others stalled.
    if (storm.failure) |failure| return failure;
    if (in_flight != 0) return error.CandidateStalled;
    close_all();
    return span_ns;
}

/// Opens a socket and starts its connect. The clock starts here: opening the socket is part of
/// what a new connection costs.
fn start_one(storm: *Storm, index: u32) !void {
    const descriptor = try sync.open_socket(.ipv4);
    connections[index] = .{
        .descriptor = descriptor,
        .started_ns = now_ns(),
        .live = true,
    };
    bytes[index] = probe_byte;
    _ = storm.loop.submit(&.{.{
        .user_data = user_data_of(.connect, index),
        .kind = .{ .connect = .{ .socket = descriptor, .address = &storm.address } },
    }}, &.{});
}

/// True while this slot still has an operation in flight.
fn handle(storm: *Storm, event: Event) bool {
    const index = index_of(event.user_data);
    const kind = kind_of(event.user_data);
    const count = event.outcome() catch
        return stop(storm, if (kind == .connect) error.ConnectFailed else error.CandidateClosed);
    switch (kind) {
        .connect => {
            _ = storm.loop.submit(&.{.{
                .user_data = user_data_of(.send, index),
                .kind = .{ .send = .{
                    .socket = connections[index].descriptor,
                    .buffer = .{ .bytes = bytes[index .. index + 1] },
                } },
            }}, &.{});
            return true;
        },
        .send => {
            _ = storm.loop.submit(&.{.{
                .user_data = user_data_of(.receive, index),
                .kind = .{ .receive = .{
                    .socket = connections[index].descriptor,
                    .target = .{ .buffer = .{ .bytes = bytes[index .. index + 1] } },
                } },
            }}, &.{});
            return true;
        },
        .receive => return finish(storm, index, count),
    }
}

/// Ends this connection, whose receive took `received` bytes, and records it when its byte came
/// back. Its socket stays open until the burst ends, so the whole burst is connected at once and
/// the server holds every one of them, which is the load the workload is about.
fn finish(storm: *Storm, index: u32, received: u32) bool {
    // The server closed the connection before it echoed the byte.
    if (received == 0) return stop(storm, error.CandidateClosed);
    latencies.record(now_ns() - connections[index].started_ns);
    storm.completed += 1;
    // The receive wrote the echoed byte over the probe the send took from the same slot.
    if (bytes[index] != probe_byte) return stop(storm, error.CandidateCorrupted);
    return false;
}

/// Ends this connection's part of the burst and records why the burst fails. The first failure is
/// the one reported.
fn stop(storm: *Storm, failure: BurstError) bool {
    if (storm.failure == null) storm.failure = failure;
    return false;
}

const testing = std.testing;
const faulty_server = @import("faulty_server.zig");

test "a storm row claims no core, because the storm pins none" {
    const configuration = configuration_of(64);
    try testing.expectEqual(@as(u32, 0), configuration.cores);
    try testing.expectEqual(@as(u32, 64), configuration.connections);
    // One byte, and it is the probe rather than a payload the row is about.
    try testing.expectEqual(@as(u32, 1), configuration.payload_bytes);
    try testing.expectEqual(harness.report.Load.even, configuration.load);
}

/// Connections in each burst of the tests. A storm runs two bursts, so the faulty server accepts
/// twice this, which its `connections_max` holds.
const test_connections = 4;

/// Runs a storm against a server with `fault`, and returns what the storm returned. The server is
/// stopped before this returns.
fn storm_against(fault: faulty_server.Fault) !Result {
    var server: faulty_server.Server = undefined;
    try server.start(fault);
    const outcome = run(.{ .port = server.port, .connections = test_connections });
    try server.stop();
    return outcome;
}

test "a storm against a server that echoes its byte counts every connection" {
    if (!backend.supported) return error.SkipZigTest;
    const result = try storm_against(.none);
    try testing.expectEqual(@as(u64, test_connections), result.operations);
}

test "a storm against a server that closes its connections fails, and gives no row" {
    if (!backend.supported) return error.SkipZigTest;
    try testing.expectError(error.CandidateClosed, storm_against(.close));
}

test "a storm against a server that changes the byte it echoes fails" {
    if (!backend.supported) return error.SkipZigTest;
    try testing.expectError(error.CandidateCorrupted, storm_against(.corrupt));
}

/// A storm for the tests that hand `handle` a made-up event (decision 10), with connection 0's
/// clock started and its probe in place. No such event reaches the loop: each one ends its
/// connection before anything is submitted.
fn storm_for_test() Storm {
    connections[0] = .{ .descriptor = -1, .started_ns = now_ns(), .live = false };
    bytes[0] = probe_byte;
    return .{
        .loop = undefined,
        .options = .{ .port = 0 },
        .address = core.Address.ipv4(.{ 127, 0, 0, 1 }, 0),
    };
}

test "a burst fails when a connect, a send or a receive fails, or a receive takes 0 bytes" {
    const Case = struct { event: Event, failure: BurstError };
    const cases = [_]Case{
        .{
            .event = Event.failure(user_data_of(.connect, 0), .connection_refused),
            .failure = error.ConnectFailed,
        },
        .{
            .event = Event.failure(user_data_of(.send, 0), .broken_pipe),
            .failure = error.CandidateClosed,
        },
        .{
            .event = Event.failure(user_data_of(.receive, 0), .connection_reset),
            .failure = error.CandidateClosed,
        },
        .{
            .event = Event.success(user_data_of(.receive, 0), 0),
            .failure = error.CandidateClosed,
        },
    };
    for (cases) |case| {
        var storm = storm_for_test();
        try testing.expect(!handle(&storm, case.event));
        try testing.expectEqual(@as(?BurstError, case.failure), storm.failure);
        try testing.expectEqual(@as(u64, 0), storm.completed);
    }
}

test "the first failure of a burst is the one it reports" {
    var storm = storm_for_test();
    storm.failure = error.CandidateCorrupted;
    try testing.expect(!handle(&storm, Event.failure(user_data_of(.send, 0), .broken_pipe)));
    try testing.expectEqual(@as(?BurstError, error.CandidateCorrupted), storm.failure);
}

test "a burst counts a connection whose probe came back, and fails on any other byte" {
    const received = Event.success(user_data_of(.receive, 0), 1);

    var served = storm_for_test();
    try testing.expect(!handle(&served, received));
    try testing.expectEqual(@as(?BurstError, null), served.failure);
    try testing.expectEqual(@as(u64, 1), served.completed);

    var corrupted = storm_for_test();
    bytes[0] = ~probe_byte;
    try testing.expect(!handle(&corrupted, received));
    try testing.expectEqual(@as(?BurstError, error.CandidateCorrupted), corrupted.failure);
}
