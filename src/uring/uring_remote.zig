//! `Remote`: how a thread that owns no loop posts to one on io_uring (decision 4, "What another
//! thread may do").
//!
//! It is a small ring created for that thread, used only to submit `MSG_RING`. A loop posts by
//! putting a `MSG_RING` entry on its own ring, and the kernel places a completion on the target's
//! ring; a thread with no loop has no ring to put the entry on, so a `Remote` carries one of its
//! own. The ring is `constants.remote_entries` deep, which is one: `post` submits one entry and
//! reads its answer before it returns, so a second entry is never outstanding, and `unanswered`
//! is what keeps that true when the answer is late.
//!
//! A post is finished when it returns, as it is on kqueue. The kernel answers a `MSG_RING` with a
//! completion on the sender's ring, carrying 0 or an errno, and `post` reads it before returning,
//! so a full target or a target that is not a ring comes back as `PostError`, and the conformance
//! suite drives both backends with one scenario (decision 10). The errno goes through
//! `uring_errno.zig`, the map a loop's own post goes through, so the two report one condition
//! under one name.
//!
//! When the kernel answers. On Linux 6.1, and on 6.10 and later, the kernel completes a `MSG_RING`
//! inside the `io_uring_enter` that submits it, so one system call submits and finds the answer.
//! On 6.3 to 6.9 a `MSG_RING` to a target set up with `DEFER_TASKRUN`, which every rotor loop is,
//! runs as task work of the target's thread, and the sender's completion is queued from there: the
//! answer arrives once the target's thread has run. (Recalled from `io_uring/msg_ring.c` across
//! those versions; not read for this file.) So the enter that submits also waits, for
//! `constants.remote_wait_ns` at most. An answer that has not come by then leaves the post
//! `Unanswered`: the message may still land, the entry stays in the kernel, and the next post reads
//! and drops the late answer before it submits, or is `Unanswered` itself when the answer is still
//! not there.
//!
//! One thread owns a `Remote`. `init` records the thread, and `post` and `deinit` halt on any
//! other, as a loop does. The ring is also created with `SINGLE_ISSUER`, so the kernel would
//! refuse the submission anyway.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");
const constants = @import("constants.zig");
const errno_module = @import("uring_errno.zig");
const registry_module = @import("uring_registry.zig");
const ring_module = @import("uring_ring.zig");
const submit_module = @import("uring_submit.zig");

const Registry = registry_module.Registry;
const Ring = ring_module.Ring;

pub const InitError = core.remote.InitError;
pub const PostError = core.remote.PostError;

pub const Remote = struct {
    registry: *Registry,
    /// The identity of the thread that called `init`, from `core.tables.thread_identity`.
    owner: usize,
    /// This remote's id among the ids of `registry`. It names no ring of its own to the others: a
    /// remote receives nothing.
    id: core.LoopId,
    /// True while an entry a post submitted is still in the kernel: that post returned
    /// `Unanswered`. At most one, which is what sizes the ring at one entry.
    unanswered: bool,
    ring: Ring,

    /// Claims `id` for the calling thread and creates the ring the thread submits through. Must run
    /// on the thread that will post: the ring is single-issuer.
    ///
    /// `id` must be below the count the registry was sized for, and free. Claiming one twice, or one
    /// a loop already holds, halts.
    pub fn init(remote: *Remote, registry: *Registry, id: core.LoopId) InitError!void {
        assert(id < registry.loops());
        const ring = try Ring.init(constants.remote_entries);
        remote.* = .{
            .registry = registry,
            .owner = core.tables.thread_identity(),
            .id = id,
            .unanswered = false,
            .ring = ring,
        };
        registry.set_remote(id);
        assert(registry.get(id) == registry_module.descriptor_remote);
    }

    /// Gives the id back and closes the ring. With an entry still unanswered, closing the ring
    /// waits for the kernel to answer it (recalled: `io_ring_exit_work` in io_uring/io_uring.c
    /// waits for every request of the ring).
    pub fn deinit(remote: *Remote) void {
        remote.assert_owner();
        remote.registry.clear(remote.id);
        remote.ring.deinit();
    }

    /// Sends one message to the loop `target` runs, or says why it could not. The entry is built by
    /// `uring_submit.prepare_message`, as a loop's own post is, so the target's reap reads it the
    /// same way.
    pub fn post(remote: *Remote, target: core.LoopId, message: core.Message) PostError!void {
        remote.assert_owner();
        assert(target != remote.id);
        assert(message.tag <= core.constants.message_tag_max);
        const registry = remote.registry;
        if (target >= registry.loops()) return error.LoopNotFound;
        const target_ring = registry.get(target);
        // Negative covers a loop that is not running and another remote, which publishes a
        // sentinel below zero for exactly this reason.
        if (target_ring < 0) return error.LoopNotFound;
        if (remote.unanswered) try remote.drop_late_answer();

        assert(remote.ring.cq_ready() == 0);
        const sqe = remote.ring.get_sqe().?;
        sqe.* = std.mem.zeroes(linux.io_uring_sqe);
        submit_module.prepare_message(sqe, target_ring, message);
        return remote.answer(constants.remote_wait_ns);
    }

    /// Submits the one entry the caller filled, waits `wait_ns` at most for its answer, and reads
    /// it. One system call when the kernel answers inside it, which is the common case.
    fn answer(remote: *Remote, wait_ns: u64) PostError!void {
        assert(!remote.unanswered);
        assert(remote.ring.cq_ready() == 0);
        const entered = remote.ring.enter(wait_ns) catch |err| {
            // The call that failed is the one that took the entry, so the entry may be in the
            // kernel, and the next post finds out.
            remote.unanswered = true;
            return switch (err) {
                error.SystemResources => error.Unanswered,
                error.Unexpected => error.Unexpected,
            };
        };
        // The completion ring holds two and never has more than one in it, so it cannot overflow.
        assert(entered == .submitted);
        if (remote.ring.cq_ready() == 0) {
            remote.unanswered = true;
            return error.Unanswered;
        }
        return remote.read_answer();
    }

    /// The kernel's answer to a post whose caller was already told `Unanswered`: read and dropped,
    /// which frees the one entry. When it is still not there, the post that asked is `Unanswered`
    /// too, and nothing was submitted for it.
    fn drop_late_answer(remote: *Remote) PostError!void {
        assert(remote.unanswered);
        // The enter runs the deferred completion work the answer may be waiting behind, and
        // submits an entry that a failed enter left in the submission ring.
        _ = remote.ring.enter(null) catch |err| return switch (err) {
            error.SystemResources => error.Unanswered,
            error.Unexpected => error.Unexpected,
        };
        if (remote.ring.cq_ready() == 0) return error.Unanswered;
        remote.ring.cq_advance(1);
        remote.unanswered = false;
        assert(remote.ring.cq_ready() == 0);
    }

    /// Reads the one completion and hands it back to the kernel.
    fn read_answer(remote: *Remote) PostError!void {
        assert(remote.ring.cq_ready() == 1);
        const result = remote.ring.cqe_at(0).res;
        remote.ring.cq_advance(1);
        return result_of(result);
    }

    /// Halts when another thread calls into the remote: a programmer error, which the kernel
    /// would otherwise report as an `io_uring_enter` refused.
    fn assert_owner(remote: *const Remote) void {
        assert(remote.owner == core.tables.thread_identity());
    }
};

/// What the kernel's answer to a `MSG_RING` means. 0 is a message the kernel took. An errno goes
/// through the map a loop's own post uses, so both name one condition one way. Of the codes that
/// map yields for a post, three have an error of their own here. `would_block`, which Linux 6.1
/// answers for an IOPOLL target it could not lock (recalled; rotor's rings are not IOPOLL), is a
/// transient refusal like `system_resources` and shares its error. Every other code is `Unexpected`.
fn result_of(result: i32) PostError!void {
    if (result == 0) return;
    const errno = errno_module.errno_of(result);
    return switch (errno_module.code_of(errno, .{ .is_post = true })) {
        .mailbox_full => error.MailboxFull,
        .loop_not_found => error.LoopNotFound,
        .system_resources, .would_block => error.SystemResources,
        else => error.Unexpected,
    };
}

const testing = std.testing;

fn negative(errno: linux.E) i32 {
    return -@as(i32, @intCast(@intFromEnum(errno)));
}

test "the kernel's answers map to the errors a post reports, through the map a loop's post uses" {
    try result_of(0);
    try testing.expectError(error.MailboxFull, result_of(negative(.OVERFLOW)));
    try testing.expectError(error.LoopNotFound, result_of(negative(.BADF)));
    try testing.expectError(error.LoopNotFound, result_of(negative(.BADFD)));
    try testing.expectError(error.LoopNotFound, result_of(negative(.OWNERDEAD)));
    try testing.expectError(error.SystemResources, result_of(negative(.NOMEM)));
    try testing.expectError(error.SystemResources, result_of(negative(.AGAIN)));
    try testing.expectError(error.Unexpected, result_of(negative(.INVAL)));
    try testing.expectError(error.Unexpected, result_of(negative(.TIME)));
}

test "a remote claims an id with the sentinel, and gives it back" {
    if (!@import("uring.zig").supported) return error.SkipZigTest;
    var registry: Registry = undefined;
    var memory: [Registry.memory_bytes(3)]u8 align(core.layout.memory_alignment) = undefined;
    registry.init(&memory, 3);

    var remote: Remote = undefined;
    try remote.init(&registry, 2);
    try testing.expectEqual(core.tables.thread_identity(), remote.owner);
    try testing.expect(!remote.unanswered);
    try testing.expectEqual(registry_module.descriptor_remote, registry.get(2));
    remote.deinit();
    try testing.expectEqual(registry_module.descriptor_none, registry.get(2));
}

test "a post to an id that runs no loop, or to another remote, is refused" {
    if (!@import("uring.zig").supported) return error.SkipZigTest;
    var registry: Registry = undefined;
    var memory: [Registry.memory_bytes(3)]u8 align(core.layout.memory_alignment) = undefined;
    registry.init(&memory, 3);

    var first: Remote = undefined;
    var second: Remote = undefined;
    try first.init(&registry, 1);
    defer first.deinit();
    try second.init(&registry, 2);
    defer second.deinit();

    const message: core.Message = .{ .payload = 7, .tag = 1 };
    try testing.expectError(error.LoopNotFound, first.post(0, message));
    // An id above the count the registry was sized for, and the largest id there is: both are
    // refused before the registry is asked, which would halt on the second.
    try testing.expectError(error.LoopNotFound, first.post(3, message));
    try testing.expectError(error.LoopNotFound, first.post(core.constants.loops_max, message));
    try testing.expectError(error.LoopNotFound, first.post(2, message));
    try testing.expectError(error.LoopNotFound, second.post(1, message));
}

test "an answer that comes after the wait is Unanswered, and the next post drops it" {
    if (!@import("uring.zig").supported) return error.SkipZigTest;
    // The wait `answer` is given, and how long after it the fabricated answer comes. Both are the
    // test's own and not limits of the module.
    const short_wait_ns: u64 = 10 * core.constants.ns_per_ms;
    const late_answer_ns: u64 = 200 * core.constants.ns_per_ms;
    var registry: Registry = undefined;
    var memory: [Registry.memory_bytes(2)]u8 align(core.layout.memory_alignment) = undefined;
    registry.init(&memory, 2);
    // A ring stands in for loop 0, so the message has somewhere real to land.
    var target = try Ring.init(4);
    defer target.deinit();
    registry.set(0, target.descriptor());
    defer registry.clear(0);
    var remote: Remote = undefined;
    try remote.init(&registry, 1);
    defer remote.deinit();

    // A fabricated late answer (decision 10): a timeout entry the kernel answers well after the
    // wait `answer` is given, which is what a `MSG_RING` to a starved target looks like.
    var timespec: linux.kernel_timespec = .{ .sec = 0, .nsec = @intCast(late_answer_ns) };
    remote.ring.get_sqe().?.prep_timeout(&timespec, 0, 0);
    try testing.expectError(error.Unanswered, remote.answer(short_wait_ns));
    try testing.expect(remote.unanswered);

    // Still not there: the post is refused, and nothing was submitted for it.
    const message: core.Message = .{ .payload = 7, .tag = 1 };
    try testing.expectError(error.Unanswered, remote.post(0, message));
    try testing.expect(remote.unanswered);
    _ = try target.enter(null);
    try testing.expectEqual(@as(u32, 0), target.cq_ready());

    // Once the answer is there, the next post drops it and goes through.
    _ = try remote.ring.enter(2 * late_answer_ns);
    try testing.expectEqual(@as(u32, 1), remote.ring.cq_ready());
    try remote.post(0, message);
    try testing.expect(!remote.unanswered);
    try testing.expectEqual(@as(u32, 0), remote.ring.cq_ready());
    _ = try target.enter(null);
    try testing.expectEqual(@as(u32, 1), target.cq_ready());
    try testing.expectEqual(@as(u64, 7), target.cqe_at(0).user_data);
    const expected_result: i32 = @bitCast(@as(u32, 1) | constants.message_result_flag);
    try testing.expectEqual(expected_result, target.cqe_at(0).res);
}
