//! Rows C14, C15 and C16: loopback TCP, the unit every echo workload pays in.
//!
//! All three use one connected pair of TCP sockets on 127.0.0.1 with TCP_NODELAY set, and
//! blocking calls. Every operation is timed alone, so the p99 is the p99 of single operations.
//!
//!   - C14: the measuring thread drives both ends: send a byte on one socket, receive it on the
//!     other, send it back, receive it. The row is the four calls together.
//!   - C15: a second thread owns the far end and echoes. The measuring thread sends a byte and
//!     blocks until the echo arrives, so every round trip wakes a blocked thread twice.
//!   - C16: `send` and then `recv` of 4 KiB. Before the clock starts, the far end already holds
//!     one whole block from the send before, so the timed `recv` never waits: the row is the two
//!     system calls and their two copies.
//!
//! What they cannot show. Neither thread is pinned, so "one core" and "two cores" in the row
//! names are what the scheduler chose. On macOS, as recalled from the XNU sources and not
//! verified here, a loopback segment is not delivered inside `send`: the kernel queues it for an
//! input thread of its own. That would explain why C14 and C15 measure alike, since both then
//! wake a thread on every leg, and it means the timed `recv` of C16 can find the socket locked by
//! that thread while it appends the block just sent.
const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const measure = @import("../measure.zig");
const sys = @import("../sys.zig");
const Environment = measure.Environment;
const Error = measure.Error;
const Plan = measure.Plan;
const Result = measure.Result;

pub const probes = [_]measure.Probe{
    .{
        .row = 14,
        .operation = "loopback TCP round trip, 1 byte each way, both ends on one core",
        .run = run_one_thread,
    },
    .{
        .row = 15,
        .operation = "loopback TCP round trip, 1 byte each way, ends on two cores",
        .run = run_two_threads,
    },
    .{
        .row = 16,
        .operation = "send plus recv of 4 KiB on a connected loopback socket," ++
            " the two syscalls alone",
        .run = run_transfer,
    },
};

/// Every operation is timed alone. A round trip lasts over ten microseconds, so 10,000 of them
/// keep a row under a second.
const round_trip_plan: Plan = .{ .warmup = 500, .samples = 10000, .batch = 1 };
const transfer_plan: Plan = .{ .warmup = 500, .samples = 10000, .batch = 1 };

/// The byte that travels in C14 and C15.
const payload_byte = 0x5a;

/// The bytes C16 moves per call.
const block_bytes = 4096;

/// Sends one byte on `from` and receives it on `to`.
fn move_byte(from: sys.fd_t, to: sys.fd_t, byte: *[1]u8) Error!void {
    if (try sys.send(from, byte) != byte.len) return error.UnexpectedResult;
    if (try sys.recv(to, byte, 0) != byte.len) return error.UnexpectedResult;
}

// Row C14.

const OneThread = struct {
    pair: sys.Pair,
    byte: [1]u8 = .{payload_byte},

    pub fn run_batch(trip: *OneThread, round_trips: u32) Error!void {
        var remaining = round_trips;
        while (remaining != 0) : (remaining -= 1) {
            try move_byte(trip.pair.near, trip.pair.far, &trip.byte);
            try move_byte(trip.pair.far, trip.pair.near, &trip.byte);
        }
    }
};

fn run_one_thread(environment: *Environment) Error!Result {
    const pair = try sys.tcp_pair();
    defer pair.deinit();
    var trip: OneThread = .{ .pair = pair };
    const plan = round_trip_plan;
    const summary = try measure.sample(OneThread, &trip, plan, environment.values[0]);
    if (trip.byte[0] != payload_byte) return error.UnexpectedResult;
    return .{
        .summary = summary,
        .plan = plan,
        .unit = "round trips",
        .note = "send, recv, send, recv of 1 byte from the one measuring thread, blocking," ++
            " TCP_NODELAY; the thread is not pinned and the kernel's own work runs where the" ++
            " scheduler puts it, so \"one core\" is not enforced",
    };
}

// Row C15.

const Echo = struct {
    far: sys.fd_t,
    round_trips: u64,
    failed: std.atomic.Value(bool) = .init(false),

    fn run(echo: *Echo) void {
        _ = measure.place_current_thread();
        echo.serve() catch {
            echo.failed.store(true, .release);
            // The measuring thread is blocked in recv: end the stream so it fails too.
            sys.shutdown(echo.far);
        };
    }

    fn serve(echo: *Echo) Error!void {
        var byte: [1]u8 = undefined;
        var remaining = echo.round_trips;
        while (remaining != 0) : (remaining -= 1) try move_byte(echo.far, echo.far, &byte);
    }
};

const TwoThreads = struct {
    near: sys.fd_t,
    byte: [1]u8 = .{payload_byte},

    pub fn run_batch(trip: *TwoThreads, round_trips: u32) Error!void {
        var remaining = round_trips;
        while (remaining != 0) : (remaining -= 1) try move_byte(trip.near, trip.near, &trip.byte);
    }
};

fn run_two_threads(environment: *Environment) Error!Result {
    const pair = try sys.tcp_pair();
    defer pair.deinit();
    const plan = round_trip_plan;
    var echo: Echo = .{
        .far = pair.far,
        .round_trips = @as(u64, plan.warmup + plan.samples) * plan.batch,
    };
    const thread = std.Thread.spawn(.{}, Echo.run, .{&echo}) catch
        return error.SystemCallFailed;

    var trip: TwoThreads = .{ .near = pair.near };
    const sampled = measure.sample(TwoThreads, &trip, plan, environment.values[0]);
    // On failure the echo thread is blocked in recv: end the stream so it returns and joins.
    if (sampled) |_| {} else |_| sys.shutdown(pair.near);
    thread.join();
    const summary = try sampled;
    if (echo.failed.load(.acquire)) return error.UnexpectedResult;
    if (trip.byte[0] != payload_byte) return error.UnexpectedResult;
    return .{
        .summary = summary,
        .plan = plan,
        .unit = "round trips",
        .note = "send then a blocking recv of 1 byte on the measuring thread, the echo on a" ++
            " second thread, TCP_NODELAY; the two threads could not be pinned to two cores on" ++
            " this OS, so the scheduler chose where each ran",
    };
}

// Row C16.

const Transfer = struct {
    pair: sys.Pair,
    block: [block_bytes]u8 = @splat(payload_byte),
    sink: [block_bytes]u8 = undefined,

    /// Not timed. Blocks until a whole block sits in the far end's receive buffer, and leaves it
    /// there, so the timed `recv` finds its data without waiting.
    pub fn prepare(transfer: *Transfer) Error!void {
        const flags = posix.MSG.PEEK | posix.MSG.WAITALL;
        const waiting = try sys.recv(transfer.pair.far, &transfer.sink, flags);
        if (waiting != block_bytes) return error.UnexpectedResult;
    }

    pub fn run_batch(transfer: *Transfer, transfers: u32) Error!void {
        // `prepare` guarantees one block, so only one transfer per batch is free of waiting.
        assert(transfers == 1);
        const sent = try sys.send(transfer.pair.near, &transfer.block);
        const received = try sys.recv(transfer.pair.far, &transfer.sink, 0);
        if (sent != block_bytes) return error.UnexpectedResult;
        if (received != block_bytes) return error.UnexpectedResult;
    }
};

fn run_transfer(environment: *Environment) Error!Result {
    const pair = try sys.tcp_pair();
    defer pair.deinit();
    var transfer: Transfer = .{ .pair = pair };
    // The block that is always one send ahead of the timed recv.
    if (try sys.send(pair.near, &transfer.block) != block_bytes) return error.UnexpectedResult;
    const plan = transfer_plan;
    const summary = try measure.sample(Transfer, &transfer, plan, environment.values[0]);
    if (transfer.sink[block_bytes - 1] != payload_byte) return error.UnexpectedResult;
    return .{
        .summary = summary,
        .plan = plan,
        .unit = "send and recv pairs",
        .note = "one send and one recv of 4,096 bytes, both from the measuring thread; the" ++
            " block the recv returns had fully arrived before the clock started, so the" ++
            " number is two system calls and two copies, not a wait",
    };
}
