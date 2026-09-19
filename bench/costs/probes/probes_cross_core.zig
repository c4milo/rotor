//! Rows C18 and C19: one 16-byte message from one thread to another through a ring both share,
//! the unit docs/decisions/0004-threading.md pays in on kqueue.
//!
//! The ring is single-producer single-consumer: two atomic indices, no lock. Each index has a
//! 128-byte line of its own and the slots start on a third, so the producer and the consumer
//! never write one line. `push` reads the consumer's index to refuse a full ring, as any real
//! ring must, so every message moves both index lines between the two cores.
//!
//!   - C18, macOS only: the consumer blocks in `kevent`. The producer reads the clock, writes the
//!     message, and triggers the consumer's EVFILT_USER filter. The consumer wakes, takes the
//!     message, and reads the clock. The message carries the producer's clock reading, so the
//!     sample is post to reap, and each message is timed alone. The producer spins for
//!     `idle_gap_ns` after the consumer says it is about to block, so the consumer is asleep when
//!     the trigger arrives; if the scheduler held it back, that sample is a message to a thread
//!     that was still awake, and the minimum shows it.
//!   - C19: the consumer never sleeps; it spins on the ring. One message takes about as long as
//!     two steps of the macOS clock, so it cannot be timed alone. The probe times a batch of
//!     round trips instead: the measuring thread pushes a request and spins for the reply, the
//!     other thread spins for the request and pushes the reply. A round trip is two messages, so
//!     the sample is the batch time over twice the round trips, and the p99 is the p99 of batch
//!     means. The spin has no pause instruction in it: a loop that pauses reaps later.
//!
//! What they cannot show: the two threads are not pinned, so the scheduler chose the two cores,
//! and on Apple silicon they may share a cluster's L2 or not.
//!
//! C19 is sensitive to the build. On an M1 Pro its median held within 2 percent from run to run
//! of one binary, and moved between 60 and 100 ns across binaries whose only differences were
//! elsewhere in the file. The cause was not measured. One candidate is the branch a spinning
//! receiver leaves its loop through: it mispredicts, and how much of the pop the core ran ahead
//! of it depends on the layout of the loop. Read the row as that range.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const posix = std.posix;
const measure = @import("../measure.zig");
const sys = @import("../sys.zig");
const kqueue = @import("probes_kqueue.zig");
const Environment = measure.Environment;
const Error = measure.Error;
const Plan = measure.Plan;
const Result = measure.Result;

const c18: measure.Probe = .{
    .row = 18,
    .operation = "one cross-core message by a shared ring plus an EVFILT_USER wake, post to reap",
    .run = run_wake,
};

const c19: measure.Probe = .{
    .row = 19,
    .operation = "one cross-core message by a shared ring when the receiver is already awake",
    .run = run_awake,
};

/// C18 needs kqueue, so only macOS has it. docs/costs.md marks it not applicable on Linux.
pub const probes = switch (builtin.os.tag) {
    .macos => [_]measure.Probe{ c18, c19 },
    else => [_]measure.Probe{c19},
};

/// The line both index fields are aligned to: the 128-byte cache line of Apple silicon, which
/// also keeps two 64-byte lines apart where the hardware prefetches the line next door.
const cache_line_bytes = 128;

/// The ring's capacity. The probes keep one message in flight, so any power of two does.
const ring_slots = 64;
const ring_mask = ring_slots - 1;

/// The most times a thread polls for the other thread before it gives up: tens of seconds of
/// spinning, and a thread that is merely descheduled comes back in milliseconds.
const spins_max = 1 << 34;

/// How long C18's producer spins after the consumer says it is about to block. Entering `kevent`
/// and blocking takes a few microseconds. In development runs, gaps from 50 to 1,000
/// microseconds gave the same median.
const idle_gap_ns = 100 * std.time.ns_per_us;

/// How long C18's consumer waits in `kevent` before it calls the producer lost. A loop that has
/// timers blocks with a timeout too.
const wake_timeout: posix.timespec = .{ .sec = 5, .nsec = 0 };

const wake_plan: Plan = .{ .warmup = 200, .samples = 5000, .batch = 1 };

/// 128 messages are 64 round trips.
const awake_plan: Plan = .{ .warmup = 200, .samples = 2000, .batch = 128 };

/// The message of decision 4: a 64-bit payload, a 32-bit tag, 32 bits reserved.
const Message = extern struct {
    payload: u64,
    tag: u32,
    reserved: u32 = 0,
};

const Ring = extern struct {
    /// Messages pushed so far. The producer alone writes it.
    tail: std.atomic.Value(u32) align(cache_line_bytes) = .init(0),
    /// Messages popped so far. The consumer alone writes it.
    head: std.atomic.Value(u32) align(cache_line_bytes) = .init(0),
    slots: [ring_slots]Message align(cache_line_bytes) = undefined,

    /// Refuses a full ring, so it reads the consumer's index on every push. A push that kept its
    /// last reading of that index, and read it again only when the ring looked full, was tried
    /// and measured the same on an M1 Pro, so the plain check stays.
    fn push(ring: *Ring, message: Message) Error!void {
        // The producer alone writes `tail`, so it reads its own index with a plain load.
        const tail = ring.tail.raw;
        const head = ring.head.load(.acquire);
        if (tail -% head >= ring_slots) return error.UnexpectedResult;
        ring.slots[tail & ring_mask] = message;
        ring.tail.store(tail +% 1, .release);
    }

    fn pop(ring: *Ring) ?Message {
        // The consumer alone writes `head`.
        const head = ring.head.raw;
        if (ring.tail.load(.acquire) == head) return null;
        const message = ring.slots[head & ring_mask];
        ring.head.store(head +% 1, .release);
        return message;
    }

    /// Polls until a message arrives: the receiver that is already awake.
    fn pop_spinning(ring: *Ring) Error!Message {
        var spins: u64 = 0;
        while (spins < spins_max) : (spins += 1) {
            if (ring.pop()) |message| return message;
        }
        return error.HelperStalled;
    }
};

comptime {
    assert(@sizeOf(Message) == 16);
    assert(std.math.isPowerOfTwo(ring_slots));
    assert(@offsetOf(Ring, "tail") % cache_line_bytes == 0);
    assert(@offsetOf(Ring, "head") - @offsetOf(Ring, "tail") == cache_line_bytes);
    assert(@offsetOf(Ring, "slots") - @offsetOf(Ring, "head") == cache_line_bytes);
}

// Row C19.

const Awake = struct {
    request: Ring = .{},
    reply: Ring = .{},
    sequence: u32 = 0,
    /// The requests the responder serves before it returns.
    round_trips: u64,
    failed: std.atomic.Value(bool) = .init(false),

    fn respond(awake: *Awake) void {
        _ = measure.place_current_thread();
        awake.serve() catch awake.failed.store(true, .release);
    }

    fn serve(awake: *Awake) Error!void {
        var remaining = awake.round_trips;
        while (remaining != 0) : (remaining -= 1) {
            try awake.reply.push(try awake.request.pop_spinning());
        }
    }

    pub fn run_batch(awake: *Awake, messages: u32) Error!void {
        assert(messages % 2 == 0);
        var remaining = messages / 2;
        while (remaining != 0) : (remaining -= 1) {
            try awake.request.push(.{ .payload = awake.sequence, .tag = awake.sequence });
            const answer = try awake.reply.pop_spinning();
            if (answer.tag != awake.sequence) return error.UnexpectedResult;
            awake.sequence +%= 1;
        }
    }
};

fn run_awake(environment: *Environment) Error!Result {
    const plan = awake_plan;
    var awake: Awake = .{ .round_trips = @as(u64, plan.warmup + plan.samples) * plan.batch / 2 };
    const thread = std.Thread.spawn(.{}, Awake.respond, .{&awake}) catch
        return error.SystemCallFailed;
    // On failure the responder runs out of spins and returns, so the join always ends.
    const sampled = measure.sample(Awake, &awake, plan, environment.values[0]);
    thread.join();
    const summary = try sampled;
    if (awake.failed.load(.acquire)) return error.UnexpectedResult;
    return .{
        .summary = summary,
        .plan = plan,
        .unit = "messages, two to a round trip",
        .note = "request and reply through two rings, both threads spinning with no pause" ++
            " instruction; half a round trip is one message from post to reap; the threads" ++
            " could not be pinned, so the scheduler chose the two cores; the median moves with" ++
            " the build of this probe, so read it as a range (README.md)",
    };
}

// Row C18.

const Wake = struct {
    ring: Ring = .{},
    /// One more than the number of the message the consumer is about to block for.
    armed: std.atomic.Value(u32) align(cache_line_bytes) = .init(0),
    /// The fields below are read by both threads and written by neither while messages flow, so
    /// they start a line of their own, away from `armed`.
    failed: std.atomic.Value(bool) align(cache_line_bytes) = .init(false),
    kq: sys.fd_t,
    plan: Plan,
    latencies_ns: []f64,

    fn consume(wake: *Wake) void {
        _ = measure.place_current_thread();
        wake.reap_all() catch wake.failed.store(true, .release);
    }

    fn reap_all(wake: *Wake) Error!void {
        var events: [1]posix.Kevent = undefined;
        var index: u32 = 0;
        while (index < wake.plan.warmup + wake.plan.samples) : (index += 1) {
            wake.armed.store(index + 1, .release);
            const rc = std.c.kevent(wake.kq, &events, 0, &events, 1, &wake_timeout);
            if (rc != 1) return error.UnexpectedResult;
            const message = wake.ring.pop() orelse return error.UnexpectedResult;
            const reaped_ns = measure.now_ns();
            if (message.tag != index) return error.UnexpectedResult;
            // Both threads read one system-wide clock, so the reap cannot precede the post.
            if (reaped_ns < message.payload) return error.UnexpectedResult;
            if (index < wake.plan.warmup) continue;
            const latency_ns: f64 = @floatFromInt(reaped_ns - message.payload);
            wake.latencies_ns[index - wake.plan.warmup] = latency_ns;
        }
    }

    fn post_all(wake: *Wake) Error!void {
        var index: u32 = 0;
        while (index < wake.plan.warmup + wake.plan.samples) : (index += 1) {
            try wake.wait_until_armed(index + 1);
            measure.spin_until(measure.now_ns() + idle_gap_ns);
            const posted_ns = measure.now_ns();
            try wake.ring.push(.{ .payload = posted_ns, .tag = index });
            try kqueue.submit(wake.kq, &.{kqueue.trigger_change});
        }
    }

    fn wait_until_armed(wake: *Wake, armed: u32) Error!void {
        var spins: u64 = 0;
        while (spins < spins_max) : (spins += 1) {
            if (wake.armed.load(.acquire) == armed) return;
            if (wake.failed.load(.acquire)) return error.UnexpectedResult;
        }
        return error.HelperStalled;
    }
};

fn run_wake(environment: *Environment) Error!Result {
    const kq = try kqueue.open_with_user_filter();
    defer sys.close(kq);
    const plan = wake_plan;
    var wake: Wake = .{ .kq = kq, .plan = plan, .latencies_ns = environment.values[0] };
    const thread = std.Thread.spawn(.{}, Wake.consume, .{&wake}) catch
        return error.SystemCallFailed;
    // On failure the consumer's kevent times out and it returns, so the join always ends.
    const posted = wake.post_all();
    thread.join();
    try posted;
    if (wake.failed.load(.acquire)) return error.UnexpectedResult;
    const summary = measure.summarize(wake.latencies_ns[0..plan.samples]);
    const note = environment.note(
        "from the producer's clock read before it writes the ring to the consumer's clock read" ++
            " after it takes the message: ring write, the kevent that triggers, the wake from" ++
            " a blocking kevent, ring read; the consumer had been blocked for about {d}" ++
            " microseconds, a longer sleep may wake slower; threads not pinned",
        .{idle_gap_ns / std.time.ns_per_us},
    );
    return .{ .summary = summary, .plan = plan, .unit = "messages", .note = note };
}

// Tests. `zig build test` compiles the probes and does not run these; run them with
// `zig test bench/costs/main.zig`.

const testing = std.testing;

test "the ring hands messages over in order and reports empty and full" {
    var ring: Ring = .{};
    try testing.expect(ring.pop() == null);
    for (0..ring_slots) |index| try ring.push(.{ .payload = index, .tag = @intCast(index) });
    try testing.expectError(error.UnexpectedResult, ring.push(.{ .payload = 0, .tag = 0 }));
    for (0..ring_slots) |index| {
        const message = ring.pop().?;
        try testing.expectEqual(@as(u64, index), message.payload);
        try testing.expectEqual(@as(u32, @intCast(index)), message.tag);
    }
    try testing.expect(ring.pop() == null);
    // The indices wrap past the slot count and the ring still holds `ring_slots` messages.
    try ring.push(.{ .payload = 7, .tag = 7 });
    try testing.expectEqual(@as(u64, 7), ring.pop().?.payload);
}
