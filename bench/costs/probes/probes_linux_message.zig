//! Row C17: one cross-core message by `IORING_OP_MSG_RING`, post to reap. Decision 4's unit of
//! cost, and the number every argument about handing work between loops divides by.
//!
//! The probe is two rings and two threads: the sender posts into the receiver's ring and the
//! receiver posts back, and the sample is the round trip halved. A round trip is measured and not
//! a one-way post, because a one-way post cannot be timed without a clock on each side and the
//! two clocks would have to agree.
//!
//! Two things the first version of this probe got wrong, and what they cost to learn:
//!
//!   - **A ring cannot spin on `cq_ready`.** With `DEFER_TASKRUN`, which `src/uring` sets, a
//!     message only becomes a completion when the receiving ring's own thread enters the kernel.
//!     A spinning receiver waits for ever. Both sides here block in `io_uring_enter`, which is
//!     what a rotor loop does when it is idle, so this number includes waking the receiver.
//!   - **A post's own completion looks exactly like a message.** Both land in the sender's ring
//!     with `res` 0. They are told apart by `user_data`: a post's is `own_post`, and a message
//!     carries whatever the sender put in `off`. A probe that did not separate them reaped its
//!     own completion and called it the answer.
//!   - **Each ring is created by the thread that drives it.** `SINGLE_ISSUER` binds a ring to
//!     one task, so a ring created on the main thread and entered from another answers EEXIST.
//!     `Loop.init` says the same of rotor's own loops; the first version of this probe made both
//!     rings on one thread and hung, because the far thread failed on its first enter and the
//!     near one waited for an answer that was never coming.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const measure = @import("../measure.zig");
const sys = @import("../sys.zig");
const shared = @import("probes_linux.zig");

const Environment = measure.Environment;
const Error = measure.Error;
const Plan = measure.Plan;
const Result = measure.Result;
const Ring = shared.Ring;

pub const probes = [_]measure.Probe{
    .{
        .row = 17,
        .operation = "one cross-core message by IORING_OP_MSG_RING, post to reap",
        .run = run_message,
    },
};

const ring_entries = 8;
const message_plan: Plan = .{ .warmup = 32, .samples = 1000, .batch = 64 };

/// The two halves of one round trip: the sender's post and the answer.
const trips_per_message = 2;

/// The `user_data` a post gives its own completion. A message never carries it: every value a
/// sender sends is at least `first_value`.
const own_post: u64 = 0;

/// The smallest value a message carries, so no message is mistaken for a post's completion.
const first_value: u64 = 1;

fn post(ring: *Ring, target: linux.fd_t, value: u64) Error!void {
    assert(value >= first_value);
    const sqe = ring.io.get_sqe() catch return error.UnexpectedResult;
    sqe.* = std.mem.zeroes(linux.io_uring_sqe);
    sqe.opcode = .MSG_RING;
    sqe.fd = target;
    sqe.addr = @intFromEnum(linux.IORING_MSG_RING_COMMAND.DATA);
    // `len` becomes the target completion's `res` and `off` becomes its `user_data`.
    sqe.len = 0;
    sqe.off = value;
    sqe.user_data = own_post;
    const submitted = ring.io.submit() catch return error.SystemCallFailed;
    if (submitted != 1) return error.UnexpectedResult;
}

/// Takes the next message this ring was sent, blocking, and drops the completions of this side's
/// own posts on the way.
fn receive(ring: *Ring) Error!u64 {
    while (true) {
        const cqe = ring.io.copy_cqe() catch return error.SystemCallFailed;
        if (cqe.res != 0) return error.UnexpectedResult;
        if (cqe.user_data != own_post) return cqe.user_data;
    }
}

/// The far thread. It makes its own ring, because `SINGLE_ISSUER` binds a ring to the task that
/// created it, and answers every message until it is sent `stop`.
const Answerer = struct {
    ring: Ring = undefined,
    near_ring: linux.fd_t,
    /// The far ring's descriptor once it exists, `failed_to_start` when it could not be made,
    /// and `starting` until one or the other.
    descriptor: std.atomic.Value(linux.fd_t) = .init(starting),
    failed: bool = false,
    /// What `pin_current_thread` answered on this thread, for the note: a row that says two
    /// cores must say so when it did not get them.
    placement: std.atomic.Value(u8) = .init(0),

    const starting: linux.fd_t = -1;
    const failed_to_start: linux.fd_t = -2;
    const stop: u64 = std.math.maxInt(u64);
    /// Sent back when this thread is giving up, so the near thread does not wait for ever.
    const gave_up: u64 = std.math.maxInt(u64) - 1;

    fn serve(answerer: *Answerer) void {
        const placement = measure.pin_current_thread(measure.second_cpu);
        answerer.placement.store(@intFromEnum(placement), .release);
        answerer.ring = Ring.init(ring_entries) catch {
            answerer.descriptor.store(failed_to_start, .release);
            return;
        };
        defer answerer.ring.deinit();
        answerer.descriptor.store(answerer.ring.io.fd, .release);
        answerer.answer_until_stopped();
    }

    fn answer_until_stopped(answerer: *Answerer) void {
        while (true) {
            const value = receive(&answerer.ring) catch return answerer.give_up();
            if (value == stop) return;
            post(&answerer.ring, answerer.near_ring, value) catch return answerer.give_up();
        }
    }

    /// Tells the near thread to stop waiting, so a failure here ends the probe instead of
    /// hanging it.
    fn give_up(answerer: *Answerer) void {
        answerer.failed = true;
        post(&answerer.ring, answerer.near_ring, gave_up) catch {};
    }

    /// Waits for `serve` to publish its ring. Returns the descriptor, or fails.
    fn started(answerer: *Answerer) Error!linux.fd_t {
        while (true) {
            const descriptor = answerer.descriptor.load(.acquire);
            if (descriptor == failed_to_start) return error.SystemCallFailed;
            if (descriptor != starting) return descriptor;
        }
    }
};

const Message = struct {
    near: Ring,
    far_ring: linux.fd_t,
    next: u64 = first_value,

    pub fn run_batch(context: *Message, messages: u32) Error!void {
        var remaining = messages;
        while (remaining != 0) : (remaining -= 1) {
            const value = context.next;
            context.next += 1;
            try post(&context.near, context.far_ring, value);
            const answer = try receive(&context.near);
            if (answer != value) return error.UnexpectedResult;
        }
    }
};

fn run_message(environment: *Environment) Error!Result {
    // Both threads are pinned where the OS allows it. A spawned thread inherits this thread's
    // affinity, so an unpinned far thread after a pinned row shares this core, and the row then
    // measures a handoff on one core instead of a wake across two.
    const near_placement = measure.pin_current_thread(measure.first_cpu);
    var near = try Ring.init(ring_entries);
    defer near.deinit();
    var answerer: Answerer = .{ .near_ring = near.io.fd };

    const thread = std.Thread.spawn(.{}, Answerer.serve, .{&answerer}) catch {
        return error.SystemCallFailed;
    };
    const far_ring = answerer.started() catch {
        thread.join();
        return error.SystemCallFailed;
    };
    var context: Message = .{ .near = near, .far_ring = far_ring };
    const plan = message_plan;
    const summary = measure.sample(Message, &context, plan, environment.values[0]);
    // The far thread ends whether the sampling failed or not, so the probe never leaves it
    // blocked on a ring that is about to close.
    post(&context.near, far_ring, Answerer.stop) catch {};
    thread.join();
    const measured = try summary;
    if (answerer.failed) return error.UnexpectedResult;

    const far_placement: measure.Placement = @enumFromInt(answerer.placement.load(.acquire));
    const note = environment.note(
        "a round trip halved: two rings on two threads, each set up as src/uring sets one up," ++
            " posting MSG_RING to the other; DEFER_TASKRUN means the receiver must enter the" ++
            " kernel to see a message, so both sides block and this number includes waking one;" ++
            " near thread {s}, far thread {s}. The row means two cores only when both say pinned",
        .{ near_placement.text(), far_placement.text() },
    );
    return .{
        .summary = measured.scaled(1.0 / @as(f64, trips_per_message)),
        .plan = plan,
        .unit = "messages",
        .note = note,
    };
}
