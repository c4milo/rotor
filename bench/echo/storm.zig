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
const builtin = @import("builtin");
const core = @import("core");
const backend = @import("backend");
const harness = @import("harness");

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

var connections: [connections_max]Connection = undefined;
var bytes: [connections_max]u8 = undefined;
var latencies: Histogram = Histogram.empty;

const Storm = struct {
    loop: *Loop,
    options: Options,
    address: core.Address,
    /// Connections that completed in this burst.
    completed: u64 = 0,
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
        .configuration = .{
            .cores = 1,
            .connections = options.connections,
            // One byte, which is the probe and not a payload the workload is about.
            .payload_bytes = 1,
            .load = .even,
        },
        .duration_ns = measured_ns,
        .operations = storm.completed,
    }, &latencies);
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
/// the burst took, which is what the throughput divides.
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
            if (!try handle(storm, event)) in_flight -= 1;
        }
    }
    const span_ns = now_ns() - started_ns;
    if (in_flight != 0) {
        storm.loop.cancel_all();
        try storm.loop.drain(&events);
        return error.CandidateStalled;
    }
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
fn handle(storm: *Storm, event: Event) !bool {
    const index = index_of(event.user_data);
    _ = event.outcome() catch return finish(storm, index, false);
    switch (kind_of(event.user_data)) {
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
        .receive => return finish(storm, index, true),
    }
}

/// Ends this connection and records it when it completed. Its socket stays open until the burst
/// ends, so the whole burst is connected at once and the server holds every one of them, which is
/// the load the workload is about.
fn finish(storm: *Storm, index: u32, completed: bool) !bool {
    if (completed) {
        latencies.record(now_ns() - connections[index].started_ns);
        storm.completed += 1;
    }
    return false;
}

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
