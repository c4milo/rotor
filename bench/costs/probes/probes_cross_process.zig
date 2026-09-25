//! Rows C24 and C25: one 16-byte message from one process to another through a ring in memory both
//! map, the unit docs/decisions/0021-loops-in-several-processes.md pays in. They are C19 and a wake
//! of that record's kind, with the far side in a process of its own, started by `fork` after the
//! shared memory and the wake exist, as a group's processes start after its creator made them.
//!
//!   - C24: the far process spins on the ring and the near one times batches of round trips. The
//!     code is C19's (`probes_cross_core.zig`); only where the far side runs and where the rings
//!     live differ, so the difference between the two rows is what a process boundary costs.
//!   - C25: the far process blocks in its wait, and the near one wakes it with decision 21's wake:
//!     on macOS one byte written to a pipe whose read end the far process's kqueue watches with
//!     EVFILT_READ; on Linux one count written to an eventfd whose poll the far process keeps in an
//!     io_uring ring set up as rotor's. The far process reads the wake, takes the message, reads the
//!     clock and records the sample, post to reap as C18 does. The near process waits
//!     `idle_gap_ns` after the far one says it is about to block, so the far one is asleep.
//!
//! What they cannot show: as for C18 and C19. On macOS nothing can be pinned; on Linux the near
//! process pins the first core and the far one the second, and each note says whether they did.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const linux = std.os.linux;
const posix = std.posix;
const measure = @import("../measure.zig");
const process = @import("harness").process;
const sys = @import("../sys.zig");
const cross_core = @import("probes_cross_core.zig");
const linux_probes = @import("probes_linux.zig");

const Environment = measure.Environment;
const Error = measure.Error;
const Plan = measure.Plan;
const Result = measure.Result;
const Ring = cross_core.Ring;
const Awake = cross_core.Awake;

pub const probes = [_]measure.Probe{
    .{
        .row = 24,
        .operation = "one message between processes by a shared ring when the receiver is already awake",
        .run = run_awake,
    },
    .{
        .row = 25,
        .operation = "one message between processes by a shared ring plus decision 21's wake, post to reap",
        .run = run_wake,
    },
};

const wake_plan = cross_core.wake_plan;

/// The most bytes the far process of C25 reads from its wake per wake: an eventfd's count is 8.
const wake_read_bytes = 64;

/// What C25's near process writes to wake the far one: one count, as an eventfd takes it. A pipe
/// takes the first byte of it.
const one_count: u64 = 1;

/// The ring entries C25's far process holds on Linux: one poll at a time.
const ring_entries = 8;

// Row C24.

fn run_awake(environment: *Environment) Error!Result {
    const near_placement = measure.pin_current_thread(measure.first_cpu);
    const plan = cross_core.awake_plan;
    const memory = process.shared(@sizeOf(Awake)) catch return error.SystemCallFailed;
    defer process.release(memory);
    const awake: *Awake = @ptrCast(@alignCast(memory.ptr));
    awake.* = .{ .round_trips = @as(u64, plan.warmup + plan.samples) * plan.batch / 2 };
    const child = process.start(*Awake, awake, respond) catch return error.SystemCallFailed;
    const sampled = measure.sample(Awake, awake, plan, environment.values[0]);
    // A near process that failed leaves the far one spinning for a request; it would stop by
    // itself after its spin limit, which is tens of seconds.
    if (sampled) |_| {} else |_| process.kill(child);
    const status = process.wait(child) catch return error.UnexpectedResult;
    const summary = try sampled;
    if (status != process.status_passed) return error.UnexpectedResult;
    const far_placement: measure.Placement = @enumFromInt(awake.placement.load(.acquire));
    const note = environment.note(
        "C19's request and reply with the far side in a process made by fork, both rings in a" ++
            " shared mapping, both sides spinning; half a round trip is one message from post to" ++
            " reap; near process {s}, far process {s}",
        .{ near_placement.text(), far_placement.text() },
    );
    return .{
        .summary = summary,
        .plan = plan,
        .unit = "messages, two to a round trip",
        .note = note,
    };
}

fn respond(awake: *Awake) u8 {
    awake.respond();
    return if (awake.failed.load(.acquire)) process.status_failed else process.status_passed;
}

// Row C25.

/// What the two processes of C25 share. It lives in a shared mapping, so the far process's
/// samples reach the near one.
const Wake = struct {
    ring: Ring = .{},
    /// One more than the number of the message the far process is about to block for.
    armed: std.atomic.Value(u32) align(cross_core.cache_line_bytes) = .init(0),
    failed: std.atomic.Value(bool) align(cross_core.cache_line_bytes) = .init(false),
    /// What `pin_current_thread` answered in the far process, for the note.
    placement: std.atomic.Value(u8) = .init(0),
    /// What the near process writes to: the pipe's write end, or the eventfd.
    send: sys.fd_t,
    /// What the far process waits on: the pipe's read end, or the same eventfd.
    watch: sys.fd_t,
    latencies_ns: [wake_plan.samples]f64 = undefined,

    fn post_all(wake: *Wake) Error!void {
        var index: u32 = 0;
        while (index < wake_plan.warmup + wake_plan.samples) : (index += 1) {
            try wake.wait_until_armed(index + 1);
            measure.spin_until(measure.now_ns() + cross_core.idle_gap_ns);
            try wake.ring.push(.{ .payload = measure.now_ns(), .tag = index });
            const written = posix.system.write(wake.send, std.mem.asBytes(&one_count), write_bytes);
            if (posix.errno(written) != .SUCCESS) return error.SystemCallFailed;
        }
    }

    fn wait_until_armed(wake: *Wake, armed: u32) Error!void {
        var spins: u64 = 0;
        while (spins < cross_core.spins_max) : (spins += 1) {
            if (wake.armed.load(.acquire) == armed) return;
            if (wake.failed.load(.acquire)) return error.UnexpectedResult;
        }
        return error.HelperStalled;
    }

    /// The far process's side of one message, once its wait ended: empties the wake, takes the
    /// message, and records the sample.
    fn take(wake: *Wake, index: u32) Error!void {
        var bytes: [wake_read_bytes]u8 = undefined;
        const read = posix.system.read(wake.watch, &bytes, bytes.len);
        if (posix.errno(read) != .SUCCESS) return error.SystemCallFailed;
        const message = wake.ring.pop() orelse return error.UnexpectedResult;
        const reaped_ns = measure.now_ns();
        if (message.tag != index) return error.UnexpectedResult;
        // Both processes read one system-wide clock, so the reap cannot precede the post.
        if (reaped_ns < message.payload) return error.UnexpectedResult;
        if (index < wake_plan.warmup) return;
        wake.latencies_ns[index - wake_plan.warmup] = @floatFromInt(reaped_ns - message.payload);
    }
};

/// A pipe takes one byte of the count; an eventfd takes all eight.
const write_bytes: usize = if (builtin.os.tag == .linux) @sizeOf(u64) else 1;

fn run_wake(environment: *Environment) Error!Result {
    const near_placement = measure.pin_current_thread(measure.first_cpu);
    const memory = process.shared(@sizeOf(Wake)) catch return error.SystemCallFailed;
    defer process.release(memory);
    const wake: *Wake = @ptrCast(@alignCast(memory.ptr));
    const ends = try make_wake();
    defer close_wake(ends);
    wake.* = .{ .send = ends[1], .watch = ends[0] };
    const child = process.start(*Wake, wake, consume) catch return error.SystemCallFailed;
    const posted = wake.post_all();
    if (posted) |_| {} else |_| process.kill(child);
    const status = process.wait(child) catch return error.UnexpectedResult;
    try posted;
    if (status != process.status_passed or wake.failed.load(.acquire)) return error.UnexpectedResult;
    const values = environment.values[0][0..wake_plan.samples];
    @memcpy(values, &wake.latencies_ns);
    const summary = measure.summarize(values);
    const far_placement: measure.Placement = @enumFromInt(wake.placement.load(.acquire));
    const note = environment.note(
        "from the near process's clock read before it writes the ring to the far process's clock" ++
            " read after it takes the message: ring write, the write that wakes ({s}), the wake," ++
            " the read of the wake, ring read; the far process had been blocked for about {d}" ++
            " microseconds; near process {s}, far process {s}",
        .{
            wake_name,
            cross_core.idle_gap_ns / std.time.ns_per_us,
            near_placement.text(),
            far_placement.text(),
        },
    );
    return .{ .summary = summary, .plan = wake_plan, .unit = "messages", .note = note };
}

const wake_name = if (builtin.os.tag == .linux)
    "an eventfd polled from io_uring"
else
    "a pipe watched with EVFILT_READ";

/// The wake's two ends: `watch`, then `send`. On Linux both are one eventfd.
fn make_wake() Error![2]sys.fd_t {
    return if (builtin.os.tag == .linux) make_eventfd() else make_pipe();
}

fn make_eventfd() Error![2]sys.fd_t {
    const rc = linux.eventfd(0, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SystemCallFailed;
    const descriptor: sys.fd_t = @intCast(rc);
    return .{ descriptor, descriptor };
}

fn make_pipe() Error![2]sys.fd_t {
    var ends: [2]sys.fd_t = undefined;
    if (std.c.pipe(&ends) != 0) return error.SystemCallFailed;
    return ends;
}

fn close_wake(ends: [2]sys.fd_t) void {
    sys.close(ends[0]);
    if (ends[1] != ends[0]) sys.close(ends[1]);
}

/// The far process: it pins itself, then blocks for every message in turn.
fn consume(wake: *Wake) u8 {
    const placement = measure.pin_current_thread(measure.second_cpu);
    wake.placement.store(@intFromEnum(placement), .release);
    const consumed = if (builtin.os.tag == .linux) consume_io_uring(wake) else consume_kqueue(wake);
    consumed catch {
        wake.failed.store(true, .release);
        return process.status_failed;
    };
    return process.status_passed;
}

fn consume_kqueue(wake: *Wake) Error!void {
    const kq = std.c.kqueue();
    if (kq < 0) return error.SystemCallFailed;
    defer sys.close(kq);
    const watch = [1]posix.Kevent{.{
        .ident = @intCast(wake.watch),
        .filter = std.c.EVFILT.READ,
        .flags = std.c.EV.ADD,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    }};
    var events: [1]posix.Kevent = undefined;
    if (std.c.kevent(kq, &watch, watch.len, &events, 0, &cross_core.wake_timeout) != 0) {
        return error.SystemCallFailed;
    }
    var index: u32 = 0;
    while (index < wake_plan.warmup + wake_plan.samples) : (index += 1) {
        wake.armed.store(index + 1, .release);
        const rc = std.c.kevent(kq, &events, 0, &events, 1, &cross_core.wake_timeout);
        if (rc != 1) return error.UnexpectedResult;
        try wake.take(index);
    }
}

fn consume_io_uring(wake: *Wake) Error!void {
    var ring = try linux_probes.Ring.init(ring_entries);
    defer ring.deinit();
    var index: u32 = 0;
    while (index < wake_plan.warmup + wake_plan.samples) : (index += 1) {
        const sqe = ring.io.get_sqe() catch return error.UnexpectedResult;
        sqe.prep_poll_add(wake.watch, linux.POLL.IN);
        sqe.user_data = index;
        const submitted = ring.io.submit() catch return error.SystemCallFailed;
        if (submitted != 1) return error.UnexpectedResult;
        wake.armed.store(index + 1, .release);
        const cqe = ring.io.copy_cqe() catch return error.SystemCallFailed;
        if (cqe.res <= 0 or cqe.user_data != index) return error.UnexpectedResult;
        try wake.take(index);
    }
}

// Tests. `zig build test` compiles the probes and does not run these; run them with
// `zig test bench/costs/main.zig`.

const testing = std.testing;

test "a child process spins on rings the parent maps, and the parent's round trips come back" {
    const memory = try process.shared(@sizeOf(Awake));
    defer process.release(memory);
    const awake: *Awake = @ptrCast(@alignCast(memory.ptr));
    awake.* = .{ .round_trips = 8 };
    const child = try process.start(*Awake, awake, respond);
    try awake.run_batch(16);
    try testing.expectEqual(process.status_passed, try process.wait(child));
}
