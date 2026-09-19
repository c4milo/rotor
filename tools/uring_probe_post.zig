//! The checks of uring_probe.zig that answer the question docs/decisions/0002-scope.md leaves
//! open: whether IORING_OP_MSG_RING can post into a ring set up with IORING_SETUP_DEFER_TASKRUN.
//! Every ring here has the flags of a loop's ring, the sender's included.
//!
//! The probe posts three times, in this order:
//!   1. One thread owns both rings, posts from one into the other, and reaps both.
//!   2. The same again with IORING_MSG_RING_FLAGS_PASS, which lets a post choose the flags of the
//!      completion it becomes. The backend may mark a posted message with a flag bit. Decision 2's
//!      table does not list the flag, so this check never fails the probe.
//!   3. A second thread sets up a ring of its own, as a second loop would, and posts into the
//!      first thread's ring while the first thread waits inside io_uring_enter. That is how one
//!      loop posts to another (docs/decisions/0004-threading.md), and the kernel takes another
//!      path for it, because the sender is not the task that owns the receiver. The post must
//!      also wake the receiver, so the check measures how long the receiver waited. This post
//!      carries the flags of post 2 when the kernel passes them.
//!
//! Each line says what the sender's own completion held, what the receiver reaped, and what was
//! sent. A refusal shows as the errno of the sender's completion.

const std = @import("std");
const probe = @import("uring_probe.zig");

const linux = probe.linux;
const IoUring = probe.IoUring;
const Report = probe.Report;
const Feature = probe.Feature;
const assert = std.debug.assert;

const post_one_thread: Feature = .{ .name = "MSG_RING into a DEFER_TASKRUN ring, one thread" };
const post_two_threads: Feature = .{ .name = "MSG_RING into a DEFER_TASKRUN ring, two threads" };
const flags_pass: Feature = .{
    .name = "IORING_MSG_RING_FLAGS_PASS (not required)",
    .need = .optional,
};

/// The user_data of the sender's own completion for a post.
const user_data_post = 0x9057;

/// Milliseconds the second thread lets pass before it posts, so that the receiver is already
/// waiting inside io_uring_enter when the post arrives.
const post_delay_ms = 50;

/// What one post carries: the receiver's completion holds `user_data`, and `result` as its res.
const Message = struct {
    user_data: u64,
    result: i32,
    /// The flags of the receiver's completion, asked for with IORING_MSG_RING_FLAGS_PASS. Null
    /// posts without it, and the receiver's completion then has no flags.
    cqe_flags: ?u32,
};

/// The post of the two required checks.
const plain_message: Message = .{ .user_data = 0x726f_746f_72, .result = 1234, .cqe_flags = null };

/// The post that asks for completion flags. The pattern has bits in both halves of the word. It
/// leaves out IORING_CQE_F_SKIP and IORING_CQE_F_32, which tell a reader how to walk the ring.
const flagged_message: Message = .{
    .user_data = 0x666c_6167,
    .result = 5678,
    .cqe_flags = 0xa5c3_0101,
};

/// What one post came to. Null means the completion did not arrive within the wait.
const Outcome = struct {
    /// The errno of the sender's own completion. SUCCESS means the kernel accepted the post.
    sender: ?linux.E,
    /// The completion the receiver reaped.
    received: ?linux.io_uring_cqe = null,
    /// Milliseconds from the start of the second thread to the end of the receiver's wait. Only
    /// the post between threads measures it.
    waited_ms: ?u64 = null,
};

/// Runs the three posts, or says why not: they need the opcode and the setup flags.
pub fn check(report: *Report, possible: bool) !void {
    if (!possible) {
        const names = probe.op_msg_ring.name ++ " and " ++ probe.defer_taskrun.name;
        for ([_]Feature{ post_one_thread, flags_pass, post_two_threads }) |feature| {
            try report.verdict(feature, .not_tried, ", it needs " ++ names, .{});
        }
        return;
    }
    var sender = try IoUring.init(probe.ring_entries, probe.loop_ring_flags);
    defer sender.deinit();
    var receiver = try IoUring.init(probe.ring_entries, probe.loop_ring_flags);
    defer receiver.deinit();

    const plain = try post_on_one_thread(&sender, &receiver, plain_message);
    _ = try report_outcome(report, post_one_thread, plain, plain_message);
    const flagged = try post_on_one_thread(&sender, &receiver, flagged_message);
    const passes = try report_outcome(report, flags_pass, flagged, flagged_message);
    const message = if (passes) flagged_message else plain_message;
    const remote = try post_from_second_thread(&receiver, message);
    _ = try report_outcome(report, post_two_threads, remote, message);
}

/// Submits one IORING_OP_MSG_RING that posts `message` into the ring behind `target`, and
/// returns the errno of the sender's own completion.
fn post(ring: *IoUring, target: linux.fd_t, message: Message) !?linux.E {
    assert(target >= 0);
    assert(target != ring.fd);
    const sqe = try ring.get_sqe();
    const command = @intFromEnum(linux.IORING_MSG_RING_COMMAND.DATA);
    // The kernel reads the command from addr, the receiver's res from len and its user_data
    // from off. With FLAGS_PASS it reads the receiver's flags from file_index, which std names
    // splice_fd_in.
    sqe.prep_rw(.MSG_RING, target, command, @intCast(message.result), message.user_data);
    if (message.cqe_flags) |cqe_flags| {
        sqe.rw_flags = linux.IORING_MSG_RING_FLAGS_PASS;
        sqe.splice_fd_in = @bitCast(cqe_flags);
    }
    sqe.user_data = user_data_post;
    var cqes: [1]linux.io_uring_cqe = undefined;
    if (try probe.reap(ring, &cqes, 1) == 0) return null;
    assert(cqes[0].user_data == user_data_post);
    return cqes[0].err();
}

fn receive(receiver: *IoUring) !?linux.io_uring_cqe {
    var cqes: [1]linux.io_uring_cqe = undefined;
    return if (try probe.reap(receiver, &cqes, 1) == 0) null else cqes[0];
}

fn post_on_one_thread(sender: *IoUring, receiver: *IoUring, message: Message) !Outcome {
    const sent = try post(sender, receiver.fd, message);
    // A post the kernel refused puts nothing in the receiver, so there is nothing to wait for.
    if (sent == null or sent.? != .SUCCESS) return .{ .sender = sent };
    return .{ .sender = sent, .received = try receive(receiver) };
}

/// What the second thread is given and what it hands back. The first thread reads the results
/// only after it joined the second.
const Remote = struct {
    target: linux.fd_t,
    message: Message,
    sender: ?linux.E = null,
    failure: ?anyerror = null,

    /// Sets up this thread's own ring, lets `post_delay_ms` pass, and posts.
    fn run(remote: *Remote) void {
        var ring = IoUring.init(probe.ring_entries, probe.loop_ring_flags) catch |failure| {
            remote.failure = failure;
            return;
        };
        defer ring.deinit();
        const delay: linux.timespec = .{ .sec = 0, .nsec = post_delay_ms * std.time.ns_per_ms };
        _ = linux.nanosleep(&delay, null);
        remote.sender = post(&ring, remote.target, remote.message) catch |failure| {
            remote.failure = failure;
            return;
        };
    }
};

fn monotonic_ns() !u64 {
    var now: linux.timespec = undefined;
    _ = try probe.check("clock_gettime", linux.clock_gettime(.MONOTONIC, &now));
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

/// The receiver waits on this thread while the second thread posts. The second thread is joined
/// before any result is read or any error returned.
fn post_from_second_thread(receiver: *IoUring, message: Message) !Outcome {
    var remote: Remote = .{ .target = receiver.fd, .message = message };
    const started_ns = try monotonic_ns();
    const thread = try std.Thread.spawn(.{}, Remote.run, .{&remote});
    const received = receive(receiver);
    const ended_ns = monotonic_ns();
    thread.join();
    if (remote.failure) |failure| return failure;
    const waited_ns = try ended_ns - started_ns;
    return .{
        .sender = remote.sender,
        .received = try received,
        .waited_ms = waited_ns / std.time.ns_per_ms,
    };
}

/// Prints one post's line and returns whether the post arrived as it was sent.
fn report_outcome(report: *Report, feature: Feature, outcome: Outcome, message: Message) !bool {
    const sender = outcome.sender orelse {
        const detail = ", the sender's own completion did not arrive within {d} s";
        try report.verdict(feature, .missing, detail, .{probe.wait_seconds});
        return false;
    };
    if (sender != .SUCCESS) {
        try report.refused(feature, "the sender's completion", sender);
        return false;
    }
    const cqe = outcome.received orelse {
        const detail = ", the kernel accepted the post and the receiver reaped nothing in {d} s";
        try report.verdict(feature, .missing, detail, .{probe.wait_seconds});
        return false;
    };
    if (outcome.waited_ms) |waited_ms| {
        const timing = "the second thread posted after {d} ms;" ++
            " the receiver's wait ended after {d} ms";
        try report.line(timing, .{ post_delay_ms, waited_ms });
        if (waited_ms >= probe.wait_seconds * std.time.ms_per_s) {
            const detail = ", the wait ran out first, so the post did not wake the receiver";
            try report.verdict(feature, .missing, detail, .{});
            return false;
        }
    }
    const flags = message.cqe_flags orelse 0;
    const intact = cqe.user_data == message.user_data and cqe.res == message.result and
        cqe.flags == flags;
    const detail = ", sender res 0; receiver reaped user_data 0x{x} res {d} flags 0x{x};" ++
        " sent user_data 0x{x} res {d} flags 0x{x}";
    try report.verdict(feature, if (intact) .present else .missing, detail, .{
        cqe.user_data, cqe.res, cqe.flags, message.user_data, message.result, flags,
    });
    return intact;
}
