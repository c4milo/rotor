//! Rows C14, C15, C16 and C22: loopback TCP, the unit every echo workload pays in.
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
//!   - C22: the same two calls at 64 KiB, which is the large payload of the echo comparison. It
//!     sizes both ends' kernel buffers first and refuses to report a number unless the receiving
//!     end holds two whole blocks, because one block waits while the timed `send` adds another:
//!     a smaller buffer would make the row a measure of waiting for room.
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
    .{
        .row = 22,
        .operation = "send plus recv of 64 KiB on a connected loopback socket," ++
            " the two syscalls alone",
        .run = run_large_transfer,
    },
};

/// Every operation is timed alone. A round trip lasts over ten microseconds, so 10,000 of them
/// keep a row under a second.
const round_trip_plan: Plan = .{ .warmup = 500, .samples = 10000, .batch = 1 };
const transfer_plan: Plan = .{ .warmup = 500, .samples = 10000, .batch = 1 };

/// C22 moves sixteen times the bytes per operation, so fewer samples keep the row near a second.
const large_transfer_plan: Plan = .{ .warmup = 200, .samples = 4000, .batch = 1 };

/// The byte that travels in C14 and C15.
const payload_byte = 0x5a;

/// The bytes C16 moves per call.
const block_bytes = 4096;

/// The bytes C22 moves per call: the large payload of the echo comparison, so the row says what
/// the kernel alone charges for one echo of that size.
const large_block_bytes = 64 * 1024;

/// The kernel buffer C22 asks each end for. Two blocks must fit, and this asks for eight, because
/// a kernel is free to give less than it is asked for.
const large_buffer_bytes = 8 * large_block_bytes;

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
    const placement = measure.pin_current_thread(measure.first_cpu);
    const pair = try sys.tcp_pair();
    defer pair.deinit();
    var trip: OneThread = .{ .pair = pair };
    const plan = round_trip_plan;
    const summary = try measure.sample(OneThread, &trip, plan, environment.values[0]);
    if (trip.byte[0] != payload_byte) return error.UnexpectedResult;
    const note = environment.note(
        "send, recv, send, recv of 1 byte from the one measuring thread, blocking, TCP_NODELAY;" ++
            " {s}. One thread is one core at a time whatever the pinning says, but the kernel's" ++
            " own work runs where the scheduler puts it",
        .{placement.text()},
    );
    return .{
        .summary = summary,
        .plan = plan,
        .unit = "round trips",
        .note = note,
    };
}

// Row C15.

const Echo = struct {
    far: sys.fd_t,
    round_trips: u64,
    failed: std.atomic.Value(bool) = .init(false),
    /// What `pin_current_thread` answered on the far thread, for the note: a row that says two
    /// cores must say so when it did not get them.
    placement: std.atomic.Value(u8) = .init(0),

    fn run(echo: *Echo) void {
        echo.placement.store(@intFromEnum(measure.pin_current_thread(measure.second_cpu)), .release);
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
    const near_placement = measure.pin_current_thread(measure.first_cpu);
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
    const far_placement: measure.Placement = @enumFromInt(echo.placement.load(.acquire));
    const note = environment.note(
        "one byte each way between two threads; near thread {s}, far thread {s}. The row means" ++
            " two cores only when both say pinned: unpinned, the scheduler may have put both" ++
            " ends on one core, which is what this row is set against C14 to separate",
        .{ near_placement.text(), far_placement.text() },
    );
    return .{
        .summary = summary,
        .plan = plan,
        .unit = "round trips",
        .note = note,
    };
}

// Row C16.

fn Transfer(comptime bytes: u32) type {
    return struct {
        pair: sys.Pair,
        block: [bytes]u8 = @splat(payload_byte),
        sink: [bytes]u8 = undefined,

        /// Not timed. Blocks until a whole block sits in the far end's receive buffer, and leaves
        /// it there, so the timed `recv` finds its data without waiting.
        pub fn prepare(transfer: *@This()) Error!void {
            const flags = posix.MSG.PEEK | posix.MSG.WAITALL;
            const waiting = try sys.recv(transfer.pair.far, &transfer.sink, flags);
            if (waiting != bytes) return error.UnexpectedResult;
        }

        pub fn run_batch(transfer: *@This(), transfers: u32) Error!void {
            // `prepare` guarantees one block, so only one transfer per batch is free of waiting.
            assert(transfers == 1);
            const sent = try sys.send(transfer.pair.near, &transfer.block);
            const received = try sys.recv(transfer.pair.far, &transfer.sink, 0);
            if (sent != bytes) return error.UnexpectedResult;
            if (received != bytes) return error.UnexpectedResult;
        }
    };
}

fn run_transfer(environment: *Environment) Error!Result {
    const pair = try sys.tcp_pair();
    defer pair.deinit();
    var transfer: Transfer(block_bytes) = .{ .pair = pair };
    // The block that is always one send ahead of the timed recv.
    if (try sys.send(pair.near, &transfer.block) != block_bytes) return error.UnexpectedResult;
    const plan = transfer_plan;
    const summary = try measure.sample(Transfer(block_bytes), &transfer, plan, environment.values[0]);
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

// Row C22.

/// Asks both ends for `large_buffer_bytes` and answers what the receiving end got. Linux reports
/// twice what it granted, because it counts its own bookkeeping; either way the number read back
/// is the one the check below uses, never the number asked for.
fn widen_buffers(pair: sys.Pair) Error!u32 {
    try sys.set_buffer_bytes(pair.near, .send, large_buffer_bytes);
    try sys.set_buffer_bytes(pair.far, .receive, large_buffer_bytes);
    return sys.buffer_bytes(pair.far, .receive);
}

fn run_large_transfer(environment: *Environment) Error!Result {
    const Large = Transfer(large_block_bytes);
    const pair = try sys.tcp_pair();
    defer pair.deinit();
    const granted = try widen_buffers(pair);
    // One block waits while the timed send adds another, so both must fit or the row measures a
    // wait for room instead of two calls.
    if (granted < 2 * large_block_bytes) return error.UnexpectedResult;
    var transfer: Large = .{ .pair = pair };
    // The block that is always one send ahead of the timed recv.
    if (try sys.send(pair.near, &transfer.block) != large_block_bytes) {
        return error.UnexpectedResult;
    }
    const plan = large_transfer_plan;
    const summary = try measure.sample(Large, &transfer, plan, environment.values[0]);
    if (transfer.sink[large_block_bytes - 1] != payload_byte) return error.UnexpectedResult;
    return .{
        .summary = summary,
        .plan = plan,
        .unit = "send and recv pairs",
        .note = environment.note(
            "one send and one recv of {d} bytes, both from the measuring thread; the block the" ++
                " recv returns had fully arrived before the clock started and the receiving end's" ++
                " buffer reads back as {d} bytes, so the number is two system calls and two" ++
                " copies of this size, not a wait",
            .{ large_block_bytes, granted },
        ),
    };
}
